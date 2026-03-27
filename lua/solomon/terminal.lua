local M = {}

--- Build the claude command with configured flags.
---@return string[]
local function build_cmd()
  local config = require("solomon.config").options
  local cmd = { config.cli.cmd }

  if config.cli.model then
    table.insert(cmd, "--model")
    table.insert(cmd, config.cli.model)
  end

  for _, arg in ipairs(config.cli.args) do
    table.insert(cmd, arg)
  end

  return cmd
end

--- Build snacks terminal options from solomon config.
---@return snacks.terminal.Opts
local function build_opts()
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

--- Toggle the Claude Code terminal.
function M.toggle()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end
  snacks.terminal.toggle(build_cmd(), build_opts())
end

--- Open the Claude Code terminal (without toggling).
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end

  local terminal = snacks.terminal.get(build_cmd(), vim.tbl_extend("force", build_opts(), { create = false }))
  if terminal and terminal:win_valid() then
    terminal:focus()
  else
    snacks.terminal.open(build_cmd(), build_opts())
  end
end

--- Close the Claude Code terminal if open.
function M.close()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return
  end

  local terminal = snacks.terminal.get(build_cmd(), vim.tbl_extend("force", build_opts(), { create = false }))
  if terminal and terminal:win_valid() then
    terminal:hide()
  end
end

return M
