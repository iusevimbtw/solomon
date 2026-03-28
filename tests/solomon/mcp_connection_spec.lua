describe("solomon.mcp end-to-end connection", function()
  local server, transport

  before_each(function()
    package.loaded["solomon.mcp.server"] = nil
    package.loaded["solomon.mcp.transport"] = nil
    package.loaded["solomon.mcp.handlers"] = nil
    package.loaded["solomon.mcp.sha1"] = nil
    package.loaded["solomon.config"] = nil
    require("solomon.config").setup({ mcp = { enabled = true, auto_start = false } })
    server = require("solomon.mcp.server")
    transport = require("solomon.mcp.transport")
  end)

  after_each(function()
    if server.is_running() then
      server.stop()
    end
  end)

  it("MCP server starts and listens on a port", function()
    local ok = server.start()
    assert.is_true(ok)
    assert.is_true(server.is_running())

    local port = server.get_port()
    assert.is_number(port)
    assert.is_true(port > 0)
  end)

  it("lock file is written with correct fields", function()
    server.start()
    local port = server.get_port()

    local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
    local lock_path = config_dir .. "/ide/" .. port .. ".lock"

    local f = io.open(lock_path, "r")
    assert.is_not_nil(f, "Lock file should exist at " .. lock_path)

    local content = f:read("*a")
    f:close()

    local data = vim.json.decode(content)
    assert.is_string(data.authToken)
    assert.is_number(data.pid)
    assert.is_table(data.workspaceFolders)
    assert.is_true(#data.workspaceFolders > 0)
    assert.equals("ws", data.transport)
    assert.equals("Neovim", data.ideName)
  end)

  it("WebSocket client can connect and complete handshake", function()
    server.start()
    local port = server.get_port()

    -- Read auth token from lock file
    local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
    local lock_path = config_dir .. "/ide/" .. port .. ".lock"
    local f = io.open(lock_path, "r")
    local lock_data = vim.json.decode(f:read("*a"))
    f:close()

    -- Connect as a TCP client
    local client = vim.uv.new_tcp()
    local connected = false
    local upgrade_response = ""
    local connect_err = nil

    client:connect("127.0.0.1", port, function(err)
      if err then
        connect_err = err
        return
      end
      connected = true

      -- Send WebSocket upgrade request (mimicking Claude Code)
      local ws_key = "dGhlIHNhbXBsZSBub25jZQ=="
      local request = table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1:" .. port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. ws_key,
        "Sec-WebSocket-Version: 13",
        "X-Claude-Code-IDE-Authorization: " .. lock_data.authToken,
        "",
        "",
      }, "\r\n")

      client:write(request)

      client:read_start(function(read_err, data)
        if data then
          upgrade_response = upgrade_response .. data
        end
      end)
    end)

    -- Wait for connection and response
    vim.wait(2000, function()
      return #upgrade_response > 0 or connect_err ~= nil
    end, 10)

    -- Clean up
    pcall(function()
      client:read_stop()
      if not client:is_closing() then
        client:close()
      end
    end)

    assert.is_nil(connect_err, "TCP connection should succeed, got: " .. tostring(connect_err))
    assert.is_true(connected, "Should have connected")
    assert.truthy(upgrade_response:find("101 Switching Protocols"), "Should get 101 response, got: " .. upgrade_response:sub(1, 200))
    assert.truthy(upgrade_response:find("Sec%-WebSocket%-Accept"), "Should have accept header")
  end)

  it("WebSocket client rejected with wrong auth token", function()
    server.start()
    local port = server.get_port()

    local client = vim.uv.new_tcp()
    local response = ""

    client:connect("127.0.0.1", port, function(err)
      if err then return end

      local request = table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1:" .. port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "X-Claude-Code-IDE-Authorization: wrong-token-12345",
        "",
        "",
      }, "\r\n")

      client:write(request)
      client:read_start(function(_, data)
        if data then response = response .. data end
      end)
    end)

    vim.wait(2000, function()
      return #response > 0
    end, 10)

    pcall(function()
      client:read_stop()
      if not client:is_closing() then client:close() end
    end)

    assert.truthy(response:find("401 Unauthorized"), "Should reject bad auth, got: " .. response:sub(1, 200))
  end)

  it("MCP initialize handshake works over WebSocket", function()
    server.start()
    local port = server.get_port()

    local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")
    local lock_path = config_dir .. "/ide/" .. port .. ".lock"
    local lf = io.open(lock_path, "r")
    local lock_data = vim.json.decode(lf:read("*a"))
    lf:close()

    local client = vim.uv.new_tcp()
    local responses = {}
    local ws_upgraded = false

    client:connect("127.0.0.1", port, function(err)
      if err then return end

      -- WebSocket upgrade
      local ws_key = "dGhlIHNhbXBsZSBub25jZQ=="
      local request = table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1:" .. port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. ws_key,
        "Sec-WebSocket-Version: 13",
        "X-Claude-Code-IDE-Authorization: " .. lock_data.authToken,
        "",
        "",
      }, "\r\n")

      client:write(request)

      local buffer = ""
      client:read_start(function(_, data)
        if not data then return end
        buffer = buffer .. data

        if not ws_upgraded then
          if buffer:find("\r\n\r\n") then
            ws_upgraded = true
            -- Remove HTTP response from buffer
            local _, http_end = buffer:find("\r\n\r\n")
            buffer = buffer:sub(http_end + 1)

            -- Send MCP initialize request as a WebSocket text frame
            local init_msg = vim.json.encode({
              jsonrpc = "2.0",
              id = 1,
              method = "initialize",
              params = {
                protocolVersion = "2024-11-05",
                capabilities = {},
                clientInfo = { name = "test-client", version = "1.0" },
              },
            })
            local frame = transport._encode_frame(0x1, init_msg)
            client:write(frame)
          end
        else
          -- Try to decode WebSocket frames
          while #buffer >= 2 do
            local frame, payload, consumed = transport._decode_frame(buffer)
            if not frame then break end
            buffer = buffer:sub(consumed + 1)
            if payload and #payload > 0 then
              local ok, msg = pcall(vim.json.decode, payload)
              if ok then
                table.insert(responses, msg)
              end
            end
          end
        end
      end)
    end)

    -- Wait for MCP response
    vim.wait(3000, function()
      return #responses > 0
    end, 10)

    pcall(function()
      client:read_stop()
      if not client:is_closing() then client:close() end
    end)

    assert.is_true(#responses > 0, "Should have received MCP response")

    local init_response = responses[1]
    assert.equals(1, init_response.id)
    assert.is_not_nil(init_response.result)
    assert.equals("2024-11-05", init_response.result.protocolVersion)
    assert.equals("claudecode-neovim", init_response.result.serverInfo.name)
    assert.is_not_nil(init_response.result.capabilities.tools)
  end)
end)
