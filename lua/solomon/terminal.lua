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

--- Toggle the Claude Code terminal.
function M.toggle()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end
  snacks.terminal.toggle(M.build_cmd(), M.build_opts())
end

--- Open the Claude Code terminal (without toggling).
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end

  local terminal = snacks.terminal.get(M.build_cmd(), vim.tbl_extend("force", M.build_opts(), { create = false }))
  if terminal and terminal:win_valid() then
    terminal:focus()
  else
    snacks.terminal.open(M.build_cmd(), M.build_opts())
  end
end

--- Send text to the Claude terminal's stdin.
---@param terminal table snacks terminal instance
---@param text string
local function send_to_terminal(terminal, text)
  if not terminal or not terminal:buf_valid() then
    return
  end
  local chan = vim.bo[terminal.buf].channel
  if chan and chan > 0 then
    vim.fn.chansend(chan, text)
  end
end

--- Format a selection as context text to paste into Claude.
---@param selection {lines: string[], filepath: string, start_line: integer, filetype: string}
---@return string
function M.format_selection_context(selection)
  local code = table.concat(selection.lines, "\n")
  return string.format("File: %s:%d\n```%s\n%s\n```\n",
    selection.filepath, selection.start_line, selection.filetype, code)
end

--- Get visual selection and format as context text.
---@return string|nil
local function build_selection_context()
  local utils = require("solomon.utils")
  local selection = utils.get_visual_selection()
  if not selection then
    return nil
  end
  return M.format_selection_context(selection)
end

--- Toggle the Claude Code terminal, optionally sending visual selection as context.
---@param with_context boolean|nil
function M.toggle_with_context(with_context)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal support", vim.log.levels.ERROR)
    return
  end

  local context = with_context and build_selection_context() or nil

  local terminal, created = snacks.terminal.get(M.build_cmd(), M.build_opts())
  if created then
    -- New terminal — wait briefly for Claude to start, then send context
    if context and terminal then
      vim.defer_fn(function()
        send_to_terminal(terminal, context)
      end, 500)
    end
  else
    if terminal then
      terminal:toggle()
      -- If we're showing it and have context, send it
      if context and terminal:win_valid() then
        send_to_terminal(terminal, context)
      end
    end
  end
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

return M
