--[=[
	UUID generation, parsing, and formatting.

	This library implements the RFC 9562 UUID families `v1`, `v3`, `v4`,
	`v5`, `v6`, `v7`, and `v8`, along with parsing, coercion, comparison,
	and formatting helpers.

	UUIDs may be consumed as canonical strings, raw 16-byte `buffer`
	values, or metatable-backed UUID objects returned by this library.
	Parsed and generated UUID objects expose common metadata such as
	`variant`, `version`, and `bytes`, with additional version-specific
	fields available on timestamped layouts like `v1`, `v6`, and `v7`.

	Version overview:
	- `v1`  Time-based UUIDs with Gregorian 100ns timestamps, clock sequence, and node ID.
	- `v3`  Namespace-name UUIDs hashed with MD5.
	- `v4`  Random UUIDs generated from a cryptographically secure RNG.
	- `v5`  Namespace-name UUIDs hashed with SHA-1.
	- `v6`  Reordered time-based UUIDs optimized for bytewise sorting.
	- `v7`  Unix-millisecond ordered UUIDs intended for new sortable identifiers.
	- `v8`  Application-defined UUID layouts with normalized version and variant bits.

	Textual forms:
	- canonical: `123e4567-e89b-12d3-a456-426614174000`
	- simple:    `123e4567e89b12d3a456426614174000`
	- braced:    `{123e4567-e89b-12d3-a456-426614174000}`
	- URN:       `urn:uuid:123e4567-e89b-12d3-a456-426614174000`

	```luau
	local uuid = require("@eryx/uuid")

	local id = uuid.v7()
	print(id.kind) -- "v7"
	print(uuid.format(id)) -- canonical UUID string

	local parsed = uuid.parse("01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d")
	print(parsed.kind, parsed.version) -- "v7", 7
	```
]=]

local date = require("@eryx/date")
local hex = require("@eryx/encoding/hex")
local hash = require("@eryx/crypto/hazmat/hash")
local random = require("@eryx/crypto/hazmat/random")

local uuid = {}

local UUID = {}
UUID.__index = UUID

export type UUIDVariant = "ncs" | "rfc4122" | "microsoft" | "future"
export type UUIDVersionName = "v1" | "v3" | "v4" | "v5" | "v6" | "v7" | "v8"
export type UUIDFormatStyle = "canonical" | "simple" | "urn" | "braced"
export type UUIDOrdering = number
export type RandomSource = (byteCount: number) -> buffer

type UUIDMethods = {
	toString: (self: any, style: UUIDFormatStyle?) -> string,
	toBuffer: (self: any) -> buffer,
	equals: (self: any, other: UUIDLike) -> boolean,
	compare: (self: any, other: UUIDLike) -> UUIDOrdering,
	isNil: (self: any) -> boolean,
	unixMilliseconds: (self: any) -> integer?,
}

type UUIDBase = UUIDMethods & {
	--- String tag used for type narrowing.
	read kind: UUIDVersionName?,
	--- Decoded UUID variant bits.
	read variant: UUIDVariant,
	--- Numeric UUID version nibble when present.
	read version: number?,
	--- Packed 16-byte representation.
	read bytes: buffer,
}

export type UUIDUnknown = UUIDBase & {
	read kind: nil,
}

export type UUIDv1 = UUIDBase & {
	read kind: "v1",
	read version: number,
	--- Gregorian timestamp in 100ns intervals since 1582-10-15.
	read timestamp: integer,
	--- Convenience timestamp in Unix milliseconds.
	read unixMillis: integer,
	--- 14-bit clock sequence.
	read clockSequence: number,
	--- 48-bit node identifier as 6 bytes.
	read node: buffer,
}

export type UUIDv3 = UUIDBase & {
	read kind: "v3",
	read version: number,
}

export type UUIDv4 = UUIDBase & {
	read kind: "v4",
	read version: number,
}

export type UUIDv5 = UUIDBase & {
	read kind: "v5",
	read version: number,
}

export type UUIDv6 = UUIDBase & {
	read kind: "v6",
	read version: number,
	--- Reordered Gregorian timestamp in 100ns intervals since 1582-10-15.
	read timestamp: integer,
	--- Convenience timestamp in Unix milliseconds.
	read unixMillis: integer,
	--- 14-bit clock sequence.
	read clockSequence: number,
	--- 48-bit node identifier as 6 bytes.
	read node: buffer,
}

export type UUIDv7 = UUIDBase & {
	read kind: "v7",
	read version: number,
	--- Milliseconds since the Unix epoch.
	read unixMillis: integer,
	--- The 12-bit `rand_a` field.
	read randA: number,
	--- The trailing 64-bit payload as 8 bytes, including variant bits.
	read randB: buffer,
}

export type UUIDv8 = UUIDBase & {
	read kind: "v8",
	read version: number,
}

export type UUID = UUIDUnknown | UUIDv1 | UUIDv3 | UUIDv4 | UUIDv5 | UUIDv6 | UUIDv7 | UUIDv8

export type UUIDLike = UUID | string | buffer

export type ParseOptions = {
	allowSimple: boolean?,
	allowBraced: boolean?,
	allowUrn: boolean?,
}

export type UUIDv1Options = {
	unixMillis: integer?,
	nanoseconds: number?,
	clockSequence: number?,
	node: buffer | string?,
	random: RandomSource?,
}

export type UUIDv3Options = {
	namespace: UUIDLike,
	name: string | buffer,
}

export type UUIDv4Options = {
	random: RandomSource?,
}

export type UUIDv5Options = {
	namespace: UUIDLike,
	name: string | buffer,
}

export type UUIDv6Options = {
	unixMillis: integer?,
	nanoseconds: number?,
	clockSequence: number?,
	node: buffer | string?,
	random: RandomSource?,
}

export type UUIDv7Options = {
	unixMillis: integer?,
	sequence: number?,
	random: RandomSource?,
}

export type UUIDv8Options = {
	bytes: buffer,
}

local UUID_EPOCH_OFFSET_MS: integer = 12219292800000i
local UUID_EPOCH_OFFSET_100NS: integer = 0x1B21DD213814000i
local MAX_UUID_TIMESTAMP_100NS: integer = 0x0FFF_FFFF_FFFF_FFFFi
local MAX_V1V6_UNIX_MILLIS: integer = integer.idiv(integer.sub(MAX_UUID_TIMESTAMP_100NS, UUID_EPOCH_OFFSET_100NS), 10000i)
local VERSION_KIND: { [number]: UUIDVersionName } = {
	[1] = "v1",
	[3] = "v3",
	[4] = "v4",
	[5] = "v5",
	[6] = "v6",
	[7] = "v7",
	[8] = "v8",
}
local buildUuid: (buffer) -> UUID
local lastV7UnixMillis: integer? = nil
local lastV7Sequence: number? = nil

local function fail(message: string): never
	error(message, 2)
end

local function digest(algorithm: string, data: buffer): buffer
	local ctx = hash.new(algorithm)
	ctx:update(data)
	return ctx:final()
end

local function copyBuffer(source: buffer, offset: number?, length: number?): buffer
	local from = offset or 0
	local size = length or (buffer.len(source) - from)
	local out = buffer.create(size)
	buffer.copy(out, 0, source, from, size)
	return out
end

local function isHexByte(byte: number): boolean
	return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102)
end

local function isUuid(value: any): boolean
	return type(value) == "table" and getmetatable(value) == UUID
end

local function classifyVariant(octet: number): UUIDVariant
	if bit32.band(octet, 0x80) == 0 then
		return "ncs"
	end
	if bit32.band(octet, 0xC0) == 0x80 then
		return "rfc4122"
	end
	if bit32.band(octet, 0xE0) == 0xC0 then
		return "microsoft"
	end
	return "future"
end

local function bufferToCanonical(bytes: buffer): string
	local encoded = hex.encode(bytes)
	return string.format(
		"%s-%s-%s-%s-%s",
		encoded:sub(1, 8),
		encoded:sub(9, 12),
		encoded:sub(13, 16),
		encoded:sub(17, 20),
		encoded:sub(21, 32)
	)
end

local function normalizeString(value: string, options: ParseOptions?): string
	local source = value
	local allowSimple = if options then options.allowSimple == true else false
	local allowBraced = if options then options.allowBraced == true else false
	local allowUrn = if options then options.allowUrn == true else false

	if allowUrn and source:sub(1, 9):lower() == "urn:uuid:" then
		source = source:sub(10)
	end

	if allowBraced and source:sub(1, 1) == "{" and source:sub(-1) == "}" then
		source = source:sub(2, -2)
	end

	if #source == 36 then
		if
			source:sub(9, 9) ~= "-"
			or source:sub(14, 14) ~= "-"
			or source:sub(19, 19) ~= "-"
			or source:sub(24, 24) ~= "-"
		then
			fail("invalid UUID string")
		end

		local out = table.create(32)
		local outIndex = 0
		for i = 1, 36 do
			if i ~= 9 and i ~= 14 and i ~= 19 and i ~= 24 then
				local byte = string.byte(source, i)
				if not isHexByte(byte) then
					fail("invalid UUID string")
				end
				outIndex += 1
				out[outIndex] = string.char(byte)
			end
		end
		return table.concat(out)
	end

	if #source == 32 and allowSimple then
		for i = 1, 32 do
			if not isHexByte(string.byte(source, i)) then
				fail("invalid UUID string")
			end
		end
		return source
	end

	fail("invalid UUID string")
	assert(false)
end

local function readU48BE(bytes: buffer, offset: number): integer
	local value: integer = 0i
	for i = 0, 5 do
		value = integer.add(integer.mul(value, 256i), integer.create(buffer.readu8(bytes, offset + i)) :: integer)
	end
	return value
end

local function readU60V1(bytes: buffer): integer
	local timeLow: integer = 0i
	for i = 0, 3 do
		timeLow = integer.add(integer.mul(timeLow, 256i), integer.create(buffer.readu8(bytes, i)) :: integer)
	end

	local timeMid = integer.add(
		integer.mul(integer.create(buffer.readu8(bytes, 4)) :: integer, 256i),
		integer.create(buffer.readu8(bytes, 5)) :: integer
	)
	local timeHi = integer.add(
		integer.mul(integer.create(bit32.band(buffer.readu8(bytes, 6), 0x0F)) :: integer, 256i),
		integer.create(buffer.readu8(bytes, 7)) :: integer
	)
	return integer.add(integer.add(integer.mul(timeHi, 0x1_0000_0000_0000i), integer.mul(timeMid, 0x1_0000_0000i)), timeLow)
end

local function readU60V6(bytes: buffer): integer
	local timestampHigh: integer = 0i
	for i = 0, 5 do
		timestampHigh = integer.add(integer.mul(timestampHigh, 256i), integer.create(buffer.readu8(bytes, i)) :: integer)
	end

	local timestampLow = integer.add(
		integer.mul(integer.create(bit32.band(buffer.readu8(bytes, 6), 0x0F)) :: integer, 256i),
		integer.create(buffer.readu8(bytes, 7)) :: integer
	)
	return integer.add(integer.mul(timestampHigh, 4096i), timestampLow)
end

local function sliceNode(bytes: buffer, offset: number, length: number): buffer
	return copyBuffer(bytes, offset, length)
end

local function decodeV1Timestamp(bytes: buffer): integer
	return readU60V1(bytes)
end

local function decodeV6Timestamp(bytes: buffer): integer
	return readU60V6(bytes)
end

local function unixMillisFromTimestamp100ns(timestamp100ns: integer): integer
	return integer.sub(integer.idiv(timestamp100ns, 10000i), UUID_EPOCH_OFFSET_MS)
end

local function decodeClockSequence(bytes: buffer): number
	return bit32.band(buffer.readu8(bytes, 8), 0x3F) * 256 + buffer.readu8(bytes, 9)
end

local function coerceName(value: string | buffer): buffer
	if type(value) == "string" then
		return buffer.fromstring(value)
	end
	return value
end

local function parseNodeString(value: string): buffer
	local compact = value:gsub("[:-]", "")
	if #compact ~= 12 then
		fail("UUID node strings must contain exactly 12 hex digits")
	end
	for i = 1, #compact do
		if not isHexByte(string.byte(compact, i)) then
			fail("UUID node strings must be hexadecimal")
		end
	end
	return hex.decode(compact)
end

local function coerceNode(value: buffer | string?, rng: RandomSource): buffer
	if value == nil then
		local node = copyBuffer(rng(6))
		buffer.writeu8(node, 0, bit32.bor(buffer.readu8(node, 0), 0x01))
		return node
	end
	if type(value) == "string" then
		value = parseNodeString(value)
	end
	local value_ = value :: buffer
	if buffer.len(value_) ~= 6 then
		fail("UUID node values must be exactly 6 bytes")
	end
	return copyBuffer(value_)
end

local function coerceClockSequence(value: number?, rng: RandomSource): number
	if value == nil then
		local bytes = rng(2)
		return bit32.band(bit32.lshift(buffer.readu8(bytes, 0), 8) + buffer.readu8(bytes, 1), 0x3FFF)
	end
	if math.floor(value) ~= value or value < 0 or value > 0x3FFF then
		fail("UUID clockSequence must be an integer in the 0..16383 range")
	end
	return value
end

local function coerceSubMillisecond100ns(nanoseconds: number?): integer
	local ns = nanoseconds or 0
	if math.floor(ns) ~= ns or ns < 0 or ns >= 1000000 then
		fail("UUID nanoseconds must be an integer in the 0..999999 range")
	end
	if ns % 100 ~= 0 then
		fail("UUID nanoseconds must be a multiple of 100")
	end
	return integer.create(ns // 100) :: integer
end

local function timestamp100nsFromUnixMillis(unixMillis: integer, subMs100ns: integer): integer
	return integer.add(UUID_EPOCH_OFFSET_100NS, integer.add(integer.mul(unixMillis, 10000i), subMs100ns))
end

local function validateV1V6UnixMillis(unixMillis: integer, versionName: string)
	if integer.lt(unixMillis, 0i) then
		fail(`uuid.{versionName} unixMillis must be non-negative`)
	end
	if integer.gt(unixMillis, MAX_V1V6_UNIX_MILLIS) then
		fail(`uuid.{versionName} unixMillis is out of range for a 60-bit UUID timestamp`)
	end
end

local function currentUnixMillis(): integer
	local value = integer.create(date.now("UTC"):toUnixMs())
	if value == nil then
		fail("current Unix time could not be represented as an integer")
	end
	return value
end

local function sequenceFromRandomTail(randomTail: buffer): number
	return bit32.band(
		bit32.lshift(buffer.readu8(randomTail, 0), 4) + bit32.rshift(buffer.readu8(randomTail, 1), 4),
		0x0FFF
	)
end

local function nextMonotonicV7(unixMillis: integer, initialSequence: number): (integer, number)
	if lastV7UnixMillis == nil or lastV7Sequence == nil or integer.gt(unixMillis, lastV7UnixMillis) then
		local sequence = initialSequence
		lastV7UnixMillis = unixMillis
		lastV7Sequence = sequence
		return unixMillis, sequence
	end

	local previousSequence = lastV7Sequence :: number
	local previousUnixMillis = lastV7UnixMillis :: integer
	local nextSequence = (previousSequence + 1) % 0x1000
	local nextUnixMillis = previousUnixMillis
	if nextSequence == 0 then
		nextUnixMillis = integer.add(nextUnixMillis, 1i)
	end

	lastV7UnixMillis = nextUnixMillis
	lastV7Sequence = nextSequence
	return nextUnixMillis, nextSequence
end

local function writeTimestampV1(bytes: buffer, timestamp100ns: integer)
	local timeLow = integer.mod(timestamp100ns, 4294967296i)
	local rest = integer.idiv(timestamp100ns, 4294967296i)
	local timeMid = integer.mod(rest, 65536i)
	local timeHi = integer.idiv(rest, 65536i)

	local low = timeLow
	for i = 3, 0, -1 do
		buffer.writeu8(bytes, i, integer.tonumber(integer.mod(low, 256i)))
		low = integer.idiv(low, 256i)
	end

	local mid = timeMid
	for i = 5, 4, -1 do
		buffer.writeu8(bytes, i, integer.tonumber(integer.mod(mid, 256i)))
		mid = integer.idiv(mid, 256i)
	end

	buffer.writeu8(bytes, 6, bit32.bor(0x10, bit32.band(integer.tonumber(integer.idiv(timeHi, 256i)), 0x0F)))
	buffer.writeu8(bytes, 7, integer.tonumber(integer.mod(timeHi, 256i)))
end

local function writeTimestampV6(bytes: buffer, timestamp100ns: integer)
	local high = integer.idiv(timestamp100ns, 4096i)
	local low = integer.mod(timestamp100ns, 4096i)

	for i = 5, 0, -1 do
		buffer.writeu8(bytes, i, integer.tonumber(integer.mod(high, 256i)))
		high = integer.idiv(high, 256i)
	end

	buffer.writeu8(bytes, 6, bit32.bor(0x60, bit32.band(integer.tonumber(integer.idiv(low, 256i)), 0x0F)))
	buffer.writeu8(bytes, 7, integer.tonumber(integer.mod(low, 256i)))
end

local function writeClockSequence(bytes: buffer, clockSequence: number)
	buffer.writeu8(bytes, 8, bit32.bor(0x80, bit32.band(bit32.rshift(clockSequence, 8), 0x3F)))
	buffer.writeu8(bytes, 9, bit32.band(clockSequence, 0xFF))
end

local function writeNode(bytes: buffer, node: buffer)
	buffer.copy(bytes, 10, node, 0, 6)
end

local function hashUuid(namespace: UUIDLike, name: string | buffer, algorithm: string, version: number): UUID
	local ns = uuid.from(namespace).bytes
	local nameBuffer = coerceName(name)
	local payload = buffer.create(16 + buffer.len(nameBuffer))
	buffer.copy(payload, 0, ns, 0, 16)
	buffer.copy(payload, 16, nameBuffer, 0, buffer.len(nameBuffer))

	local hashed = digest(algorithm, payload)
	local bytes = copyBuffer(hashed, 0, 16)
	buffer.writeu8(bytes, 6, bit32.bor(bit32.band(buffer.readu8(bytes, 6), 0x0F), bit32.lshift(version, 4)))
	buffer.writeu8(bytes, 8, bit32.bor(bit32.band(buffer.readu8(bytes, 8), 0x3F), 0x80))
	return buildUuid(bytes)
end

function buildUuid(bytes: buffer): UUID
	if buffer.len(bytes) ~= 16 then
		fail("UUID buffers must be exactly 16 bytes")
	end

	local stored = copyBuffer(bytes)
	local variant = classifyVariant(buffer.readu8(stored, 8))
	local version = bit32.rshift(buffer.readu8(stored, 6), 4)
	local kind = if variant == "rfc4122" then VERSION_KIND[version] else nil

	local value = {
		kind = kind,
		variant = variant,
		version = if kind then version else nil,
		bytes = stored,
	}
	local typedValue: any = value

	if kind == "v1" then
		typedValue.timestamp = decodeV1Timestamp(stored)
		typedValue.unixMillis = unixMillisFromTimestamp100ns(typedValue.timestamp)
		typedValue.clockSequence = decodeClockSequence(stored)
		typedValue.node = sliceNode(stored, 10, 6)
	elseif kind == "v6" then
		typedValue.timestamp = decodeV6Timestamp(stored)
		typedValue.unixMillis = unixMillisFromTimestamp100ns(typedValue.timestamp)
		typedValue.clockSequence = decodeClockSequence(stored)
		typedValue.node = sliceNode(stored, 10, 6)
	elseif kind == "v7" then
		typedValue.unixMillis = readU48BE(stored, 0)
		typedValue.randA = bit32.lshift(bit32.band(buffer.readu8(stored, 6), 0x0F), 8) + buffer.readu8(stored, 7)
		typedValue.randB = sliceNode(stored, 8, 8)
	end

	return table.freeze(setmetatable(value, UUID)) :: any
end

local function coerceRandom(source: RandomSource?): RandomSource
	return source or random.bytes
end

function UUID.toString(self: UUID, style: UUIDFormatStyle?): string
	return uuid.format(self, style)
end

--[=[
	Return this UUID formatted as a string.

	@param style Optional output style. Defaults to `"canonical"`.
	@return string -- The formatted UUID string.
]=]
function UUID.toBuffer(self: UUID): buffer
	return copyBuffer(self.bytes)
end

--[=[
	Return a copy of this UUID's raw 16-byte representation.

	@return buffer -- A new buffer containing the UUID bytes.
]=]
function UUID.equals(self: UUID, other: UUIDLike): boolean
	return uuid.equals(self, other)
end

--[=[
	Check whether this UUID equals another UUID-like value.

	@param other A UUID object, UUID string, or 16-byte buffer.
	@return boolean -- `true` when both values encode the same bytes.
]=]
function UUID.compare(self: UUID, other: UUIDLike): UUIDOrdering
	return uuid.compare(self, other)
end

--[=[
	Compare this UUID to another UUID-like value using bytewise ordering.

	@param other A UUID object, UUID string, or 16-byte buffer.
	@return number -- `-1`, `0`, or `1` depending on ordering.
]=]
function UUID.isNil(self: UUID): boolean
	for i = 0, 15 do
		if buffer.readu8(self.bytes, i) ~= 0 then
			return false
		end
	end
	return true
end

--[=[
	Check whether this UUID is the all-zero nil UUID.

	@return boolean -- `true` when every byte is zero.
]=]
function UUID.unixMilliseconds(self: UUID): integer?
	return (self :: any).unixMillis
end

--[=[
	Return the recoverable Unix-millisecond timestamp for timestamped UUIDs.

	For `v1` and `v6`, this is derived from the embedded Gregorian 100ns
	timestamp. For `v7`, it is the native Unix-millisecond field. Other
	UUID versions return `nil`.

	@return integer? -- Unix milliseconds, or `nil` when not applicable.
]=]
function UUID.__tostring(self: UUID): string
	return self:toString()
end

--[=[
	Parse a UUID string into a UUID object.

	Canonical hyphenated strings are always accepted. Hyphenless, braced,
	and URN forms may be enabled through `options`.

	@param value UUID string to parse.
	@param options Optional parse flags controlling accepted textual forms.
	@return UUID -- Parsed UUID object with recovered metadata where available.
]=]
function uuid.parse(value: string, options: ParseOptions?): UUID
	if type(value) ~= "string" then
		fail("UUID must be parsed from a string")
	end
	return buildUuid(hex.decode(normalizeString(value, options)))
end

--[=[
	Parse a UUID string, returning `nil` instead of raising on invalid input.

	@param value UUID string to parse.
	@param options Optional parse flags controlling accepted textual forms.
	@return UUID? -- Parsed UUID object, or `nil` when parsing fails.
]=]
function uuid.tryParse(value: string, options: ParseOptions?): UUID?
	local ok, parsed = pcall(uuid.parse, value, options)
	if ok then
		return parsed
	end
	return nil
end

--[=[
	Coerce a UUID-like value into a UUID object.

	Existing UUID objects are returned as-is. Strings are parsed, and
	16-byte buffers are decoded directly.

	@param value UUID object, UUID string, or 16-byte buffer.
	@param options Optional parse flags used when `value` is a string.
	@return UUID -- Normalized UUID object.
]=]
function uuid.from(value: UUIDLike, options: ParseOptions?): UUID
	if isUuid(value) then
		return value :: UUID
	end
	if type(value) == "string" then
		return uuid.parse(value, options)
	end
	if type(value) == "buffer" then
		return buildUuid(value)
	end
	fail("expected UUID, UUID string, or 16-byte buffer")
	assert(false)
end

--[=[
	Return whether a UUID-like value can be successfully coerced.

	@param value UUID object, UUID string, or 16-byte buffer.
	@param options Optional parse flags used when `value` is a string.
	@return boolean -- `true` when coercion succeeds.
]=]
function uuid.validate(value: UUIDLike, options: ParseOptions?): boolean
	local ok = pcall(uuid.from, value, options)
	return ok
end

--[=[
	Format a UUID-like value into a textual representation.

	@param value UUID object, UUID string, or 16-byte buffer.
	@param style Optional output style. Defaults to `"canonical"`.
	@return string -- Formatted UUID string.
]=]
function uuid.format(value: UUIDLike, style: UUIDFormatStyle?): string
	local id = uuid.from(value)
	local canonical = bufferToCanonical(id.bytes)
	local requested = style or "canonical"

	if requested == "canonical" then
		return canonical
	end
	if requested == "simple" then
		return (canonical:gsub("-", ""))
	end
	if requested == "urn" then
		return "urn:uuid:" .. canonical
	end
	if requested == "braced" then
		return "{" .. canonical .. "}"
	end

	fail("invalid UUID format style")
	assert(false)
end

--[=[
	Return a copy of a UUID-like value as a raw 16-byte buffer.

	@param value UUID object, UUID string, or 16-byte buffer.
	@return buffer -- New buffer containing the UUID bytes.
]=]
function uuid.toBuffer(value: UUIDLike): buffer
	return uuid.from(value):toBuffer()
end

--[=[
	Check whether two UUID-like values are bytewise equal.

	@param a Left-hand UUID value.
	@param b Right-hand UUID value.
	@return boolean -- `true` when both values encode the same UUID.
]=]
function uuid.equals(a: UUIDLike, b: UUIDLike): boolean
	local left = uuid.from(a).bytes
	local right = uuid.from(b).bytes

	for i = 0, 15 do
		if buffer.readu8(left, i) ~= buffer.readu8(right, i) then
			return false
		end
	end
	return true
end

--[=[
	Compare two UUID-like values using raw byte ordering.

	This is useful for sortable UUID families such as `v6` and `v7`, or
	when storing UUIDs in ordered indexes.

	@param a Left-hand UUID value.
	@param b Right-hand UUID value.
	@return number -- `-1`, `0`, or `1` depending on ordering.
]=]
function uuid.compare(a: UUIDLike, b: UUIDLike): UUIDOrdering
	local left = uuid.from(a).bytes
	local right = uuid.from(b).bytes

	for i = 0, 15 do
		local av = buffer.readu8(left, i)
		local bv = buffer.readu8(right, i)
		if av < bv then
			return -1
		end
		if av > bv then
			return 1
		end
	end
	return 0
end

--[=[
	Generate a version 1 UUID.

	When not explicitly supplied, the node and clock sequence are derived
	from cryptographically secure random bytes. The `nanoseconds` field
	represents the sub-millisecond portion of the timestamp and must be a
	multiple of 100.

	@param options Optional generation controls.
	@return UUIDv1 -- Generated version 1 UUID.
]=]
function uuid.v1(options: UUIDv1Options?): UUIDv1
	local rng = coerceRandom(if options then options.random else nil)
	local unixMillis = if options and options.unixMillis ~= nil then options.unixMillis else currentUnixMillis()
	validateV1V6UnixMillis(unixMillis, "v1")

	local subMs100ns = coerceSubMillisecond100ns(if options then options.nanoseconds else nil)
	local clockSequence = coerceClockSequence(if options then options.clockSequence else nil, rng)
	local node = coerceNode(if options then options.node else nil, rng)
	local timestamp100ns = timestamp100nsFromUnixMillis(unixMillis, subMs100ns)
	local bytes = buffer.create(16)

	writeTimestampV1(bytes, timestamp100ns)
	writeClockSequence(bytes, clockSequence)
	writeNode(bytes, node)

	return buildUuid(bytes) :: any
end

--[=[
	Generate a version 3 namespace-name UUID using MD5.

	@param options Namespace and name to hash.
	@return UUIDv3 -- Generated version 3 UUID.
]=]
function uuid.v3(options: UUIDv3Options): UUIDv3
	return hashUuid(options.namespace, options.name, "md5", 3) :: any
end

--[=[
	Generate a version 4 random UUID.

	By default this uses `@eryx/crypto/hazmat/random.bytes`.

	@param options Optional RNG override.
	@return UUIDv4 -- Generated version 4 UUID.
]=]
function uuid.v4(options: UUIDv4Options?): UUIDv4
	local rng = coerceRandom(if options then options.random else nil)
	local bytes = copyBuffer(rng(16))

	buffer.writeu8(bytes, 6, bit32.bor(bit32.band(buffer.readu8(bytes, 6), 0x0F), 0x40))
	buffer.writeu8(bytes, 8, bit32.bor(bit32.band(buffer.readu8(bytes, 8), 0x3F), 0x80))

	return buildUuid(bytes) :: any
end

--[=[
	Generate a version 5 namespace-name UUID using SHA-1.

	@param options Namespace and name to hash.
	@return UUIDv5 -- Generated version 5 UUID.
]=]
function uuid.v5(options: UUIDv5Options): UUIDv5
	return hashUuid(options.namespace, options.name, "sha1", 5) :: any
end

--[=[
	Generate a version 6 reordered time-based UUID.

	This uses the same Gregorian 100ns timestamp source model as `v1`, but
	reorders the bytes to improve sort locality.

	@param options Optional generation controls.
	@return UUIDv6 -- Generated version 6 UUID.
]=]
function uuid.v6(options: UUIDv6Options?): UUIDv6
	local rng = coerceRandom(if options then options.random else nil)
	local unixMillis = if options and options.unixMillis ~= nil then options.unixMillis else currentUnixMillis()
	validateV1V6UnixMillis(unixMillis, "v6")

	local subMs100ns = coerceSubMillisecond100ns(if options then options.nanoseconds else nil)
	local clockSequence = coerceClockSequence(if options then options.clockSequence else nil, rng)
	local node = coerceNode(if options then options.node else nil, rng)
	local timestamp100ns = timestamp100nsFromUnixMillis(unixMillis, subMs100ns)
	local bytes = buffer.create(16)

	writeTimestampV6(bytes, timestamp100ns)
	writeClockSequence(bytes, clockSequence)
	writeNode(bytes, node)

	return buildUuid(bytes) :: any
end

--[=[
	Generate a version 7 Unix-time-ordered UUID.

	When `sequence` is omitted, this library applies monotonic sequencing so
	that repeated calls remain bytewise ordered even within the same
	millisecond.

	@param options Optional generation controls.
	@return UUIDv7 -- Generated version 7 UUID.
]=]
function uuid.v7(options: UUIDv7Options?): UUIDv7
	local requestedUnixMillis = if options and options.unixMillis ~= nil then options.unixMillis else currentUnixMillis()
	local unixMillis = requestedUnixMillis
	if integer.lt(unixMillis, 0i) or integer.ge(unixMillis, 281474976710656i) then
		fail("uuid.v7 unixMillis must be an integer in the 48-bit range")
	end

	local sequence = if options then options.sequence else nil
	if sequence ~= nil and (math.floor(sequence) ~= sequence or sequence < 0 or sequence > 0xFFF) then
		fail("uuid.v7 sequence must be an integer in the 0..4095 range")
	end

	local rng = coerceRandom(if options then options.random else nil)
	local randomTail = rng(10)
	local bytes = buffer.create(16)

	local ts = unixMillis
	for i = 5, 0, -1 do
		buffer.writeu8(bytes, i, integer.tonumber(integer.mod(ts, 256i)))
		ts = integer.idiv(ts, 256i)
	end

	local randA: number
	if sequence ~= nil then
		randA = sequence
	else
		unixMillis, randA = nextMonotonicV7(requestedUnixMillis, sequenceFromRandomTail(randomTail))
		ts = unixMillis
		for i = 5, 0, -1 do
			buffer.writeu8(bytes, i, integer.tonumber(integer.mod(ts, 256i)))
			ts = integer.idiv(ts, 256i)
		end
	end

	buffer.writeu8(bytes, 6, bit32.bor(0x70, bit32.band(bit32.rshift(randA, 8), 0x0F)))
	buffer.writeu8(bytes, 7, bit32.band(randA, 0xFF))

	for i = 0, 7 do
		buffer.writeu8(bytes, 8 + i, buffer.readu8(randomTail, 2 + i))
	end
	buffer.writeu8(bytes, 8, bit32.bor(bit32.band(buffer.readu8(bytes, 8), 0x3F), 0x80))

	return buildUuid(bytes) :: any
end

--[=[
	Generate a version 8 UUID from caller-supplied bytes.

	The provided payload must be exactly 16 bytes long. The version and
	variant bits are normalized to match a valid `v8` UUID.

	@param options Raw payload bytes to wrap as a version 8 UUID.
	@return UUIDv8 -- Generated version 8 UUID.
]=]
function uuid.v8(options: UUIDv8Options): UUIDv8
	if buffer.len(options.bytes) ~= 16 then
		fail("uuid.v8 bytes must be exactly 16 bytes")
	end
	local bytes = copyBuffer(options.bytes)
	buffer.writeu8(bytes, 6, bit32.bor(bit32.band(buffer.readu8(bytes, 6), 0x0F), 0x80))
	buffer.writeu8(bytes, 8, bit32.bor(bit32.band(buffer.readu8(bytes, 8), 0x3F), 0x80))
	return buildUuid(bytes) :: any
end

return table.freeze(uuid)
