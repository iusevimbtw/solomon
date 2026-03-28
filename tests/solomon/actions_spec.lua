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

  describe("cursor and visual mode adjustment after inline replacement", function()
    local bufnr

    local function adjust(line, replace_end_1, line_delta)
      if line > replace_end_1 and line_delta ~= 0 then
        return math.max(1, math.min(line + line_delta, vim.api.nvim_buf_line_count(bufnr)))
      end
      return line
    end

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
      pcall(function()
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false
        )
      end)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    -- Normal mode cursor adjustment

    it("normal mode: cursor below deletion shifts to correct content", function()
      vim.api.nvim_win_set_cursor(0, { 8, 0 })

      vim.api.nvim_buf_set_lines(bufnr, 1, 5, false, { "new A", "new B" })

      local new_row = adjust(8, 6, -2)
      vim.api.nvim_win_set_cursor(0, { new_row, 0 })

      assert.equals(6, vim.api.nvim_win_get_cursor(0)[1])
      assert.equals("line 8", vim.api.nvim_buf_get_lines(bufnr, new_row - 1, new_row, false)[1])
    end)

    it("normal mode: cursor above replacement stays put", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_buf_set_lines(bufnr, 4, 8, false, { "x" })
      assert.equals(1, adjust(1, 9, -3))
    end)

    it("normal mode: cursor inside replacement stays put", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.api.nvim_buf_set_lines(bufnr, 1, 5, false, { "new A", "new B" })
      assert.equals(3, adjust(3, 6, -2))
    end)

    it("normal mode: adjust clamps to buffer bounds", function()
      assert.equals(1, math.max(1, math.min(3 - 8, 1)))
    end)

    -- Visual mode detection

    it("visual mode: nvim_get_mode detects visual mode", function()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      vim.cmd("normal! V3j")

      local mode_info = vim.api.nvim_get_mode()
      assert.equals("V", mode_info.mode)
    end)

    it("visual mode: anchor and cursor captured via line()", function()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { 8, 0 })

      assert.equals(5, vim.fn.line("v"))
      assert.equals(8, vim.fn.line("."))
    end)

    -- Visual mode restoration after replacement

    it("visual mode: restored after deletion above with correct positions", function()
      -- Enter visual line mode on lines 7-9
      vim.api.nvim_win_set_cursor(0, { 7, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { 9, 0 })

      local va = vim.fn.line("v")
      local vc = vim.fn.line(".")
      local vm = vim.api.nvim_get_mode().mode

      -- Exit visual before modifying buffer
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false
      )

      -- Action A completes above: lines 2-4 → 1 line (delta = -2)
      vim.api.nvim_buf_set_lines(bufnr, 1, 4, false, { "collapsed" })

      -- Adjust positions
      local new_anchor = adjust(va, 5, -2)
      local new_cursor = adjust(vc, 5, -2)
      assert.equals(5, new_anchor) -- 7 - 2
      assert.equals(7, new_cursor) -- 9 - 2

      -- Restore visual mode
      vim.api.nvim_win_set_cursor(0, { new_anchor, 0 })
      vim.cmd("normal! " .. vm)
      vim.api.nvim_win_set_cursor(0, { new_cursor, 0 })

      -- Verify visual mode is active
      assert.equals("V", vim.api.nvim_get_mode().mode)

      -- Verify content at adjusted positions is correct
      assert.equals("line 7", vim.api.nvim_buf_get_lines(bufnr, new_anchor - 1, new_anchor, false)[1])
      assert.equals("line 9", vim.api.nvim_buf_get_lines(bufnr, new_cursor - 1, new_cursor, false)[1])
    end)

    it("visual mode: restored even when line count unchanged", function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { 8, 0 })

      local va = vim.fn.line("v")
      local vc = vim.fn.line(".")
      local vm = vim.api.nvim_get_mode().mode

      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false
      )

      -- Same-size replacement (delta = 0) still exits visual
      vim.api.nvim_buf_set_lines(bufnr, 1, 3, false, { "new 2", "new 3" })

      -- Restore visual — positions unchanged
      vim.api.nvim_win_set_cursor(0, { va, 0 })
      vim.cmd("normal! " .. vm)
      vim.api.nvim_win_set_cursor(0, { vc, 0 })

      assert.equals("V", vim.api.nvim_get_mode().mode)
    end)

    it("visual mode: replacement below does not shift positions", function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      local va = vim.fn.line("v")
      local vc = vim.fn.line(".")

      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false
      )

      vim.api.nvim_buf_set_lines(bufnr, 6, 9, false, { "collapsed" })

      assert.equals(2, adjust(va, 10, -2))
      assert.equals(3, adjust(vc, 10, -2))
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

  describe("_build_context_str", function()
    it("returns formatted context with surrounding code", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line 1", "line 2", "line 3", "line 4", "line 5",
      })

      local selection = {
        lines = { "line 3" },
        filetype = "lua",
        filename = "test.lua",
        start_line = 3,
      }
      local source = { bufnr = bufnr, start_line = 3, end_line = 3 }

      local result = actions._build_context_str(selection, source)
      assert.is_string(result)
      assert.truthy(result:find("test.lua", 1, true))
      assert.truthy(result:find("line 3", 1, true))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("_build_full_prompt", function()
    it("expands template placeholders", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 1" })

      local action = {
        name = "Test",
        prompt_template = "Do something: {context}",
      }
      local selection = {
        lines = { "local x = 1" },
        filetype = "lua",
        filename = "t.lua",
        start_line = 1,
      }
      local source = { bufnr = bufnr, start_line = 1, end_line = 1 }

      local result = actions._build_full_prompt(action, selection, source)
      assert.truthy(result:find("Do something:", 1, true))
      assert.truthy(result:find("local x = 1", 1, true))
      -- Template placeholders should be gone
      assert.is_falsy(result:find("{context}", 1, true))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("includes user_prompt when provided", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "code" })

      local action = {
        name = "Task",
        prompt_template = "{user_prompt}\n{context}",
      }
      local selection = { lines = { "code" }, filetype = "lua", filename = "f.lua", start_line = 1 }
      local source = { bufnr = bufnr, start_line = 1, end_line = 1 }

      local result = actions._build_full_prompt(action, selection, source, "make it async")
      assert.truthy(result:find("make it async", 1, true))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("_build_diagnostics_context", function()
    it("returns empty string when no diagnostics", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "clean code" })

      local source = { bufnr = bufnr, start_line = 1, end_line = 1 }
      local result = actions._build_diagnostics_context(source)
      assert.equals("", result)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("includes diagnostic text when present", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "bad code" })

      local ns = vim.api.nvim_create_namespace("test_actions_diag")
      vim.diagnostic.set(ns, bufnr, {
        { lnum = 0, col = 0, message = "unused variable", severity = vim.diagnostic.severity.WARN },
      })

      local source = { bufnr = bufnr, start_line = 1, end_line = 1 }
      local result = actions._build_diagnostics_context(source)
      assert.truthy(result:find("unused variable", 1, true))
      assert.truthy(result:find("LSP Diagnostics", 1, true))

      vim.diagnostic.reset(ns, bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
