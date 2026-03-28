describe("solomon.terminal", function()
  local terminal

  before_each(function()
    package.loaded["solomon.terminal"] = nil
    package.loaded["solomon.config"] = nil
    package.loaded["solomon.mcp.sha1"] = nil
    package.loaded["solomon.mcp.transport"] = nil
    require("solomon.config").setup()
    terminal = require("solomon.terminal")
  end)

  describe("format_selection_context", function()
    it("includes filepath and start line", function()
      local selection = {
        lines = { "local x = 1" },
        filepath = "/home/user/project/main.lua",
        start_line = 10,
        filetype = "lua",
      }
      local result = terminal.format_selection_context(selection)
      assert.truthy(result:find("/home/user/project/main.lua:10", 1, true))
    end)

    it("includes filetype in code fence", function()
      local selection = {
        lines = { "const x = 1" },
        filepath = "/project/index.ts",
        start_line = 1,
        filetype = "typescript",
      }
      local result = terminal.format_selection_context(selection)
      assert.truthy(result:find("```typescript"))
    end)

    it("includes all selected lines", function()
      local selection = {
        lines = { "line one", "line two", "line three" },
        filepath = "/project/file.py",
        start_line = 5,
        filetype = "python",
      }
      local result = terminal.format_selection_context(selection)
      assert.truthy(result:find("line one", 1, true))
      assert.truthy(result:find("line two", 1, true))
      assert.truthy(result:find("line three", 1, true))
    end)

    it("joins lines with newlines", function()
      local selection = {
        lines = { "a", "b", "c" },
        filepath = "/f.lua",
        start_line = 1,
        filetype = "lua",
      }
      local result = terminal.format_selection_context(selection)
      assert.truthy(result:find("a\nb\nc", 1, true))
    end)

    it("wraps code in fenced block", function()
      local selection = {
        lines = { "code here" },
        filepath = "/f.go",
        start_line = 1,
        filetype = "go",
      }
      local result = terminal.format_selection_context(selection)
      -- Should start with File: header, then ```go, then code, then ```
      assert.truthy(result:find("^File:"))
      assert.truthy(result:find("```go\n"))
      assert.truthy(result:find("\n```\n"))
    end)

    it("produces correct full format", function()
      local selection = {
        lines = { "func main() {", "  fmt.Println(\"hi\")", "}" },
        filepath = "/home/aiden/project/main.go",
        start_line = 3,
        filetype = "go",
      }
      local result = terminal.format_selection_context(selection)
      local expected = 'File: /home/aiden/project/main.go:3\n```go\nfunc main() {\n  fmt.Println("hi")\n}\n```\n'
      assert.equals(expected, result)
    end)

    it("handles single line selection", function()
      local selection = {
        lines = { "return nil" },
        filepath = "/f.lua",
        start_line = 42,
        filetype = "lua",
      }
      local result = terminal.format_selection_context(selection)
      assert.truthy(result:find("return nil", 1, true))
      assert.truthy(result:find(":42", 1, true))
    end)

    it("handles empty filetype", function()
      local selection = {
        lines = { "plain text" },
        filepath = "/f.txt",
        start_line = 1,
        filetype = "",
      }
      local result = terminal.format_selection_context(selection)
      -- Should have ``` with no language tag
      assert.truthy(result:find("```\n"))
    end)
  end)

  describe("build_cmd", function()
    it("starts with claude command", function()
      local cmd = terminal.build_cmd()
      assert.equals("claude", cmd[1])
    end)

    it("includes extra args", function()
      local cmd = terminal.build_cmd({ "--resume", "abc123" })
      assert.equals("--resume", cmd[2])
      assert.equals("abc123", cmd[3])
    end)

    it("includes model when configured", function()
      require("solomon.config").setup({ cli = { model = "opus" } })
      local cmd = terminal.build_cmd()
      local found = false
      for i, v in ipairs(cmd) do
        if v == "--model" and cmd[i + 1] == "opus" then
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)
end)
