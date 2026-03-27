describe("solomon.actions", function()
  local actions

  before_each(function()
    package.loaded["solomon.actions"] = nil
    package.loaded["solomon.config"] = nil
    require("solomon.config").setup()
    actions = require("solomon.actions")
  end)

  describe("_extract_code_block", function()
    it("extracts code from fenced block with language", function()
      local text = "Here's the refactored code:\n\n```lua\nlocal x = 1\nreturn x\n```\n\nThis is better."
      local code = actions._extract_code_block(text)
      assert.equals("local x = 1\nreturn x", code)
    end)

    it("extracts code from fenced block without language", function()
      local text = "```\nplain code\n```"
      local code = actions._extract_code_block(text)
      assert.equals("plain code", code)
    end)

    it("extracts only the first code block", function()
      local text = "```lua\nfirst\n```\n\nsome text\n\n```lua\nsecond\n```"
      local code = actions._extract_code_block(text)
      assert.equals("first", code)
    end)

    it("returns nil when no code block present", function()
      local text = "This is just plain text with no code blocks."
      local code = actions._extract_code_block(text)
      assert.is_nil(code)
    end)

    it("handles multiline code blocks", function()
      local text = "```python\ndef foo():\n    return 42\n\nclass Bar:\n    pass\n```"
      local code = actions._extract_code_block(text)
      assert.equals("def foo():\n    return 42\n\nclass Bar:\n    pass", code)
    end)

    it("handles code block with empty lines inside", function()
      local text = "```go\nfunc main() {\n\n\tfmt.Println(\"hi\")\n}\n```"
      local code = actions._extract_code_block(text)
      assert.truthy(code)
      assert.truthy(code:find("fmt.Println", 1, true))
    end)
  end)

  describe("inline thinking indicator", function()
    local bufnr, ns

    before_each(function()
      -- Create a buffer with some code lines
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line 1",
        "line 2",
        "line 3",
        "line 4",
        "line 5",
      })
      ns = vim.api.nvim_create_namespace("solomon_inline_test")
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("creates extmarks with virtual lines above and below selection", function()
      -- Simulate what _execute_inline does: set extmarks on lines 2-4
      local start_line = 2
      local end_line = 4

      vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0, {
        virt_lines = { { { "⠋ Thinking...", "Comment" } } },
        virt_lines_above = true,
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0, {
        virt_lines = { { { "⠋ Thinking...", "Comment" } } },
      })

      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
      assert.equals(2, #extmarks)

      -- First extmark: above selection start
      local above = extmarks[1]
      assert.equals(start_line - 1, above[2]) -- 0-indexed row
      assert.is_true(above[4].virt_lines_above)
      assert.equals("⠋ Thinking...", above[4].virt_lines[1][1][1])
      assert.equals("Comment", above[4].virt_lines[1][1][2])

      -- Second extmark: below selection end
      local below = extmarks[2]
      assert.equals(end_line - 1, below[2])
      assert.is_falsy(below[4].virt_lines_above)
      assert.equals("⠋ Thinking...", below[4].virt_lines[1][1][1])
    end)

    it("clears extmarks from namespace", function()
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
        virt_lines = { { { "⠋ Thinking...", "Comment" } } },
        virt_lines_above = true,
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 0, {
        virt_lines = { { { "⠋ Thinking...", "Comment" } } },
      })

      local before = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      assert.equals(2, #before)

      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      local after = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      assert.equals(0, #after)
    end)

    it("updates extmarks with new spinner frame", function()
      local frames = { "⠋", "⠙", "⠹" }

      for _, frame in ipairs(frames) do
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
          virt_lines = { { { frame .. " Thinking...", "Comment" } } },
          virt_lines_above = true,
        })
      end

      -- After the loop, the last frame should be set
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
      assert.equals(1, #extmarks)
      assert.equals("⠹ Thinking...", extmarks[1][4].virt_lines[1][1][1])
    end)

    it("does not affect the actual buffer lines", function()
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
        virt_lines = { { { "⠋ Thinking...", "Comment" } } },
        virt_lines_above = true,
      })

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equals(5, #lines)
      assert.equals("line 1", lines[1])
      assert.equals("line 5", lines[5])
    end)
  end)

  describe("action definitions", function()
    it("improve action is marked as inline", function()
      assert.is_true(actions.actions.improve.inline)
    end)

    it("explain action is not inline", function()
      assert.is_nil(actions.actions.explain.inline)
    end)

    it("all non-ask actions have prompt templates", function()
      for name, action in pairs(actions.actions) do
        if name ~= "ask" then
          assert.is_string(action.prompt_template, name .. " missing prompt_template")
        end
      end
    end)
  end)
end)
