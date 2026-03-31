--- MCP tool handlers — Neovim operations exposed to Claude Code.
--- Tool names match claudecode.nvim convention so Claude Code recognizes them.

local M = {}

--- Get all tool definitions (for tools/list).
---@return table[]
function M.get_tool_definitions()
  return {
    {
      name = "openFile",
      description = "Open a file in the Neovim editor.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = {
            type = "string",
            description = "Absolute or relative file path to open",
          },
        },
        required = { "filePath" },
      },
    },
    {
      name = "getOpenEditors",
      description = "List all open buffers/editors in Neovim with their file paths and modified status.",
      inputSchema = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
    {
      name = "getCurrentSelection",
      description = "Get the current visual selection or cursor context in the editor.",
      inputSchema = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
    {
      name = "getLatestSelection",
      description = "Get the most recent visual selection in the editor.",
      inputSchema = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
    {
      name = "getDiagnostics",
      description = "Get LSP diagnostics (errors, warnings, hints) for a buffer or all buffers.",
      inputSchema = {
        type = "object",
        properties = {
          uri = {
            type = "string",
            description = "File URI to get diagnostics for. If omitted, returns diagnostics for all buffers.",
          },
        },
      },
    },
    {
      name = "openDiff",
      description = "Open a diff view comparing old and new file content.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = {
            type = "string",
            description = "File path to diff",
          },
          oldContent = {
            type = "string",
            description = "The original file content",
          },
          newContent = {
            type = "string",
            description = "The new file content",
          },
          tabLabel = {
            type = "string",
            description = "Label for the diff tab",
          },
        },
        required = { "filePath", "oldContent", "newContent" },
      },
    },
    {
      name = "closeAllDiffTabs",
      description = "Close all open diff views.",
      inputSchema = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
    {
      name = "getWorkspaceFolders",
      description = "Get the workspace folders for the current project.",
      inputSchema = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
    {
      name = "checkDocumentDirty",
      description = "Check if a document has unsaved changes.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = {
            type = "string",
            description = "File path to check",
          },
        },
        required = { "filePath" },
      },
    },
    {
      name = "saveDocument",
      description = "Save a document to disk.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = {
            type = "string",
            description = "File path to save",
          },
        },
        required = { "filePath" },
      },
    },
  }
end

--- Get tool handler functions (for tools/call dispatch).
---@return table<string, fun(args: table, client: solomon.WSClient): any>
function M.get_tool_handlers()
  return {
    openFile = M.handle_open_file,
    getOpenEditors = M.handle_get_open_editors,
    getCurrentSelection = M.handle_get_current_selection,
    getLatestSelection = M.handle_get_latest_selection,
    getDiagnostics = M.handle_get_diagnostics,
    openDiff = M.handle_open_diff,
    closeAllDiffTabs = M.handle_close_all_diff_tabs,
    getWorkspaceFolders = M.handle_get_workspace_folders,
    checkDocumentDirty = M.handle_check_document_dirty,
    saveDocument = M.handle_save_document,
  }
end

--- Open a file in the editor.
---@param args {filePath: string}
function M.handle_open_file(args)
  if not args.filePath then
    error("Missing required argument: filePath")
  end
  vim.cmd.edit(vim.fn.fnameescape(args.filePath))
  return { opened = args.filePath }
end

--- List all open editors/buffers.
function M.handle_get_open_editors()
  local editors = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.bo[buf].buftype == "" then
        table.insert(editors, {
          filePath = name,
          name = vim.fn.fnamemodify(name, ":t"),
          isActive = buf == vim.api.nvim_get_current_buf(),
          isDirty = vim.bo[buf].modified,
          languageId = vim.bo[buf].filetype,
        })
      end
    end
  end
  return editors
end

--- Get the current selection or cursor context.
--- Uses tracked selection from selection.lua if available.
function M.handle_get_current_selection()
  local ok, sel_mod = pcall(require, "solomon.selection")
  if ok then
    local tracked = sel_mod.get_latest()
    if tracked then
      return tracked
    end
  end

  -- Fallback: return cursor position
  local cursor = vim.api.nvim_win_get_cursor(0)
  local filepath = vim.api.nvim_buf_get_name(0)
  return {
    text = "",
    filePath = filepath,
    fileUrl = "file://" .. filepath,
    selection = {
      start = { line = cursor[1] - 1, character = cursor[2] },
      ["end"] = { line = cursor[1] - 1, character = cursor[2] },
      isEmpty = true,
    },
  }
end

--- Get the latest tracked selection (may include visual selection text from before switching to Claude).
function M.handle_get_latest_selection()
  local ok, sel_mod = pcall(require, "solomon.selection")
  if ok then
    local tracked = sel_mod.get_latest()
    if tracked then
      return tracked
    end
  end
  -- Fallback to current selection
  return M.handle_get_current_selection()
end

--- Get LSP diagnostics.
---@param args {uri: string|nil}
function M.handle_get_diagnostics(args)
  local buf = nil
  if args.uri then
    -- Convert URI to buffer
    local path = args.uri:gsub("^file://", "")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then
        buf = b
        break
      end
    end
  end

  local diagnostics = vim.diagnostic.get(buf)
  local results = {}
  local severity_names = { "Error", "Warning", "Information", "Hint" }

  for _, d in ipairs(diagnostics) do
    local bufname = vim.api.nvim_buf_get_name(d.bufnr)
    table.insert(results, {
      filePath = bufname,
      range = {
        start = { line = d.lnum, character = d.col },
        ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
      },
      severity = severity_names[d.severity] or "Unknown",
      message = d.message,
      source = d.source,
      code = d.code,
    })
  end

  return results
end

--- Open a diff view.
---@param args {filePath: string, oldContent: string, newContent: string, tabLabel: string|nil}
function M.handle_open_diff(args)
  if not args.filePath then error("Missing required argument: filePath") end
  if not args.oldContent then error("Missing required argument: oldContent") end
  if not args.newContent then error("Missing required argument: newContent") end

  local old_lines = vim.split(args.oldContent, "\n", { plain = true })
  local new_lines = vim.split(args.newContent, "\n", { plain = true })
  local filename = vim.fn.fnamemodify(args.filePath, ":t")
  local label = args.tabLabel or filename
  local suffix = tostring(vim.uv.hrtime())
  local ft = vim.filetype.match({ filename = filename }) or ""

  vim.cmd.tabnew()
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, old_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[orig_buf].filetype = ft
  vim.api.nvim_buf_set_name(orig_buf, "solomon://original/" .. label .. "." .. suffix)
  vim.cmd.diffthis()

  vim.cmd.vsplit()
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, new_buf)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, new_lines)
  vim.bo[new_buf].buftype = "nofile"
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[new_buf].filetype = ft
  vim.api.nvim_buf_set_name(new_buf, "solomon://proposed/" .. label .. "." .. suffix)
  vim.cmd.diffthis()

  -- Keymaps
  for _, buf in ipairs({ orig_buf, new_buf }) do
    vim.keymap.set("n", "q", function() vim.cmd.tabclose() end, { buffer = buf })
    vim.keymap.set("n", "<CR>", function()
      -- Find the source buffer and apply
      local source_buf = nil
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == args.filePath then
          source_buf = b
          vim.api.nvim_buf_set_lines(b, 0, -1, false, new_lines)
          break
        end
      end

      -- Find first changed line
      local first_diff = 1
      for i = 1, math.max(#old_lines, #new_lines) do
        if old_lines[i] ~= new_lines[i] then
          first_diff = i
          break
        end
      end

      -- Close diff tab
      vim.cmd.tabclose()

      -- Jump to the source file at the first changed line
      if source_buf then
        -- Find a non-terminal window to show the file
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) then
            local wbuf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(wbuf)
            if not name:find("^term://") and not name:find("^solomon://") then
              vim.api.nvim_set_current_win(win)
              vim.api.nvim_win_set_buf(win, source_buf)
              pcall(vim.api.nvim_win_set_cursor, win, { first_diff, 0 })
              vim.cmd("normal! zz") -- center the changed line
              break
            end
          end
        end
      end
    end, { buffer = buf })
  end

  return { status = "diff_shown", filePath = args.filePath }
end

--- Close all diff tabs.
function M.handle_close_all_diff_tabs()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find("^solomon://") then
        pcall(function()
          vim.api.nvim_set_current_tabpage(tab)
          vim.cmd.tabclose()
        end)
        break
      end
    end
  end
  return { closed = true }
end

--- Get workspace folders.
function M.handle_get_workspace_folders()
  return { vim.fn.getcwd() }
end

--- Check if a document has unsaved changes.
---@param args {filePath: string}
function M.handle_check_document_dirty(args)
  if not args.filePath then error("Missing required argument: filePath") end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == args.filePath then
      return { isDirty = vim.bo[buf].modified }
    end
  end
  return { isDirty = false }
end

--- Save a document.
---@param args {filePath: string}
function M.handle_save_document(args)
  if not args.filePath then error("Missing required argument: filePath") end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == args.filePath then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("write")
      end)
      return { saved = true }
    end
  end
  return { saved = false, error = "Buffer not found" }
end

return M
