describe("solomon.mcp.transport", function()
  local transport

  before_each(function()
    package.loaded["solomon.mcp.transport"] = nil
    package.loaded["solomon.mcp.sha1"] = nil
    transport = require("solomon.mcp.transport")
  end)

  describe("_encode_frame", function()
    it("encodes small text frame", function()
      local frame = transport._encode_frame(0x1, "hi")
      -- FIN + text opcode = 0x81, length = 2, payload = "hi"
      assert.equals(4, #frame)
      assert.equals(0x81, frame:byte(1))
      assert.equals(2, frame:byte(2))
      assert.equals(string.byte("h"), frame:byte(3))
      assert.equals(string.byte("i"), frame:byte(4))
    end)

    it("encodes empty frame", function()
      local frame = transport._encode_frame(0x1, "")
      assert.equals(2, #frame)
      assert.equals(0x81, frame:byte(1))
      assert.equals(0, frame:byte(2))
    end)

    it("uses 2-byte length for 126-byte payload", function()
      local payload = string.rep("x", 126)
      local frame = transport._encode_frame(0x1, payload)
      assert.equals(0x81, frame:byte(1))
      assert.equals(126, frame:byte(2)) -- signals 2-byte extended length
      -- Next 2 bytes = length 126 in big-endian
      assert.equals(0, frame:byte(3))
      assert.equals(126, frame:byte(4))
      assert.equals(126 + 4, #frame)
    end)

    it("uses 2-byte length for 1000-byte payload", function()
      local payload = string.rep("x", 1000)
      local frame = transport._encode_frame(0x1, payload)
      assert.equals(126, frame:byte(2))
      local len = frame:byte(3) * 256 + frame:byte(4)
      assert.equals(1000, len)
    end)

    it("encodes close frame", function()
      local frame = transport._encode_frame(0x8, "")
      assert.equals(0x88, frame:byte(1)) -- FIN + close opcode
    end)

    it("encodes pong frame", function()
      local frame = transport._encode_frame(0xA, "ping-data")
      assert.equals(0x8A, frame:byte(1)) -- FIN + pong opcode
    end)
  end)

  describe("_decode_frame", function()
    it("decodes unmasked text frame", function()
      -- Build a frame: FIN + text, unmasked, length 5, "hello"
      local data = string.char(0x81, 5) .. "hello"
      local frame, payload, consumed = transport._decode_frame(data)
      assert.is_not_nil(frame)
      assert.is_true(frame.fin)
      assert.equals(0x1, frame.opcode)
      assert.equals("hello", payload)
      assert.equals(7, consumed)
    end)

    it("returns nil for incomplete header", function()
      local frame, payload, consumed = transport._decode_frame("x")
      assert.is_nil(frame)
    end)

    it("returns nil for incomplete payload", function()
      local data = string.char(0x81, 10) .. "short"
      local frame, payload, consumed = transport._decode_frame(data)
      assert.is_nil(frame)
    end)

    it("decodes masked frame", function()
      -- Masked frame: FIN + text, masked, length 4, mask key, masked payload
      local mask = { 0x37, 0xfa, 0x21, 0x3d }
      local plain = "test"
      local masked = ""
      for i = 1, #plain do
        masked = masked .. string.char(bit.bxor(plain:byte(i), mask[((i - 1) % 4) + 1]))
      end
      local data = string.char(0x81, bit.bor(0x80, 4)) -- masked + length 4
        .. string.char(mask[1], mask[2], mask[3], mask[4])
        .. masked
      local frame, payload, consumed = transport._decode_frame(data)
      assert.is_not_nil(frame)
      assert.equals("test", payload)
    end)

    it("round-trips with _encode_frame for unmasked", function()
      local original = "Hello, WebSocket!"
      local encoded = transport._encode_frame(0x1, original)
      local frame, payload, consumed = transport._decode_frame(encoded)
      assert.is_not_nil(frame)
      assert.equals(original, payload)
      assert.equals(#encoded, consumed)
    end)

    it("handles close frame", function()
      local data = string.char(0x88, 0) -- FIN + close, no payload
      local frame, payload, consumed = transport._decode_frame(data)
      assert.is_not_nil(frame)
      assert.equals(0x8, frame.opcode)
    end)
  end)

  describe("_generate_token", function()
    it("returns a string", function()
      local token = transport._generate_token()
      assert.is_string(token)
    end)

    it("has UUID-like format", function()
      local token = transport._generate_token()
      assert.truthy(token:match("^%x+%-%x+%-4%x+%-%x+%-%x+$"))
    end)

    it("generates unique tokens", function()
      local a = transport._generate_token()
      local b = transport._generate_token()
      assert.are_not.equal(a, b)
    end)
  end)
end)
