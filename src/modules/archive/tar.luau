--[=[
	Read TAR archives from streams or filesystem paths, with support for sequential
	iteration, seekable indexing, PAX metadata, GNU long-name records, ACL sideband
	entries, and GNU sparse-file reconstruction.

	This library is designed for archive inspection and extraction workflows rather
	than archive creation. Use `tar.open` for one-pass reading from any readable
	stream, `tar.openSeekable` when the stream also supports seeking, or
	`tar.openPath` to open a TAR file directly from disk. Sequential readers expose
	raw parser entries through `TarReader:nextEntry` and higher-level normalized
	members through `TarReader:nextMember`. Seekable readers can additionally build
	a `TarIndex` for path-based lookups and lazy content reads. Readers that wrap
	open handles should be closed explicitly with `reader:close()` when you are
	finished with them, especially those created through `tar.openPath`.

	Returned members preserve both normalized fields such as `kind`, `path`, and
	`linkPath`, and lower-level format details such as the original header, merged
	PAX attributes, stored payload size, and sparse-file metadata. This makes the
	library suitable both for straightforward unpacking and for tooling that needs to
	inspect TAR format behavior more closely.
]=]

local fs = require("@eryx/fs")
local stream = require("@eryx/stream")
local path = require("@eryx/path")

local tar = {}

local TarReader = {}
TarReader.__index = TarReader

local SeekableTarReader = setmetatable({}, TarReader)
SeekableTarReader.__index = SeekableTarReader

local TarIndex = {}
TarIndex.__index = TarIndex

--[=[
	Internal reader state carried between TAR headers while consuming an archive
	sequentially. This includes persistent global PAX attributes as well as
	one-shot metadata records that apply only to the next member.
]=]
type TarReaderState = {
	--- Byte-oriented source being decoded.
	stream: stream.StreamThatCanRead,
	--- `true` once the reader has been closed and can no longer read from the archive.
	closed: boolean,
	--- PAX attributes inherited by subsequent entries until replaced.
	globalPax: { [string]: string },
	--- PAX attributes queued for only the next entry.
	nextPax: { [string]: string }?,
	--- GNU long path captured from a preceding `L` record.
	longPath: string?,
	--- GNU long link path captured from a preceding `K` record.
	longLinkPath: string?,
	--- ACL text captured from a preceding `A` record.
	pendingAcl: string?,
}

--[=[
	Sequential TAR reader returned by `tar.open`. It walks the archive in stream
	order and exposes raw entries or normalized members one at a time.
]=]
export type TarReader = setmetatable<TarReaderState, typeof(TarReader)>

--[=[
	Seek-capable TAR reader returned by `tar.openSeekable` and `tar.openPath`.
	In addition to sequential reads, this variant can rewind and build a random
	access index because its underlying stream supports seeking.
]=]
export type SeekableTarReader = setmetatable<
	TarReaderState & { stream: stream.StreamThatCanRead & stream.StreamThatCanSeek },
	typeof(SeekableTarReader)
>

--[=[
	Decoded 512-byte TAR header plus any parsed extended timestamp fields. This is
	the closest representation of the on-disk metadata block before higher-level
	normalization is applied.
]=]
type TarEntryHeader = {
	--- Original 512-byte header block.
	raw: buffer,

	--- Raw entry name stored in the header name field.
	name: string,
	--- File mode parsed from the header.
	mode: number,
	--- Owner user id.
	uid: number,
	--- Owner group id.
	gid: number,
	--- Entry payload size reported by the effective header metadata.
	size: number,
	--- Modification time as a Unix timestamp.
	mtime: number,
	--- Header checksum value stored in the archive.
	chksum: number,

	--- TAR type flag describing the entry kind.
	typeflag: string,
	--- Raw link target path for link entries.
	linkname: string,
	--- Archive format marker such as `ustar`.
	magic: string,
	--- USTAR version field when present.
	version: string,
	--- Owner user name when present.
	uname: string,
	--- Owner group name when present.
	gname: string,
	--- Major device number for device entries.
	devmajor: number,
	--- Minor device number for device entries.
	devminor: number,
	--- USTAR path prefix used to extend `name`.
	prefix: string,
	--- Access time from extended metadata when available.
	atime: number?,
	--- Change time from extended metadata when available.
	ctime: number?,
}

--[=[
	Internal entry representation produced directly from the parser before ACL
	coalescing and kind normalization.
]=]
type TarEntry = {
	--- Effective path after applying prefix, GNU long names, and PAX overrides.
	path: string,
	--- Effective TAR type flag for the entry.
	typeflag: string,
	--- Parsed header metadata for the entry.
	header: TarEntryHeader,
	--- Raw payload bytes captured for the entry.
	data: string,
	--- Effective merged PAX attribute map.
	attributes: { [string]: string },
	--- Sparse-file mapping information when the entry uses GNU sparse extensions.
	sparse: TarSparseInfo?,
	--- Byte offset where the stored payload begins for seekable streams.
	dataOffset: number?,
	--- Payload length physically stored in the archive before sparse reconstruction.
	storedSize: number,
	-- offset: number,
}

--[=[
	Single sparse data segment within a sparse TAR member.
]=]
type TarSparseBlock = {
	--- Logical offset where the data segment begins in the reconstructed file.
	offset: number,
	--- Number of stored bytes belonging to the segment.
	length: number,
}

--[=[
	Sparse metadata describing how to reconstruct a logical file from the stored
	payload bytes present in the archive.
]=]
type TarSparseInfo = {
	--- Sparse metadata source, such as `gnu` or `pax`.
	format: string,
	--- Logical size of the fully reconstructed file.
	size: number,
	--- Stored data extents in logical-file order.
	blocks: { TarSparseBlock },
}

--[=[
	Normalized archive member returned by `TarReader:nextMember` and stored inside
	`TarIndex`. This is the main consumer-facing representation of TAR contents.
]=]
export type TarMember = {
	--- Final archive path for the member.
	path: string,
	--- High-level member kind such as `file`, `directory`, or `symlink`.
	kind: string,
	--- Original TAR type flag for callers that need format-level detail.
	typeflag: string,
	--- Parsed header metadata.
	header: TarEntryHeader,
	--- Stored payload bytes captured while reading sequentially.
	data: string,
	--- Byte offset where the stored payload begins, when known.
	dataOffset: number?,
	--- Number of payload bytes physically present in the archive.
	storedSize: number,
	--- Logical content size after accounting for sparse metadata.
	size: number,
	--- Link target for symlink and hardlink members.
	linkPath: string?,
	--- Effective merged PAX attribute map.
	attributes: { [string]: string },
	--- Access-control payload attached from a preceding ACL record.
	acl: string?,
	--- Sparse reconstruction metadata when present.
	sparse: TarSparseInfo?,
}
export type TarIndexEntry = TarMember

--[=[
	Random-access index built from a seekable TAR stream. It caches every member in
	archive order and exposes path lookups plus lazy payload reads.
]=]
export type TarIndex = setmetatable<
	{
		--- Reader used to build and service the index.
		reader: SeekableTarReader,
		--- Members in archive order.
		entries: { TarIndexEntry },
		--- Last member seen for each archive path.
		byPath: { [string]: TarIndexEntry },
	},
	typeof(TarIndex)
>

local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1

--- Parse a GNU/star base-256 numeric header field into a Luau number.
local function parseBase256TarNumber(data: buffer, offset: number, length: number): number
	local first = buffer.readu8(data, offset)

	if bit32.band(first, 0x80) == 0 then
		error(`Invalid tar base-256 number marker: {first}`)
	end

	local payloadFirst = bit32.band(first, 0x7f)
	local negative = bit32.band(payloadFirst, 0x40) ~= 0

	if not negative then
		local value = payloadFirst

		for i = offset + 1, offset + length - 1 do
			value = value * 256 + buffer.readu8(data, i)

			if value > MAX_SAFE_INTEGER then
				error("Tar number is too large to represent exactly")
			end
		end

		return value
	end

	local bytes: { number } = {}
	bytes[1] = payloadFirst
	for i = 2, length do
		bytes[i] = buffer.readu8(data, offset + i - 1)
	end

	-- Strip sign-extension bytes before doing two's-complement inversion.
	local startIndex = 1
	while startIndex < length and bytes[startIndex] == 0x7f and bytes[startIndex + 1] == 0xff do
		startIndex += 1
	end

	local carry = 1
	local value = 0
	for i = length, startIndex, -1 do
		local byte = 0xff - bytes[i] + carry
		if byte >= 256 then
			byte -= 256
			carry = 1
		else
			carry = 0
		end
		bytes[i] = byte
	end

	for i = startIndex, length do
		value = value * 256 + bytes[i]

		if value > MAX_SAFE_INTEGER then
			error("Tar number is too large to represent exactly")
		end
	end

	return -value
end

--- Parse a TAR numeric field, accepting standard octal and GNU base-256 encodings.
local function parseTarNumber(data: buffer, offset: number, length: number): number
	if bit32.band(buffer.readu8(data, offset), 0x80) == 0x80 then
		-- GNU/star base-256 extension
		return parseBase256TarNumber(data, offset, length)
	end

	local raw = buffer.readstring(data, offset, length)

	-- Stop at first NUL
	local nul = string.find(raw, "\0", 1, true)
	if nul then
		raw = string.sub(raw, 1, nul - 1)
	end

	-- Trim spaces
	raw = string.gsub(raw, "^%s+", "")
	raw = string.gsub(raw, "%s+$", "")

	if raw == "" then
		return 0
	end

	local num = tonumber(raw, 8)
	if not num then
		error(`Invalid tar octal: {raw}`)
	end

	return num
end

--- Parse an integer-valued PAX attribute and reject values that lose precision.
local function parsePaxNumber(raw: string, name: string): number
	if not string.match(raw, "^[+-]?%d+$") then
		error(`Invalid pax {name}: {raw}`)
	end

	local num = tonumber(raw)
	if not num or math.abs(num) > MAX_SAFE_INTEGER then
		error(`Pax {name} is too large to represent exactly`)
	end

	return num
end

--- Read a fixed-width NUL-terminated string field from a TAR header buffer.
local function readCString(buf: buffer, offset: number, len: number): string
	local s = buffer.readstring(buf, offset, len)
	local nul = string.find(s, "\0", 1, true)
	if nul then
		return string.sub(s, 1, nul - 1)
	end
	return s
end

--- Check whether a 512-byte block is entirely zero-filled.
local function isNulBlock(data: buffer)
	for i = 0, ((512 / 4) - 1) do
		if buffer.readu32(data, i * 4) ~= 0 then
			return false
		end
	end
	return true
end

--- Detect whether a header carries a USTAR-compatible magic marker.
local function isUstarHeader(header: buffer): boolean
	local magic = buffer.readstring(header, 257, 6)
	return string.sub(magic, 1, 5) == "ustar"
end

--- Parse newline-terminated PAX key/value records from an extended-header payload.
local function parsePaxRecords(data: string): { [string]: string }
	local records = {}
	local pos = 1

	while pos <= #data do
		local space = string.find(data, " ", pos, true)
		if not space then
			break
		end

		local length = tonumber(string.sub(data, pos, space - 1))
		if not length or length <= 0 then
			break
		end

		local recordEnd = pos + length - 1
		if recordEnd > #data then
			break
		end

		local record = string.sub(data, space + 1, recordEnd)
		if string.sub(record, -1) == "\n" then
			record = string.sub(record, 1, -2)
		end

		local equals = string.find(record, "=", 1, true)
		if equals then
			local key = string.sub(record, 1, equals - 1)
			local value = string.sub(record, equals + 1)
			records[key] = value
		end

		pos = recordEnd + 1
	end

	return records
end

--- Overlay one PAX attribute map onto another, keeping later values.
local function mergePaxRecords(base: { [string]: string }, extra: { [string]: string }?): { [string]: string }
	local merged = table.clone(base)
	if extra then
		for key, value in extra do
			merged[key] = value
		end
	end
	return merged
end

--- Remove trailing NUL padding from GNU long name payloads.
local function trimTrailingNuls(s: string): string
	return (string.gsub(s, "\0+$", ""))
end

--- Round a byte count up to the next TAR block boundary.
local function round512(n: number): number
	if n < 0 then
		error("Negative tar size")
	end
	return math.ceil(n / 512) * 512
end

--- Read a payload plus its trailing block padding, optionally retaining the logical bytes.
local function readPayload(stream_: stream.StreamThatCanRead, size: number, capture: boolean): (string, boolean)
	local paddedLength = round512(size)
	local remaining = paddedLength
	local logicalRemaining = size
	local chunks = if capture then {} else nil

	while remaining > 0 do
		local chunkSize = math.min(remaining, 65536)
		local chunk = stream_:read(chunkSize)

		if #chunk == 0 then
			return if capture then table.concat(chunks :: { string }) else "", false
		end

		remaining -= #chunk

		if capture and logicalRemaining > 0 then
			local take = math.min(logicalRemaining, #chunk)
			table.insert(chunks :: { string }, string.sub(chunk, 1, take))
			logicalRemaining -= take
		end
	end

	return if capture then table.concat(chunks :: { string }) else "", true
end

--- Expand sparse-file extents into a fully reconstructed logical file string.
local function reconstructSparseData(rawData: string, sparse: TarSparseInfo, fallbackSize: number): string
	local logicalSize = sparse.size
	if logicalSize <= 0 then
		logicalSize = fallbackSize
	end

	local chunks: { string } = {}
	local cursor = 0
	local rawCursor = 1

	for _, block in sparse.blocks do
		if block.offset > cursor then
			table.insert(chunks, string.rep("\0", block.offset - cursor))
			cursor = block.offset
		end

		local blockData = string.sub(rawData, rawCursor, rawCursor + block.length - 1)
		table.insert(chunks, blockData)
		rawCursor += block.length
		cursor += block.length
	end

	if logicalSize > cursor then
		table.insert(chunks, string.rep("\0", logicalSize - cursor))
	end

	return table.concat(chunks)
end

--- Decode GNU sparse block descriptors from a header or sparse extension block.
local function parseOldGnuSparseBlocks(data: buffer, offset: number, count: number): { TarSparseBlock }
	local blocks: { TarSparseBlock } = {}

	for i = 0, count - 1 do
		local blockOffset = offset + i * 24
		local sparseOffset = parseTarNumber(data, blockOffset, 12)
		local sparseLength = parseTarNumber(data, blockOffset + 12, 12)

		if sparseOffset == 0 and sparseLength == 0 then
			continue
		end

		table.insert(blocks, {
			offset = sparseOffset,
			length = sparseLength,
		})
	end

	return blocks
end

--- Read legacy GNU sparse metadata, including chained extension headers when present.
local function readOldGnuSparseInfo(stream_: stream.StreamThatCanRead, header: buffer): TarSparseInfo?
	local blocks = parseOldGnuSparseBlocks(header, 386, 4)
	local realSize = parseTarNumber(header, 483, 12)
	local extended = buffer.readu8(header, 482) ~= 0

	while extended do
		local extension = stream_:readBuffer(512)
		local length = buffer.len(extension)
		if length == 0 then
			return nil
		end
		if length ~= 512 then
			error("TAR truncated")
		end

		for _, block in parseOldGnuSparseBlocks(extension, 0, 21) do
			table.insert(blocks, block)
		end

		extended = buffer.readu8(extension, 504) ~= 0
	end

	return {
		format = "gnu",
		size = realSize,
		blocks = blocks,
	}
end

--- Parse a GNU sparse map stored in PAX metadata as alternating offset,length pairs.
local function parseSparseMap(raw: string): { TarSparseBlock }
	local blocks: { TarSparseBlock } = {}
	local parts = string.split(raw, ",")

	if #parts % 2 ~= 0 then
		error("Invalid GNU sparse map")
	end

	for i = 1, #parts, 2 do
		local sparseOffset = tonumber(parts[i])
		local sparseLength = tonumber(parts[i + 1])
		if sparseOffset == nil or sparseLength == nil then
			error("Invalid GNU sparse map")
		end

		table.insert(blocks, {
			offset = sparseOffset,
			length = sparseLength,
		})
	end

	return blocks
end

--- Build sparse metadata from GNU PAX sparse attributes when available.
local function parsePaxSparseInfo(pax: { [string]: string }): TarSparseInfo?
	local sparseSize = pax["GNU.sparse.size"] or pax["GNU.sparse.realsize"]
	local sparseMap = pax["GNU.sparse.map"]

	if sparseSize == nil and sparseMap == nil then
		return nil
	end

	return {
		format = "pax",
		size = if sparseSize ~= nil then parsePaxNumber(sparseSize, "GNU.sparse.size") else 0,
		blocks = if sparseMap ~= nil then parseSparseMap(sparseMap) else {},
	}
end

--- Normalize ACL payload text by trimming the first terminating NUL or trailing padding.
local function parseAclText(data: string): string
	local nul = string.find(data, "\0", 1, true)
	if nul then
		return string.sub(data, 1, nul - 1)
	end
	return trimTrailingNuls(data)
end

--- Map TAR type flags onto a smaller set of human-friendly member kinds.
local function classifyType(typeflag: string): string
	if typeflag == "" or typeflag == "0" then
		return "file"
	elseif typeflag == "1" then
		return "hardlink"
	elseif typeflag == "2" then
		return "symlink"
	elseif typeflag == "3" then
		return "character-device"
	elseif typeflag == "4" then
		return "block-device"
	elseif typeflag == "5" then
		return "directory"
	elseif typeflag == "6" then
		return "fifo"
	elseif typeflag == "7" then
		return "reserved"
	elseif typeflag == "S" then
		return "file"
	elseif typeflag == "V" then
		return "volume-label"
	elseif typeflag == "A" then
		return "acl"
	end

	return "file"
end

--- Read and decode the next raw 512-byte TAR header, or nil at end of archive.
local function readRawHeader(stream: stream.StreamThatCanRead): TarEntryHeader?
	local header = stream:readBuffer(512)
	local headerLength = buffer.len(header)
	if headerLength == 0 then
		return nil
	end
	if headerLength ~= 512 then
		error("TAR truncated")
	end
	if isNulBlock(header) then
		return nil
	end
	return {
		raw = header,

		-- Old tar format
		name = readCString(header, 0, 100),
		mode = parseTarNumber(header, 100, 8),
		uid = parseTarNumber(header, 108, 8),
		gid = parseTarNumber(header, 116, 8),
		size = parseTarNumber(header, 124, 12),
		mtime = parseTarNumber(header, 136, 12),
		chksum = parseTarNumber(header, 148, 8),
		typeflag = readCString(header, 156, 1), -- aka linkflag
		linkname = readCString(header, 157, 100),

		-- ustar extensions
		magic = readCString(header, 257, 6),
		version = if isUstarHeader(header) then readCString(header, 263, 2) else "",
		uname = if isUstarHeader(header) then readCString(header, 265, 32) else "",
		gname = if isUstarHeader(header) then readCString(header, 297, 32) else "",
		devmajor = if isUstarHeader(header) then parseTarNumber(header, 329, 8) else 0,
		devminor = if isUstarHeader(header) then parseTarNumber(header, 337, 8) else 0,
		prefix = if isUstarHeader(header) then readCString(header, 345, 155) else "",
	}
end

--- Compute the standard unsigned TAR checksum for a header block.
local function calculateChecksum(header: buffer): number
	local sum = 0

	for i = 0, 511 do
		local byte

		-- The checksum field itself is treated as spaces.
		if i >= 148 and i < 156 then
			byte = 32 -- ASCII space
		else
			byte = buffer.readu8(header, i)
		end

		sum += byte
	end

	return sum
end

--- Compute the signed-byte checksum variant accepted by some TAR writers.
local function calculateSignedChecksum(header: buffer): number
	local sum = 0

	for i = 0, 511 do
		local byte

		if i >= 148 and i < 156 then
			byte = 32
		else
			byte = buffer.readi8(header, i)
		end

		sum += byte
	end

	return sum
end

--- Clear any accumulated extended-header state so the reader starts fresh.
local function resetReaderState(self: any)
	self.globalPax = {}
	self.nextPax = nil
	self.longPath = nil
	self.longLinkPath = nil
	self.pendingAcl = nil
end

--[=[
	Create a sequential TAR reader over an already-open readable stream.
	The reader consumes the stream progressively and cannot seek backwards unless
	the supplied stream object also supports that capability separately.
	@param stream_ Readable stream positioned at the start of a TAR archive.
	@return Sequential TAR reader instance.
]=]
function TarReader.new(stream_: stream.StreamThatCanRead)
	local self = {
		stream = stream_,
		closed = false,
		globalPax = {} :: { [string]: string },
		nextPax = nil,
		longPath = nil,
		longLinkPath = nil,
		pendingAcl = nil,
	}
	return setmetatable(self, TarReader) :: any
end

--[=[
	Create a TAR reader backed by a seekable stream.
	Use this when you want to rewind, build an index, or lazily re-read member
	payloads later without reopening the archive.
	@param stream_ Readable seekable stream at the archive start.
	@return Seek-capable TAR reader instance.
]=]
function SeekableTarReader.new(stream_: stream.StreamThatCanRead & stream.StreamThatCanSeek)
	local self = {
		stream = stream_,
		closed = false,
		globalPax = {} :: { [string]: string },
		nextPax = nil,
		longPath = nil,
		longLinkPath = nil,
		pendingAcl = nil,
	}
	return setmetatable(self, SeekableTarReader) :: any
end

--- Error if a reader has already been closed.
local function ensureReaderOpen(self: TarReaderState)
	if self.closed then
		error("TAR reader is closed")
	end
end

--- Close the wrapped stream when it supports explicit close semantics.
local function closeUnderlyingStream(self: TarReaderState, sync: boolean)
	if self.closed then
		return
	end

	local streamAny = self.stream :: any
	if sync then
		local closeSync = streamAny.closeSync
		if closeSync ~= nil then
			(closeSync :: any)(streamAny)
			self.closed = true
			return
		end
	end

	local close = streamAny.close
	if close ~= nil then
		(close :: any)(streamAny)
	end

	self.closed = true
end

--[=[
	Seek back to the start of the archive and discard all in-flight extended
	metadata state such as global PAX records, queued long paths, and pending ACLs.
	@return Absolute stream offset returned by the underlying seek call.
]=]
function SeekableTarReader.rewind(self: SeekableTarReader): number
	ensureReaderOpen(self)
	local offset = self.stream:seek(0, "set")
	resetReaderState(self)
	return offset
end

--[=[
	Close the reader and, when supported, close the wrapped stream.
	This is especially important for readers opened from `tar.openPath`, because
	the underlying file handle otherwise remains open until garbage collection.
	Calling `close` more than once is safe.
	@param self Reader instance.
	@return Nothing.
]=]
function TarReader.close(self: TarReader)
	closeUnderlyingStream(self, false)
end

--[=[
	Non-yielding variant of `close` when the wrapped stream supports `closeSync`.
	If only `close` exists, this falls back to that implementation.
	@param self Reader instance.
	@return Nothing.
]=]
function TarReader.closeSync(self: TarReader)
	closeUnderlyingStream(self, true)
end

--- Read the next raw entry, applying PAX/GNU metadata records before returning it.
local function nextEntryImpl(self: any): TarEntry?
	ensureReaderOpen(self)

	-- Check for a header, guarding for two nil headers (EOF)
	local header = readRawHeader(self.stream)
	if not header then
		header = readRawHeader(self.stream)
		if not header then
			return nil
		end
	end
	assert(header)

	-- Validate checksum
	local valid = header.chksum == calculateChecksum(header.raw) or header.chksum == calculateSignedChecksum(header.raw)
	if not valid then
		if header.name == "" then
			return nil
		end
		error("Invalid tar checksum")
	end

	local typeflag = header.typeflag
	if typeflag == "" then
		typeflag = "0"
	end

	local sparse = nil
	if typeflag == "S" then
		sparse = readOldGnuSparseInfo(self.stream, header.raw)
		if sparse == nil then
			return nil
		end
	end

	local storedSize = header.size
	if
		typeflag == "1"
		or typeflag == "2"
		or typeflag == "3"
		or typeflag == "4"
		or typeflag == "5"
		or typeflag == "6"
		or typeflag == "7"
		or typeflag == "V"
	then
		storedSize = 0
	end

	local dataOffset = nil
	local maybeSeekable = self.stream :: any
	local tell = maybeSeekable.tell
	if tell ~= nil then
		dataOffset = (tell :: any)(maybeSeekable)
	end

	local capturePayload = true
	local fileData, readOk = readPayload(self.stream, storedSize, capturePayload)
	if not readOk then
		if capturePayload then
			return nil
		end
		error("TAR truncated")
	end

	if typeflag == "g" then
		self.globalPax = mergePaxRecords(self.globalPax, parsePaxRecords(fileData))
		return self:nextEntry()
	end
	if typeflag == "x" then
		self.nextPax = parsePaxRecords(fileData)
		return self:nextEntry()
	end
	if typeflag == "L" then
		self.longPath = trimTrailingNuls(fileData)
		return self:nextEntry()
	end
	if typeflag == "K" then
		self.longLinkPath = trimTrailingNuls(fileData)
		return self:nextEntry()
	end

	local pax = mergePaxRecords(self.globalPax, self.nextPax)
	self.nextPax = nil

	-- Normalize path
	local path = header.name
	if header.prefix ~= "" then
		path = `{header.prefix}/{header.name}`
	end
	if self.longPath ~= nil then
		path = self.longPath
		self.longPath = nil
	end
	if pax.path ~= nil then
		path = pax.path
	end
	if pax["GNU.sparse.name"] ~= nil then
		path = pax["GNU.sparse.name"]
	end
	if path == "" then
		path = header.name
	end

	if self.longLinkPath ~= nil then
		header.linkname = self.longLinkPath
		self.longLinkPath = nil
	end
	if pax.linkpath ~= nil then
		header.linkname = pax.linkpath
	end
	if pax.size ~= nil then
		header.size = parsePaxNumber(pax.size, "size")
		if header.size < 0 then
			error("Invalid pax size")
		end
	end
	if pax.mtime ~= nil then
		header.mtime = parsePaxNumber(string.match(pax.mtime, "^[+-]?%d+") or pax.mtime, "mtime")
	end
	if pax.atime ~= nil then
		header.atime = parsePaxNumber(string.match(pax.atime, "^[+-]?%d+") or pax.atime, "atime")
	end
	if pax.ctime ~= nil then
		header.ctime = parsePaxNumber(string.match(pax.ctime, "^[+-]?%d+") or pax.ctime, "ctime")
	end
	if sparse == nil then
		sparse = parsePaxSparseInfo(pax)
	end

	if pax.size ~= nil and storedSize ~= header.size then
		fileData, readOk = readPayload(self.stream, header.size, true)
		if not readOk then
			error("TAR truncated")
		end
	end

	return {
		path = path,
		typeflag = typeflag,
		header = header,
		data = fileData,
		attributes = pax,
		sparse = sparse,
		dataOffset = dataOffset,
		storedSize = storedSize,
	}
end

--[=[
	Read the next raw TAR entry from the stream.
	This exposes parser-level details, including metadata-only extension entries
	such as PAX records when they survive normalization, and returns nil at end of archive.
	@param self Reader instance.
	@return Next parsed entry, or nil when the archive is exhausted.
]=]
function TarReader.nextEntry(self: TarReader): TarEntry?
	return nextEntryImpl(self)
end

--- Read the next consumer-facing member, folding ACL records into the following entry.
local function nextMemberImpl(self: any): TarMember?
	while true do
		local entry = nextEntryImpl(self)
		if not entry then
			return nil
		end

		if entry.typeflag == "A" then
			self.pendingAcl = parseAclText(entry.data)
			continue
		end

		local member: TarMember = {
			path = entry.path,
			kind = classifyType(entry.typeflag),
			typeflag = entry.typeflag,
			header = entry.header,
			data = entry.data,
			dataOffset = entry.dataOffset,
			storedSize = entry.storedSize,
			size = if entry.sparse ~= nil and entry.sparse.size > 0 then entry.sparse.size else entry.header.size,
			linkPath = if entry.header.linkname ~= "" then entry.header.linkname else nil,
			attributes = entry.attributes,
			acl = self.pendingAcl,
			sparse = entry.sparse,
		}
		if member.kind == "file" and string.sub(member.path, -1) == "/" then
			member.kind = "directory"
		end
		self.pendingAcl = nil

		return member
	end
end

--[=[
	Read the next normalized archive member from the stream.
	Metadata-only records used to describe subsequent entries are consumed
	internally so callers receive a cleaner member-oriented view of the archive.
	@param self Reader instance.
	@return Next normalized member, or nil when no members remain.
]=]
function TarReader.nextMember(self: TarReader): TarMember?
	return nextMemberImpl(self)
end

--[=[
	Create an immutable TAR index from a seekable reader and precomputed lookup tables.
	This constructor is primarily used internally by `SeekableTarReader:index`.
	@param reader Reader the index will use for lazy payload reads.
	@param entries Members in archive order.
	@param byPath Path lookup table for indexed members.
	@return Random-access TAR index.
]=]
function TarIndex.new(
	reader: SeekableTarReader,
	entries: { TarIndexEntry },
	byPath: { [string]: TarIndexEntry }
): TarIndex
	return setmetatable({
		reader = reader,
		entries = entries,
		byPath = byPath,
	}, TarIndex)
end

--[=[
	Return a shallow copy of the indexed members in archive order.
	Mutating the returned array will not affect the index internals.
	@param self TAR index instance.
	@return Indexed members in archive order.
]=]
function TarIndex.list(self: TarIndex): { TarIndexEntry }
	return table.clone(self.entries)
end

--[=[
	Look up a member by its archive path.
	If the archive contains duplicate paths, the last indexed occurrence wins.
	@param self TAR index instance.
	@param path Exact archive path to find.
	@return Indexed member metadata, or nil when absent.
]=]
function TarIndex.get(self: TarIndex, path: string): TarIndexEntry?
	return self.byPath[path]
end

--[=[
	Read and return the stored contents for a file-like indexed member.
	Only regular files and hardlinks are readable through this helper; directories
	and other non-data entries return nil. Sparse members are reconstructed into
	their full logical contents before being returned.
	@param self TAR index instance.
	@param path Exact archive path to read.
	@return Member contents, or nil when the path is missing or not readable as file data.
]=]
function TarIndex.read(self: TarIndex, path: string): string?
	ensureReaderOpen(self.reader)

	local entry = self.byPath[path]
	if entry == nil then
		return nil
	end
	if entry.kind ~= "file" and entry.kind ~= "hardlink" then
		return nil
	end
	if entry.dataOffset == nil then
		return nil
	end

	local previousOffset = self.reader.stream:tell()
	self.reader.stream:seek(entry.dataOffset, "set")

	local data, ok = readPayload(self.reader.stream, entry.storedSize, true)
	self.reader.stream:seek(previousOffset, "set")

	if not ok then
		error("TAR truncated")
	end
	if entry.sparse ~= nil then
		return reconstructSparseData(data, entry.sparse, entry.size)
	end
	return data
end

--[=[
	Scan the entire archive and build a random-access index over its members.
	The reader is rewound before and after indexing so the caller can continue from
	a clean start position once the index has been created.
	@param self Seekable TAR reader instance.
	@return Random-access index for the archive.
]=]
function SeekableTarReader.index(self: SeekableTarReader): TarIndex
	self:rewind()

	local entries: { TarIndexEntry } = {}
	local byPath: { [string]: TarIndexEntry } = {}

	while true do
		local member = nextMemberImpl(self)
		if member == nil then
			break
		end
		table.insert(entries, member)
		byPath[member.path] = member
	end

	self:rewind()
	return TarIndex.new(self, entries, byPath)
end

tar.TarReader = TarReader
tar.SeekableTarReader = SeekableTarReader
tar.TarIndex = TarIndex
tar.TarFile = TarReader

--[=[
	Open a TAR archive from an already-open readable stream.
	Use this for one-pass iteration when random access is not required.
	@param stream_ Readable stream positioned at the start of a TAR archive.
	@return Sequential TAR reader.
]=]
function tar.open(stream_: stream.StreamThatCanRead): TarReader
	return TarReader.new(stream_)
end

--[=[
	Open a TAR archive from a readable, seekable stream.
	This variant can rewind, build an index, and lazily re-read payloads later.
	@param stream_ Readable seekable stream positioned at the archive start.
	@return Seek-capable TAR reader.
]=]
function tar.openSeekable(stream_: stream.StreamThatCanRead & stream.StreamThatCanSeek): SeekableTarReader
	return SeekableTarReader.new(stream_)
end

--[=[
	Open a TAR archive directly from a filesystem path in read mode.
	The returned reader is seekable because it wraps a filesystem stream.
	Call `reader:close()` when finished so the file handle is released promptly.
	@param path Path to the TAR archive on disk.
	@return Seek-capable TAR reader for the file.
]=]
function tar.openPath(path: path.PathLike): SeekableTarReader
	return SeekableTarReader.new(fs.open(path, "r"))
end

return table.freeze(tar)
