--[=[
Brotli compression helpers.
]=]

local brotli = {}

--[=[
	Compress data with Brotli.
	@param data buffer -- input bytes to compress
	@param quality number? -- 0..11 (QUALITY_MIN..QUALITY_MAX). Default 11.
	@param lgwin number? -- log2 window size in bytes (WINDOW_MIN..WINDOW_MAX). Default 22.
	@param mode number? -- MODE_GENERIC/MODE_TEXT/MODE_FONT
	@return buffer -- compressed brotli frame
]=]
function brotli.compress(data: buffer, quality: number?, lgwin: number?, mode: number?): buffer
	return nil :: any
end

--[=[
	Decompress Brotli data.
	@param data buffer -- brotli frame to decompress
	@return buffer -- decompressed bytes
]=]
function brotli.decompress(data: buffer): buffer
	return nil :: any
end

--[=[
	Upper bound on compressed output size for `len` input bytes.
	@param len number -- input length in bytes
	@return number -- upper bound in bytes (0 if too large)

	Returns 0 if len is too large for Brotli to handle in one call.
]=]
function brotli.maxCompressedSize(len: number): number
	return nil :: any
end

--- Mode constants
brotli.MODE_GENERIC = 0 :: number --- general data
brotli.MODE_TEXT = 1 :: number --- UTF-8 text (enables context modelling)
brotli.MODE_FONT = 2 :: number --- WOFF2 font data

--- Quality constants
brotli.QUALITY_MIN = 0 :: number
brotli.QUALITY_MAX = 11 :: number
brotli.QUALITY_DEFAULT = 11 :: number

--- Window size constants (log2 of bytes, so WINDOW_MAX=24 means 16 MB window)
brotli.WINDOW_MIN = 10 :: number
brotli.WINDOW_MAX = 24 :: number
brotli.WINDOW_DEFAULT = 22 :: number

return brotli
