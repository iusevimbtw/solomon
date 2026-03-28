--- MCP server — manages lifecycle, JSON-RPC dispatch, lock file.
--- Implements the MCP protocol over WebSocket transport.

local transport = require("solomon.mcp.transport")

local M = {}

---@class solomon.MCPServer
---@field ws solomon.WSServer|nil WebSocket server
---@field initialized boolean
---@field lock_path string|nil
---@field handlers table<string, fun(params: table, client: solomon.WSClient): table>

---@type solomon.MCPServer|nil
M.instance = nil

local PROTOCOL_VERSION = "2024-11-05"
local SERVER_NAME = "solomon-nvim"
local SERVER_VERSION = "0.1.0"

--- Start the MCP server.
---@return boolean success
function M.start()
  if M.instance and M.instance.ws then
    vim.notify("[solomon] MCP server already running on port " .. M.instance.ws.port, vim.log.levels.WARN)
    return true
  end

  local handlers_mod = require("solomon.mcp.handlers")
  local tool_handlers = handlers_mod.get_tool_handlers()

  local ws, err = transport.create({
    on_message = function(client, message)
      M._handle_message(client, message)
    end,
    on_connect = function(client)
      vim.notify("[solomon] MCP client connected: " .. client.id, vim.log.levels.INFO)
    end,
    on_disconnect = function(client)
      vim.notify("[solomon] MCP client disconnected: " .. client.id, vim.log.levels.INFO)
    end,
  })

  if not ws then
    vim.notify("[solomon] Failed to start MCP server: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return false
  end

  M.instance = {
    ws = ws,
    initialized = false,
    lock_path = nil,
    handlers = tool_handlers,
  }

  -- Write lock file for Claude Code discovery
  M._write_lock_file(ws.port, ws.auth_token)

  vim.notify(
    string.format("[solomon] MCP server started on port %d", ws.port),
    vim.log.levels.INFO
  )

  return true
end

--- Stop the MCP server.
function M.stop()
  if not M.instance then
    return
  end

  if M.instance.ws then
    transport.stop(M.instance.ws)
  end

  M._remove_lock_file()
  M.instance = nil
  vim.notify("[solomon] MCP server stopped", vim.log.levels.INFO)
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

  -- Route the message
  if method == "initialize" then
    M._handle_initialize(client, id, params)
  elseif method == "notifications/initialized" then
    -- Notification, no response needed
    if M.instance then
      M.instance.initialized = true
      -- Flush queued mentions after a brief delay for Claude to be fully ready
      if #M._mention_queue > 0 then
        vim.defer_fn(function()
          M._flush_mention_queue()
        end, 600)
      end
    end
  elseif method == "ping" then
    M._send_result(client, id, {})
  elseif method == "tools/list" then
    M._handle_tools_list(client, id)
  elseif method == "tools/call" then
    M._handle_tools_call(client, id, params)
  elseif method == "resources/list" then
    M._handle_resources_list(client, id)
  elseif method == "resources/read" then
    M._handle_resources_read(client, id, params)
  else
    -- Unknown method
    if id then
      M._send_error(client, id, -32601, "Method not found: " .. tostring(method))
    end
  end
end

--- Handle initialize request.
---@param client solomon.WSClient
---@param id any
---@param params table
function M._handle_initialize(client, id, params)
  M._send_result(client, id, {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = {
      tools = { listChanged = true },
      resources = { subscribe = false, listChanged = true },
    },
    serverInfo = {
      name = SERVER_NAME,
      version = SERVER_VERSION,
    },
    instructions = "Solomon Neovim MCP server. Provides access to Neovim buffers, diagnostics, and editor operations.",
  })
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

  -- Execute the handler (handlers run via vim.schedule for Neovim API safety)
  local handler = M.instance.handlers[tool_name]
  local success, result = pcall(handler, arguments, client)

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

  -- List open buffers as resources
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
  transport.send(client, msg)
end

--- Mention queue for at_mentioned notifications sent before Claude connects.
M._mention_queue = {}

--- Broadcast a JSON-RPC notification to all connected clients.
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
  for _, client in pairs(M.instance.ws.clients) do
    if client.upgraded then
      transport.send(client, msg)
    end
  end
end

--- Check if any Claude client is connected and initialized.
---@return boolean
function M.is_client_connected()
  if not M.instance or not M.instance.ws or not M.instance.initialized then
    return false
  end
  for _, client in pairs(M.instance.ws.clients) do
    if client.upgraded then
      return true
    end
  end
  return false
end

--- Send an at_mentioned notification for a file selection.
--- If Claude is not connected, queues the mention for delivery after handshake.
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

  if M.is_client_connected() then
    M.broadcast_notification("notifications/at_mentioned", {
      filePath = mention.filePath,
      lineStart = mention.lineStart,
      lineEnd = mention.lineEnd,
    })
  else
    -- Queue for delivery when Claude connects
    table.insert(M._mention_queue, mention)
  end
end

--- Flush queued mentions to connected clients.
--- Called after Claude completes handshake.
function M._flush_mention_queue()
  local now = vim.uv.hrtime()
  local queue = M._mention_queue
  M._mention_queue = {}

  -- Process sequentially with 25ms delays between mentions
  local function send_next(idx)
    if idx > #queue then
      return
    end
    local mention = queue[idx]
    -- Discard mentions older than 5 seconds
    local age_ms = (now - mention.timestamp) / 1e6
    if age_ms < 5000 then
      M.broadcast_notification("notifications/at_mentioned", {
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

--- Write the lock file for Claude Code discovery.
---@param port integer
---@param auth_token string
function M._write_lock_file(port, auth_token)
  local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
  local ide_dir = config_dir .. "/ide"

  -- Ensure the directory exists
  vim.fn.mkdir(ide_dir, "p")

  local lock_path = ide_dir .. "/" .. port .. ".lock"
  local lock_data = vim.json.encode({
    port = port,
    authToken = auth_token,
    pid = vim.fn.getpid(),
    workspacePath = vim.fn.getcwd(),
    serverName = SERVER_NAME,
    serverVersion = SERVER_VERSION,
  })

  local f = io.open(lock_path, "w")
  if f then
    f:write(lock_data)
    f:close()
    if M.instance then
      M.instance.lock_path = lock_path
    end
  else
    vim.notify("[solomon] Failed to write lock file: " .. lock_path, vim.log.levels.WARN)
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
