local M = {}

function M.check()
  vim.health.start("solomon.nvim")

  -- Check claude CLI
  local config = require("solomon.config").options
  local cmd = config.cli.cmd

  if vim.fn.executable(cmd) == 1 then
    vim.health.ok("Claude CLI found: " .. cmd)

    -- Try to get version
    local result = vim.fn.system({ cmd, "--version" })
    if vim.v.shell_error == 0 then
      vim.health.ok("Claude CLI version: " .. vim.trim(result))
    end
  else
    vim.health.error("Claude CLI not found: " .. cmd, {
      "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
      "Or set cli.cmd in solomon setup to the correct path",
    })
  end

  -- Check Neovim version
  if vim.fn.has("nvim-0.11.0") == 1 then
    vim.health.ok("Neovim >= 0.11.0")
  else
    vim.health.error("Neovim >= 0.11.0 required")
  end

  -- Check required plugins
  local ok_nui = pcall(require, "nui.popup")
  if ok_nui then
    vim.health.ok("nui.nvim found")
  else
    vim.health.warn("nui.nvim not found (required for prompt window)")
  end

  -- Check optional plugins
  local optional = {
    { mod = "snacks", name = "snacks.nvim", purpose = "terminal, picker, notifications" },
    { mod = "lualine", name = "lualine.nvim", purpose = "statusline component" },
    { mod = "which-key", name = "which-key.nvim", purpose = "keymap discovery" },
    { mod = "gitsigns", name = "gitsigns.nvim", purpose = "git hunk context" },
  }

  for _, plugin in ipairs(optional) do
    if pcall(require, plugin.mod) then
      vim.health.ok(plugin.name .. " found (" .. plugin.purpose .. ")")
    else
      vim.health.info(plugin.name .. " not found (optional: " .. plugin.purpose .. ")")
    end
  end

  -- Check MCP server
  local mcp = require("solomon.mcp.server")
  if mcp.is_running() then
    vim.health.ok("MCP server running on port " .. (mcp.get_port() or "?"))
  else
    if config.mcp.enabled then
      vim.health.info("MCP server not running (auto_start: " .. tostring(config.mcp.auto_start) .. ")")
    else
      vim.health.info("MCP server disabled")
    end
  end

  -- Check lock file directory
  local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
  local ide_dir = config_dir .. "/ide"
  if vim.fn.isdirectory(ide_dir) == 1 then
    vim.health.ok("Lock file directory exists: " .. ide_dir)
  else
    vim.health.info("Lock file directory will be created on MCP start: " .. ide_dir)
  end

  -- Check config
  vim.health.ok("Configuration loaded successfully")
end

return M
