local Popup = require("nui.popup")
local Layout = require("nui.layout")

local M = {}

---@class solomon.PromptOpts
---@field context_lines string[] Code context to display
---@field filetype string Filetype for syntax highlighting
---@field filename string Source filename
---@field start_line integer|nil Starting line number
---@field on_submit fun(prompt: string) Called when user submits

--- Open the prompt window with code context and input area.
---@param opts solomon.PromptOpts
function M.open(opts)
  local max_context = math.floor(vim.o.lines * 0.4)
  -- Add 2 for border (top + bottom) so all content lines are visible
  local context_height = math.min(#opts.context_lines + 2, max_context)
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
      position = "50%",
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

  -- Resize and reposition on terminal/screen resize
  local augroup = vim.api.nvim_create_augroup("solomon_prompt_resize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if not input_popup.winid or not vim.api.nvim_win_is_valid(input_popup.winid) then
        vim.api.nvim_del_augroup_by_id(augroup)
        return
      end
      layout:update({
        relative = "editor",
        position = "50%",
        size = {
          width = "70%",
          height = context_height + input_height + 4,
        },
      })
    end,
  })

  -- Clean up autocmd when layout is unmounted
  local orig_unmount = layout.unmount
  layout.unmount = function(self, ...)
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    return orig_unmount(self, ...)
  end

  -- Set context content (read-only)
  vim.api.nvim_buf_set_lines(context_popup.bufnr, 0, -1, false, opts.context_lines)
  vim.bo[context_popup.bufnr].modifiable = false

  -- Set line number offset to match source file
  if opts.start_line and opts.start_line > 1 then
    vim.wo[context_popup.winid].numberwidth = #tostring(opts.start_line + #opts.context_lines) + 1
  end

  -- Start in insert mode
  vim.cmd("startinsert!")

  -- Submit keymap (Enter in normal mode, Ctrl-Enter in insert mode)
  local function submit()
    local input_lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, -1, false)
    local prompt = vim.trim(table.concat(input_lines, "\n"))

    if prompt == "" then
      vim.notify("[solomon] Prompt cannot be empty", vim.log.levels.WARN)
      return
    end

    layout:unmount()
    opts.on_submit(prompt)
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
