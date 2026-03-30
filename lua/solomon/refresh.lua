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
