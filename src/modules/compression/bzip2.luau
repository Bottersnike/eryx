--[=[
Bzip2 compression utilities.
]=]

local bzip2 = {}

--[=[
	Compress data with bzip2.
	@param data buffer -- input bytes to compress
	@param blockSize number? -- block size 1..9 (higher=better compression)
	@return buffer -- compressed bzip2 stream

	blockSize: 1 (BLOCK_FAST, least memory) - 9 (BLOCK_BEST, best compression).
	Default 9. Controls the Burrows-Wheeler block size; higher = better ratio
	but ~100 KB more memory per level during compression.
]=]
function bzip2.compress(data: buffer, blockSize: number?): buffer
	return nil :: any
end

--[=[
	Decompress bzip2 data.
	@param data buffer -- compressed bzip2 stream
	@param small boolean? -- use small-memory decoder when true
	@return buffer -- decompressed bytes

	small: if true, uses an alternative algorithm (~2 MB vs ~3.5 MB RAM)
	at roughly half the speed. Useful in memory-constrained environments.
]=]
function bzip2.decompress(data: buffer, small: boolean?): buffer
	return nil :: any
end

--[=[
	Conservative upper bound on compressed output size for `len` input bytes.
	@param len number -- input length in bytes
	@return number -- upper bound on compressed size

	The exact formula is approximately len * 1.01 + 600.
]=]
function bzip2.compressBound(len: number): number
	return nil :: any
end

--[=[
	A streaming bzip2 compressor.
]=]
export type Compressor = setmetatable<{}, { __index: {
	write: (self: Compressor, data: buffer) -> buffer,
	flush: (self: Compressor) -> buffer,
	finish: (self: Compressor) -> buffer,
	close: (self: Compressor) -> (),
} }>

--[=[
	A streaming bzip2 decompressor.
]=]
export type Decompressor = setmetatable<{}, { __index: {
	write: (self: Decompressor, data: buffer) -> (buffer, boolean),
	close: (self: Decompressor) -> (),
} }>

--[=[
	Creates a streaming bzip2 compressor.
	@param blockSize number? -- block size 1..9
	@return Compressor -- the streaming compressor
]=]
function bzip2.createCompressor(blockSize: number?): Compressor
	return nil :: any
end

--[=[
	Creates a streaming bzip2 decompressor.
	@param small boolean? -- use small-memory decoder
	@return Decompressor -- the streaming decompressor
]=]
function bzip2.createDecompressor(small: boolean?): Decompressor
	return nil :: any
end

--- Block size constants
bzip2.BLOCK_FAST = 1 :: number --- fastest, least memory
bzip2.BLOCK_BEST = 9 :: number --- best compression, most memory

return bzip2
