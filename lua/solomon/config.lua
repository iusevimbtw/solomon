---@class solomon.Config
---@field terminal solomon.TerminalConfig
---@field keymaps solomon.KeymapConfig
---@field cli solomon.CliConfig
---@field mcp solomon.MCPConfig

---@class solomon.TerminalConfig
---@field style "float"|"split" Window style
---@field float_opts table Floating window options
---@field split_opts table Split window options
---@field auto_close boolean Close terminal when CLI exits
---@field auto_insert boolean Enter insert mode when opening terminal

---@class solomon.KeymapConfig
---@field send string Keymap for smart send (selection/file/neo-tree)
---@field toggle string Keymap to toggle terminal
---@field ask string Keymap for free-form ask (visual)
---@field explain string Keymap for explain action
---@field improve string Keymap for improve action (refactor + fix + optimize)
---@field task string Keymap for task action (prompt + inline replace)
---@field sessions string Keymap for session picker
---@field continue_session string Keymap for continue last session
---@field diff string Keymap for git diff review
---@field commit string Keymap for generate commit message
---@field blame string Keymap for explain git blame

---@class solomon.CliConfig
---@field cmd string Path to claude binary
---@field model string|nil Model override
---@field args string[] Extra CLI arguments

---@class solomon.MCPConfig
---@field auto_start boolean Start MCP server automatically on setup
---@field enabled boolean Enable MCP server functionality

local M = {}

---@type solomon.Config
M.defaults = {
  terminal = {
    style = "split",
    float_opts = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
    split_opts = {
      position = "right",
      size = 0.4,
    },
    auto_close = true,
    auto_insert = true,
  },
  keymaps = {
    send = "<leader>aa",
    toggle = "<leader>an",
    ask = "<leader>ak",
    explain = "<leader>ae",
    improve = "<leader>ai",
    task = "<leader>at",
    sessions = "<leader>as",
    continue_session = "<leader>ac",
    diff = "<leader>ad",
    commit = "<leader>am",
    blame = "<leader>ab",
  },
  cli = {
    cmd = "claude",
    model = nil,
    args = {},
  },
  mcp = {
    enabled = true,
    auto_start = true,
  },
}

---@type solomon.Config
M.options = {}

---@param opts solomon.Config|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  M.validate()
end

function M.validate()
  local opts = M.options
  assert(
    vim.tbl_contains({ "float", "split" }, opts.terminal.style),
    "[solomon] terminal.style must be 'float' or 'split'"
  )
  assert(type(opts.cli.cmd) == "string", "[solomon] cli.cmd must be a string")
end

return M
