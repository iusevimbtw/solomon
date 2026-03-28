describe("solomon.mcp.handlers", function()
  local handlers

  before_each(function()
    package.loaded["solomon.mcp.handlers"] = nil
    handlers = require("solomon.mcp.handlers")
  end)

  describe("get_tool_definitions", function()
    it("returns a list of tools", function()
      local tools = handlers.get_tool_definitions()
      assert.is_table(tools)
      assert.is_true(#tools > 0)
    end)

    it("all tools have required fields", function()
      local tools = handlers.get_tool_definitions()
      for _, tool in ipairs(tools) do
        assert.is_string(tool.name, "tool missing name")
        assert.is_string(tool.description, "tool missing description: " .. (tool.name or "?"))
        assert.is_table(tool.inputSchema, "tool missing inputSchema: " .. tool.name)
        assert.equals("object", tool.inputSchema.type, "inputSchema.type should be object: " .. tool.name)
      end
    end)

    it("includes expected tool names", function()
      local tools = handlers.get_tool_definitions()
      local names = {}
      for _, tool in ipairs(tools) do
        names[tool.name] = true
      end
      assert.is_true(names["openFile"])
      assert.is_true(names["getOpenEditors"])
      assert.is_true(names["getCurrentSelection"])
      assert.is_true(names["getLatestSelection"])
      assert.is_true(names["getDiagnostics"])
      assert.is_true(names["openDiff"])
      assert.is_true(names["closeAllDiffTabs"])
      assert.is_true(names["getWorkspaceFolders"])
      assert.is_true(names["checkDocumentDirty"])
      assert.is_true(names["saveDocument"])
    end)

    it("properties are objects not arrays (vim.empty_dict)", function()
      local tools = handlers.get_tool_definitions()
      for _, tool in ipairs(tools) do
        local json = vim.json.encode(tool.inputSchema)
        -- Should never contain "properties":[] — must be "properties":{}
        assert.is_falsy(
          json:find('"properties"%s*:%s*%['),
          "properties should be object not array in: " .. tool.name
        )
      end
    end)
  end)

  describe("get_tool_handlers", function()
    it("returns handlers for all defined tools", function()
      local tool_handlers = handlers.get_tool_handlers()
      local tools = handlers.get_tool_definitions()
      for _, tool in ipairs(tools) do
        assert.is_function(
          tool_handlers[tool.name],
          "missing handler for tool: " .. tool.name
        )
      end
    end)
  end)

  describe("handle_get_open_editors", function()
    it("returns a list", function()
      local result = handlers.handle_get_open_editors()
      assert.is_table(result)
    end)

    it("includes file buffers with expected fields", function()
      -- Create a temp buffer with a file
      local buf = vim.api.nvim_create_buf(true, false)
      local tmpfile = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "test" }, tmpfile)
      vim.api.nvim_buf_set_name(buf, tmpfile)
      vim.bo[buf].filetype = "lua"

      local result = handlers.handle_get_open_editors()
      local found = false
      for _, editor in ipairs(result) do
        if editor.filePath == tmpfile then
          found = true
          assert.is_string(editor.name)
          assert.is_boolean(editor.isActive)
          assert.is_boolean(editor.isDirty)
          assert.equals("lua", editor.languageId)
        end
      end

      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(tmpfile)
      assert.is_true(found, "Should find the temp buffer in editors list")
    end)
  end)

  describe("handle_get_workspace_folders", function()
    it("returns a table with cwd", function()
      local result = handlers.handle_get_workspace_folders()
      assert.is_table(result)
      assert.equals(vim.fn.getcwd(), result[1])
    end)
  end)

  describe("handle_check_document_dirty", function()
    it("returns isDirty false for unmodified buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local tmpfile = vim.fn.tempname()
      vim.fn.writefile({ "test" }, tmpfile)
      vim.api.nvim_buf_set_name(buf, tmpfile)

      local result = handlers.handle_check_document_dirty({ filePath = tmpfile })
      assert.is_false(result.isDirty)

      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(tmpfile)
    end)

    it("returns isDirty false for unknown file", function()
      local result = handlers.handle_check_document_dirty({ filePath = "/nonexistent/file.lua" })
      assert.is_false(result.isDirty)
    end)

    it("errors on missing filePath", function()
      assert.has_error(function()
        handlers.handle_check_document_dirty({})
      end)
    end)
  end)

  describe("handle_open_file", function()
    it("errors on missing filePath", function()
      assert.has_error(function()
        handlers.handle_open_file({})
      end)
    end)
  end)

  describe("handle_get_diagnostics", function()
    it("returns a table", function()
      local result = handlers.handle_get_diagnostics({})
      assert.is_table(result)
    end)
  end)

  describe("handle_close_all_diff_tabs", function()
    it("returns closed status", function()
      local result = handlers.handle_close_all_diff_tabs()
      assert.is_true(result.closed)
    end)
  end)
end)
