--- Auto-reload buffers when Claude Code edits files on disk.
--- Uses timer-based polling + event-driven checktime.

local M = {}

M._timer = nil
M._augroup = nil
M._original_updatetime = nil
M._active = false

local POLL_INTERVAL = 1000 -- ms
local ACTIVE_UPDATETIME = 100 -- ms (for faster CursorHold)

--- Start auto-refresh polling and event triggers.
function M.start()
  if M._active then
    return
  end
  M._active = true

  -- Save and reduce updatetime for faster CursorHold
  M._original_updatetime = vim.o.updatetime
  vim.o.updatetime = ACTIVE_UPDATETIME

  -- Timer-based polling
  local utils = require("solomon.utils")
  utils.stop_timer(M._timer)
  M._timer = vim.uv.new_timer()
  M._timer:start(POLL_INTERVAL, POLL_INTERVAL, vim.schedule_wrap(function()
    if not M._active then
      utils.stop_timer(M._timer)
      M._timer = nil
      return
    end
    pcall(vim.cmd, "checktime")
  end))

  -- Event-driven triggers
  M._augroup = vim.api.nvim_create_augroup("solomon_refresh", { clear = true })
  local events = { "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }
  for _, event in ipairs(events) do
    vim.api.nvim_create_autocmd(event, {
      group = M._augroup,
      callback = function()
        pcall(vim.cmd, "checktime")
      end,
    })
  end

  -- Highlight changed lines when a buffer is reloaded from disk
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = M._augroup,
    callback = function()
      M._highlight_changes()
    end,
  })
end

local HIGHLIGHT_NS = vim.api.nvim_create_namespace("solomon_diff_highlight")
local HIGHLIGHT_DURATION = 3000 -- ms

--- Highlight lines that changed in the current buffer after a reload.
function M._highlight_changes()
  local buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(buf)
  if filepath == "" then
    return
  end

  -- Define highlight group (subtle background)
  vim.api.nvim_set_hl(0, "SolomonDiffChange", { link = "DiffChange", default = true })

  -- Get changed lines from git diff
  local diff = vim.fn.system({ "git", "diff", "--no-color", "-U0", "--", filepath })
  if vim.v.shell_error ~= 0 or not diff or diff == "" then
    return
  end

  -- Parse @@ headers to find changed line ranges
  local changed_lines = {}
  for line in diff:gmatch("[^\n]+") do
    local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if start then
      start = tonumber(start)
      count = tonumber(count) or 1
      for i = start, start + count - 1 do
        table.insert(changed_lines, i)
      end
    end
  end

  if #changed_lines == 0 then
    return
  end

  -- Set extmark highlights on changed lines
  vim.api.nvim_buf_clear_namespace(buf, HIGHLIGHT_NS, 0, -1)
  local total_lines = vim.api.nvim_buf_line_count(buf)
  for _, lnum in ipairs(changed_lines) do
    if lnum >= 1 and lnum <= total_lines then
      vim.api.nvim_buf_set_extmark(buf, HIGHLIGHT_NS, lnum - 1, 0, {
        line_hl_group = "SolomonDiffChange",
        priority = 50,
      })
    end
  end

  -- Clear highlights after duration
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, HIGHLIGHT_NS, 0, -1)
    end
  end, HIGHLIGHT_DURATION)
end

--- Stop auto-refresh.
function M.stop()
  if not M._active then
    return
  end
  M._active = false

  -- Stop timer
  require("solomon.utils").stop_timer(M._timer)
  M._timer = nil

  -- Remove autocmds
  if M._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
    M._augroup = nil
  end

  -- Restore updatetime
  if M._original_updatetime then
    vim.o.updatetime = M._original_updatetime
    M._original_updatetime = nil
  end
end

--- Check if refresh is active.
---@return boolean
function M.is_active()
  return M._active
end

return M
