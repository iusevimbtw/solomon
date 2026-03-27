--- MCP tool handlers — Neovim operations exposed to Claude Code.

local M = {}

--- Get all tool definitions (for tools/list).
---@return table[]
function M.get_tool_definitions()
  return {
    {
      name = "nvim_get_open_buffers",
      description = "List all open buffers in Neovim with their file paths, filetypes, and modified status.",
      inputSchema = {
        type = "object",
        properties = {},
      },
    },
    {
      name = "nvim_get_buffer",
      description = "Read the contents of a specific buffer by its file path or buffer number.",
      inputSchema = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "File path or buffer number to read",
          },
        },
        required = { "path" },
      },
    },
    {
      name = "nvim_get_current_buffer",
      description = "Get the contents and metadata of the currently focused buffer.",
      inputSchema = {
        type = "object",
        properties = {},
      },
    },
    {
      name = "nvim_open_file",
      description = "Open a file in the Neovim editor.",
      inputSchema = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "Absolute or relative file path to open",
          },
        },
        required = { "path" },
      },
    },
    {
      name = "nvim_edit_with_diff",
      description = "Propose an edit to a file. Opens a side-by-side diff view in Neovim for the user to accept or reject.",
      inputSchema = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "File path to edit",
          },
          new_content = {
            type = "string",
            description = "The complete new file content",
          },
          description = {
            type = "string",
            description = "Short description of what changed",
          },
        },
        required = { "path", "new_content" },
      },
    },
    {
      name = "nvim_get_diagnostics",
      description = "Get LSP diagnostics (errors, warnings, hints) for a buffer or all buffers.",
      inputSchema = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "File path to get diagnostics for. If omitted, returns diagnostics for all buffers.",
          },
          severity = {
            type = "string",
            description = "Filter by severity: 'error', 'warn', 'info', 'hint'. If omitted, returns all.",
            enum = { "error", "warn", "info", "hint" },
          },
        },
      },
    },
    {
      name = "nvim_get_cursor_context",
      description = "Get the code around the user's current cursor position, including the function/block scope.",
      inputSchema = {
        type = "object",
        properties = {
          lines_before = {
            type = "number",
            description = "Number of lines before cursor to include (default: 20)",
          },
          lines_after = {
            type = "number",
            description = "Number of lines after cursor to include (default: 20)",
          },
        },
      },
    },
  }
end

--- Get tool handler functions (for tools/call dispatch).
---@return table<string, fun(args: table, client: solomon.WSClient): any>
function M.get_tool_handlers()
  return {
    nvim_get_open_buffers = M.handle_get_open_buffers,
    nvim_get_buffer = M.handle_get_buffer,
    nvim_get_current_buffer = M.handle_get_current_buffer,
    nvim_open_file = M.handle_open_file,
    nvim_edit_with_diff = M.handle_edit_with_diff,
    nvim_get_diagnostics = M.handle_get_diagnostics,
    nvim_get_cursor_context = M.handle_get_cursor_context,
  }
end

--- List all open buffers.
function M.handle_get_open_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(buffers, {
          bufnr = buf,
          path = name,
          name = vim.fn.fnamemodify(name, ":t"),
          filetype = vim.bo[buf].filetype,
          modified = vim.bo[buf].modified,
          line_count = vim.api.nvim_buf_line_count(buf),
        })
      end
    end
  end
  return buffers
end

--- Read a buffer's contents by path or buffer number.
---@param args {path: string}
function M.handle_get_buffer(args)
  if not args.path then
    error("Missing required argument: path")
  end
  local buf = M._find_buffer(args.path)
  if not buf then
    error("Buffer not found: " .. args.path)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return {
    bufnr = buf,
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    content = table.concat(lines, "\n"),
    line_count = #lines,
  }
end

--- Get the current buffer contents.
function M.handle_get_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)

  return {
    bufnr = buf,
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    content = table.concat(lines, "\n"),
    line_count = #lines,
    cursor_line = cursor[1],
    cursor_col = cursor[2],
  }
end

--- Open a file in the editor.
---@param args {path: string}
function M.handle_open_file(args)
  if not args.path then
    error("Missing required argument: path")
  end
  vim.cmd.edit(vim.fn.fnameescape(args.path))
  return { opened = args.path }
end

--- Propose an edit via diff view.
---@param args {path: string, new_content: string, description: string|nil}
function M.handle_edit_with_diff(args)
  if not args.path then
    error("Missing required argument: path")
  end
  if not args.new_content then
    error("Missing required argument: new_content")
  end

  local path = args.path
  local new_content = args.new_content
  local desc = args.description or "Proposed edit"

  -- Open the file if not already open
  vim.cmd.edit(vim.fn.fnameescape(path))
  local source_buf = vim.api.nvim_get_current_buf()
  local original_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local new_lines = vim.split(new_content, "\n", { plain = true })

  -- Unique suffix to avoid buffer name collisions
  local suffix = tostring(vim.uv.hrtime())
  local filename = vim.fn.fnamemodify(path, ":t")

  -- Open diff tab
  vim.cmd.tabnew()
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[orig_buf].swapfile = false
  vim.bo[orig_buf].filetype = vim.bo[source_buf].filetype
  vim.api.nvim_buf_set_name(orig_buf, "solomon://original/" .. filename .. "." .. suffix)
  vim.cmd.diffthis()

  vim.cmd.vsplit()
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, new_buf)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, new_lines)
  vim.bo[new_buf].buftype = "nofile"
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[new_buf].swapfile = false
  vim.bo[new_buf].filetype = vim.bo[source_buf].filetype
  vim.api.nvim_buf_set_name(new_buf, "solomon://proposed/" .. filename .. "." .. suffix)
  vim.cmd.diffthis()

  -- Store result state
  local result_state = { accepted = false }

  local function close_diff()
    vim.cmd.tabclose()
  end

  local function accept_diff()
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, new_lines)
    result_state.accepted = true
    vim.notify("[solomon] Applied: " .. desc, vim.log.levels.INFO)
    close_diff()
  end

  -- Keymaps on both diff buffers
  for _, buf in ipairs({ orig_buf, new_buf }) do
    vim.keymap.set("n", "q", close_diff, { buffer = buf, desc = "Reject and close diff" })
    vim.keymap.set("n", "<CR>", accept_diff, { buffer = buf, desc = "Accept changes" })
    vim.keymap.set("n", "<Esc>", close_diff, { buffer = buf, desc = "Close diff" })
  end

  vim.notify("[solomon] " .. desc .. " — <CR> to accept, q to reject", vim.log.levels.INFO)
  return { status = "diff_shown", description = desc }
end

--- Get LSP diagnostics.
---@param args {path: string|nil, severity: string|nil}
function M.handle_get_diagnostics(args)
  local severity_map = {
    error = vim.diagnostic.severity.ERROR,
    warn = vim.diagnostic.severity.WARN,
    info = vim.diagnostic.severity.INFO,
    hint = vim.diagnostic.severity.HINT,
  }

  local buf = nil
  if args.path then
    buf = M._find_buffer(args.path)
  end

  local opts = {}
  if args.severity then
    opts.severity = severity_map[args.severity]
  end

  local diagnostics = vim.diagnostic.get(buf, opts)
  local results = {}

  for _, d in ipairs(diagnostics) do
    local bufname = vim.api.nvim_buf_get_name(d.bufnr)
    table.insert(results, {
      path = bufname,
      line = d.lnum + 1,
      col = d.col + 1,
      severity = ({ "error", "warn", "info", "hint" })[d.severity] or "unknown",
      message = d.message,
      source = d.source,
      code = d.code,
    })
  end

  return results
end

--- Get code around the cursor.
---@param args {lines_before: number|nil, lines_after: number|nil}
function M.handle_get_cursor_context(args)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local total_lines = vim.api.nvim_buf_line_count(buf)

  local before = args.lines_before or 20
  local after = args.lines_after or 20

  local start_line = math.max(1, cursor_line - before)
  local end_line = math.min(total_lines, cursor_line + after)

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

  return {
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    cursor_line = cursor_line,
    cursor_col = cursor[2],
    start_line = start_line,
    end_line = end_line,
    content = table.concat(lines, "\n"),
  }
end

--- Find a buffer by file path or buffer number string.
---@param path string
---@return integer|nil
function M._find_buffer(path)
  -- Try as buffer number first
  local bufnr = tonumber(path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end

  -- Try as file path
  local abs_path = vim.fn.fnamemodify(path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == path or name == abs_path then
        return buf
      end
    end
  end

  -- Try to open the file
  if vim.fn.filereadable(abs_path) == 1 then
    vim.cmd("badd " .. vim.fn.fnameescape(abs_path))
    return vim.fn.bufnr(abs_path)
  end

  return nil
end

return M
