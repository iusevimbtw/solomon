describe("solomon.mcp.server", function()
  local server

  before_each(function()
    package.loaded["solomon.mcp.server"] = nil
    package.loaded["solomon.mcp.handlers"] = nil
    package.loaded["solomon.mcp.transport"] = nil
    package.loaded["solomon.mcp.sha1"] = nil
    package.loaded["solomon.config"] = nil
    require("solomon.config").setup()
    server = require("solomon.mcp.server")

    -- Set up a minimal mock instance (no actual WebSocket)
    server.instance = {
      ws = { clients = {}, port = 12345 },
      lock_path = nil,
      handlers = require("solomon.mcp.handlers").get_tool_handlers(),
      clients = {},
      pending_cancels = {},
    }
  end)

  after_each(function()
    server._mention_queue = {}
    server._stop_heartbeat()
    server.instance = nil
  end)

  describe("per-client state", function()
    it("tracks client state on connect", function()
      -- Simulate on_connect
      local client = { id = "test-client-1", upgraded = true }
      server.instance.clients[client.id] = {
        handshake_complete = false,
        protocol_version = nil,
        capabilities = nil,
      }

      assert.is_not_nil(server.instance.clients["test-client-1"])
      assert.is_false(server.instance.clients["test-client-1"].handshake_complete)
    end)

    it("cleans up client state on disconnect", function()
      server.instance.clients["test-client-1"] = {
        handshake_complete = true,
        protocol_version = "2024-11-05",
        capabilities = {},
      }

      -- Simulate on_disconnect
      server.instance.clients["test-client-1"] = nil

      assert.is_nil(server.instance.clients["test-client-1"])
    end)

    it("marks handshake complete on initialized notification", function()
      local client = { id = "c1", upgraded = true, socket = {} }
      server.instance.clients["c1"] = {
        handshake_complete = false,
        protocol_version = "2024-11-05",
        capabilities = {},
      }

      server._handle_initialized(client)

      assert.is_true(server.instance.clients["c1"].handshake_complete)
    end)
  end)

  describe("protocol version negotiation", function()
    local sent_messages = {}
    local mock_client

    before_each(function()
      sent_messages = {}
      mock_client = { id = "c1", upgraded = true, socket = {} }
      server.instance.clients["c1"] = {
        handshake_complete = false,
        protocol_version = nil,
        capabilities = nil,
      }
      -- Mock transport.send to capture messages
      local transport = require("solomon.mcp.transport")
      transport.send = function(client, msg)
        table.insert(sent_messages, vim.json.decode(msg))
      end
    end)

    it("accepts supported protocol version 2024-11-05", function()
      server._handle_initialize(mock_client, 1, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "test", version = "1.0" },
      })

      assert.equals(1, #sent_messages)
      assert.is_not_nil(sent_messages[1].result)
      assert.equals("2024-11-05", sent_messages[1].result.protocolVersion)
    end)

    it("accepts supported protocol version 2025-03-26", function()
      server._handle_initialize(mock_client, 1, {
        protocolVersion = "2025-03-26",
        capabilities = {},
        clientInfo = { name = "test", version = "1.0" },
      })

      assert.equals(1, #sent_messages)
      assert.equals("2025-03-26", sent_messages[1].result.protocolVersion)
    end)

    it("accepts any protocol version by echoing it back", function()
      server._handle_initialize(mock_client, 1, {
        protocolVersion = "9999-01-01",
        capabilities = {},
      })

      assert.equals(1, #sent_messages)
      assert.is_not_nil(sent_messages[1].result)
      assert.equals("9999-01-01", sent_messages[1].result.protocolVersion)
    end)

    it("stores client capabilities after initialize", function()
      server._handle_initialize(mock_client, 1, {
        protocolVersion = "2024-11-05",
        capabilities = { roots = { listChanged = true } },
      })

      local state = server.instance.clients["c1"]
      assert.equals("2024-11-05", state.protocol_version)
      assert.is_not_nil(state.capabilities)
      assert.is_true(state.capabilities.roots.listChanged)
    end)
  end)

  describe("request cancellation", function()
    it("tracks cancelled request IDs", function()
      server._handle_cancelled({ requestId = 42 })
      assert.is_true(server.instance.pending_cancels[42])
    end)

    it("is_cancelled returns true and clears the ID", function()
      server.instance.pending_cancels[42] = true

      assert.is_true(server.is_cancelled(42))
      -- Should be cleared after check
      assert.is_false(server.is_cancelled(42))
    end)

    it("is_cancelled returns false for unknown IDs", function()
      assert.is_false(server.is_cancelled(999))
    end)
  end)

  describe("is_client_connected", function()
    it("returns false when no clients", function()
      assert.is_false(server.is_client_connected())
    end)

    it("returns false when client connected but handshake not complete", function()
      local client = { id = "c1", upgraded = true }
      server.instance.ws.clients = { [{}] = client }
      server.instance.clients["c1"] = {
        handshake_complete = false,
      }

      assert.is_false(server.is_client_connected())
    end)

    it("returns true when client connected and handshake complete", function()
      local client = { id = "c1", upgraded = true }
      server.instance.ws.clients = { [{}] = client }
      server.instance.clients["c1"] = {
        handshake_complete = true,
      }

      assert.is_true(server.is_client_connected())
    end)
  end)

  describe("mention queue", function()
    it("queues mentions when no client connected", function()
      assert.equals(0, #server._mention_queue)

      server.send_at_mention("/tmp/test.lua", 1, 10)

      assert.equals(1, #server._mention_queue)
      assert.equals("/tmp/test.lua", server._mention_queue[1].filePath)
      assert.equals(1, server._mention_queue[1].lineStart)
      assert.equals(10, server._mention_queue[1].lineEnd)
    end)

    it("queues multiple mentions", function()
      server.send_at_mention("/tmp/a.lua", 1, 5)
      server.send_at_mention("/tmp/b.lua", 10, 20)

      assert.equals(2, #server._mention_queue)
      assert.equals("/tmp/a.lua", server._mention_queue[1].filePath)
      assert.equals("/tmp/b.lua", server._mention_queue[2].filePath)
    end)

    it("flush clears the queue", function()
      server.send_at_mention("/tmp/test.lua", 1, 5)
      assert.equals(1, #server._mention_queue)

      server._flush_mention_queue()

      assert.equals(0, #server._mention_queue)
    end)

    it("flush discards mentions older than 10 seconds", function()
      -- Insert a mention with a very old timestamp
      table.insert(server._mention_queue, {
        filePath = "/tmp/old.lua",
        lineStart = 1,
        lineEnd = 5,
        timestamp = vim.uv.hrtime() - (11 * 1e9), -- 11 seconds ago
      })

      -- This should discard the old mention (no error, just skipped)
      server._flush_mention_queue()
      assert.equals(0, #server._mention_queue)
    end)
  end)

  describe("broadcast_notification", function()
    it("only sends to handshake-complete clients", function()
      local sent_to = {}
      local transport = require("solomon.mcp.transport")
      transport.send = function(client, msg)
        table.insert(sent_to, client.id)
      end

      local ready_client = { id = "ready", upgraded = true, socket = {} }
      local pending_client = { id = "pending", upgraded = true, socket = {} }

      server.instance.ws.clients = {
        [{}] = ready_client,
        [{}] = pending_client,
      }
      server.instance.clients["ready"] = { handshake_complete = true }
      server.instance.clients["pending"] = { handshake_complete = false }

      server.broadcast_notification("test/method", { data = "hello" })

      -- Only the ready client should receive it
      assert.equals(1, #sent_to)
      assert.equals("ready", sent_to[1])
    end)
  end)

  describe("graceful shutdown", function()
    it("sends shutdown notification on stop", function()
      local sent_messages = {}
      local transport = require("solomon.mcp.transport")

      -- Mock transport
      local orig_send = transport.send
      transport.send = function(client, msg)
        table.insert(sent_messages, vim.json.decode(msg))
      end
      local orig_stop = transport.stop
      transport.stop = function() end

      local client = { id = "c1", upgraded = true, socket = {} }
      server.instance.ws.clients = { [{}] = client }
      server.instance.clients["c1"] = { handshake_complete = true }

      server.stop()

      -- Should have sent shutdown notification
      local found_shutdown = false
      for _, msg in ipairs(sent_messages) do
        if msg.method == "notifications/server_shutdown" then
          found_shutdown = true
        end
      end
      assert.is_true(found_shutdown)

      -- Restore
      transport.send = orig_send
      transport.stop = orig_stop
    end)
  end)
end)
