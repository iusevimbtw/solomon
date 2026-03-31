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
      current_file = line:match("^diff %-%-git %w/(.-) %w/")
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
--- Checks unstaged changes, then staged changes, then unpushed commits.
function M.start()
  if M._state then
    M.quit()
  end

  -- Try unstaged changes first (includes untracked files)
  local diff = vim.fn.system({ "git", "diff", "-U3", "--no-color" })
  local source = "unstaged"
  local has_unstaged = vim.v.shell_error == 0 and diff and vim.trim(diff) ~= ""

  -- Check for untracked files alongside unstaged changes
  local untracked = M._get_untracked_files()
  local has_untracked = #untracked > 0

  -- If no unstaged changes and no untracked files, try staged
  if not has_unstaged and not has_untracked then
    diff = vim.fn.system({ "git", "diff", "--staged", "-U3", "--no-color" })
    source = "staged"
  end

  -- If no staged, try unpushed commits vs remote
  if source ~= "unstaged" and (vim.v.shell_error ~= 0 or not diff or vim.trim(diff) == "") then
    -- Find the upstream branch
    local upstream = vim.trim(vim.fn.system({ "git", "rev-parse", "--abbrev-ref", "@{u}" }))
    if vim.v.shell_error == 0 and upstream ~= "" then
      diff = vim.fn.system({ "git", "diff", upstream .. "..HEAD", "-U3", "--no-color" })
      source = "unpushed"
    end
  end

  local hunks = {}
  if diff and vim.trim(diff) ~= "" then
    hunks = M._parse_hunks(diff)
  end

  -- Append untracked (new) files as synthetic hunks for unstaged source
  if source == "unstaged" and has_untracked then
    local new_file_hunks = M._make_new_file_hunks(untracked)
    vim.list_extend(hunks, new_file_hunks)
  end

  if #hunks == 0 then
    vim.notify("[solomon] No changes to review (checked unstaged, staged, and unpushed)", vim.log.levels.INFO)
    return
  end

  local new_count = 0
  for _, h in ipairs(hunks) do
    if h.is_new_file then new_count = new_count + 1 end
  end
  local msg = string.format("[solomon] Reviewing %d %s hunks", #hunks, source)
  if new_count > 0 then
    msg = msg .. string.format(" (%d new files)", new_count)
  end
  vim.notify(msg, vim.log.levels.INFO)

  M._state = {
    hunks = hunks,
    current = 1,
    total = #hunks,
    reviewed = 0,
    source = source,
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
    { "y", M.accept, "Yes (accept hunk)" },
    { "n", M.reject, "No (reject hunk)" },
    { "o", M.edit, "Open file at hunk" },
    { "ak", M.ask, "Ask Claude about this hunk" },
    { "s", M.next_hunk, "Skip to next hunk" },
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

  local source_label = hunk.is_new_file and "new file" or M._state.source
  local info_text = string.format(
    " %s [%d/%d] (%s)  y: accept | n: reject | o: open | ak: ask | s: skip | q: quit ",
    hunk.file, M._state.reviewed + 1, M._state.total, source_label
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

  -- Reposition on resize
  local augroup = vim.api.nvim_create_augroup("solomon_review_resize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if not win or not vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        return
      end
      local new_width = math.min(#info_text + 2, vim.o.columns - 4)
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row = vim.o.lines - 3,
        col = math.floor((vim.o.columns - new_width) / 2),
        width = new_width,
        height = 1,
      })
    end,
  })

  M._state.info_buf = buf
  M._state.info_win = win
  M._state.info_augroup = augroup
end

--- Close the info bar.
function M._close_info_bar()
  if not M._state then
    return
  end
  if M._state.info_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._state.info_augroup)
    M._state.info_augroup = nil
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

--- Accept the current hunk.
--- Unstaged: stages the hunk. Staged/unpushed: keeps as-is (already committed/staged).
function M.accept()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  local source = M._state.source
  local action_desc = "Accepted"

  if source == "unstaged" then
    local result
    if hunk.is_new_file then
      -- Stage the entire new file
      result = vim.fn.system({ "git", "add", "--", hunk.file })
    else
      -- Stage the hunk
      result = vim.fn.system({ "git", "apply", "--cached", "-" }, hunk.patch)
    end
    if vim.v.shell_error ~= 0 then
      vim.notify("[solomon] Failed to stage hunk: " .. vim.trim(result), vim.log.levels.ERROR)
      return
    end
    action_desc = "Staged"
  end
  -- For staged and unpushed: accept = keep as-is, just move on

  vim.notify(
    string.format("[solomon] %s hunk %d/%d (%s)", action_desc, M._state.current, #M._state.hunks, hunk.file),
    vim.log.levels.INFO
  )

  M._advance()
end

--- Reject (revert) the current hunk.
--- Unstaged: reverts via git apply -R. Staged: unstages. Unpushed: reverts in working tree.
function M.reject()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  local source = M._state.source
  local result

  if source == "unstaged" then
    if hunk.is_new_file then
      -- Delete the new file
      local ok = vim.fn.delete(hunk.file)
      if ok ~= 0 then
        vim.notify("[solomon] Failed to delete new file: " .. hunk.file, vim.log.levels.ERROR)
        return
      end
    else
      result = vim.fn.system({ "git", "apply", "-R", "-" }, hunk.patch)
    end
  elseif source == "staged" then
    -- Unstage the hunk (remove from index)
    result = vim.fn.system({ "git", "apply", "--cached", "-R", "-" }, hunk.patch)
  elseif source == "unpushed" then
    -- Revert in working tree
    result = vim.fn.system({ "git", "apply", "-R", "-" }, hunk.patch)
  end

  if result and vim.v.shell_error ~= 0 then
    vim.notify("[solomon] Failed to revert hunk: " .. vim.trim(result), vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format("[solomon] Reverted hunk %d/%d (%s)", M._state.current, #M._state.hunks, hunk.file),
    vim.log.levels.INFO
  )

  M._advance()
end

--- Edit — open the file at the hunk location and exit review.
function M.edit()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  local filepath = hunk.file
  local line = hunk.new_start

  M._close_diff_ui()
  M._state = nil

  -- Open the file and jump to the hunk
  vim.cmd.edit(vim.fn.fnameescape(filepath))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
end

--- Ask Claude about the current hunk — opens prompt window with diff as context.
function M.ask()
  if not M._state then
    return
  end

  local hunk = M._state.hunks[M._state.current]
  if not hunk then
    return
  end

  local diff_lines = { hunk.header }
  vim.list_extend(diff_lines, hunk.diff_lines)

  local prompt_mod = require("solomon.prompt")
  prompt_mod.open({
    context_lines = diff_lines,
    filetype = "diff",
    filename = hunk.file,
    start_line = hunk.new_start,
    on_submit = function(user_prompt)
      M._close_diff_ui()
      local diff_text = hunk.header .. "\n" .. table.concat(hunk.diff_lines, "\n")
      local full_prompt = "You are a code assistant responding in a Neovim editor. "
        .. "Answer the question below about this code change. "
        .. "If the question is asking for a modification, provide the updated code in a single code block.\n\n"
        .. "Question: " .. user_prompt .. "\n\n"
        .. "File: " .. hunk.file .. "\n```diff\n" .. diff_text .. "\n```"
      require("solomon.actions")._send_to_claude(full_prompt, nil, { keymaps = {} })
    end,
    on_cancel = function()
      -- Return to the review hunk
      if M._state then
        M._show_current_hunk()
      end
    end,
  })
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

--- Advance to next hunk, or finish if none left.
function M._advance()
  if not M._state then
    return
  end

  -- Remove the current hunk from the list (it's been handled)
  table.remove(M._state.hunks, M._state.current)
  M._state.reviewed = M._state.reviewed + 1

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

--- Get untracked files (new files not yet added to git).
---@return string[]
function M._get_untracked_files()
  local output = vim.fn.system({ "git", "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 or not output or vim.trim(output) == "" then
    return {}
  end
  local files = vim.split(vim.trim(output), "\n", { plain = true })
  -- Filter out empty strings
  return vim.tbl_filter(function(f) return f ~= "" end, files)
end

--- Create synthetic hunks for new (untracked) files.
---@param files string[] List of untracked file paths
---@return solomon.Hunk[]
function M._make_new_file_hunks(files)
  local hunks = {}
  for _, file in ipairs(files) do
    local content = vim.fn.readfile(file)
    if content and #content > 0 then
      local diff_lines = {}
      for _, line in ipairs(content) do
        table.insert(diff_lines, "+" .. line)
      end

      local header = string.format("@@ -0,0 +1,%d @@", #content)
      local patch_lines = {
        "diff --git a/" .. file .. " b/" .. file,
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/" .. file,
        header,
      }
      vim.list_extend(patch_lines, diff_lines)
      table.insert(patch_lines, "") -- trailing newline

      table.insert(hunks, {
        file = file,
        header = header,
        old_start = 0,
        old_count = 0,
        new_start = 1,
        new_count = #content,
        diff_lines = diff_lines,
        patch = table.concat(patch_lines, "\n"),
        is_new_file = true,
      })
    end
  end
  return hunks
end

--- Check if review mode is active.
---@return boolean
function M.is_active()
  return M._state ~= nil
end

return M
