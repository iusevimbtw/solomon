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

  describe("extmark tracking for concurrent inline actions", function()
    local bufnr, track_ns

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
      track_ns = vim.api.nvim_create_namespace("test_track")
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("extmarks shift down when lines are inserted above", function()
      -- Track lines 6-8 (0-indexed: 5-7)
      local mark_start = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 5, 0, {})
      local mark_end = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 7, 0, {})

      -- Insert 2 lines at the top (simulating action A completing above with more lines)
      vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, { "new 1", "new 2", "new 3", "new 4" })

      -- Marks should have shifted down by 2
      local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_start, {})
      local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_end, {})
      assert.equals(7, s[1]) -- was 5, shifted +2
      assert.equals(9, e[1]) -- was 7, shifted +2
    end)

    it("extmarks shift up when lines are deleted above", function()
      -- Track lines 6-8 (0-indexed: 5-7)
      local mark_start = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 5, 0, {})
      local mark_end = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 7, 0, {})

      -- Replace lines 1-3 with just 1 line (delete 2 lines above)
      vim.api.nvim_buf_set_lines(bufnr, 0, 3, false, { "collapsed" })

      -- Marks should have shifted up by 2
      local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_start, {})
      local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_end, {})
      assert.equals(3, s[1]) -- was 5, shifted -2
      assert.equals(5, e[1]) -- was 7, shifted -2
    end)

    it("replacement at tracked range hits correct lines after shift", function()
      -- Track lines 6-8 (0-indexed: 5-7)
      local mark_start = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 5, 0, {})
      local mark_end = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 7, 0, {})

      -- Simulate action A: replace lines 1-3 with 1 line
      vim.api.nvim_buf_set_lines(bufnr, 0, 3, false, { "collapsed" })

      -- Read tracked range
      local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_start, {})
      local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_end, {})

      -- Replace the tracked range (what was lines 6-8)
      vim.api.nvim_buf_set_lines(bufnr, s[1], e[1] + 1, false, { "replaced" })

      -- Verify the replacement went to the right place
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equals("collapsed", lines[1])  -- action A result
      assert.equals("line 4", lines[2])
      assert.equals("line 5", lines[3])
      assert.equals("replaced", lines[4])   -- action B result (was lines 6-8)
      assert.equals("line 9", lines[5])
    end)

    it("extmarks unaffected by changes below them", function()
      -- Track lines 2-4 (0-indexed: 1-3)
      local mark_start = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 1, 0, {})
      local mark_end = vim.api.nvim_buf_set_extmark(bufnr, track_ns, 3, 0, {})

      -- Delete lines 8-10 (below tracked range)
      vim.api.nvim_buf_set_lines(bufnr, 7, 10, false, {})

      -- Marks should not have moved
      local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_start, {})
      local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_end, {})
      assert.equals(1, s[1])
      assert.equals(3, e[1])
    end)
  end)

  describe("cursor adjustment after inline replacement", function()
    local bufnr

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line 1",
        "line 2",
        "line 3",
        "line 4",
        "line 5",
        "line 6",
        "line 7",
        "line 8",
        "line 9",
        "line 10",
      })
      vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("cursor below replacement shifts up when lines are removed", function()
      -- Cursor on line 8
      vim.api.nvim_win_set_cursor(0, { 8, 0 })

      -- Replace lines 2-5 (4 lines) with 2 lines (delta = -2)
      vim.api.nvim_buf_set_lines(bufnr, 1, 5, false, { "new A", "new B" })

      -- Simulate the cursor adjustment logic from _execute_inline
      local cursor = vim.api.nvim_win_get_cursor(0)
      local line_delta = -2 -- 2 lines replaced 4
      local replace_end_1 = 6 -- 1-indexed end of replaced range (was line 5 + 1)
      if cursor[1] > replace_end_1 then
        local new_row = cursor[1] + line_delta
        new_row = math.max(1, math.min(new_row, vim.api.nvim_buf_line_count(bufnr)))
        vim.api.nvim_win_set_cursor(0, { new_row, cursor[2] })
      end

      local final_cursor = vim.api.nvim_win_get_cursor(0)
      -- Was on line 8, 2 lines removed above → should be on line 6
      assert.equals(6, final_cursor[1])
    end)

    it("cursor below insertion is auto-adjusted by Neovim", function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })

      -- Replace lines 2-3 (2 lines) with 4 lines (delta = +2)
      -- Neovim auto-adjusts cursor for net insertions in current buffer
      vim.api.nvim_buf_set_lines(bufnr, 1, 3, false, { "a", "b", "c", "d" })

      local final_cursor = vim.api.nvim_win_get_cursor(0)
      -- Verify cursor tracked the content correctly
      local line = vim.api.nvim_buf_get_lines(bufnr, final_cursor[1] - 1, final_cursor[1], false)[1]
      assert.equals("line 6", line)
    end)

    it("cursor inside replacement is not adjusted", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      -- Replace lines 2-5
      vim.api.nvim_buf_set_lines(bufnr, 1, 5, false, { "new A", "new B" })

      local cursor = vim.api.nvim_win_get_cursor(0)
      local line_delta = -2
      local replace_end_1 = 6
      -- Cursor row 3 is NOT > 6, so no adjustment
      if cursor[1] > replace_end_1 then
        vim.api.nvim_win_set_cursor(0, { cursor[1] + line_delta, cursor[2] })
      end

      local final_cursor = vim.api.nvim_win_get_cursor(0)
      -- Neovim may have clamped to buffer size, but we didn't manually adjust
      -- The key assertion: we did NOT apply the delta
      assert.is_true(final_cursor[1] <= 3)
    end)

    it("cursor above replacement is not adjusted", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Replace lines 5-8
      vim.api.nvim_buf_set_lines(bufnr, 4, 8, false, { "x" })

      local cursor = vim.api.nvim_win_get_cursor(0)
      local replace_end_1 = 9
      if cursor[1] > replace_end_1 then
        vim.api.nvim_win_set_cursor(0, { cursor[1] - 3, cursor[2] })
      end

      local final_cursor = vim.api.nvim_win_get_cursor(0)
      assert.equals(1, final_cursor[1])
    end)

    it("cursor does not go below line 1", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      -- Replace nearly everything
      vim.api.nvim_buf_set_lines(bufnr, 0, 9, false, { "only line" })

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local new_row = math.max(1, math.min(3 - 8, line_count))
      assert.equals(1, new_row)
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

  describe("_build_project_context", function()
    local tmpdir
    local orig_cwd

    before_each(function()
      -- Pre-load solomon.utils before cd-ing away from plugin root
      require("solomon.utils")
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      orig_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(tmpdir))
    end)

    after_each(function()
      vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
      vim.fn.delete(tmpdir, "rf")
    end)

    it("returns formatted CLAUDE.md content when it exists", function()
      local f = io.open(tmpdir .. "/CLAUDE.md", "w")
      f:write("Use tabs. Pure Lua.")
      f:close()

      local ctx = actions._build_project_context()
      assert.truthy(ctx:find("Project conventions"))
      assert.truthy(ctx:find("Use tabs. Pure Lua."))
      assert.truthy(ctx:find("CLAUDE.md"))
    end)

    it("returns empty string when no CLAUDE.md", function()
      local ctx = actions._build_project_context()
      assert.equals("", ctx)
    end)
  end)
end)
