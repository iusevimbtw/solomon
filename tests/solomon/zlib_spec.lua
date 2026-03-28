describe("solomon.mcp.zlib", function()
  local zlib

  before_each(function()
    package.loaded["solomon.mcp.zlib"] = nil
    zlib = require("solomon.mcp.zlib")
  end)

  describe("is_available", function()
    it("returns true on systems with libz", function()
      assert.is_true(zlib.is_available())
    end)
  end)

  describe("version", function()
    it("returns a version string", function()
      local ver = zlib.version()
      assert.is_string(ver)
      assert.truthy(ver:match("^%d+%."))
    end)
  end)

  describe("deflate_raw / inflate_raw round-trip", function()
    it("compresses and decompresses short text", function()
      local original = "Hello, WebSocket compression!"
      local compressed, err = zlib.deflate_raw(original)
      assert.is_nil(err)
      assert.is_string(compressed)
      assert.is_true(#compressed > 0)

      local decompressed, err2 = zlib.inflate_raw(compressed)
      assert.is_nil(err2)
      assert.equals(original, decompressed)
    end)

    it("compresses and decompresses JSON", function()
      local original = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
      local compressed = zlib.deflate_raw(original)
      assert.is_not_nil(compressed)

      local decompressed = zlib.inflate_raw(compressed)
      assert.equals(original, decompressed)
    end)

    it("compresses and decompresses large text", function()
      local original = string.rep("The quick brown fox jumps over the lazy dog. ", 100)
      local compressed = zlib.deflate_raw(original)
      assert.is_not_nil(compressed)
      -- Compressed should be much smaller for repetitive text
      assert.is_true(#compressed < #original)

      local decompressed = zlib.inflate_raw(compressed)
      assert.equals(original, decompressed)
    end)

    it("compresses and decompresses empty string", function()
      local compressed = zlib.deflate_raw("")
      assert.is_not_nil(compressed)

      local decompressed = zlib.inflate_raw(compressed)
      assert.equals("", decompressed)
    end)

    it("compressed data does not end with sync flush trailer", function()
      local compressed = zlib.deflate_raw("test data")
      assert.is_not_nil(compressed)
      -- Per RFC 7692, trailing 0x00 0x00 0xff 0xff should be stripped
      if #compressed >= 4 then
        assert.are_not.equal(
          zlib.SYNC_FLUSH_TRAILER,
          compressed:sub(-4)
        )
      end
    end)
  end)
end)
