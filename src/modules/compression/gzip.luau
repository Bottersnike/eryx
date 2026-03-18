--[=[
Gzip helpers: compress/decompress and header inspection utilities.
]=]

export type GzipHeader = {
	method: number, --- compression method (8 = deflate)
	flags: number, --- raw FLG byte
	mtime: number, --- modification time (Unix timestamp, 0 if not set)
	xfl: number, --- extra flags
	os: number, --- OS identifier (see OS_* constants)
	name: string?, --- original filename, if embedded
	comment: string?, --- comment, if embedded
	extra: buffer?, --- extra field bytes, if present
	headerCrc16: number?, --- header CRC-16, if FHCRC flag is set
	dataOffset: number, --- byte offset where compressed payload begins
}

export type CompressExOptions = {
	level: number?, --- compression level (NO_COMPRESSION-BEST_COMPRESSION)
	name: string?, --- embed a filename in the header
	comment: string?, --- embed a comment in the header
	mtime: number?, --- embed a modification timestamp (Unix seconds)
	os: number?, --- OS identifier constant (default OS_UNKNOWN)
}

local gzip = {}

--[=[
	Standard gzip compress.
	@param data buffer -- input bytes to compress
	@param level number? -- compression level (NO_COMPRESSION..BEST_COMPRESSION)
	@return buffer -- gzip-wrapped compressed bytes
]=]
function gzip.compress(data: buffer, level: number?): buffer
	return nil :: any
end

--[=[
	Gzip compress with a custom header (filename, timestamp, OS, comment).
	@param data buffer -- input bytes to compress
	@param options CompressExOptions -- header and compression options
	@return buffer -- gzip-wrapped compressed bytes
]=]
function gzip.compressEx(data: buffer, options: CompressExOptions): buffer
	return nil :: any
end

--[=[
	Gzip decompress.
	@param data buffer -- gzip stream to decompress
	@return buffer -- decompressed bytes
]=]
function gzip.decompress(data: buffer): buffer
	return nil :: any
end

--[=[
	Returns true if the buffer starts with the gzip magic bytes (0x1F 0x8B).
	@param data buffer -- data to inspect
	@return boolean -- true when buffer looks like gzip
]=]
function gzip.isGzip(data: buffer): boolean
	return nil :: any
end

--[=[
	Parses the gzip header fields without decompressing the payload.
	@param data buffer -- gzip stream
	@return GzipHeader -- parsed header fields
]=]
function gzip.readHeader(data: buffer): GzipHeader
	return nil :: any
end

--- OS identifier constants (from the gzip spec RFC 1952)
gzip.OS_FAT = 0 :: number --- MS-DOS / FAT
gzip.OS_AMIGA = 1 :: number
gzip.OS_VMS = 2 :: number
gzip.OS_UNIX = 3 :: number
gzip.OS_HPFS = 6 :: number --- OS/2 / NT
gzip.OS_MAC = 7 :: number
gzip.OS_NTFS = 11 :: number
gzip.OS_UNKNOWN = 255 :: number

--- Compression levels
gzip.NO_COMPRESSION = 0 :: number
gzip.BEST_SPEED = 1 :: number
gzip.BEST_COMPRESSION = 9 :: number
gzip.DEFAULT_COMPRESSION = -1 :: number

return gzip
