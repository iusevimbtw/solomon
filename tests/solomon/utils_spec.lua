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

  describe("read_claude_md", function()
    local tmpdir
    local orig_cwd

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      orig_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(tmpdir))
    end)

    after_each(function()
      vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
      vim.fn.delete(tmpdir, "rf")
    end)

    it("reads CLAUDE.md from project root", function()
      local f = io.open(tmpdir .. "/CLAUDE.md", "w")
      f:write("# My Project\n\nUse tabs. No semicolons.")
      f:close()

      local content = utils.read_claude_md()
      assert.is_not_nil(content)
      assert.truthy(content:find("Use tabs"))
      assert.truthy(content:find("No semicolons"))
    end)

    it("reads CLAUDE.md from .claude/ subdirectory", function()
      vim.fn.mkdir(tmpdir .. "/.claude", "p")
      local f = io.open(tmpdir .. "/.claude/CLAUDE.md", "w")
      f:write("nested conventions")
      f:close()

      local content = utils.read_claude_md()
      assert.is_not_nil(content)
      assert.equals("nested conventions", content)
    end)

    it("prefers root CLAUDE.md over .claude/CLAUDE.md", function()
      local f1 = io.open(tmpdir .. "/CLAUDE.md", "w")
      f1:write("root version")
      f1:close()

      vim.fn.mkdir(tmpdir .. "/.claude", "p")
      local f2 = io.open(tmpdir .. "/.claude/CLAUDE.md", "w")
      f2:write("nested version")
      f2:close()

      local content = utils.read_claude_md()
      assert.equals("root version", content)
    end)

    it("returns nil when no CLAUDE.md exists", function()
      local content = utils.read_claude_md()
      assert.is_nil(content)
    end)

    it("returns nil for empty CLAUDE.md", function()
      local f = io.open(tmpdir .. "/CLAUDE.md", "w")
      f:write("")
      f:close()

      local content = utils.read_claude_md()
      assert.is_nil(content)
    end)
  end)

  describe("detect_indent", function()
    it("detects common leading spaces", function()
      local indent = utils.detect_indent({ "    foo", "    bar", "      baz" })
      assert.equals("    ", indent)
    end)

    it("detects tabs", function()
      local indent = utils.detect_indent({ "\tfoo", "\t\tbar" })
      assert.equals("\t", indent)
    end)

    it("skips empty lines", function()
      local indent = utils.detect_indent({ "    foo", "", "    bar" })
      assert.equals("    ", indent)
    end)

    it("returns empty string for no indent", function()
      local indent = utils.detect_indent({ "foo", "bar" })
      assert.equals("", indent)
    end)

    it("returns empty string for empty input", function()
      local indent = utils.detect_indent({})
      assert.equals("", indent)
    end)

    it("returns empty string for all empty lines", function()
      local indent = utils.detect_indent({ "", "", "" })
      assert.equals("", indent)
    end)
  end)

  describe("reindent", function()
    it("adds indentation to unindented code", function()
      local result = utils.reindent({ "local x = 1", "return x" }, "    ")
      assert.equals("    local x = 1", result[1])
      assert.equals("    return x", result[2])
    end)

    it("replaces existing indent with target", function()
      local result = utils.reindent({ "  foo", "    bar" }, "      ")
      assert.equals("      foo", result[1])
      assert.equals("        bar", result[2])
    end)

    it("preserves empty lines", function()
      local result = utils.reindent({ "foo", "", "bar" }, "  ")
      assert.equals("  foo", result[1])
      assert.equals("", result[2])
      assert.equals("  bar", result[3])
    end)

    it("handles no target indent", function()
      local result = utils.reindent({ "    foo", "    bar" }, "")
      assert.equals("foo", result[1])
      assert.equals("bar", result[2])
    end)

    it("preserves relative indentation", function()
      -- Input has 2-space base with 4-space nested
      -- Target is 4 spaces — nested should become 6
      local result = utils.reindent({ "  if true then", "    return 1", "  end" }, "    ")
      assert.equals("    if true then", result[1])
      assert.equals("      return 1", result[2])
      assert.equals("    end", result[3])
    end)
  end)
end)
