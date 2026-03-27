-- Pure Lua SHA-1 implementation for WebSocket handshake.
-- Minimal, self-contained, no external dependencies.
-- Based on RFC 3174.

local M = {}

local bit = require("bit")
local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

local function uint32(n)
  return band(n, 0xFFFFFFFF)
end

local function rotl(x, n)
  return uint32(bor(lshift(x, n), rshift(x, 32 - n)))
end

--- Compute SHA-1 hash and return raw 20-byte binary string.
---@param msg string
---@return string
function M.binary(msg)
  local len = #msg
  local bit_len = len * 8

  -- Pre-processing: padding
  msg = msg .. "\128" -- append bit '1'
  local pad = (56 - (#msg % 64)) % 64
  msg = msg .. string.rep("\0", pad)
  -- Append original length as 64-bit big-endian
  msg = msg .. string.char(
    0, 0, 0, 0, -- high 32 bits (we only support < 2^32 bit messages)
    band(rshift(bit_len, 24), 0xFF),
    band(rshift(bit_len, 16), 0xFF),
    band(rshift(bit_len, 8), 0xFF),
    band(bit_len, 0xFF)
  )

  -- Initialize hash values
  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  -- Process each 512-bit (64-byte) chunk
  for chunk_start = 1, #msg, 64 do
    local w = {}

    -- Break chunk into sixteen 32-bit big-endian words
    for i = 0, 15 do
      local offset = chunk_start + i * 4
      local b1, b2, b3, b4 = msg:byte(offset, offset + 3)
      w[i] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
    end

    -- Extend the sixteen 32-bit words into eighty 32-bit words
    for i = 16, 79 do
      w[i] = rotl(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for i = 0, 79 do
      local f, k
      if i <= 19 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i <= 39 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif i <= 59 then
        f = bor(band(b, c), band(b, d), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end

      local temp = uint32(rotl(a, 5) + f + e + k + w[i])
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = temp
    end

    h0 = uint32(h0 + a)
    h1 = uint32(h1 + b)
    h2 = uint32(h2 + c)
    h3 = uint32(h3 + d)
    h4 = uint32(h4 + e)
  end

  -- Produce the final 20-byte binary digest
  local function to_bytes(n)
    return string.char(
      band(rshift(n, 24), 0xFF),
      band(rshift(n, 16), 0xFF),
      band(rshift(n, 8), 0xFF),
      band(n, 0xFF)
    )
  end

  return to_bytes(h0) .. to_bytes(h1) .. to_bytes(h2) .. to_bytes(h3) .. to_bytes(h4)
end

return M
