describe("solomon.selection", function()
  local selection

  before_each(function()
    package.loaded["solomon.selection"] = nil
    package.loaded["solomon.utils"] = nil
    selection = require("solomon.selection")
    if selection._enabled then
      selection.disable()
    end
  end)

  after_each(function()
    if selection._enabled then
      selection.disable()
    end
  end)

  describe("enable/disable", function()
    it("starts disabled", function()
      assert.is_false(selection._enabled)
    end)

    it("enable creates autocmds", function()
      selection.enable()
      assert.is_true(selection._enabled)
      assert.is_not_nil(selection._augroup)
    end)

    it("disable cleans up", function()
      selection.enable()
      selection.disable()
      assert.is_false(selection._enabled)
      assert.is_nil(selection._augroup)
      assert.is_nil(selection._debounce_timer)
    end)

    it("enable is idempotent", function()
      selection.enable()
      local group = selection._augroup
      selection.enable()
      assert.equals(group, selection._augroup)
    end)

    it("disable is safe when not enabled", function()
      assert.has_no_error(function()
        selection.disable()
      end)
    end)
  end)

  describe("get_latest", function()
    it("returns nil initially", function()
      assert.is_nil(selection.get_latest())
    end)

    it("returns stored selection after manual set", function()
      local sel = {
        text = "test",
        filePath = "/tmp/test.lua",
        fileUrl = "file:///tmp/test.lua",
        selection = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 4 },
          isEmpty = false,
        },
      }
      selection._latest_selection = sel
      assert.equals(sel, selection.get_latest())
    end)
  end)

  describe("_get_cursor_position", function()
    it("returns cursor position with empty text", function()
      local pos = selection._get_cursor_position()
      assert.is_table(pos)
      assert.equals("", pos.text)
      assert.is_true(pos.selection.isEmpty)
      assert.is_string(pos.filePath)
    end)
  end)

  describe("_has_changed", function()
    it("returns true when old is nil", function()
      selection._latest_selection = nil
      assert.is_true(selection._has_changed({ text = "x", filePath = "/f", fileUrl = "file:///f", selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 }, isEmpty = true } }))
    end)

    it("returns false when same", function()
      local sel = {
        text = "",
        filePath = "/f",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      }
      selection._latest_selection = sel
      assert.is_false(selection._has_changed(sel))
    end)

    it("returns true when filePath differs", function()
      selection._latest_selection = {
        text = "",
        filePath = "/a",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      }
      assert.is_true(selection._has_changed({
        text = "",
        filePath = "/b",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      }))
    end)

    it("returns true when text differs", function()
      selection._latest_selection = {
        text = "old",
        filePath = "/f",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
      }
      assert.is_true(selection._has_changed({
        text = "new",
        filePath = "/f",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
      }))
    end)

    it("returns true when line position differs", function()
      selection._latest_selection = {
        text = "",
        filePath = "/f",
        selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      }
      assert.is_true(selection._has_changed({
        text = "",
        filePath = "/f",
        selection = { start = { line = 5, character = 0 }, ["end"] = { line = 5, character = 0 } },
      }))
    end)
  end)
end)
