--- Pure FFI wrapper for zlib raw deflate/inflate.
--- Used for WebSocket permessage-deflate (RFC 7692).

local M = {}

local ffi = require("ffi")

-- Track if zlib is available
local zlib_lib = nil
local _available = false

-- WebSocket permessage-deflate trailer that gets stripped/appended
M.SYNC_FLUSH_TRAILER = "\x00\x00\xff\xff"

-- zlib constants
local Z_OK = 0
local Z_STREAM_END = 1
local Z_SYNC_FLUSH = 2
local Z_FINISH = 4
local Z_DEFLATED = 8
local Z_DEFAULT_COMPRESSION = -1
local MAX_WBITS = 15
local DEF_MEM_LEVEL = 8
local Z_DEFAULT_STRATEGY = 0

-- Define zlib structures and functions
ffi.cdef([[
  typedef struct {
    const unsigned char *next_in;
    unsigned int avail_in;
    unsigned long total_in;
    unsigned char *next_out;
    unsigned int avail_out;
    unsigned long total_out;
    const char *msg;
    void *state;
    void *zalloc;
    void *zfree;
    void *opaque;
    int data_type;
    unsigned long adler;
    unsigned long reserved;
  } z_stream;

  const char *zlibVersion(void);
  int deflateInit2_(z_stream*, int, int, int, int, int, const char*, int);
  int inflateInit2_(z_stream*, int, const char*, int);
  int deflate(z_stream*, int);
  int inflate(z_stream*, int);
  int deflateEnd(z_stream*);
  int inflateEnd(z_stream*);
]])

--- Try to load the zlib library.
local function init()
  if _available then
    return true
  end
  local ok, lib = pcall(ffi.load, "z")
  if ok and lib then
    zlib_lib = lib
    _available = true
    return true
  end
  return false
end

--- Check if zlib is available.
---@return boolean
function M.is_available()
  return init()
end

--- Get zlib version string.
---@return string|nil
function M.version()
  if not init() then
    return nil
  end
  return ffi.string(zlib_lib.zlibVersion())
end

--- Compress data using raw deflate (no header/trailer).
--- Per RFC 7692: uses -MAX_WBITS for raw deflate, Z_SYNC_FLUSH,
--- and strips the trailing 0x00 0x00 0xff 0xff.
---@param data string
---@return string|nil compressed
---@return string|nil error
function M.deflate_raw(data)
  if not init() then
    return nil, "zlib not available"
  end

  local stream = ffi.new("z_stream")
  stream.zalloc = nil
  stream.zfree = nil
  stream.opaque = nil

  -- -MAX_WBITS = raw deflate (no zlib/gzip header)
  local ver = zlib_lib.zlibVersion()
  local ret = zlib_lib.deflateInit2_(
    stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
    -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY,
    ver, ffi.sizeof("z_stream")
  )
  if ret ~= Z_OK then
    return nil, "deflateInit2 failed: " .. ret
  end

  local input_buf = ffi.new("unsigned char[?]", #data)
  ffi.copy(input_buf, data, #data)

  -- Output buffer — compressed data is typically similar size or smaller
  local out_size = #data + 256
  local output_buf = ffi.new("unsigned char[?]", out_size)

  stream.next_in = input_buf
  stream.avail_in = #data
  stream.next_out = output_buf
  stream.avail_out = out_size

  ret = zlib_lib.deflate(stream, Z_SYNC_FLUSH)
  if ret ~= Z_OK then
    zlib_lib.deflateEnd(stream)
    return nil, "deflate failed: " .. ret
  end

  local compressed_len = out_size - stream.avail_out
  zlib_lib.deflateEnd(stream)

  local compressed = ffi.string(output_buf, compressed_len)

  -- Strip trailing sync flush marker (0x00 0x00 0xff 0xff) per RFC 7692
  if #compressed >= 4 and compressed:sub(-4) == M.SYNC_FLUSH_TRAILER then
    compressed = compressed:sub(1, -5)
  end

  return compressed, nil
end

--- Decompress raw deflate data.
--- Per RFC 7692: appends 0x00 0x00 0xff 0xff before inflating.
---@param data string
---@return string|nil decompressed
---@return string|nil error
function M.inflate_raw(data)
  if not init() then
    return nil, "zlib not available"
  end

  -- Append sync flush trailer per RFC 7692
  data = data .. M.SYNC_FLUSH_TRAILER

  local stream = ffi.new("z_stream")
  stream.zalloc = nil
  stream.zfree = nil
  stream.opaque = nil

  local ver = zlib_lib.zlibVersion()
  local ret = zlib_lib.inflateInit2_(stream, -MAX_WBITS, ver, ffi.sizeof("z_stream"))
  if ret ~= Z_OK then
    return nil, "inflateInit2 failed: " .. ret
  end

  local input_buf = ffi.new("unsigned char[?]", #data)
  ffi.copy(input_buf, data, #data)

  stream.next_in = input_buf
  stream.avail_in = #data

  -- Inflate in chunks — decompressed size is unknown
  local chunks = {}
  local chunk_size = math.max(#data * 20, 4096)
  local output_buf = ffi.new("unsigned char[?]", chunk_size)

  repeat
    stream.next_out = output_buf
    stream.avail_out = chunk_size

    ret = zlib_lib.inflate(stream, Z_SYNC_FLUSH)
    if ret ~= Z_OK and ret ~= Z_STREAM_END then
      zlib_lib.inflateEnd(stream)
      return nil, "inflate failed: " .. ret
    end

    local produced = chunk_size - stream.avail_out
    if produced > 0 then
      chunks[#chunks + 1] = ffi.string(output_buf, produced)
    end
  until stream.avail_in == 0 or ret == Z_STREAM_END

  zlib_lib.inflateEnd(stream)
  return table.concat(chunks), nil
end

return M
