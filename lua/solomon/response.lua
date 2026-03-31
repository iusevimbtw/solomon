local M = {}

---@class solomon.SourceInfo
---@field bufnr integer Source buffer number
---@field start_line integer Start line of original selection (1-indexed)
---@field end_line integer End line of original selection (1-indexed)
---@field filetype string
---@field filename string

---@class solomon.ResponseWindow
---@field popup table nui.popup instance
---@field buf integer buffer number
---@field lines string[] accumulated lines
---@field job solomon.StreamingJob|nil active streaming job
---@field source solomon.SourceInfo|nil source buffer info for apply

---@type solomon.ResponseWindow|nil
M.current = nil

--- Create and show the response window.
---@param source solomon.SourceInfo|nil
---@param opts {keymaps: table[]|nil}|nil Custom keymaps: list of {key, fn, desc}
---@return solomon.ResponseWindow
function M.open(source, opts)
  opts = opts or {}

  if M.current then
    M.close()
  end

  -- Build bottom hints from keymaps
  local bottom_hints
  if opts.keymaps then
    local parts = { "q/esc: close" }
    for _, km in ipairs(opts.keymaps) do
      table.insert(parts, km[1] .. ": " .. (km[3] or ""))
    end
    bottom_hints = " " .. table.concat(parts, " | ") .. " "
  elseif source then
    bottom_hints = " q/esc: close | a: apply | y: yank | d: diff "
  else
    bottom_hints = " q/esc: close "
  end

  local Popup = require("nui.popup")
  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = " Solomon ",
        top_align = "center",
        bottom = bottom_hints,
        bottom_align = "center",
      },
    },
    relative = "editor",
    position = "50%",
    size = {
      width = "80%",
      height = "70%",
    },
    buf_options = {
      modifiable = true,
      filetype = "markdown",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      wrap = true,
      linebreak = true,
      cursorline = false,
    },
  })

  popup:mount()

  -- Resize and reposition on terminal/screen resize
  local augroup = vim.api.nvim_create_augroup("solomon_response_resize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if not popup.winid or not vim.api.nvim_win_is_valid(popup.winid) then
        vim.api.nvim_del_augroup_by_id(augroup)
        return
      end
      popup:update_layout({
        relative = "editor",
        position = "50%",
        size = {
          width = "80%",
          height = "70%",
        },
      })
    end,
  })

  local win = {
    popup = popup,
    buf = popup.bufnr,
    lines = {},
    job = nil,
    source = source,
    on_close = opts.on_close,
    _thinking = true,
    _spinner_timer = nil,
  }

  M.current = win

  -- Show animated spinner until first token arrives
  local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local frame_idx = 1

  local function render_spinner()
    if not win._thinking or not vim.api.nvim_buf_is_valid(win.buf) then
      return
    end
    local spinner = spinner_frames[frame_idx]
    vim.bo[win.buf].modifiable = true
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, { "", "  " .. spinner .. " Thinking...", "" })
    vim.bo[win.buf].modifiable = false
  end

  render_spinner()

  local timer = vim.uv.new_timer()
  win._spinner_timer = timer
  timer:start(80, 80, vim.schedule_wrap(function()
    if not win._thinking then
      require("solomon.utils").stop_timer(timer)
      return
    end
    frame_idx = (frame_idx % #spinner_frames) + 1
    pcall(render_spinner)
  end))

  -- Always register close keymaps
  popup:map("n", "q", function()
    M.close()
  end, { noremap = true, silent = true })

  popup:map("n", "<Esc>", function()
    M.close()
  end, { noremap = true, silent = true })

  -- Register custom keymaps if provided, otherwise defaults
  if opts.keymaps then
    for _, km in ipairs(opts.keymaps) do
      popup:map("n", km[1], km[2], { noremap = true, silent = true, desc = km[3] })
    end
  elseif source then
    popup:map("n", "a", function()
      M.apply_code_block()
    end, { noremap = true, silent = true })

    popup:map("n", "y", function()
      M.yank_code_block()
    end, { noremap = true, silent = true })

    popup:map("n", "d", function()
      M.diff_code_block()
    end, { noremap = true, silent = true })
  end

  return win
end

--- Append a text token to the response window.
---@param token string
function M.append_token(token)
  local win = M.current
  if not win or not vim.api.nvim_buf_is_valid(win.buf) then
    return
  end

  -- Stop the thinking spinner on first token
  if win._thinking then
    win._thinking = false
    require("solomon.utils").stop_timer(win._spinner_timer)
    win._spinner_timer = nil
  end

  local token_lines = vim.split(token, "\n", { plain = true })

  if #win.lines == 0 then
    win.lines = { "" }
  end

  win.lines[#win.lines] = win.lines[#win.lines] .. token_lines[1]

  for i = 2, #token_lines do
    table.insert(win.lines, token_lines[i])
  end

  vim.bo[win.buf].modifiable = true
  vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, win.lines)
  vim.bo[win.buf].modifiable = false

  local win_id = win.popup.winid
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    local line_count = vim.api.nvim_buf_line_count(win.buf)
    pcall(vim.api.nvim_win_set_cursor, win_id, { line_count, 0 })
  end
end

--- Set the response window title/border text.
---@param text string
function M.set_status(text)
  local win = M.current
  if not win then
    return
  end
  pcall(function()
    win.popup.border:set_text("top", " " .. text .. " ", "center")
  end)
end

--- Show completion info in the border.
---@param result solomon.StreamingResult
function M.show_result_info(result)
  local parts = {}
  if result.model then
    table.insert(parts, result.model)
  end
  if result.duration_ms then
    table.insert(parts, string.format("%.1fs", result.duration_ms / 1000))
  end
  if result.cost_usd then
    table.insert(parts, string.format("$%.4f", result.cost_usd))
  end

  if #parts > 0 then
    M.set_status("Solomon - " .. table.concat(parts, " | "))
  else
    M.set_status("Solomon (done)")
  end
end

--- Cancel the current streaming request.
function M.cancel()
  local win = M.current
  if not win then
    return
  end
  win._thinking = false
  require("solomon.utils").stop_timer(win._spinner_timer)
  win._spinner_timer = nil
  if win.job then
    win.job.cancel()
    win.job = nil
    M.set_status("Solomon (cancelled)")
    vim.notify("[solomon] Request cancelled", vim.log.levels.INFO)
  end
end

--- Close the response window.
function M.close()
  local win = M.current
  if win then
    local on_close = win.on_close
    if win.job then
      win.job.cancel()
    end
    win._thinking = false
    if win._spinner_timer then
      require("solomon.utils").stop_timer(win._spinner_timer)
      win._spinner_timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_id,
      vim.api.nvim_create_augroup("solomon_response_resize", { clear = true }))
    pcall(function()
      win.popup:unmount()
    end)
    M.current = nil
    if on_close then
      on_close()
    end
  end
end

--- Find a code block in the response.
--- If cursor_line is given, finds the block containing that line.
--- If cursor_line is nil, returns the first block found.
---@param cursor_line integer|nil 1-indexed cursor line, or nil for first block
---@return {start_line: integer, end_line: integer, lang: string|nil, lines: string[]}|nil
function M._find_code_block(cursor_line)
  local win = M.current
  if not win then
    return nil
  end

  local in_block = false
  local current_start, current_lang

  for i, line in ipairs(win.lines) do
    local trimmed = line:match("^%s*(.*)")
    if trimmed:match("^```") and not in_block then
      in_block = true
      current_start = i + 1
      current_lang = trimmed:match("^```(%S+)")
    elseif trimmed:match("^```") and in_block then
      in_block = false
      -- If no cursor constraint, return the first block found
      -- If cursor given, check if cursor is within this block (including fence lines)
      if not cursor_line or (cursor_line >= current_start - 1 and cursor_line <= i) then
        local code_lines = {}
        for j = current_start, i - 1 do
          table.insert(code_lines, win.lines[j])
        end
        return {
          start_line = current_start,
          end_line = i - 1,
          lang = current_lang,
          lines = code_lines,
        }
      end
    end
  end

  return nil
end

--- Try cursor-based block first, then fall back to first block.
---@return table|nil
function M._get_best_code_block()
  local win = M.current
  if not win or not win.popup or not win.popup.winid then
    return M._find_code_block(nil)
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win.popup.winid)
  if ok then
    local block = M._find_code_block(cursor[1])
    if block then
      return block
    end
  end
  return M._find_code_block(nil)
end

--- Apply the code block — tries cursor position first, then first block in response.
function M.apply_code_block()
  local win = M.current
  if not win then
    return
  end

  local block = M._get_best_code_block()
  if not block then
    vim.notify("[solomon] No code block found in response", vim.log.levels.WARN)
    return
  end

  local source = win.source
  if not source then
    vim.notify("[solomon] No source buffer context — copying to clipboard instead", vim.log.levels.INFO)
    M.yank_code_block()
    return
  end
  if not vim.api.nvim_buf_is_valid(source.bufnr) then
    vim.notify("[solomon] Source buffer no longer valid — copying to clipboard instead", vim.log.levels.INFO)
    M.yank_code_block()
    return
  end

  -- Match indentation of the original source lines
  local utils = require("solomon.utils")
  local original_lines = vim.api.nvim_buf_get_lines(source.bufnr, source.start_line - 1, source.end_line, false)
  local target_indent = utils.detect_indent(original_lines)
  local reindented = utils.reindent(block.lines, target_indent)

  -- Replace the original selection in the source buffer
  vim.api.nvim_buf_set_lines(
    source.bufnr,
    source.start_line - 1,
    source.end_line,
    false,
    reindented
  )

  -- Update source range for subsequent applies
  source.end_line = source.start_line + #reindented - 1

  local msg = string.format("[solomon] Applied %d lines to %s:%d", #block.lines, source.filename, source.start_line)

  -- Close response window and focus the source buffer so user sees the change
  M.close()
  vim.api.nvim_set_current_buf(source.bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { source.start_line, 0 })
  vim.notify(msg, vim.log.levels.INFO)
end

--- Yank the code block to clipboard — tries cursor position first, then first block.
function M.yank_code_block()
  local block = M._get_best_code_block()
  if not block then
    vim.notify("[solomon] No code block found in response", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", table.concat(block.lines, "\n"))
  vim.notify(
    string.format("[solomon] Copied %d lines (%s) to clipboard", #block.lines, block.lang or "text"),
    vim.log.levels.INFO
  )
end

--- Open a diff view comparing the code block under cursor with the original selection.
function M.diff_code_block()
  local win = M.current
  if not win then
    return
  end

  local block = M._get_best_code_block()
  if not block then
    vim.notify("[solomon] No code block found in response", vim.log.levels.WARN)
    return
  end

  local source = win.source
  if not source or not vim.api.nvim_buf_is_valid(source.bufnr) then
    vim.notify("[solomon] No source buffer to diff against", vim.log.levels.WARN)
    return
  end

  -- Get the original lines from source buffer
  local original_lines = vim.api.nvim_buf_get_lines(
    source.bufnr,
    source.start_line - 1,
    source.end_line,
    false
  )

  -- Close the response window first
  M.close()

  -- Create a vertical split diff view
  -- Left: original (scratch buffer)
  vim.cmd("tabnew")
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[orig_buf].swapfile = false
  vim.bo[orig_buf].filetype = source.filetype
  vim.api.nvim_buf_set_name(orig_buf, "solomon://original")
  vim.cmd("diffthis")

  -- Right: proposed (scratch buffer)
  vim.cmd("vsplit")
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, new_buf)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, block.lines)
  vim.bo[new_buf].buftype = "nofile"
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[new_buf].swapfile = false
  vim.bo[new_buf].filetype = source.filetype
  vim.api.nvim_buf_set_name(new_buf, "solomon://proposed")
  vim.cmd("diffthis")

  -- Keymaps for the diff tab
  local function close_diff()
    vim.cmd("tabclose")
  end

  local function accept_diff()
    -- Apply the proposed lines to the source buffer
    vim.api.nvim_buf_set_lines(
      source.bufnr,
      source.start_line - 1,
      source.end_line,
      false,
      block.lines
    )
    source.end_line = source.start_line + #block.lines - 1
    vim.notify(
      string.format("[solomon] Applied %d lines to %s:%d", #block.lines, source.filename, source.start_line),
      vim.log.levels.INFO
    )
    close_diff()
  end

  -- Buffer-local keymaps on both diff buffers
  for _, buf in ipairs({ orig_buf, new_buf }) do
    vim.keymap.set("n", "q", close_diff, { buffer = buf, desc = "Close diff" })
    vim.keymap.set("n", "<CR>", accept_diff, { buffer = buf, desc = "Accept changes" })
    vim.keymap.set("n", "<Esc>", close_diff, { buffer = buf, desc = "Close diff" })
  end
end

return M
