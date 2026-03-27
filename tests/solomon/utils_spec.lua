describe("solomon.utils", function()
  local utils

  before_each(function()
    package.loaded["solomon.utils"] = nil
    utils = require("solomon.utils")
  end)

  describe("format_context", function()
    it("formats code with filetype and filename", function()
      local result = utils.format_context({ "local x = 1", "return x" }, "lua", "test.lua", nil)
      assert.truthy(result:find("File: test.lua"))
      assert.truthy(result:find("```lua"))
      assert.truthy(result:find("local x = 1"))
      assert.truthy(result:find("return x"))
      assert.truthy(result:find("```", 1, true))
    end)

    it("includes start_line in header when provided", function()
      local result = utils.format_context({ "x = 1" }, "lua", "test.lua", 42)
      assert.truthy(result:find("File: test.lua:42"))
    end)

    it("omits start_line when nil", function()
      local result = utils.format_context({ "x = 1" }, "lua", "test.lua", nil)
      assert.truthy(result:find("File: test.lua\n"))
    end)

    it("handles empty filetype", function()
      local result = utils.format_context({ "hello" }, "", "file.txt", nil)
      assert.truthy(result:find("```\n"))
    end)

    it("joins multiple lines", function()
      local result = utils.format_context({ "a", "b", "c" }, "lua", "f.lua", nil)
      assert.truthy(result:find("a\nb\nc"))
    end)
  end)
end)
