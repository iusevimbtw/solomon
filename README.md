# solomon.nvim

Claude Code integration for Neovim. A hybrid architecture combining terminal embedding with an MCP bridge for bidirectional communication.

## Features

- **Terminal** — Claude Code CLI in a side panel or floating window
- **Code Actions** — Explain, improve, task, or ask about code in normal or visual mode
- **Inline Replace** — Animated spinner in buffer, auto-replaces selection with Claude's response
- **Streaming Responses** — Real-time streaming display with markdown highlighting
- **Code Apply** — Apply code blocks from responses directly into your source buffer
- **MCP Server** — WebSocket server with permessage-deflate compression for full IDE integration
- **Selection Tracking** — Live cursor/visual selection broadcast to Claude via MCP
- **Context Sending** — Send files/selections to Claude as @mentions via MCP
- **Interactive Review** — Hunk-by-hunk diff review with accept/reject/ask Claude
- **Session Management** — Browse, resume, and continue Claude Code conversations
- **Git Integration** — Diff review, commit message generation, blame explanation
- **Auto-Refresh** — Buffers reload automatically when Claude edits files, with diff highlights
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
    close = "<leader>aq",
    ask = "<leader>ak",
    explain = "<leader>ae",
    improve = "<leader>ai",
    task = "<leader>at",
    review = "<leader>aR",
    sessions = "<leader>as",
    continue_session = "<leader>ac",
    diff = "<leader>ad",
    commit = "<leader>am",
    blame = "<leader>ab",
  },
  cli = {
    cmd = "claude",
    model = nil,
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
| `<leader>aq` | Close Claude Code terminal |
| `<leader>aa` | Send selection/file/neo-tree file to Claude as @mention |
| `<leader>ac` | Continue last session |
| `<leader>as` | Browse project sessions |

### Git & review

| Key | Action |
|-----|--------|
| `<leader>aR` | Interactive diff review (hunk-by-hunk) |
| `<leader>ad` | Git diff review |
| `<leader>am` | Generate commit message |
| `<leader>ab` | Explain git blame |

### Response window

| Key | Action |
|-----|--------|
| `a` | Apply code block to source (when applicable) |
| `y` | Yank code block to clipboard (when applicable) |
| `d` | Open diff view vs original (when applicable) |
| `q`/`<Esc>` | Close |

### Review mode

| Key | Action |
|-----|--------|
| `y` | Accept (stage hunk) |
| `n` | Reject (revert hunk) |
| `e` | Edit (open file at hunk) |
| `k` | Ask Claude about hunk |
| `s` | Skip to next |
| `q` | Quit review |

## Commands

```vim
:Solomon                  " Open new terminal
:Solomon open             " Open new terminal
:Solomon focus            " Focus existing terminal
:Solomon close            " Close terminal
:Solomon send             " Send context to Claude
:Solomon review           " Interactive diff review
:Solomon diff             " Review unstaged changes
:Solomon diff-staged      " Review staged changes
:Solomon diff-hunk        " Review current hunk
:Solomon commit           " Generate commit message
:Solomon blame            " Explain git blame
:Solomon sessions         " Browse project sessions
:Solomon continue         " Continue last session
:Solomon resume [id]      " Resume specific session
:Solomon mcp-start        " Start MCP server
:Solomon mcp-stop         " Stop MCP server
:Solomon mcp-status       " Show MCP status
:Solomon mcp-log          " Open MCP debug log
```

## Statusline

```lua
lualine_x = {
  require("solomon.statusline").lualine(),
}
```

## MCP Server

Solomon runs a WebSocket MCP server with permessage-deflate compression that Claude Code discovers automatically via a lock file. Features:

- 10 editor tools (openFile, getDiagnostics, openDiff, etc.)
- Live selection tracking broadcast to Claude
- @mention context sending
- Auto-refresh with diff highlights when Claude edits files
- System prompt dynamically built from tool definitions

## License

MIT
