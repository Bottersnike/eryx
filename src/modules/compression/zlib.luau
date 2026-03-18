--[=[
Zlib utilities: compress/decompress, checksums, and helpers.
]=]

local zlib = {}

--[=[
	Standard zlib compress (zlib header + Adler-32 trailer).
	@param data buffer -- input bytes to compress
	@param level number? -- compression level (NO_COMPRESSION..BEST_COMPRESSION)
	@return buffer -- compressed zlib stream
]=]
function zlib.compress(data: buffer, level: number?): buffer
	return nil :: any
end

--[=[
	Full deflateInit2 access. Use windowBits=RAW_WBITS(-15) for headerless
	raw deflate, GZIP_WBITS(MAX_WBITS+16) for gzip, AUTO_WBITS(MAX_WBITS+32)
	to auto-detect. memLevel 1-9 trades memory for speed. strategy: STRATEGY_*.
	@param data buffer -- input bytes to compress
	@param level number? -- compression level
	@param windowBits number? -- window bits preset (MAX_WBITS/RAW_WBITS/etc)
	@param memLevel number? -- memory level 1..9
	@param strategy number? -- compression strategy constant
	@return buffer -- deflate stream (no outer wrapper unless windowBits requests it)
]=]
function zlib.compressRaw(
	data: buffer,
	level: number?,
	windowBits: number?,
	memLevel: number?,
	strategy: number?
): buffer
	return nil :: any
end

--[=[
	Standard zlib inflate.
	@param data buffer -- zlib-wrapped compressed data
	@return buffer -- decompressed bytes
]=]
function zlib.decompress(data: buffer): buffer
	return nil :: any
end

--[=[
	Inflate with custom windowBits (e.g. RAW_WBITS for raw deflate streams).
	@param data buffer -- compressed stream
	@param windowBits number? -- window bits preset
	@return buffer -- decompressed bytes
]=]
function zlib.decompressRaw(data: buffer, windowBits: number?): buffer
	return nil :: any
end

--[=[
	Running Adler-32 checksum. Pass previous result as `initial` to chain.
	@param data buffer -- input bytes to checksum
	@param initial number? -- previous checksum to continue from
	@return number checksum value
]=]
function zlib.adler32(data: buffer, initial: number?): number
	return nil :: any
end

--[=[
	Running CRC-32 checksum. Pass previous result as `initial` to chain.
	@param data buffer -- input bytes to checksum
	@param initial number? -- previous checksum to continue from
	@return number checksum value
]=]
function zlib.crc32(data: buffer, initial: number?): number
	return nil :: any
end

--[=[
	Upper bound on compressed output size for input of `len` bytes.
	@param len number -- input length in bytes
	@return number upper bound in bytes
]=]
function zlib.compressBound(len: number): number
	return nil :: any
end

--- Compression levels
zlib.NO_COMPRESSION = 0 :: number
zlib.BEST_SPEED = 1 :: number
zlib.BEST_COMPRESSION = 9 :: number
zlib.DEFAULT_COMPRESSION = -1 :: number

--- Deflate strategies
zlib.STRATEGY_DEFAULT = 0 :: number
zlib.STRATEGY_FILTERED = 1 :: number
zlib.STRATEGY_HUFFMAN_ONLY = 2 :: number
zlib.STRATEGY_RLE = 3 :: number
zlib.STRATEGY_FIXED = 4 :: number

--- windowBits presets for compressRaw / decompressRaw
zlib.MAX_WBITS = 15 :: number --- standard zlib
zlib.RAW_WBITS = -15 :: number --- raw deflate (no header/trailer)
zlib.GZIP_WBITS = 31 :: number --- gzip wrapper
zlib.AUTO_WBITS = 47 :: number --- auto-detect zlib or gzip on decompress

return zlib
