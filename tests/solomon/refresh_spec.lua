describe("solomon.refresh", function()
  local refresh

  before_each(function()
    package.loaded["solomon.refresh"] = nil
    package.loaded["solomon.utils"] = nil
    refresh = require("solomon.refresh")
    -- Ensure clean state
    if refresh.is_active() then
      refresh.stop()
    end
  end)

  after_each(function()
    if refresh.is_active() then
      refresh.stop()
    end
  end)

  describe("start", function()
    it("sets active state", function()
      assert.is_false(refresh.is_active())
      refresh.start()
      assert.is_true(refresh.is_active())
    end)

    it("creates a timer", function()
      refresh.start()
      assert.is_not_nil(refresh._timer)
    end)

    it("creates autocmd group", function()
      refresh.start()
      assert.is_not_nil(refresh._augroup)
    end)

    it("reduces updatetime", function()
      local original = vim.o.updatetime
      refresh.start()
      assert.equals(100, vim.o.updatetime)
      refresh.stop()
      assert.equals(original, vim.o.updatetime)
    end)

    it("is idempotent — calling start twice does not double-create", function()
      refresh.start()
      local timer1 = refresh._timer
      local augroup1 = refresh._augroup
      refresh.start() -- second call should be a no-op
      assert.equals(timer1, refresh._timer)
      assert.equals(augroup1, refresh._augroup)
    end)
  end)

  describe("stop", function()
    it("clears active state", function()
      refresh.start()
      assert.is_true(refresh.is_active())
      refresh.stop()
      assert.is_false(refresh.is_active())
    end)

    it("cleans up timer", function()
      refresh.start()
      refresh.stop()
      assert.is_nil(refresh._timer)
    end)

    it("cleans up autocmd group", function()
      refresh.start()
      refresh.stop()
      assert.is_nil(refresh._augroup)
    end)

    it("restores original updatetime", function()
      local original = vim.o.updatetime
      refresh.start()
      assert.are_not.equal(original, vim.o.updatetime)
      refresh.stop()
      assert.equals(original, vim.o.updatetime)
    end)

    it("is safe to call when not active", function()
      assert.has_no_error(function()
        refresh.stop()
      end)
    end)
  end)

  describe("is_active", function()
    it("returns false initially", function()
      assert.is_false(refresh.is_active())
    end)

    it("returns true after start", function()
      refresh.start()
      assert.is_true(refresh.is_active())
    end)

    it("returns false after stop", function()
      refresh.start()
      refresh.stop()
      assert.is_false(refresh.is_active())
    end)
  end)
end)
