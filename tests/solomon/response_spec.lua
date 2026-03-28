describe("solomon.response", function()
  local response

  before_each(function()
    package.loaded["solomon.response"] = nil
    response = require("solomon.response")
  end)

  describe("_find_code_block", function()
    -- We test the block-finding logic by setting up win.lines manually
    -- and mocking the cursor position

    local function setup_and_find(lines, cursor_line)
      -- Create a minimal mock for the response window
      local mock_win = {
        popup = {
          winid = vim.api.nvim_get_current_win(),
        },
        lines = lines,
        job = nil,
        source = nil,
      }
      response.current = mock_win

      local result = response._find_code_block(cursor_line)

      response.current = nil

      return result
    end

    it("finds code block when cursor is inside", function()
      local lines = {
        "Some text",
        "```lua",
        "local x = 1",
        "return x",
        "```",
        "More text",
      }
      local block = setup_and_find(lines, 3) -- cursor on "local x = 1"
      assert.is_not_nil(block)
      assert.equals(2, #block.lines)
      assert.equals("local x = 1", block.lines[1])
      assert.equals("return x", block.lines[2])
      assert.equals("lua", block.lang)
    end)

    it("finds block when cursor is on opening fence", function()
      local lines = {
        "Text",
        "```python",
        "print('hi')",
        "```",
      }
      local block = setup_and_find(lines, 2) -- cursor on ```python
      assert.is_not_nil(block)
      assert.equals("python", block.lang)
    end)

    it("finds block when cursor is on closing fence", function()
      local lines = {
        "Text",
        "```lua",
        "x = 1",
        "```",
      }
      local block = setup_and_find(lines, 4) -- cursor on closing ```
      assert.is_not_nil(block)
      assert.equals(1, #block.lines)
    end)

    it("returns nil when cursor is outside all blocks", function()
      local lines = {
        "Some text",
        "```lua",
        "code",
        "```",
        "More text",
      }
      local block = setup_and_find(lines, 1) -- cursor on "Some text"
      assert.is_nil(block)
    end)

    it("returns nil when cursor is between blocks", function()
      local lines = {
        "```lua",
        "block1",
        "```",
        "between",
        "```python",
        "block2",
        "```",
      }
      local block = setup_and_find(lines, 4) -- cursor on "between"
      assert.is_nil(block)
    end)

    it("handles indented fences", function()
      local lines = {
        "Text",
        "  ```lua",
        "  local x = 1",
        "  ```",
      }
      local block = setup_and_find(lines, 3)
      assert.is_not_nil(block)
      assert.equals("  local x = 1", block.lines[1])
    end)

    it("finds correct block among multiple", function()
      local lines = {
        "```lua",
        "first",
        "```",
        "text",
        "```python",
        "second",
        "```",
      }
      local block = setup_and_find(lines, 6) -- cursor on "second"
      assert.is_not_nil(block)
      assert.equals("second", block.lines[1])
      assert.equals("python", block.lang)
    end)

    it("handles code block with no language", function()
      local lines = {
        "```",
        "plain code",
        "```",
      }
      local block = setup_and_find(lines, 2)
      assert.is_not_nil(block)
      assert.is_nil(block.lang)
      assert.equals("plain code", block.lines[1])
    end)

    it("returns nil when no current window", function()
      response.current = nil
      local result = response._find_code_block()
      assert.is_nil(result)
    end)
  end)
end)
