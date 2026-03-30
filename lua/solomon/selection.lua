--- Selection tracking — broadcasts cursor/visual selection to Claude via MCP.
--- Claude Code uses this for getCurrentSelection and getLatestSelection tools.

local M = {}

M._enabled = false
M._augroup = nil
M._debounce_timer = nil
M._demotion_timer = nil
M._latest_selection = nil

local DEBOUNCE_MS = 100
local DEMOTION_MS = 50

--- Enable selection tracking.
function M.enable()
  if M._enabled then
    return
  end
  M._enabled = true
  M._create_autocmds()
end

--- Disable selection tracking.
function M.disable()
  if not M._enabled then
    return
  end
  M._enabled = false

  if M._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
    M._augroup = nil
  end

  local utils = require("solomon.utils")
  utils.stop_timer(M._debounce_timer)
  M._debounce_timer = nil
  utils.stop_timer(M._demotion_timer)
  M._demotion_timer = nil
  M._latest_selection = nil
end

--- Get the latest tracked selection.
---@return table|nil
function M.get_latest()
  return M._latest_selection
end

--- Create autocmds for tracking.
function M._create_autocmds()
  M._augroup = vim.api.nvim_create_augroup("solomon_selection", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = M._augroup,
    callback = function()
      M._debounce_update()
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = M._augroup,
    callback = function()
      M._debounce_update()
    end,
  })

  vim.api.nvim_create_autocmd("TextChanged", {
    group = M._augroup,
    callback = function()
      M._debounce_update()
    end,
  })
end

--- Debounced selection update.
function M._debounce_update()
  local utils = require("solomon.utils")
  utils.stop_timer(M._debounce_timer)

  M._debounce_timer = vim.defer_fn(function()
    M._debounce_timer = nil
    M._update()
  end, DEBOUNCE_MS)
end

--- Update the current selection state.
function M._update()
  if not M._enabled then
    return
  end

  -- Skip Claude terminal buffers
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name:match("^term://") and buf_name:lower():find("claude", 1, true) then
    return
  end

  local mode_info = vim.api.nvim_get_mode()
  local mode = mode_info.mode
  local new_selection

  if mode == "v" or mode == "V" or mode == "\22" then
    -- Cancel any pending demotion
    require("solomon.utils").stop_timer(M._demotion_timer)
    M._demotion_timer = nil

    new_selection = M._get_visual_selection()
  else
    -- Normal mode — check if we just left visual mode
    if M._latest_selection and not M._latest_selection.selection.isEmpty and not M._demotion_timer then
      -- Schedule demotion: keep visual selection briefly in case user switches to Claude terminal
      M._demotion_timer = vim.uv.new_timer()
      M._demotion_timer:start(DEMOTION_MS, 0, vim.schedule_wrap(function()
        require("solomon.utils").stop_timer(M._demotion_timer)
        M._demotion_timer = nil
        -- Check if we're now in Claude terminal — if so, keep the visual selection
        local current_name = vim.api.nvim_buf_get_name(0)
        if current_name:match("^term://") and current_name:lower():find("claude", 1, true) then
          return
        end
        -- Demote to cursor position
        local cursor_sel = M._get_cursor_position()
        if M._has_changed(cursor_sel) then
          M._latest_selection = cursor_sel
          M._broadcast(cursor_sel)
        end
      end))
      return -- Don't update yet, wait for demotion
    end

    new_selection = M._get_cursor_position()
  end

  if not new_selection then
    new_selection = M._get_cursor_position()
  end

  if M._has_changed(new_selection) then
    M._latest_selection = new_selection
    M._broadcast(new_selection)
  end
end

--- Get current visual selection in LSP-compatible format.
---@return table|nil
function M._get_visual_selection()
  local mode = vim.api.nvim_get_mode().mode
  if not (mode == "v" or mode == "V" or mode == "\22") then
    return nil
  end

  local anchor = vim.fn.getpos("v")
  if anchor[2] == 0 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(buf)

  -- Determine start/end (anchor vs cursor could be in either order)
  local start_line = math.min(anchor[2], cursor[1])
  local end_line = math.max(anchor[2], cursor[1])

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")

  local start_col, end_col
  if mode == "V" then
    start_col = 0
    end_col = #lines[#lines]
  else
    if anchor[2] < cursor[1] or (anchor[2] == cursor[1] and anchor[3] <= cursor[2] + 1) then
      start_col = anchor[3] - 1
      end_col = cursor[2] + 1
    else
      start_col = cursor[2]
      end_col = anchor[3]
    end
  end

  return {
    text = text,
    filePath = filepath,
    fileUrl = "file://" .. filepath,
    selection = {
      start = { line = start_line - 1, character = start_col },
      ["end"] = { line = end_line - 1, character = end_col },
      isEmpty = false,
    },
  }
end

--- Get cursor position as an empty selection.
---@return table
function M._get_cursor_position()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local filepath = vim.api.nvim_buf_get_name(0)

  return {
    text = "",
    filePath = filepath,
    fileUrl = "file://" .. filepath,
    selection = {
      start = { line = cursor[1] - 1, character = cursor[2] },
      ["end"] = { line = cursor[1] - 1, character = cursor[2] },
      isEmpty = true,
    },
  }
end

--- Check if selection has changed.
---@param new table
---@return boolean
function M._has_changed(new)
  local old = M._latest_selection
  if not old then
    return true
  end
  if not new then
    return old ~= nil
  end
  if old.filePath ~= new.filePath then
    return true
  end
  if old.text ~= new.text then
    return true
  end
  local os, ns = old.selection, new.selection
  if os.start.line ~= ns.start.line or os.start.character ~= ns.start.character then
    return true
  end
  if os["end"].line ~= ns["end"].line or os["end"].character ~= ns["end"].character then
    return true
  end
  return false
end

--- Broadcast selection change to MCP clients.
---@param sel table
function M._broadcast(sel)
  pcall(function()
    require("solomon.mcp.server").broadcast_notification("selection_changed", sel)
  end)
end

return M
