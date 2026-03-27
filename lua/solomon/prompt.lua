local Popup = require("nui.popup")
local Layout = require("nui.layout")

local M = {}

---@class solomon.PromptOpts
---@field context_lines string[] Code context to display
---@field filetype string Filetype for syntax highlighting
---@field filename string Source filename
---@field start_line integer|nil Starting line number
---@field action_prompt string|nil Pre-filled system instruction (for predefined actions)
---@field on_submit fun(prompt: string, context: string) Called when user submits

--- Open the prompt window with code context and input area.
---@param opts solomon.PromptOpts
function M.open(opts)
  local context_height = math.min(#opts.context_lines, 20)
  local input_height = 5

  -- Context pane (top) — read-only code preview
  local context_popup = Popup({
    border = {
      style = "rounded",
      text = {
        top = " " .. (opts.filename or "Context") .. " ",
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = true,
      readonly = false,
      filetype = opts.filetype or "",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      number = true,
      cursorline = true,
      wrap = false,
    },
  })

  -- Input pane (bottom) — editable prompt
  local input_popup = Popup({
    enter = true,
    border = {
      style = "rounded",
      text = {
        top = " Prompt ",
        top_align = "left",
        bottom = " <CR>: send | <Esc>: cancel ",
        bottom_align = "center",
      },
    },
    buf_options = {
      modifiable = true,
      filetype = "markdown",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      wrap = true,
      linebreak = true,
    },
  })

  local layout = Layout(
    {
      relative = "editor",
      position = {
        row = "10%",
        col = "15%",
      },
      size = {
        width = "70%",
        height = context_height + input_height + 4, -- account for borders
      },
    },
    Layout.Box({
      Layout.Box(context_popup, { size = context_height }),
      Layout.Box(input_popup, { grow = 1 }),
    }, { dir = "col" })
  )

  layout:mount()

  -- Set context content (read-only)
  vim.api.nvim_buf_set_lines(context_popup.bufnr, 0, -1, false, opts.context_lines)
  vim.bo[context_popup.bufnr].modifiable = false

  -- Set line number offset to match source file
  if opts.start_line and opts.start_line > 1 then
    vim.wo[context_popup.winid].numberwidth = #tostring(opts.start_line + #opts.context_lines) + 1
  end

  -- Pre-fill action prompt if provided
  if opts.action_prompt then
    vim.api.nvim_buf_set_lines(input_popup.bufnr, 0, -1, false, { opts.action_prompt })
    -- Place cursor at end
    local line_count = vim.api.nvim_buf_line_count(input_popup.bufnr)
    local last_line = vim.api.nvim_buf_get_lines(input_popup.bufnr, line_count - 1, line_count, false)[1]
    pcall(vim.api.nvim_win_set_cursor, input_popup.winid, { line_count, #last_line })
  end

  -- Start in insert mode
  vim.cmd("startinsert!")

  -- Build the context string for submission
  local utils = require("solomon.utils")
  local context_str = utils.format_context(
    opts.context_lines,
    opts.filetype or "",
    opts.filename or "unknown",
    opts.start_line
  )

  -- Submit keymap (Enter in normal mode, Ctrl-Enter in insert mode)
  local function submit()
    local input_lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, -1, false)
    local prompt = vim.trim(table.concat(input_lines, "\n"))

    if prompt == "" then
      vim.notify("[solomon] Prompt cannot be empty", vim.log.levels.WARN)
      return
    end

    layout:unmount()
    opts.on_submit(prompt, context_str)
  end

  local function close()
    layout:unmount()
  end

  -- Input pane keymaps
  input_popup:map("n", "<CR>", submit, { noremap = true, silent = true })
  input_popup:map("i", "<C-CR>", submit, { noremap = true, silent = true })
  input_popup:map("n", "<Esc>", close, { noremap = true, silent = true })
  input_popup:map("n", "q", close, { noremap = true, silent = true })

  -- Context pane keymaps
  context_popup:map("n", "<Esc>", close, { noremap = true, silent = true })
  context_popup:map("n", "q", close, { noremap = true, silent = true })
  -- Tab to switch between panes
  context_popup:map("n", "<Tab>", function()
    vim.api.nvim_set_current_win(input_popup.winid)
  end, { noremap = true, silent = true })
  input_popup:map("n", "<Tab>", function()
    vim.api.nvim_set_current_win(context_popup.winid)
  end, { noremap = true, silent = true })
end

return M
