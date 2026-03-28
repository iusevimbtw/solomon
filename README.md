# solomon.nvim

Claude Code integration for Neovim. A hybrid architecture combining terminal embedding with an MCP bridge for bidirectional communication.

## Features

- **Terminal** — Claude Code CLI in a side panel or floating window
- **Code Actions** — Explain, improve, task, or ask about code in normal or visual mode
- **Inline Replace** — Animated spinner in buffer, auto-replaces selection with Claude's response
- **Streaming Responses** — Real-time streaming display with markdown highlighting
- **Code Apply** — Apply code blocks from responses directly into your source buffer
- **MCP Server** — WebSocket server with permessage-deflate compression for full IDE integration
- **Context Sending** — Send files/selections to Claude as @mentions via MCP
- **Session Management** — Browse, resume, and continue Claude Code conversations with a picker
- **Git Integration** — Diff review, commit message generation, blame explanation
- **Statusline** — Lualine component showing MCP status, model, and cost
- **Context Aware** — Auto-includes surrounding code, CLAUDE.md conventions, and LSP diagnostics

## Requirements

- Neovim >= 0.11.0
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) in PATH
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)

Optional: [snacks.nvim](https://github.com/folke/snacks.nvim), [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim), [which-key.nvim](https://github.com/folke/which-key.nvim), [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)

## Installation

### lazy.nvim

```lua
{
  "your-username/solomon.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
  },
  opts = {},
  keys = {
    { "<leader>an", desc = "Solomon: Open Claude Code" },
    { "<leader>aa", desc = "Solomon: Send to Claude" },
  },
}
```

### Local development

```lua
{ dir = "/path/to/solomon", opts = {} }
```

## Configuration

```lua
require("solomon").setup({
  terminal = {
    style = "split",         -- "float" or "split"
    float_opts = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
    split_opts = {
      position = "right",
      size = 0.4,
    },
    auto_close = true,
    auto_insert = true,
  },
  keymaps = {
    send = "<leader>aa",
    toggle = "<leader>an",
    focus = "<leader>af",
    ask = "<leader>ak",
    explain = "<leader>ae",
    improve = "<leader>ai",
    task = "<leader>at",
    sessions = "<leader>as",
    continue_session = "<leader>ac",
    diff = "<leader>ad",
    commit = "<leader>am",
    blame = "<leader>ab",
  },
  cli = {
    cmd = "claude",
    model = nil,             -- "opus", "sonnet", etc.
    args = {},
  },
  mcp = {
    enabled = true,
    auto_start = true,
  },
})
```

## Keymaps

All code actions work in both normal mode (treesitter selects enclosing function) and visual mode.

### Code actions

| Key | Action | Mode |
|-----|--------|------|
| `<leader>ae` | Explain code | popup |
| `<leader>ai` | Improve code (fix + refactor + optimize) | inline |
| `<leader>at` | Task (custom prompt, inline replace) | prompt → inline |
| `<leader>ak` | Ask Claude (free-form question) | prompt → popup |

### Terminal & context

| Key | Action |
|-----|--------|
| `<leader>an` | Open new Claude Code terminal |
| `<leader>af` | Focus existing Claude Code terminal |
| `<leader>aa` | Send selection/file/neo-tree file to Claude as @mention |
| `<leader>ac` | Continue last session |
| `<leader>as` | Browse sessions |

### Git

| Key | Action |
|-----|--------|
| `<leader>ad` | Git diff review |
| `<leader>am` | Generate commit message |
| `<leader>ab` | Explain git blame |

### Response window

| Key | Action |
|-----|--------|
| `a` | Apply code block to source |
| `y` | Yank code block to clipboard |
| `d` | Open diff view vs original |
| `q`/`<Esc>` | Cancel and close |

## Commands

```vim
:Solomon                  " Open new terminal
:Solomon open             " Open new terminal
:Solomon focus            " Focus existing terminal
:Solomon close            " Close terminal
:Solomon send             " Send context to Claude
:Solomon diff             " Review unstaged changes
:Solomon diff-staged      " Review staged changes
:Solomon diff-hunk        " Review current hunk
:Solomon commit           " Generate commit message
:Solomon blame            " Explain git blame
:Solomon sessions         " Browse all sessions
:Solomon sessions-project " Browse project sessions
:Solomon continue         " Continue last session
:Solomon resume [id]      " Resume specific session
:Solomon mcp-start        " Start MCP server
:Solomon mcp-stop         " Stop MCP server
:Solomon mcp-status       " Show MCP status
:Solomon mcp-log          " Open MCP debug log
```

## Statusline

Add to your lualine config:

```lua
lualine_x = {
  require("solomon.statusline").lualine(),
}
```

## MCP Server

Solomon runs a WebSocket MCP server with permessage-deflate compression that Claude Code discovers automatically via a lock file. Claude can:

- Read your open buffers and get diagnostics
- Open files, propose diffs, save documents
- Get current selection and workspace folders
- Receive @mention context when you press `<leader>aa`

The server starts automatically on plugin setup and cleans up on exit.

## License

MIT
