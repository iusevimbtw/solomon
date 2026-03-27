# solomon.nvim

Claude Code integration for Neovim. A hybrid architecture combining terminal embedding with an MCP bridge for bidirectional communication.

## Features

- **Terminal** — Toggle Claude Code CLI in a floating window or split
- **Visual Actions** — Select code and ask Claude to explain, refactor, fix, optimize, or generate tests
- **Streaming Responses** — Real-time streaming display with markdown highlighting
- **Code Apply** — Apply code blocks from Claude's response directly into your source buffer
- **MCP Server** — WebSocket server that lets Claude Code read your buffers, propose diffs, and access diagnostics
- **Session Management** — Browse, resume, and continue Claude Code conversations with a picker
- **Git Integration** — Code review, commit message generation, blame explanation
- **Statusline** — Lualine component showing MCP status, model, and cost

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
    { "<leader>aa", desc = "Solomon: Toggle Claude Code" },
    { "<leader>as", desc = "Solomon: Browse sessions" },
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
    style = "float",         -- "float" or "split"
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
    toggle = "<leader>aa",
    ask = "<leader>ak",
    explain = "<leader>ae",
    refactor = "<leader>ar",
    fix = "<leader>af",
    optimize = "<leader>ao",
    tests = "<leader>at",
    sessions = "<leader>as",
    continue_session = "<leader>ac",
    review = "<leader>aR",
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

### Normal mode

| Key | Action |
|-----|--------|
| `<leader>aa` | Toggle Claude Code terminal |
| `<leader>as` | Browse sessions |
| `<leader>ac` | Continue last session |
| `<leader>aR` | Review git diff |
| `<leader>am` | Generate commit message |
| `<leader>ab` | Explain git blame |

### Visual mode

| Key | Action |
|-----|--------|
| `<leader>ak` | Ask Claude (free-form) |
| `<leader>ae` | Explain code |
| `<leader>ar` | Refactor code |
| `<leader>af` | Fix code |
| `<leader>ao` | Optimize code |
| `<leader>at` | Generate tests |

### Response window

| Key | Action |
|-----|--------|
| `ga` | Apply code block to source |
| `gy` | Yank code block to clipboard |
| `gd` | Open diff view vs original |
| `<C-c>` | Cancel request |
| `q` | Close |

## Commands

```vim
:Solomon                  " Toggle terminal
:Solomon review           " Review unstaged changes
:Solomon review-staged    " Review staged changes
:Solomon commit           " Generate commit message
:Solomon blame            " Explain git blame
:Solomon sessions         " Browse all sessions
:Solomon continue         " Continue last session
:Solomon mcp-start        " Start MCP server
:Solomon mcp-stop         " Stop MCP server
:Solomon mcp-status       " Show MCP status
```

## Statusline

Add to your lualine config:

```lua
lualine_x = {
  require("solomon.statusline").lualine(),
}
```

## MCP Server

Solomon runs a WebSocket MCP server that Claude Code discovers automatically via a lock file. Claude can:

- Read your open buffers
- Access LSP diagnostics
- Propose edits with diff review
- Open files in the editor
- Get cursor context

The server starts automatically on plugin setup and cleans up on exit.

## License

MIT
