--- MCP server — manages lifecycle, JSON-RPC dispatch, lock file.
--- Implements the MCP protocol over WebSocket transport.

local transport = require("solomon.mcp.transport")

local M = {}

-- ─── Logging ───

M._log_path = nil
M._log_enabled = false

--- Enable MCP debug logging to a file.
function M.enable_logging()
  local log_dir = vim.fn.stdpath("log")
  vim.fn.mkdir(log_dir, "p")
  M._log_path = log_dir .. "/solomon-mcp.log"
  M._log_enabled = true
  -- Clear previous log
  local f = io.open(M._log_path, "w")
  if f then
    f:write("=== Solomon MCP log started " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
    f:close()
  end
  vim.notify("[solomon] MCP logging to " .. M._log_path, vim.log.levels.INFO)
end

--- Write a line to the MCP log.
---@param direction string "RECV", "SEND", "INFO", "ERROR"
---@param msg string
function M._log(direction, msg)
  if not M._log_enabled or not M._log_path then
    return
  end
  local f = io.open(M._log_path, "a")
  if f then
    f:write(string.format("[%s] %s: %s\n", os.date("%H:%M:%S"), direction, msg))
    f:close()
  end
end

---@class solomon.MCPServer
---@field ws solomon.WSServer|nil WebSocket server
---@field lock_path string|nil
---@field handlers table<string, fun(params: table, client: solomon.WSClient): table>
---@field clients table<string, solomon.MCPClientState> Per-client state keyed by client.id
---@field pending_cancels table<any, boolean> Set of cancelled request IDs

---@class solomon.MCPClientState
---@field handshake_complete boolean
---@field protocol_version string|nil
---@field capabilities table|nil Client's requested capabilities

---@type solomon.MCPServer|nil
M.instance = nil

local PROTOCOL_VERSION = "2024-11-05"
local SUPPORTED_VERSIONS = {
  ["2024-11-05"] = true,
  ["2025-03-26"] = true,
  ["2025-06-18"] = true,
}
local SERVER_NAME = "solomon-nvim"
local SERVER_VERSION = "0.1.0"

--- Start the MCP server.
---@return boolean success
function M.start()
  if M.instance and M.instance.ws then
    M._log("INFO", "MCP server already running on port " .. M.instance.ws.port)
    return true
  end

  local handlers_mod = require("solomon.mcp.handlers")
  local tool_handlers = handlers_mod.get_tool_handlers()

  local ws, err = transport.create({
    on_message = function(client, message)
      M._handle_message(client, message)
    end,
    on_connect = function(client)
      -- Initialize per-client state
      if M.instance then
        M.instance.clients[client.id] = {
          handshake_complete = false,
          protocol_version = nil,
          capabilities = nil,
        }
      end
      M._log("INFO", "Client connected: " .. client.id)
    end,
    on_disconnect = function(client)
      -- Clean up per-client state
      if M.instance then
        M.instance.clients[client.id] = nil
        -- Stop refresh and selection tracking if no clients remain
        if not M.is_client_connected() then
          pcall(function() require("solomon.refresh").stop() end)
          pcall(function() require("solomon.selection").disable() end)
        end
      end
      M._log("INFO", "Client disconnected: " .. client.id)
    end,
  })

  if not ws then
    M._log("ERROR", "Failed to start MCP server: " .. (err or "unknown error"))
    return false
  end

  M.instance = {
    ws = ws,
    lock_path = nil,
    handlers = tool_handlers,
    clients = {},
    pending_cancels = {},
  }

  -- Write lock file for Claude Code discovery
  M._write_lock_file(ws.port, ws.auth_token)

  -- Start heartbeat timer to detect dead connections
  M._start_heartbeat()

  M._log("INFO", string.format("MCP server started on port %d", ws.port))

  return true
end

--- Stop the MCP server with graceful shutdown.
function M.stop()
  if not M.instance then
    return
  end

  -- Stop heartbeat, file refresh, and selection tracking
  M._stop_heartbeat()
  pcall(function() require("solomon.refresh").stop() end)
  pcall(function() require("solomon.selection").disable() end)

  -- Send close notification to all clients before shutting down
  if M.instance.ws then
    for _, client in pairs(M.instance.ws.clients) do
      if client.upgraded then
        pcall(function()
          transport.send(client, vim.json.encode({
            jsonrpc = "2.0",
            method = "notifications/server_shutdown",
          }))
        end)
      end
    end
    transport.stop(M.instance.ws)
  end

  M._remove_lock_file()
  M.instance = nil
  M._log("INFO", "MCP server stopped")
end

--- Check if the MCP server is running.
---@return boolean
function M.is_running()
  return M.instance ~= nil and M.instance.ws ~= nil
end

--- Get the server port.
---@return integer|nil
function M.get_port()
  if M.instance and M.instance.ws then
    return M.instance.ws.port
  end
  return nil
end

--- Handle an incoming JSON-RPC message.
---@param client solomon.WSClient
---@param raw string
function M._handle_message(client, raw)
  local ok, msg = pcall(vim.json.decode, raw)
  if not ok or not msg then
    M._send_error(client, nil, -32700, "Parse error")
    return
  end

  local method = msg.method
  local id = msg.id
  local params = msg.params or {}

  M._log("RECV", raw)

  -- Dispatch table for MCP methods
  local dispatch = {
    initialize = function() M._handle_initialize(client, id, params) end,
    ["notifications/initialized"] = function() M._handle_initialized(client) end,
    ["notifications/cancelled"] = function() M._handle_cancelled(params) end,
    ping = function() M._send_result(client, id, {}) end,
    ["tools/list"] = function() M._handle_tools_list(client, id) end,
    ["tools/call"] = function() M._handle_tools_call(client, id, params) end,
    ["prompts/list"] = function() M._send_result(client, id, { prompts = {} }) end,
    ["resources/list"] = function() M._handle_resources_list(client, id) end,
    ["resources/read"] = function() M._handle_resources_read(client, id, params) end,
    ide_connected = function()
      M._log("INFO", "Claude IDE connected, pid=" .. tostring(params.pid))
    end,
  }

  local handler = dispatch[method]
  if handler then
    handler()
  else
    if id then
      M._send_error(client, id, -32601, "Method not found: " .. tostring(method))
    end
    M._log("INFO", "Unhandled method: " .. tostring(method))
  end
end

--- Handle initialize request with protocol version negotiation.
---@param client solomon.WSClient
---@param id any
---@param params table
function M._handle_initialize(client, id, params)
  local requested_version = params.protocolVersion or PROTOCOL_VERSION

  -- Store client capabilities
  if M.instance and M.instance.clients[client.id] then
    M.instance.clients[client.id].protocol_version = requested_version
    M.instance.clients[client.id].capabilities = params.capabilities
  end

  -- Accept whatever version the client wants — echo it back
  local server_caps = {
    logging = vim.empty_dict(),
    prompts = { listChanged = true },
    resources = { subscribe = true, listChanged = true },
    tools = { listChanged = true },
  }

  M._send_result(client, id, {
    protocolVersion = requested_version,
    capabilities = server_caps,
    serverInfo = {
      name = "claudecode-neovim",
      version = SERVER_VERSION,
    },
  })
end

--- Handle notifications/initialized — client confirms handshake complete.
---@param client solomon.WSClient
function M._handle_initialized(client)
  if M.instance and M.instance.clients[client.id] then
    M.instance.clients[client.id].handshake_complete = true
  end

  -- Flush queued mentions after a brief delay for Claude to be fully ready
  if #M._mention_queue > 0 then
    vim.defer_fn(function()
      M._flush_mention_queue()
    end, 600)
  end

  -- Start auto-refresh so buffers reload when Claude edits files
  pcall(function()
    require("solomon.refresh").start()
  end)

  -- Start selection tracking so Claude knows what user is looking at
  pcall(function()
    require("solomon.selection").enable()
  end)
end

--- Handle notifications/cancelled — client cancels an in-flight request.
---@param params table
function M._handle_cancelled(params)
  if params.requestId and M.instance then
    M.instance.pending_cancels[params.requestId] = true
  end
end

--- Check if a request has been cancelled.
---@param id any
---@return boolean
function M.is_cancelled(id)
  if M.instance and M.instance.pending_cancels[id] then
    M.instance.pending_cancels[id] = nil
    return true
  end
  return false
end

--- Handle tools/list request.
---@param client solomon.WSClient
---@param id any
function M._handle_tools_list(client, id)
  local handlers_mod = require("solomon.mcp.handlers")
  M._send_result(client, id, {
    tools = handlers_mod.get_tool_definitions(),
  })
end

--- Handle tools/call request.
---@param client solomon.WSClient
---@param id any
---@param params table
function M._handle_tools_call(client, id, params)
  local tool_name = params.name
  local arguments = params.arguments or {}

  if not M.instance or not M.instance.handlers[tool_name] then
    M._send_error(client, id, -32602, "Unknown tool: " .. tostring(tool_name))
    return
  end

  -- Check if request was already cancelled
  if M.is_cancelled(id) then
    return
  end

  local handler = M.instance.handlers[tool_name]
  local success, result = pcall(handler, arguments, client)

  -- Check again after handler execution
  if M.is_cancelled(id) then
    return
  end

  if success then
    M._send_result(client, id, {
      content = {
        { type = "text", text = type(result) == "string" and result or vim.json.encode(result) },
      },
    })
  else
    M._send_result(client, id, {
      content = {
        { type = "text", text = "Error: " .. tostring(result) },
      },
      isError = true,
    })
  end
end

--- Handle resources/list request.
---@param client solomon.WSClient
---@param id any
function M._handle_resources_list(client, id)
  local resources = {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(resources, {
          uri = "nvim://buffer/" .. buf,
          name = vim.fn.fnamemodify(name, ":t"),
          description = name,
          mimeType = "text/plain",
        })
      end
    end
  end

  M._send_result(client, id, {
    resources = resources,
  })
end

--- Handle resources/read request.
---@param client solomon.WSClient
---@param id any
---@param params table
function M._handle_resources_read(client, id, params)
  local uri = params.uri
  local buf_id = tonumber(uri:match("nvim://buffer/(%d+)"))

  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    M._send_error(client, id, -32602, "Invalid buffer URI: " .. tostring(uri))
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  local content = table.concat(lines, "\n")

  M._send_result(client, id, {
    contents = {
      {
        uri = uri,
        mimeType = "text/plain",
        text = content,
      },
    },
  })
end

--- Send a JSON-RPC result response.
---@param client solomon.WSClient
---@param id any
---@param result table
function M._send_result(client, id, result)
  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    result = result,
  })
  M._log("SEND", msg)
  transport.send(client, msg)
end

--- Send a JSON-RPC error response.
---@param client solomon.WSClient
---@param id any
---@param code integer
---@param message string
function M._send_error(client, id, code, message)
  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
    },
  })
  M._log("ERROR", msg)
  transport.send(client, msg)
end

-- ─── Mention queue ───

M._mention_queue = {}

--- Broadcast a JSON-RPC notification to all connected, handshake-complete clients.
---@param method string
---@param params table|nil
function M.broadcast_notification(method, params)
  if not M.instance or not M.instance.ws then
    return
  end
  local msg = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  })
  local sent_count = 0
  for _, client in pairs(M.instance.ws.clients) do
    if client.upgraded then
      local state = M.instance.clients[client.id]
      if state and state.handshake_complete then
        transport.send(client, msg)
        sent_count = sent_count + 1
      end
    end
  end
  M._log("SEND", "Broadcast to " .. sent_count .. " clients: " .. msg:sub(1, 200))
end

--- Check if any Claude client is connected and handshake complete.
---@return boolean
function M.is_client_connected()
  if not M.instance or not M.instance.ws then
    return false
  end
  for _, client in pairs(M.instance.ws.clients) do
    if client.upgraded then
      local state = M.instance.clients[client.id]
      if state and state.handshake_complete then
        return true
      end
    end
  end
  return false
end

--- Send an at_mentioned notification for a file selection.
---@param filepath string Absolute file path
---@param start_line integer 1-indexed
---@param end_line integer 1-indexed
function M.send_at_mention(filepath, start_line, end_line)
  local mention = {
    filePath = filepath,
    lineStart = start_line,
    lineEnd = end_line,
    timestamp = vim.uv.hrtime(),
  }

  M._log("INFO", "send_at_mention: " .. filepath .. ":" .. start_line .. "-" .. end_line
    .. " connected=" .. tostring(M.is_client_connected()))

  if M.is_client_connected() then
    M._log("INFO", "Broadcasting at_mentioned immediately")
    M.broadcast_notification("at_mentioned", {
      filePath = mention.filePath,
      lineStart = mention.lineStart,
      lineEnd = mention.lineEnd,
    })
  else
    table.insert(M._mention_queue, mention)
  end
end

--- Flush queued mentions to connected clients.
function M._flush_mention_queue()
  local now = vim.uv.hrtime()
  local queue = M._mention_queue
  M._mention_queue = {}

  local function send_next(idx)
    if idx > #queue then
      return
    end
    local mention = queue[idx]
    -- Discard mentions older than 5 seconds
    local age_ms = (now - mention.timestamp) / 1e6
    if age_ms < 10000 then
      M.broadcast_notification("at_mentioned", {
        filePath = mention.filePath,
        lineStart = mention.lineStart,
        lineEnd = mention.lineEnd,
      })
    end
    if idx < #queue then
      vim.defer_fn(function()
        send_next(idx + 1)
      end, 25)
    end
  end

  send_next(1)
end

-- ─── Heartbeat ───

M._heartbeat_timer = nil

--- Start a heartbeat timer that pings clients periodically.
function M._start_heartbeat()
  M._stop_heartbeat()
  local timer = vim.uv.new_timer()
  M._heartbeat_timer = timer
  -- Ping every 30 seconds
  timer:start(30000, 30000, vim.schedule_wrap(function()
    if not M.instance or not M.instance.ws then
      M._stop_heartbeat()
      return
    end
    for socket, client in pairs(M.instance.ws.clients) do
      if client.upgraded then
        -- Send WebSocket ping frame
        pcall(function()
          local frame = require("solomon.mcp.transport")._encode_frame(0x9, "")
          socket:write(frame)
        end)
      end
    end
  end))
end

--- Stop the heartbeat timer.
function M._stop_heartbeat()
  if M._heartbeat_timer then
    require("solomon.utils").stop_timer(M._heartbeat_timer)
    M._heartbeat_timer = nil
  end
end

-- ─── Lock file ───

--- Write the lock file for Claude Code discovery.
---@param port integer
---@param auth_token string
function M._write_lock_file(port, auth_token)
  local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
  local ide_dir = config_dir .. "/ide"

  -- Create directory with 0700 permissions
  vim.fn.mkdir(ide_dir, "p")
  vim.fn.setfperm(ide_dir, "rwx------")

  local lock_path = ide_dir .. "/" .. port .. ".lock"
  local lock_data = vim.json.encode({
    pid = vim.fn.getpid(),
    workspaceFolders = { vim.fn.getcwd() },
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  })

  local f = io.open(lock_path, "w")
  if f then
    f:write(lock_data)
    f:close()
    -- Set lock file permissions to 0600
    vim.fn.setfperm(lock_path, "rw-------")
    if M.instance then
      M.instance.lock_path = lock_path
    end
  else
    M._log("ERROR", "Failed to write lock file: " .. lock_path)
  end
end

--- Remove the lock file.
function M._remove_lock_file()
  if M.instance and M.instance.lock_path then
    os.remove(M.instance.lock_path)
    M.instance.lock_path = nil
  end
end

return M
