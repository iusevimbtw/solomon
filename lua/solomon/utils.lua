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

return M
