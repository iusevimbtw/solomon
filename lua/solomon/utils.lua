local M = {}

--- Get the visual selection text and metadata.
--- Must be called while visual selection is active or just after.
---@return {lines: string[], filetype: string, filename: string, filepath: string, start_line: integer, end_line: integer}|nil
function M.get_visual_selection()
  -- Exit visual mode to set the '< '> marks for the current selection
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  -- Get marks for visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line == 0 or end_line == 0 then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil
  end

  return {
    lines = lines,
    filetype = vim.bo.filetype,
    filename = vim.fn.expand("%:t"),
    filepath = vim.fn.expand("%:p"),
    start_line = start_line,
    end_line = end_line,
  }
end

--- Get the current buffer info.
---@return {lines: string[], filetype: string, filename: string, filepath: string}
function M.get_buffer_info()
  return {
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    filetype = vim.bo.filetype,
    filename = vim.fn.expand("%:t"),
    filepath = vim.fn.expand("%:p"),
  }
end

--- Format code context for inclusion in a prompt.
---@param lines string[]
---@param filetype string
---@param filename string
---@param start_line integer|nil
---@return string
function M.format_context(lines, filetype, filename, start_line)
  local header = filename
  if start_line then
    header = header .. ":" .. start_line
  end

  local code = table.concat(lines, "\n")
  return string.format("File: %s\n```%s\n%s\n```", header, filetype, code)
end

--- Find and read CLAUDE.md from the project root (cwd or git root).
--- Returns the contents or nil if not found.
---@return string|nil
function M.read_claude_md()
  -- Try git root first, then cwd
  local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null")
  local root = vim.v.shell_error == 0 and vim.trim(git_root) or vim.fn.getcwd()

  local paths = {
    root .. "/CLAUDE.md",
    root .. "/.claude/CLAUDE.md",
  }

  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        return content
      end
    end
  end

  return nil
end

--- Detect the base indentation of a set of lines (smallest leading whitespace).
---@param lines string[]
---@return string indent The common leading whitespace prefix
function M.detect_indent(lines)
  local min_indent = nil
  for _, line in ipairs(lines) do
    -- Skip empty lines
    if line:match("%S") then
      local indent = line:match("^(%s*)")
      if min_indent == nil or #indent < #min_indent then
        min_indent = indent
      end
    end
  end
  return min_indent or ""
end

--- Re-indent lines to match a target base indentation.
--- Strips existing common indent from new_lines, then prepends target_indent.
---@param new_lines string[]
---@param target_indent string
---@return string[]
function M.reindent(new_lines, target_indent)
  -- Find common indent in new_lines
  local current_indent = M.detect_indent(new_lines)
  local strip_len = #current_indent

  local result = {}
  for _, line in ipairs(new_lines) do
    if line:match("%S") then
      -- Strip current common indent, add target indent
      local stripped = line:sub(strip_len + 1)
      table.insert(result, target_indent .. stripped)
    else
      -- Preserve empty lines
      table.insert(result, "")
    end
  end
  return result
end

--- Get the enclosing function/method/block at cursor using treesitter.
--- Returns the same format as get_visual_selection() for seamless fallback.
---@return {lines: string[], filetype: string, filename: string, filepath: string, start_line: integer, end_line: integer}|nil
function M.get_treesitter_context()
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok or not node then
    return nil
  end

  -- Walk up to find a function, method, or meaningful block node
  local target_types = {
    -- Lua
    "function_declaration", "function_definition", "local_function",
    -- Go
    "function_declaration", "method_declaration",
    -- Python
    "function_definition", "class_definition",
    -- TypeScript/JavaScript
    "function_declaration", "method_definition", "arrow_function",
    "function", "export_statement",
    -- Elixir
    "call", -- def/defp/defmodule are calls in elixir treesitter
    -- Generic
    "function", "method",
  }

  local target_set = {}
  for _, t in ipairs(target_types) do
    target_set[t] = true
  end

  local current = node
  while current do
    if target_set[current:type()] then
      break
    end
    current = current:parent()
  end

  if not current then
    return nil
  end

  local start_row, _, end_row, _ = current:range()
  -- treesitter is 0-indexed, convert to 1-indexed
  local start_line = start_row + 1
  local end_line = end_row + 1

  local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
  if #lines == 0 then
    return nil
  end

  return {
    lines = lines,
    filetype = vim.bo.filetype,
    filename = vim.fn.expand("%:t"),
    filepath = vim.fn.expand("%:p"),
    start_line = start_line,
    end_line = end_line,
  }
end

--- Get LSP diagnostics for a line range, formatted as text.
---@param bufnr integer
---@param start_line integer 1-indexed
---@param end_line integer 1-indexed
---@return string|nil
function M.get_diagnostics_for_range(bufnr, start_line, end_line)
  local diagnostics = vim.diagnostic.get(bufnr)
  if not diagnostics or #diagnostics == 0 then
    return nil
  end

  local severity_names = { "error", "warn", "info", "hint" }
  local relevant = {}

  for _, d in ipairs(diagnostics) do
    local line = d.lnum + 1 -- 0-indexed to 1-indexed
    if line >= start_line and line <= end_line then
      local sev = severity_names[d.severity] or "unknown"
      local source = d.source and (" (" .. d.source .. ")") or ""
      table.insert(relevant, string.format("- Line %d: %s: %s%s", line, sev, d.message, source))
    end
  end

  if #relevant == 0 then
    return nil
  end

  return "LSP Diagnostics:\n" .. table.concat(relevant, "\n")
end

return M
