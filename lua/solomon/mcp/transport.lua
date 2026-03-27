--- WebSocket server transport for MCP communication.
--- Uses vim.uv TCP server with RFC 6455 WebSocket framing.

local sha1 = require("solomon.mcp.sha1")
local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local M = {}

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- WebSocket opcodes
local OP_TEXT = 0x1
local OP_CLOSE = 0x8
local OP_PING = 0x9
local OP_PONG = 0xA

---@class solomon.WSServer
---@field tcp userdata vim.uv tcp handle
---@field port integer
---@field auth_token string
---@field clients table<userdata, solomon.WSClient>
---@field on_message fun(client: solomon.WSClient, message: string)
---@field on_connect fun(client: solomon.WSClient)
---@field on_disconnect fun(client: solomon.WSClient)

---@class solomon.WSClient
---@field socket userdata
---@field upgraded boolean
---@field buffer string
---@field id string

--- Create a new WebSocket server.
---@param opts {on_message: fun(client: solomon.WSClient, message: string), on_connect: fun(client: solomon.WSClient), on_disconnect: fun(client: solomon.WSClient)}
---@return solomon.WSServer|nil server
---@return string|nil error
function M.create(opts)
  local tcp = vim.uv.new_tcp()
  if not tcp then
    return nil, "Failed to create TCP socket"
  end

  -- Generate auth token
  local auth_token = M._generate_token()

  -- Bind to random port on localhost
  local ok, err = tcp:bind("127.0.0.1", 0)
  if not ok then
    tcp:close()
    return nil, "Failed to bind: " .. tostring(err)
  end

  -- Get the assigned port
  local addr = tcp:getsockname()
  if not addr then
    tcp:close()
    return nil, "Failed to get socket address"
  end

  local server = {
    tcp = tcp,
    port = addr.port,
    auth_token = auth_token,
    clients = {},
    on_message = opts.on_message,
    on_connect = opts.on_connect,
    on_disconnect = opts.on_disconnect,
  }

  tcp:listen(128, function(listen_err)
    if listen_err then
      vim.schedule(function()
        vim.notify("[solomon] MCP listen error: " .. listen_err, vim.log.levels.ERROR)
      end)
      return
    end

    local client_socket = vim.uv.new_tcp()
    tcp:accept(client_socket)

    local client = {
      socket = client_socket,
      upgraded = false,
      buffer = "",
      id = M._generate_token():sub(1, 8),
    }

    server.clients[client_socket] = client

    client_socket:read_start(function(read_err, chunk)
      if read_err then
        M._remove_client(server, client)
        return
      end

      if not chunk then
        -- Connection closed
        M._remove_client(server, client)
        return
      end

      if not client.upgraded then
        M._handle_upgrade(server, client, chunk)
      else
        M._handle_ws_data(server, client, chunk)
      end
    end)
  end)

  return server, nil
end

--- Stop the WebSocket server.
---@param server solomon.WSServer
function M.stop(server)
  -- Close all clients
  for socket, client in pairs(server.clients) do
    pcall(function()
      M.send_close(client)
      socket:read_stop()
      if not socket:is_closing() then
        socket:close()
      end
    end)
  end
  server.clients = {}

  -- Close the server socket
  if not server.tcp:is_closing() then
    server.tcp:close()
  end
end

--- Send a text message to a WebSocket client.
---@param client solomon.WSClient
---@param message string
function M.send(client, message)
  if not client.upgraded then
    return
  end
  local frame = M._encode_frame(OP_TEXT, message)
  pcall(function()
    client.socket:write(frame)
  end)
end

--- Send a close frame to a WebSocket client.
---@param client solomon.WSClient
function M.send_close(client)
  if not client.upgraded then
    return
  end
  local frame = M._encode_frame(OP_CLOSE, "")
  pcall(function()
    client.socket:write(frame)
  end)
end

--- Handle the HTTP upgrade request for WebSocket.
---@param server solomon.WSServer
---@param client solomon.WSClient
---@param data string
function M._handle_upgrade(server, client, data)
  client.buffer = client.buffer .. data

  -- Check if we have a complete HTTP request (ends with \r\n\r\n)
  if not client.buffer:find("\r\n\r\n") then
    return
  end

  local request = client.buffer
  client.buffer = ""

  -- Extract Sec-WebSocket-Key
  local ws_key = request:match("Sec%-WebSocket%-Key:%s*([^\r\n]+)")
  if not ws_key then
    client.socket:write("HTTP/1.1 400 Bad Request\r\n\r\n")
    M._remove_client(server, client)
    return
  end

  -- Validate auth token from URL query parameter or header
  local auth = request:match("[?&]token=([^%s&]+)")
    or request:match("Authorization:%s*Bearer%s+([^\r\n]+)")
  if auth ~= server.auth_token then
    client.socket:write("HTTP/1.1 401 Unauthorized\r\n\r\n")
    M._remove_client(server, client)
    return
  end

  -- Compute accept header
  local accept = vim.base64.encode(sha1.binary(ws_key .. WS_GUID))

  -- Send upgrade response
  local response = table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
    "",
    "",
  }, "\r\n")

  client.socket:write(response)
  client.upgraded = true

  vim.schedule(function()
    server.on_connect(client)
  end)
end

--- Handle incoming WebSocket frame data.
---@param server solomon.WSServer
---@param client solomon.WSClient
---@param data string
function M._handle_ws_data(server, client, data)
  client.buffer = client.buffer .. data

  -- Process all complete frames in the buffer
  while #client.buffer >= 2 do
    local frame, payload, bytes_consumed = M._decode_frame(client.buffer)
    if not frame then
      break -- Incomplete frame, wait for more data
    end

    client.buffer = client.buffer:sub(bytes_consumed + 1)

    if frame.opcode == OP_TEXT then
      vim.schedule(function()
        server.on_message(client, payload)
      end)
    elseif frame.opcode == OP_PING then
      -- Respond with pong
      local pong = M._encode_frame(OP_PONG, payload)
      pcall(function()
        client.socket:write(pong)
      end)
    elseif frame.opcode == OP_CLOSE then
      M._remove_client(server, client)
      return
    end
  end
end

--- Remove a client from the server and clean up.
---@param server solomon.WSServer
---@param client solomon.WSClient
function M._remove_client(server, client)
  server.clients[client.socket] = nil
  pcall(function()
    client.socket:read_stop()
    if not client.socket:is_closing() then
      client.socket:close()
    end
  end)
  vim.schedule(function()
    server.on_disconnect(client)
  end)
end

--- Decode a WebSocket frame from buffer.
---@param data string
---@return table|nil frame
---@return string|nil payload
---@return integer|nil bytes_consumed
function M._decode_frame(data)
  if #data < 2 then
    return nil, nil, nil
  end

  local b1 = data:byte(1)
  local b2 = data:byte(2)

  local fin = band(b1, 0x80) ~= 0
  local opcode = band(b1, 0x0F)
  local masked = band(b2, 0x80) ~= 0
  local payload_len = band(b2, 0x7F)

  local offset = 2

  if payload_len == 126 then
    if #data < 4 then
      return nil, nil, nil
    end
    payload_len = lshift(data:byte(3), 8) + data:byte(4)
    offset = 4
  elseif payload_len == 127 then
    if #data < 10 then
      return nil, nil, nil
    end
    -- Read 64-bit length (only lower 32 bits for practicality)
    payload_len = lshift(data:byte(7), 24)
      + lshift(data:byte(8), 16)
      + lshift(data:byte(9), 8)
      + data:byte(10)
    offset = 10
  end

  local mask_key
  if masked then
    if #data < offset + 4 then
      return nil, nil, nil
    end
    mask_key = { data:byte(offset + 1, offset + 4) }
    offset = offset + 4
  end

  if #data < offset + payload_len then
    return nil, nil, nil
  end

  -- Extract and unmask payload
  local payload_bytes = { data:byte(offset + 1, offset + payload_len) }
  if masked and mask_key then
    for i = 1, #payload_bytes do
      payload_bytes[i] = bxor(payload_bytes[i], mask_key[((i - 1) % 4) + 1])
    end
  end

  -- Chunked conversion to avoid Lua stack limit with large payloads
  local chunks = {}
  for i = 1, #payload_bytes, 4096 do
    local end_i = math.min(i + 4095, #payload_bytes)
    chunks[#chunks + 1] = string.char(unpack(payload_bytes, i, end_i))
  end
  local payload = table.concat(chunks)
  local frame = { fin = fin, opcode = opcode }

  return frame, payload, offset + payload_len
end

--- Encode a WebSocket frame (server → client, unmasked).
---@param opcode integer
---@param payload string
---@return string
function M._encode_frame(opcode, payload)
  local len = #payload
  local header

  if len <= 125 then
    header = string.char(bor(0x80, opcode), len)
  elseif len <= 65535 then
    header = string.char(
      bor(0x80, opcode),
      126,
      band(rshift(len, 8), 0xFF),
      band(len, 0xFF)
    )
  else
    header = string.char(
      bor(0x80, opcode),
      127,
      0, 0, 0, 0, -- high 32 bits
      band(rshift(len, 24), 0xFF),
      band(rshift(len, 16), 0xFF),
      band(rshift(len, 8), 0xFF),
      band(len, 0xFF)
    )
  end

  return header .. payload
end

--- Generate a random UUID-like token.
---@return string
function M._generate_token()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

return M
