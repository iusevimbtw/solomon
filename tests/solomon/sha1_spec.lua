describe("solomon.mcp.sha1", function()
  local sha1

  before_each(function()
    package.loaded["solomon.mcp.sha1"] = nil
    sha1 = require("solomon.mcp.sha1")
  end)

  -- Convert binary string to hex for comparison
  local function to_hex(s)
    return (s:gsub(".", function(c)
      return string.format("%02x", string.byte(c))
    end))
  end

  describe("binary", function()
    -- RFC 3174 test vectors
    it("hashes empty string correctly", function()
      local hash = to_hex(sha1.binary(""))
      assert.equals("da39a3ee5e6b4b0d3255bfef95601890afd80709", hash)
    end)

    it("hashes 'abc' correctly", function()
      local hash = to_hex(sha1.binary("abc"))
      assert.equals("a9993e364706816aba3e25717850c26c9cd0d89d", hash)
    end)

    it("hashes 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' correctly", function()
      local hash = to_hex(sha1.binary("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
      assert.equals("84983e441c3bd26ebaae4aa1f95129e5e54670f1", hash)
    end)

    it("returns 20 bytes", function()
      local result = sha1.binary("test")
      assert.equals(20, #result)
    end)

    it("produces correct WebSocket accept header input", function()
      -- Test the exact flow used in WebSocket handshake
      local key = "dGhlIHNhbXBsZSBub25jZQ=="
      local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
      local hash = sha1.binary(key .. guid)
      local accept = vim.base64.encode(hash)
      assert.equals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept)
    end)
  end)
end)
