--- Session management — discover, list, resume Claude Code sessions.

local M = {}

---@class solomon.Session
---@field session_id string UUID
---@field display string First ~100 chars of first message
---@field project string Working directory path
---@field timestamp number Milliseconds since epoch
---@field date string Human-readable date

--- Get the Claude config directory.
---@return string
function M.config_dir()
  return os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
end

--- Read and parse all sessions from history.jsonl.
---@return solomon.Session[]
function M.get_all()
  local history_path = M.config_dir() .. "/history.jsonl"
  local f = io.open(history_path, "r")
  if not f then
    return {}
  end

  -- Collect sessions grouped by session ID, keeping the first entry
  -- (which has the display text) and the latest timestamp
  local sessions_map = {} ---@type table<string, solomon.Session>
  local order = {} ---@type string[]

  for line in f:lines() do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.sessionId then
        local id = entry.sessionId
        if not sessions_map[id] then
          sessions_map[id] = {
            session_id = id,
            display = entry.display or "(no preview)",
            project = entry.project or "",
            timestamp = entry.timestamp or 0,
            date = "",
          }
          table.insert(order, id)
        else
          -- Update timestamp to the latest
          if (entry.timestamp or 0) > sessions_map[id].timestamp then
            sessions_map[id].timestamp = entry.timestamp
          end
        end
      end
    end
  end
  f:close()

  -- Convert to list and format dates
  local sessions = {}
  for _, id in ipairs(order) do
    local s = sessions_map[id]
    if s.timestamp > 0 then
      s.date = os.date("%Y-%m-%d %H:%M", math.floor(s.timestamp / 1000))
    end
    table.insert(sessions, s)
  end

  -- Sort by timestamp descending (most recent first)
  table.sort(sessions, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return sessions
end

--- Get sessions for the current project only.
---@return solomon.Session[]
function M.get_for_project()
  local cwd = vim.fn.getcwd()
  local all = M.get_all()
  return vim.tbl_filter(function(s)
    return s.project == cwd
  end, all)
end

--- Resume a session by ID in the terminal.
---@param session_id string
function M.resume(session_id)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal", vim.log.levels.ERROR)
    return
  end

  local terminal = require("solomon.terminal")
  local cmd = terminal.build_cmd({ "--resume", session_id })
  snacks.terminal.open(cmd, terminal.build_opts())
end

--- Continue the most recent session in the terminal.
---@param selection table|nil Optional selection to send via MCP at_mention
function M.continue_last(selection)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for terminal", vim.log.levels.ERROR)
    return
  end

  -- Send selection via MCP (will queue if Claude isn't connected yet)
  if selection then
    local server = require("solomon.mcp.server")
    server.send_at_mention(selection.filepath, selection.start_line, selection.end_line)
  end

  local term = require("solomon.terminal")
  local cmd = term.build_cmd({ "--continue" })
  snacks.terminal.open(cmd, term.build_opts())
end

--- Open the session picker using Snacks.picker.
---@param opts {project_only: boolean|nil}|nil
function M.pick(opts)
  opts = opts or {}
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[solomon] snacks.nvim is required for session picker", vim.log.levels.ERROR)
    return
  end

  local sessions = opts.project_only and M.get_for_project() or M.get_all()

  if #sessions == 0 then
    vim.notify("[solomon] No sessions found", vim.log.levels.INFO)
    return
  end

  -- Build picker items
  local items = {}
  for idx, session in ipairs(sessions) do
    local project_name = vim.fn.fnamemodify(session.project, ":t")
    table.insert(items, {
      idx = idx,
      text = session.display .. " " .. session.date .. " " .. project_name,
      session = session,
      display = session.display,
      date = session.date,
      project = project_name,
      project_path = session.project,
    })
  end

  snacks.picker({
    title = "Solomon Sessions",
    items = items,
    format = function(item)
      local a = snacks.picker.util.align
      return {
        { a(item.date or "", 18), "Comment" },
        { " " },
        { a(item.project or "", 20, { truncate = true }), "Directory" },
        { " " },
        { item.display or "", "Normal" },
      }
    end,
    preview = function(ctx)
      local item = ctx.item
      if not item or not item.session then
        return
      end
      -- Show first messages from the session file
      local session = item.session
      local preview_lines = M._get_session_preview(session.session_id, session.project)
      ctx.preview:set_lines(preview_lines)
      ctx.preview:highlight({ ft = "markdown" })
    end,
    confirm = function(picker, item)
      picker:close()
      if item and item.session then
        M.resume(item.session.session_id)
      end
    end,
    layout = {
      preset = "default",
    },
  })
end

--- Get preview lines for a session (first few messages).
---@param session_id string
---@param project string
---@return string[]
function M._get_session_preview(session_id, project)
  -- Normalize project path to match Claude's directory naming
  local normalized = project:gsub("/", "-")
  local session_file = M.config_dir() .. "/projects/" .. normalized .. "/" .. session_id .. ".jsonl"

  local f = io.open(session_file, "r")
  if not f then
    return { "Session file not found", "", session_file }
  end

  local lines = {}
  local message_count = 0
  local max_messages = 10

  local parse_ok, parse_err = pcall(function()
    for line in f:lines() do
      if line ~= "" and message_count < max_messages then
        local ok, entry = pcall(vim.json.decode, line)
        if ok and entry and entry.message then
          local role = entry.message.role or entry.type or "unknown"
          local content = ""

          if type(entry.message.content) == "string" then
            content = entry.message.content
          elseif type(entry.message.content) == "table" then
            for _, block in ipairs(entry.message.content) do
              if block.type == "text" and block.text then
                content = content .. block.text
              end
            end
          end

          if content ~= "" then
            if #content > 500 then
              content = content:sub(1, 500) .. "..."
            end

            table.insert(lines, "## " .. role:upper())
            table.insert(lines, "")
            for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
              table.insert(lines, l)
            end
            table.insert(lines, "")
            table.insert(lines, "---")
            table.insert(lines, "")
            message_count = message_count + 1
          end
        end
      end
    end
  end)
  f:close()

  if #lines == 0 then
    return { "No messages found in session" }
  end

  return lines
end

return M
