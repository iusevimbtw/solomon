# solomon.nvim

Neovim plugin integrating Claude Code CLI. Lua only, targets Neovim 0.11+.

## Architecture

Hybrid: terminal embedding (snacks.nvim) + WebSocket MCP server with permessage-deflate compression for bidirectional communication.

```
plugin/solomon.lua          Entry point (load guard only, setup via lazy.nvim opts)
lua/solomon/
  init.lua                  Setup, command registration, keymaps, which-key
  config.lua                Typed config with defaults and validation
  terminal.lua              Snacks.terminal wrapper (open, focus, send, close)
  streaming.lua             claude -p --output-format stream-json --verbose parser
  prompt.lua                nui.nvim floating layout (context + input panes)
  response.lua              Streaming response popup, code block apply, thinking spinner
  actions.lua               Actions (explain, improve, task, ask) + inline execution
  sessions.lua              Claude session discovery from ~/.claude/history.jsonl
  git.lua                   Git diff review, commit message gen, blame
  statusline.lua            Lualine component (MCP status, model, cost)
  health.lua                :checkhealth solomon
  utils.lua                 Visual selection, treesitter context, indentation, CLAUDE.md reader
  mcp/
    server.lua              MCP JSON-RPC 2.0 protocol, lock file lifecycle, logging
    transport.lua           WebSocket server (vim.uv TCP + RFC 6455 + permessage-deflate)
    handlers.lua            10 MCP tools matching claudecode.nvim convention
    sha1.lua                Pure Lua SHA-1 (LuaJIT bit library) for WebSocket handshake
    zlib.lua                LuaJIT FFI wrapper for system libz (deflate/inflate)
```

## Dependencies

- **Required**: nui.nvim
- **Optional**: snacks.nvim (terminal, picker), lualine.nvim, which-key.nvim, gitsigns.nvim
- All optional deps degrade gracefully (pcall checks before use)

## Actions

Two execution modes for actions:

- **Inline** (`inline = true`): Animated spinner virtual lines in buffer → auto-replaces selection with Claude's code block response. Used by `improve` and `task`.
- **Popup**: Opens response window with streaming markdown. Used by `explain` and `ask`.

Actions can also have `show_input = true` to show the prompt window first. Combining `show_input + inline` (used by `task`) shows the prompt, then runs inline after submission.

All actions work in both normal mode (treesitter selects enclosing function) and visual mode.

### Action list

| Action | Key | Mode | Behavior |
|--------|-----|------|----------|
| explain | `<leader>ae` | popup | Explain code |
| improve | `<leader>ai` | inline | Fix bugs, refactor, optimize (all-in-one) |
| task | `<leader>at` | prompt → inline | Custom instruction, inline replace |
| ask | `<leader>ak` | prompt → popup | Free-form question |

### Terminal & context

| Key | Mode | Behavior |
|-----|------|----------|
| `<leader>an` | normal | Open new Claude Code terminal (closes existing) |
| `<leader>af` | normal | Focus existing Claude Code terminal |
| `<leader>aq` | normal | Close Claude Code terminal |
| `<leader>aa` | normal/visual | Send context to Claude via MCP @mention |
| `<leader>ac` | normal/visual | Continue last session (closes existing terminal) |
| `<leader>as` | normal | Browse sessions (snacks picker) |

## MCP Server

WebSocket MCP server with:
- Lock file discovery at `~/.claude/ide/<port>.lock`
- RFC 7692 permessage-deflate compression via FFI zlib
- Per-client handshake tracking
- `at_mentioned` broadcasts for sending file/selection context
- Mention queue with 10s expiry for pre-connection sends
- 10 tools matching claudecode.nvim naming: `openFile`, `getOpenEditors`, `getCurrentSelection`, `getLatestSelection`, `getDiagnostics`, `openDiff`, `closeAllDiffTabs`, `getWorkspaceFolders`, `checkDocumentDirty`, `saveDocument`

## Key patterns

- All keymaps default to `<leader>a` prefix. Set any keymap to `""` to disable.
- Normal mode actions use `utils.get_treesitter_context()` to find enclosing function/method/block.
- Visual mode actions call `utils.get_visual_selection()` which feeds `<Esc>` to set marks before reading `'<` `'>`.
- Inline actions use unique namespaces per invocation so concurrent spinners don't jitter.
- Inline actions track selection boundaries with extmarks so concurrent completions don't corrupt each other's line ranges.
- On inline completion, cursor and visual selection are adjusted for any line delta caused by the replacement.
- Prompts auto-include surrounding context (treesitter enclosing function or 15-line fallback), CLAUDE.md from project root, and LSP diagnostics for the selected range.
- Indentation is preserved: `utils.detect_indent()` captures original indent, `utils.reindent()` applies it to Claude's response.
- Streaming uses `vim.fn.jobstart` with `on_stdout` callback. Tokens dispatched via `vim.schedule`.
- MCP server auto-starts on setup, writes lock file to `~/.claude/ide/<port>.lock`, cleans up on VimLeavePre.
- `<leader>an` always opens a fresh terminal. `<leader>af` focuses existing. They never stack.
- nui.nvim is lazy-required inside functions, not at module top level (keeps modules loadable without nui).

## Tests

```bash
make test
```

Uses plenary.busted. Tests live in `tests/solomon/`. 208 tests covering config, utils, SHA-1, zlib compression, streaming parser, WebSocket framing (including compressed frames), session parsing, code block detection, action definitions, extmark tracking, cursor/visual restoration, MCP server protocol, end-to-end WebSocket connection, tool handlers, statusline, and git.

To add a test: create `tests/solomon/<module>_spec.lua` using `describe`/`it` syntax.

## Common tasks

- **Add a new action**: Add entry to `actions.lua:M.actions` (set `inline`, `show_input` flags), add public shortcut function, add keymap field to `config.lua`, register in `init.lua:register_keymaps` + which-key.
- **Add an MCP tool**: Add definition in `handlers.lua:get_tool_definitions`, add handler function, register in `get_tool_handlers`. Use camelCase names matching claudecode.nvim convention.
- **Add a command**: Add `elseif` branch in `init.lua:register_commands`, add to completion list.
