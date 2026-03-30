--- Interactive git diff review mode.
--- Review each hunk: accept (stage), reject (revert), or ask Claude about it.

local M = {}

---@class solomon.Hunk
---@field file string File path (relative)
---@field header string The @@ line
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field diff_lines string[] The actual diff content lines (with +/- prefixes)
---@field patch string Full patch text for this hunk (ready for git apply)

---@class solomon.ReviewState
---@field hunks solomon.Hunk[]
---@field current integer Current hunk index (1-indexed)
---@field orig_buf integer|nil Original buffer for the old content
---@field new_buf integer|nil Buffer for the new content
---@field orig_win integer|nil Window for old content
---@field new_win integer|nil Window for new content
---@field info_buf integer|nil Floating info bar buffer
---@field info_win integer|nil Floating info bar window

---@type solomon.ReviewState|nil
M._state = nil

--- Parse git diff output into individual hunks.
---@param diff_text string Raw git diff output
---@return solomon.Hunk[]
function M._parse_hunks(diff_text)
  local hunks = {}
  local lines = vim.split(diff_text, "\n", { plain = true })

  local current_file = nil
  local current_header_lines = {} -- diff --git, index, ---, +++ lines for current file
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Track file header
    if line:match("^diff %-%-git") then
      current_file = line:match("^diff %-%-git a/(.-) b/")
      current_header_lines = { line }
    elseif line:match("^index ") or line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
      table.insert(current_header_lines, line)
    elseif line:match("^@@") and current_file then
      -- Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
      local old_start, old_count, new_start, new_count =
        line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

      if old_start then
        old_start = tonumber(old_start)
        old_count = tonumber(old_count) or 1
        new_start = tonumber(new_start)
        new_count = tonumber(new_count) or 1

        -- Collect diff lines until next hunk or file
        local diff_lines = {}
        local j = i + 1
        while j <= #lines do
          local dl = lines[j]
          if dl:match("^@@") or dl:match("^diff %-%-git") then
            break
          end
          table.insert(diff_lines, dl)
          j = j + 1
        end

        -- Build patch text for this hunk
        local patch_lines = {}
        for _, hl in ipairs(current_header_lines) do
          table.insert(patch_lines, hl)
        end
        table.insert(patch_lines, line) -- the @@ header
        for _, dl in ipairs(diff_lines) do
          table.insert(patch_lines, dl)
        end
        table.insert(patch_lines, "") -- trailing newline

        table.insert(hunks, {
          file = current_file,
          header = line,
          old_start = old_start,
          old_count = old_count,
          new_start = new_start,
          new_count = new_count,
          diff_lines = diff_lines,
          patch = table.concat(patch_lines, "\n"),
        })

        i = j - 1 -- will be incremented by the loop
      end
    end

    i = i + 1
  end

  return hunks
end

--- Extract old and new content from a hunk's diff lines.
---@param hunk solomon.Hunk
---@return string[] old_lines
---@return string[] new_lines
function M._extract_content(hunk)
  local old_lines = {}
  local new_lines = {}

  for _, line in ipairs(hunk.diff_lines) do
    if line:sub(1, 1) == "-" then
      table.insert(old_lines, line:sub(2))
    elseif line:sub(1, 1) == "+" then
      table.insert(new_lines, line:sub(2))
    elseif line:sub(1, 1) == " " then
      table.insert(old_lines, line:sub(2))
      table.insert(new_lines, line:sub(2))
    else
      -- Context line without prefix (empty lines in some diff formats)
      table.insert(old_lines, line)
      table.insert(new_lines, line)
    end
  end

  return old_lines, new_lines
end

--- Start interactive review mode.
function M.start()
  if M._state then
    M.quit()
  end

  -- Get unstaged diff
  local diff = vim.fn.system({ "git", "diff", "-U3", "--no-color" })
  if vim.v.shell_error ~= 0 or not diff or diff == "" then
    vim.notify("[solomon] No unstaged changes to review", vim.log.levels.INFO)
    return
  end

  local hunks = M._parse_hunks(diff)
  if #hunks == 0 then
    vim.notify("[solomon] No hunks found in diff", vim.log.levels.INFO)
    return
  end

  M._state = {
    hunks = hunks,
    current = 1,
    orig_buf = nil,
    new_buf = nil,
    orig_win = nil,
    new_win = nil,
    info_buf = nil,
    info_win = nil,
  }

  M._show_current_hunk()
end

--- Show the current hunk in a diff view.
function M._show_current_hunk()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    M.quit()
    return
  end

  -- Clean up previous diff buffers
  M._close_diff_ui()

  local old_lines, new_lines = M._extract_content(hunk)
  local ft = vim.filetype.match({ filename = hunk.file }) or ""

  -- Create the diff view in a new tab
  vim.cmd.tabnew()

  -- Left: old content
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, old_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[orig_buf].swapfile = false
  vim.bo[orig_buf].filetype = ft
  vim.api.nvim_buf_set_name(orig_buf, "solomon://review/old/" .. hunk.file)
  vim.cmd.diffthis()
  M._state.orig_buf = orig_buf
  M._state.orig_win = vim.api.nvim_get_current_win()

  -- Right: new content
  vim.cmd.vsplit()
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, new_buf)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, new_lines)
  vim.bo[new_buf].buftype = "nofile"
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[new_buf].swapfile = false
  vim.bo[new_buf].filetype = ft
  vim.api.nvim_buf_set_name(new_buf, "solomon://review/new/" .. hunk.file)
  vim.cmd.diffthis()
  M._state.new_buf = new_buf
  M._state.new_win = vim.api.nvim_get_current_win()

  -- Set keymaps on both buffers
  local keymaps = {
    { "a", M.accept, "Accept (stage hunk)" },
    { "x", M.reject, "Reject (revert hunk)" },
    { "?", M.ask, "Ask Claude about this hunk" },
    { "n", M.next_hunk, "Next hunk" },
    { "p", M.prev_hunk, "Previous hunk" },
    { "q", M.quit, "Quit review" },
  }

  for _, buf in ipairs({ orig_buf, new_buf }) do
    for _, km in ipairs(keymaps) do
      vim.keymap.set("n", km[1], km[2], { buffer = buf, desc = km[3] })
    end
  end

  -- Show info bar
  M._show_info_bar(hunk)
end

--- Show a floating info bar with hunk details and keybind hints.
---@param hunk solomon.Hunk
function M._show_info_bar(hunk)
  M._close_info_bar()

  local total = #M._state.hunks
  local current = M._state.current
  local info_text = string.format(
    " %s [%d/%d]  a: accept | x: reject | ?: ask | n: next | p: prev | q: quit ",
    hunk.file, current, total
  )

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { info_text })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(#info_text + 2, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = vim.o.lines - 3,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
  })

  vim.api.nvim_set_option_value("winhl", "Normal:Comment,FloatBorder:Comment", { win = win })

  M._state.info_buf = buf
  M._state.info_win = win
end

--- Close the info bar.
function M._close_info_bar()
  if not M._state then
    return
  end
  if M._state.info_win and vim.api.nvim_win_is_valid(M._state.info_win) then
    vim.api.nvim_win_close(M._state.info_win, true)
  end
  M._state.info_win = nil
  M._state.info_buf = nil
end

--- Close the diff UI (buffers and windows) without ending review.
function M._close_diff_ui()
  if not M._state then
    return
  end

  M._close_info_bar()

  -- Close the tab if we created one
  pcall(function()
    -- Find and close tabs with our review buffers
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if name:find("^solomon://review/") then
          vim.api.nvim_set_current_tabpage(tab)
          vim.cmd.tabclose()
          break
        end
      end
    end
  end)

  M._state.orig_buf = nil
  M._state.new_buf = nil
  M._state.orig_win = nil
  M._state.new_win = nil
end

--- Accept (stage) the current hunk.
function M.accept()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  -- Stage the hunk using git apply --cached
  local result = vim.fn.system({ "git", "apply", "--cached", "-" }, hunk.patch)
  if vim.v.shell_error ~= 0 then
    vim.notify("[solomon] Failed to stage hunk: " .. vim.trim(result), vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format("[solomon] Staged hunk %d/%d (%s)", M._state.current, #M._state.hunks, hunk.file),
    vim.log.levels.INFO
  )

  M._advance()
end

--- Reject (revert) the current hunk.
function M.reject()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  -- Revert the hunk using git apply -R
  local result = vim.fn.system({ "git", "apply", "-R", "-" }, hunk.patch)
  if vim.v.shell_error ~= 0 then
    vim.notify("[solomon] Failed to revert hunk: " .. vim.trim(result), vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format("[solomon] Reverted hunk %d/%d (%s)", M._state.current, #M._state.hunks, hunk.file),
    vim.log.levels.INFO
  )

  M._advance()
end

--- Ask Claude about the current hunk.
function M.ask()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  -- Build the diff text for the prompt
  local diff_text = hunk.header .. "\n" .. table.concat(hunk.diff_lines, "\n")
  local prompt = "Explain this code change. What does it do and why?\n\n"
    .. "File: " .. hunk.file .. "\n```diff\n" .. diff_text .. "\n```"

  -- Close the diff UI temporarily to show the response
  M._close_diff_ui()

  -- Send to Claude via the response popup
  require("solomon.actions")._send_to_claude(prompt, nil)

  -- Note: after user closes the response window, they can press <leader>aR
  -- to re-enter review mode (it will re-parse the diff from the current state)
end

--- Move to the next hunk.
function M.next_hunk()
  if not M._state then
    return
  end
  if M._state.current < #M._state.hunks then
    M._state.current = M._state.current + 1
    M._show_current_hunk()
  else
    vim.notify("[solomon] Last hunk — press 'a' to accept, 'x' to reject, or 'q' to quit", vim.log.levels.INFO)
  end
end

--- Move to the previous hunk.
function M.prev_hunk()
  if not M._state then
    return
  end
  if M._state.current > 1 then
    M._state.current = M._state.current - 1
    M._show_current_hunk()
  else
    vim.notify("[solomon] First hunk", vim.log.levels.INFO)
  end
end

--- Advance to next hunk, or finish if none left.
function M._advance()
  if not M._state then
    return
  end

  -- Remove the current hunk from the list (it's been handled)
  table.remove(M._state.hunks, M._state.current)

  if #M._state.hunks == 0 then
    vim.notify("[solomon] Review complete — all hunks reviewed", vim.log.levels.INFO)
    M.quit()
    return
  end

  -- Adjust index if we were at the end
  if M._state.current > #M._state.hunks then
    M._state.current = #M._state.hunks
  end

  M._show_current_hunk()
end

--- Quit review mode.
function M.quit()
  if not M._state then
    return
  end

  M._close_diff_ui()
  M._state = nil
end

--- Check if review mode is active.
---@return boolean
function M.is_active()
  return M._state ~= nil
end

return M
