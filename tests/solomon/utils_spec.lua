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

  describe("format_context with surrounding", function()
    it("includes markers and surrounding lines", function()
      local lines = { "return x + y" }
      local surrounding = {
        above = { "function add(x, y)" },
        below = { "end" },
      }
      local result = utils.format_context(lines, "lua", "math.lua", 2, surrounding)
      assert.truthy(result:find("SELECTED CODE"))
      assert.truthy(result:find("END SELECTED CODE"))
      assert.truthy(result:find("function add"))
      assert.truthy(result:find("return x + y", 1, true))
      assert.truthy(result:find("end", 1, true))
      assert.truthy(result:find("do not modify it"))
    end)

    it("works with only above context", function()
      local lines = { "last_line()" }
      local surrounding = { above = { "first_line()", "middle()" }, below = {} }
      local result = utils.format_context(lines, "lua", "f.lua", 3, surrounding)
      assert.truthy(result:find("SELECTED CODE"))
      assert.truthy(result:find("first_line"))
      assert.truthy(result:find("last_line"))
    end)

    it("works with only below context", function()
      local lines = { "top()" }
      local surrounding = { above = {}, below = { "bottom()" } }
      local result = utils.format_context(lines, "lua", "f.lua", 1, surrounding)
      assert.truthy(result:find("SELECTED CODE"))
      assert.truthy(result:find("bottom"))
    end)

    it("falls back to plain format when no surrounding", function()
      local result = utils.format_context({ "code" }, "lua", "f.lua", 1, nil)
      assert.is_falsy(result:find("SELECTED CODE"))
      assert.truthy(result:find("```lua"))
    end)

    it("falls back to plain format when surrounding is empty", function()
      local result = utils.format_context({ "code" }, "lua", "f.lua", 1, { above = {}, below = {} })
      assert.is_falsy(result:find("SELECTED CODE"))
    end)
  end)

  describe("get_surrounding_context", function()
    local bufnr

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line 1",   -- 1
        "line 2",   -- 2
        "line 3",   -- 3
        "line 4",   -- 4
        "line 5",   -- 5
        "line 6",   -- 6
        "line 7",   -- 7
        "line 8",   -- 8
        "line 9",   -- 9
        "line 10",  -- 10
      })
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("returns lines above and below selection with fallback padding", function()
      -- Select lines 5-6, no treesitter → 15-line fallback (clamped to buffer)
      local ctx = utils.get_surrounding_context(bufnr, 5, 6)
      assert.is_true(#ctx.above > 0)
      assert.is_true(#ctx.below > 0)
      -- Above should be lines 1-4
      assert.equals(4, #ctx.above)
      assert.equals("line 1", ctx.above[1])
      -- Below should be lines 7-10
      assert.equals(4, #ctx.below)
      assert.equals("line 10", ctx.below[4])
    end)

    it("clamps to buffer start", function()
      local ctx = utils.get_surrounding_context(bufnr, 1, 2)
      assert.equals(0, #ctx.above)
      assert.is_true(#ctx.below > 0)
    end)

    it("clamps to buffer end", function()
      local ctx = utils.get_surrounding_context(bufnr, 9, 10)
      assert.is_true(#ctx.above > 0)
      assert.equals(0, #ctx.below)
    end)

    it("returns empty when selection covers entire buffer", function()
      local ctx = utils.get_surrounding_context(bufnr, 1, 10)
      assert.equals(0, #ctx.above)
      assert.equals(0, #ctx.below)
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

  describe("stop_timer", function()
    it("stops and closes a running timer", function()
      local timer = vim.uv.new_timer()
      local called = false
      timer:start(1000, 0, function() called = true end)

      utils.stop_timer(timer)

      assert.is_true(timer:is_closing())
      -- Timer should not fire
      vim.wait(50, function() return false end)
      assert.is_false(called)
    end)

    it("handles nil timer gracefully", function()
      assert.has_no_error(function()
        utils.stop_timer(nil)
      end)
    end)
  end)

  describe("get_diagnostics_for_range", function()
    it("returns nil when no diagnostics", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local result = utils.get_diagnostics_for_range(buf, 1, 10)
      assert.is_nil(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("formats diagnostics as text", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3" })

      -- Set a diagnostic on line 2
      vim.diagnostic.set(vim.api.nvim_create_namespace("test_diag"), buf, {
        { lnum = 1, col = 0, message = "test error", severity = vim.diagnostic.severity.ERROR },
      })

      local result = utils.get_diagnostics_for_range(buf, 1, 3)
      assert.is_string(result)
      assert.truthy(result:find("test error", 1, true))
      assert.truthy(result:find("error"))
      assert.truthy(result:find("Line 2"))

      vim.diagnostic.reset(nil, buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("filters to line range", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d", "e" })

      local ns = vim.api.nvim_create_namespace("test_diag2")
      vim.diagnostic.set(ns, buf, {
        { lnum = 0, col = 0, message = "line 1 issue", severity = vim.diagnostic.severity.WARN },
        { lnum = 3, col = 0, message = "line 4 issue", severity = vim.diagnostic.severity.ERROR },
      })

      -- Only request lines 3-5, should only get the line 4 diagnostic
      local result = utils.get_diagnostics_for_range(buf, 3, 5)
      assert.is_string(result)
      assert.truthy(result:find("line 4 issue", 1, true))
      assert.is_falsy(result:find("line 1 issue", 1, true))

      vim.diagnostic.reset(ns, buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
