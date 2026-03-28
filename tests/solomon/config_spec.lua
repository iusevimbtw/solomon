describe("solomon.config", function()
  local config

  before_each(function()
    package.loaded["solomon.config"] = nil
    config = require("solomon.config")
  end)

  describe("defaults", function()
    it("has terminal config", function()
      assert.is_not_nil(config.defaults.terminal)
      assert.equals("split", config.defaults.terminal.style)
    end)

    it("has keymap config", function()
      assert.is_not_nil(config.defaults.keymaps)
      assert.equals("<leader>aa", config.defaults.keymaps.toggle)
    end)

    it("has cli config", function()
      assert.is_not_nil(config.defaults.cli)
      assert.equals("claude", config.defaults.cli.cmd)
    end)

    it("has mcp config", function()
      assert.is_not_nil(config.defaults.mcp)
      assert.is_true(config.defaults.mcp.enabled)
      assert.is_true(config.defaults.mcp.auto_start)
    end)
  end)

  describe("setup", function()
    it("uses defaults when no opts provided", function()
      config.setup()
      assert.equals("split", config.options.terminal.style)
      assert.equals("claude", config.options.cli.cmd)
    end)

    it("merges user opts over defaults", function()
      config.setup({
        terminal = { style = "split" },
        cli = { model = "opus" },
      })
      assert.equals("split", config.options.terminal.style)
      assert.equals("opus", config.options.cli.model)
      -- Unset fields keep defaults
      assert.equals("claude", config.options.cli.cmd)
      assert.equals("<leader>aa", config.options.keymaps.toggle)
    end)

    it("deep merges nested tables", function()
      config.setup({
        terminal = { float_opts = { border = "single" } },
      })
      assert.equals("single", config.options.terminal.float_opts.border)
      assert.equals(0.8, config.options.terminal.float_opts.width)
    end)
  end)

  describe("validate", function()
    it("rejects invalid terminal style", function()
      config.setup()
      config.options.terminal.style = "invalid"
      assert.has_error(function()
        config.validate()
      end)
    end)

    it("rejects non-string cli cmd", function()
      config.setup()
      config.options.cli.cmd = 123
      assert.has_error(function()
        config.validate()
      end)
    end)

    it("accepts valid config", function()
      config.setup()
      assert.has_no_error(function()
        config.validate()
      end)
    end)
  end)
end)
