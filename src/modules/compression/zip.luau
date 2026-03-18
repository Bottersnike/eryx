--[=[
	Zip file entry metadata returned by `zip.list` and `ZipReader:List`.
	@field name string: the entry filename (directories end with '/')
	@field size number: uncompressed size in bytes
	@field compressedSize number: compressed size in bytes
	@field method number: compression method (compare with `zip.METHOD_*`)
	@field crc32 number: CRC32 checksum of the entry
]=]
export type EntryInfo = {
	name: string,
	size: number,
	compressedSize: number,
	method: number,
	crc32: number,
}

export type PackOptions = {
	method: ("store" | "deflate")?,
	level: number?,
}

export type ZipReader = {
	--[=[
		List entries in the opened archive. Directories have names ending with '/'.
		@return { EntryInfo } -- list of entries in archive
	]=]
	List: (self: ZipReader) -> { EntryInfo },

	--[=[
		Read a named entry from the opened archive. Returns nil if not found.
		@param name string -- entry filename (case-sensitive)
		@return buffer? -- the entry contents or nil
	]=]
	Read: (self: ZipReader, name: string) -> buffer?,

	--- Close the reader and release any pinned buffer. Safe to call multiple times.
	Close: (self: ZipReader) -> (),
}

local zip = {}

--[=[
	Fast magic-byte check. Returns true if the buffer looks like a zip archive.
	Checks for `PK\x03\x04` (normal zip) or `PK\x05\x06` (empty zip).

	Open a zip archive from an in-memory buffer and return a `ZipReader`.
	The returned reader pins the provided buffer to avoid copying; call
	`reader:Close()` (or let it be GC'd) to release the buffer.
	@param data buffer -- zip archive bytes
	@return ZipReader -- reader object
]=]
function zip.open(data: buffer): ZipReader
	return nil :: any
end

--[=[
	Quick check whether `data` begins with ZIP magic bytes.
	@param data buffer -- data to inspect
	@return boolean -- true when buffer looks like a zip archive
]=]
function zip.isZip(data: buffer): boolean
	return nil :: any
end

--[=[
	List all entries in a zip archive without extracting.
	Directories appear as entries whose name ends with '/'.
	Return a list of `EntryInfo` for every entry in the given archive.
	This is a convenience wrapper that opens the archive transiently.
	@param data buffer -- zip archive bytes
	@return { EntryInfo } -- ordered list of entries
]=]
function zip.list(data: buffer): { EntryInfo }
	return nil :: any
end

--[=[
	Extract all files from a zip into a name->buffer table.
	Directory entries are skipped.
	Unpack all non-directory entries into a name -> buffer table.
	@param data buffer -- zip archive bytes
	@return { [string]: buffer } -- map of filename -> contents
]=]
function zip.unpack(data: buffer): { [string]: buffer }
	return nil :: any
end

--[=[
	Read a single named entry from a zip. Returns nil if not found.
	Name is matched case-sensitively.
	This opens the archive, locates the entry, reads it, and closes the archive.
	@param data buffer -- zip archive bytes
	@param name string -- entry filename to read (case-sensitive)
	@return buffer? -- entry contents or nil if not found
]=]
function zip.read(data: buffer, name: string): buffer?
	return nil :: any
end

--[=[
	Pack a name->buffer table into a zip archive returned as a buffer.
	options.method: "deflate" (default) or "store" (no compression)
	options.level: 1 (fastest) - 9 (best), -1 = default
	Create a ZIP archive from a map of filename -> buffer.
	@param files { [string]: buffer } -- map of filenames to data
	@param options? PackOptions -- optional packing options
	@return buffer -- the generated zip archive
]=]
function zip.pack(files: { [string]: buffer }, options: PackOptions?): buffer
	return nil :: any
end

--- Compression method constants (for comparing EntryInfo.method)
zip.METHOD_STORE = 0 :: number
zip.METHOD_DEFLATE = 8 :: number

return zip
