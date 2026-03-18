--[=[
Zstandard compression helpers: compress/decompress and dictionary support.
]=]

local zstd = {}

--[=[
	Compress data with Zstandard.
	@param data buffer -- input bytes to compress
	@param level number? -- compression level (CLEVEL_MIN..CLEVEL_MAX)
	@return buffer -- compressed zstd frame

	level: CLEVEL_MIN (negative, ultra-fast) - CLEVEL_MAX (22, best).
	Default CLEVEL_DEFAULT (3). Negative levels trade ratio for extreme speed.
]=]
function zstd.compress(data: buffer, level: number?): buffer
	return nil :: any
end

--[=[
	Decompress a Zstandard frame.
	@param data buffer -- zstd frame to decompress
	@return buffer -- decompressed bytes

	Uses the content size embedded in the frame header when available (fast path).
]=]
function zstd.decompress(data: buffer): buffer
	return nil :: any
end

--[=[
	Upper bound on compressed output size for `len` input bytes.
	@param len number -- input length in bytes
	@return number -- upper bound on compressed size
]=]
function zstd.compressBound(len: number): number
	return nil :: any
end

--[=[
	Returns the decompressed size stored in the frame header, or nil if it
	was not stored (compressed with contentSize=0) or the frame is invalid.
	@param data buffer -- zstd frame
	@return number? -- decompressed size or nil
]=]
function zstd.frameContentSize(data: buffer): number?
	return nil :: any
end

--[=[
	Compress using a pre-trained dictionary. The same dictionary must be
	supplied to decompressWithDict.
	@param data buffer -- input bytes
	@param dict buffer -- dictionary data
	@param level number? -- compression level
	@return buffer -- compressed frame
]=]
function zstd.compressWithDict(data: buffer, dict: buffer, level: number?): buffer
	return nil :: any
end

--[=[
	Decompress using a pre-trained dictionary.
	@param data buffer -- compressed frame
	@param dict buffer -- dictionary data used for compression
	@return buffer -- decompressed bytes
]=]
function zstd.decompressWithDict(data: buffer, dict: buffer): buffer
	return nil :: any
end

--[=[
	Train a Zstandard dictionary from an array of sample buffers.
	@param samples { buffer } -- representative examples of data
	@param capacity number -- desired dictionary size in bytes
	@return buffer -- trained dictionary

	samples: { buffer } - representative examples of data you plan to compress.
	capacity: desired dictionary size in bytes (e.g. 112640 = 110 KB).
	Returns a dictionary buffer ready to pass to compress/decompressWithDict.
]=]
function zstd.trainDictionary(samples: { buffer }, capacity: number): buffer
	return nil :: any
end

--- Compression level constants
zstd.CLEVEL_MIN = -131072 :: number --- approximate; call compressBound for the real value
zstd.CLEVEL_MAX = 22 :: number
zstd.CLEVEL_DEFAULT = 3 :: number

return zstd
