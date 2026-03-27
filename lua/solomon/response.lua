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
---@return solomon.ResponseWindow
function M.open(source)
  if M.current then
    M.close()
  end

  local bottom_hints = " q: close | <C-c>: cancel | ga: apply | gy: yank block "

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
      timer:stop()
      if not timer:is_closing() then timer:close() end
      return
    end
    frame_idx = (frame_idx % #spinner_frames) + 1
    pcall(render_spinner)
  end))

  -- Keymaps
  popup:map("n", "q", function()
    M.close()
  end, { noremap = true, silent = true })

  popup:map("n", "<Esc>", function()
    M.close()
  end, { noremap = true, silent = true })

  popup:map("n", "<C-c>", function()
    M.cancel()
  end, { noremap = true, silent = true })

  -- ga: apply code block — replace original selection
  popup:map("n", "ga", function()
    M.apply_code_block()
  end, { noremap = true, silent = true })

  -- gy: yank code block to clipboard
  popup:map("n", "gy", function()
    M.yank_code_block()
  end, { noremap = true, silent = true })

  -- gd: open diff view of code block vs original
  popup:map("n", "gd", function()
    M.diff_code_block()
  end, { noremap = true, silent = true })

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
    if win._spinner_timer then
      win._spinner_timer:stop()
      if not win._spinner_timer:is_closing() then win._spinner_timer:close() end
      win._spinner_timer = nil
    end
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
  if win._spinner_timer then
    win._spinner_timer:stop()
    if not win._spinner_timer:is_closing() then win._spinner_timer:close() end
    win._spinner_timer = nil
  end
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
    if win.job then
      win.job.cancel()
    end
    win._thinking = false
    if win._spinner_timer then
      win._spinner_timer:stop()
      if not win._spinner_timer:is_closing() then win._spinner_timer:close() end
      win._spinner_timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_id,
      vim.api.nvim_create_augroup("solomon_response_resize", { clear = true }))
    pcall(function()
      win.popup:unmount()
    end)
    M.current = nil
  end
end

--- Find the code block boundaries around the cursor.
---@return {start_line: integer, end_line: integer, lang: string|nil, lines: string[]}|nil
function M._find_code_block_at_cursor()
  local win = M.current
  if not win then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win.popup.winid)
  local cursor_line = cursor[1]

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
      -- Cursor on the fence lines counts too
      if cursor_line >= current_start - 1 and cursor_line <= i then
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

--- Apply the code block under cursor — replace original selection in source buffer.
function M.apply_code_block()
  local win = M.current
  if not win then
    return
  end

  local block = M._find_code_block_at_cursor()
  if not block then
    vim.notify("[solomon] No code block under cursor", vim.log.levels.WARN)
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

  -- Replace the original selection in the source buffer
  vim.api.nvim_buf_set_lines(
    source.bufnr,
    source.start_line - 1,
    source.end_line,
    false,
    block.lines
  )

  -- Update source range for subsequent applies
  source.end_line = source.start_line + #block.lines - 1

  local msg = string.format("[solomon] Applied %d lines to %s:%d", #block.lines, source.filename, source.start_line)

  -- Close response window and focus the source buffer so user sees the change
  M.close()
  vim.api.nvim_set_current_buf(source.bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { source.start_line, 0 })
  vim.notify(msg, vim.log.levels.INFO)
end

--- Yank the code block under cursor to clipboard.
function M.yank_code_block()
  local block = M._find_code_block_at_cursor()
  if not block then
    vim.notify("[solomon] No code block under cursor", vim.log.levels.WARN)
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

  local block = M._find_code_block_at_cursor()
  if not block then
    vim.notify("[solomon] No code block under cursor", vim.log.levels.WARN)
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
