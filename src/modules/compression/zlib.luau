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

--[=[
	A streaming deflate compressor. Feed data incrementally with `write`,
	then call `finish` to flush remaining output and close the stream.
]=]
export type Deflate = setmetatable<{}, {
	__index: {
		--[=[
			Compresses a chunk of input data. Returns compressed output (may be empty
			if zlib is buffering). Use flush constants (FLUSH_SYNC, FLUSH_FULL) to
			force output.
			@param data buffer -- input bytes to compress
			@param flush number? -- flush mode (FLUSH_NO, FLUSH_SYNC, FLUSH_FULL)
			@return buffer -- compressed output (may be empty)
		]=]
		write: (self: Deflate, data: buffer, flush: number?) -> buffer,
		--[=[
			Finishes the stream: flushes all remaining data and closes the compressor.
			@return buffer -- final compressed output
		]=]
		finish: (self: Deflate) -> buffer,
		--[=[
			Closes the stream without finishing, freeing resources.
		]=]
		close: (self: Deflate) -> (),
	},
}>

--[=[
	A streaming inflate decompressor. Feed compressed chunks with `write`;
	the second return value indicates when the stream is complete.
]=]
export type Inflate = setmetatable<{}, {
	__index: {
		--[=[
			Decompresses a chunk of compressed data. Returns decompressed output
			and a boolean indicating whether the stream has ended.
			@param data buffer -- compressed bytes
			@return buffer -- decompressed output
			@return boolean -- true when the stream is fully decompressed
		]=]
		write: (self: Inflate, data: buffer) -> (buffer, boolean),
		--[=[
			Closes the stream, freeing resources.
		]=]
		close: (self: Inflate) -> (),
	},
}>

--[=[
	Creates a streaming deflate compressor.
	@param level number? -- compression level
	@param windowBits number? -- window bits (MAX_WBITS, RAW_WBITS, GZIP_WBITS)
	@param memLevel number? -- memory level 1..9
	@param strategy number? -- compression strategy
	@return Deflate -- the streaming compressor
]=]
function zlib.createDeflate(level: number?, windowBits: number?, memLevel: number?, strategy: number?): Deflate
	return nil :: any
end

--[=[
	Creates a streaming inflate decompressor.
	@param windowBits number? -- window bits (MAX_WBITS, RAW_WBITS, AUTO_WBITS)
	@return Inflate -- the streaming decompressor
]=]
function zlib.createInflate(windowBits: number?): Inflate
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

--- Flush constants for streaming
zlib.FLUSH_NO = 0 :: number
zlib.FLUSH_SYNC = 2 :: number
zlib.FLUSH_FULL = 3 :: number
zlib.FLUSH_FINISH = 4 :: number

--- windowBits presets for compressRaw / decompressRaw
zlib.MAX_WBITS = 15 :: number --- standard zlib
zlib.RAW_WBITS = -15 :: number --- raw deflate (no header/trailer)
zlib.GZIP_WBITS = 31 :: number --- gzip wrapper
zlib.AUTO_WBITS = 47 :: number --- auto-detect zlib or gzip on decompress

return zlib
