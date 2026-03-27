--- Git integration — review, commit messages, blame context.

local M = {}

--- Run a git command and return stdout.
---@param args string[]
---@return string|nil output
---@return string|nil error
function M._git(args)
  local cmd = vim.list_extend({ "git" }, args)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(result)
  end
  return vim.trim(result), nil
end

--- Check if we're inside a git repo.
---@return boolean
function M.is_git_repo()
  local _, err = M._git({ "rev-parse", "--is-inside-work-tree" })
  return err == nil
end

--- Send the current git diff to Claude for code review.
---@param opts {staged: boolean|nil}|nil
function M.review(opts)
  opts = opts or {}

  if not M.is_git_repo() then
    vim.notify("[solomon] Not a git repository", vim.log.levels.WARN)
    return
  end

  local diff_args = { "diff" }
  local label = "unstaged changes"
  if opts.staged then
    table.insert(diff_args, "--staged")
    label = "staged changes"
  end

  local diff, err = M._git(diff_args)
  if err then
    vim.notify("[solomon] git diff failed: " .. err, vim.log.levels.ERROR)
    return
  end

  if not diff or diff == "" then
    vim.notify("[solomon] No " .. label .. " to review", vim.log.levels.INFO)
    return
  end

  local prompt = string.format(
    "Review the following git diff (%s). Point out any bugs, issues, or improvements. "
      .. "Be concise and focus on what matters.\n\n```diff\n%s\n```",
    label,
    diff
  )

  require("solomon.actions")._send_to_claude(prompt, nil)
end

--- Generate a commit message from staged changes.
function M.commit()
  if not M.is_git_repo() then
    vim.notify("[solomon] Not a git repository", vim.log.levels.WARN)
    return
  end

  local diff, err = M._git({ "diff", "--staged" })
  if err then
    vim.notify("[solomon] git diff --staged failed: " .. err, vim.log.levels.ERROR)
    return
  end

  if not diff or diff == "" then
    vim.notify("[solomon] No staged changes", vim.log.levels.INFO)
    return
  end

  -- Get recent commit messages for style reference
  local log, _ = M._git({ "log", "--oneline", "-10", "--no-decorate" })

  local prompt = "Generate a concise git commit message for these staged changes. "
    .. "Follow conventional commit format if appropriate. "
    .. "Return ONLY the commit message, nothing else.\n\n"

  if log and log ~= "" then
    prompt = prompt .. "Recent commits for style reference:\n```\n" .. log .. "\n```\n\n"
  end

  prompt = prompt .. "Staged diff:\n```diff\n" .. diff .. "\n```"

  require("solomon.actions")._send_to_claude(prompt, nil)
end

--- Explain the git blame for the current line or visual selection.
function M.blame()
  if not M.is_git_repo() then
    vim.notify("[solomon] Not a git repository", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("[solomon] No file open", vim.log.levels.WARN)
    return
  end

  -- Get visual selection range or current line
  local start_line, end_line
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    start_line = vim.fn.getpos("'<")[2]
    end_line = vim.fn.getpos("'>")[2]
  else
    start_line = vim.fn.line(".")
    end_line = start_line
  end

  local blame, err = M._git({
    "blame",
    "-L",
    start_line .. "," .. end_line,
    "--porcelain",
    file,
  })

  if err then
    vim.notify("[solomon] git blame failed: " .. err, vim.log.levels.ERROR)
    return
  end

  -- Also get the code lines for context
  local code_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local filetype = vim.bo.filetype
  local filename = vim.fn.expand("%:t")

  local prompt = string.format(
    "Explain the git history for these lines. Who changed what and why? "
      .. "Be concise.\n\nFile: %s:%d-%d\n```%s\n%s\n```\n\nGit blame (porcelain):\n```\n%s\n```",
    filename,
    start_line,
    end_line,
    filetype,
    table.concat(code_lines, "\n"),
    blame or ""
  )

  require("solomon.actions")._send_to_claude(prompt, nil)
end

--- Get git hunk context for the current line using gitsigns.nvim.
---@return string|nil hunk_diff
function M.get_hunk_context()
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return nil
  end

  -- gitsigns provides blame/hunk info via its API
  local hunk = nil
  pcall(function()
    local hunks = gitsigns.get_hunks()
    if hunks then
      local cursor_line = vim.fn.line(".")
      for _, h in ipairs(hunks) do
        if cursor_line >= h.added.start and cursor_line < h.added.start + h.added.count then
          hunk = h
          break
        end
      end
    end
  end)

  if not hunk then
    return nil
  end

  -- Format the hunk as a diff
  local lines = {}
  for _, l in ipairs(hunk.removed.lines or {}) do
    table.insert(lines, "-" .. l)
  end
  for _, l in ipairs(hunk.added.lines or {}) do
    table.insert(lines, "+" .. l)
  end

  return table.concat(lines, "\n")
end

--- Review just the current git hunk (from gitsigns).
function M.review_hunk()
  local hunk = M.get_hunk_context()
  if not hunk then
    -- Fallback: try to get the diff for just this file
    local file = vim.fn.expand("%:.")
    if file == "" then
      vim.notify("[solomon] No file open", vim.log.levels.WARN)
      return
    end

    local diff, err = M._git({ "diff", "--", file })
    if err or not diff or diff == "" then
      vim.notify("[solomon] No changes in current file", vim.log.levels.INFO)
      return
    end

    hunk = diff
  end

  local prompt = "Review this change. Point out any bugs or issues. Be concise.\n\n```diff\n" .. hunk .. "\n```"

  require("solomon.actions")._send_to_claude(prompt, nil)
end

return M
