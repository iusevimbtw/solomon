# solomon.nvim

Neovim plugin integrating Claude Code CLI. Lua only, targets Neovim 0.11+.

## Architecture

Hybrid: terminal embedding (snacks.nvim) + WebSocket MCP server for bidirectional communication.

```
plugin/solomon.lua          Entry point (load guard only, setup via lazy.nvim opts)
lua/solomon/
  init.lua                  Setup, command registration, keymaps, which-key
  config.lua                Typed config with defaults and validation
  terminal.lua              Snacks.terminal wrapper for Claude CLI
  streaming.lua             claude -p --output-format stream-json --verbose parser
  prompt.lua                nui.nvim floating layout (context + input panes)
  response.lua              Streaming response display, code block apply
  actions.lua               Predefined actions (explain, refactor, fix, optimize, tests, ask)
  sessions.lua              Claude session discovery from ~/.claude/history.jsonl
  git.lua                   Git diff review, commit message gen, blame
  statusline.lua            Lualine component (MCP status, model, cost)
  health.lua                :checkhealth solomon
  utils.lua                 Visual selection capture, context formatting
  mcp/
    server.lua              MCP JSON-RPC 2.0 protocol, lock file lifecycle
    transport.lua           WebSocket server (vim.uv TCP + RFC 6455 framing)
    handlers.lua            7 MCP tools (get_buffer, edit_with_diff, diagnostics, etc.)
    sha1.lua                Pure Lua SHA-1 for WebSocket handshake
```

## Dependencies

- **Required**: nui.nvim
- **Optional**: snacks.nvim (terminal, picker), lualine.nvim, which-key.nvim, gitsigns.nvim
- All optional deps degrade gracefully (pcall checks before use)

## Key patterns

- All keymaps default to `<leader>a` prefix. Set any keymap to `""` to disable.
- Visual mode actions call `utils.get_visual_selection()` which feeds `<Esc>` to set marks before reading `'<` `'>`.
- Streaming uses `vim.fn.jobstart` with `on_stdout` callback. Tokens dispatched via `vim.schedule`.
- MCP server auto-starts on setup, writes lock file to `~/.claude/ide/<port>.lock`, cleans up on VimLeavePre.
- Claude session dirs use path normalization: `/home/user/project` -> `-home-user-project` (leading dash preserved).
- nui.nvim is lazy-required inside functions, not at module top level (keeps modules loadable without nui).

## Tests

```bash
make test
```

Uses plenary.busted. Tests live in `tests/solomon/`. 67 tests covering config, utils, SHA-1, streaming parser, WebSocket framing, session parsing, and code block detection.

To add a test: create `tests/solomon/<module>_spec.lua` using `describe`/`it` syntax.

## Common tasks

- **Add a new action**: Add entry to `actions.lua:M.actions`, add keymap field to `config.lua`, register in `init.lua:register_keymaps`.
- **Add an MCP tool**: Add definition in `handlers.lua:get_tool_definitions`, add handler function, register in `get_tool_handlers`.
- **Add a command**: Add `elseif` branch in `init.lua:register_commands`, add to completion list.
