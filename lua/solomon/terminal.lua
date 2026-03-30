local M = {}

--- Build the claude command with configured flags.
---@param extra_args string[]|nil Additional CLI arguments
---@return string[]
function M.build_cmd(extra_args)
  local config = require("solomon.config").options
  local cmd = { config.cli.cmd }

  if extra_args then
    vim.list_extend(cmd, extra_args)
  end

  if config.cli.model then
    table.insert(cmd, "--model")
    table.insert(cmd, config.cli.model)
  end

  -- Tell Claude about the MCP editor tools (built dynamically from handler definitions)
  local tool_summary = ""
  pcall(function()
    local tools = require("solomon.mcp.handlers").get_tool_definitions()
    local parts = {}
    for _, tool in ipairs(tools) do
      table.insert(parts, tool.name .. " (" .. tool.description .. ")")
    end
    tool_summary = table.concat(parts, ", ")
  end)

  if tool_summary ~= "" then
    table.insert(cmd, "--append-system-prompt")
    table.insert(cmd, "You are running inside Neovim with an MCP server providing editor tools. "
      .. "If you cannot fulfill a request with your built-in tools, use the MCP tools proactively: "
      .. tool_summary)
  end

  for _, arg in ipairs(config.cli.args) do
    table.insert(cmd, arg)
  end

  return cmd
end

--- Build snacks terminal options from solomon config.
---@return snacks.terminal.Opts
function M.build_opts()
  local config = require("solomon.config").options
  local tc = config.terminal

  ---@type snacks.win.Config
  local win = {}

  if tc.style == "float" then
    win.position = "float"
    win.width = tc.float_opts.width
    win.height = tc.float_opts.height
    win.border = tc.float_opts.border
  else
    win.position = tc.split_opts.position
    win.width = tc.split_opts.size
    win.height = tc.split_opts.size
  end

  return {
    win = win,
    auto_close = tc.auto_close,
    auto_insert = tc.auto_insert,
    interactive = true,
  }
end

--- Open a new Claude Code terminal. Closes any existing Claude terminals first.
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end
  M.close_all()
  snacks.terminal.open(M.build_cmd(), M.build_opts())
end

--- Focus the existing Claude Code terminal. If none is visible, does nothing.
function M.focus()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find(":/usr/bin/claude") or name:find(":/usr/local/bin/claude") then
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
        return
      end
    end
  end
end

--- Format a selection as context text for display/testing.
---@param selection {lines: string[], filepath: string, start_line: integer, filetype: string}
---@return string
function M.format_selection_context(selection)
  local code = table.concat(selection.lines, "\n")
  return string.format("File: %s:%d\n```%s\n%s\n```\n",
    selection.filepath, selection.start_line, selection.filetype, code)
end

--- Smart send: send context to Claude via MCP @mention.
--- Visual mode: sends selection. Normal mode: sends whole file. Neo-tree: sends file under cursor.
function M.send()
  local utils = require("solomon.utils")
  local server = require("solomon.mcp.server")

  -- Check for neo-tree first
  local neotree_file = utils.get_neotree_file()
  if neotree_file then
    local total_lines = #vim.fn.readfile(neotree_file)
    server.send_at_mention(neotree_file, 1, total_lines)
    vim.notify("[solomon] Sent " .. vim.fn.fnamemodify(neotree_file, ":t") .. " to Claude", vim.log.levels.INFO)
    return
  end

  -- Try visual selection
  local selection = utils.get_visual_selection()
  if selection then
    server.send_at_mention(selection.filepath, selection.start_line, selection.end_line)
    vim.notify(
      string.format("[solomon] Sent %s:%d-%d to Claude", selection.filename, selection.start_line, selection.end_line),
      vim.log.levels.INFO
    )
    return
  end

  -- Normal mode: send entire current file
  local filepath = vim.fn.expand("%:p")
  if filepath == "" then
    vim.notify("[solomon] No file to send", vim.log.levels.WARN)
    return
  end
  local total_lines = vim.api.nvim_buf_line_count(0)
  server.send_at_mention(filepath, 1, total_lines)
  vim.notify("[solomon] Sent " .. vim.fn.expand("%:t") .. " to Claude", vim.log.levels.INFO)
end

--- Close the Claude Code terminal if open.
function M.close()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return
  end

  local terminal = snacks.terminal.get(M.build_cmd(), vim.tbl_extend("force", M.build_opts(), { create = false }))
  if terminal and terminal:win_valid() then
    terminal:hide()
  end
end

--- Close all solomon-related terminals (base, continue, resume).
--- Used before opening a new session to avoid stacking terminals.
function M.close_all()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return
  end

  -- Close all snacks terminals by checking for solomon-related buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find(":/usr/bin/claude") or name:find(":/usr/local/bin/claude") then
        -- Find the window displaying this buffer and close it
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end
    end
  end
end

return M
