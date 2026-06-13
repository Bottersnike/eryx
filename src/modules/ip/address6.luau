local utils = require("./utils")

local cloneArray = utils.cloneArray
local compareHextets = utils.compareHextets
local ipv6Increment = utils.ipv6Increment
local ipv6Decrement = utils.ipv6Decrement
local parseIPv6Hextets = utils.parseIPv6Hextets
local trim = utils.trim

local IPv6Address = {}
IPv6Address.__index = IPv6Address

export type IPv6Address = setmetatable<
	{
		--- IP version number (`6`). This value is a string for type narrowing
		read version: "6",
		--- IPv6 hextets in network order.
		read _hextets: { number },
	},
	typeof(IPv6Address)
>

local function ensureV6Address(v: any): IPv6Address
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Address then
		error("expected IPv6Address")
	end
	return v
end

local function createIPv6Address(hextets: { number }): IPv6Address
	local v = setmetatable({
		version = "6",
		_hextets = cloneArray(hextets),
	}, IPv6Address)
	return table.freeze(v)
end

local function stripLeadingZeros(dec: string): string
	local stripped = string.gsub(dec, "^0+", "")
	if stripped == "" then
		return "0"
	end
	return stripped
end

local function decimalDivMod(dec: string, div: number): (string, number)
	local out = table.create(#dec)
	local outLen = 0
	local rem = 0
	for i = 1, #dec do
		local digit = string.byte(dec, i) - 48
		local value = rem * 10 + digit
		local q = math.floor(value / div)
		rem = value % div
		if q ~= 0 or outLen > 0 then
			outLen += 1
			out[outLen] = string.char(48 + q)
		end
	end
	if outLen == 0 then
		return "0", rem
	end
	return table.concat(out, "", 1, outLen), rem
end

local function decimalToBytes(value: string, byteCount: number): { number }
	if not string.match(value, "^%d+$") then
		error("invalid decimal integer")
	end
	local dec = stripLeadingZeros(value)
	local out = table.create(byteCount, 0)
	for i = byteCount, 1, -1 do
		local q, rem = decimalDivMod(dec, 256)
		out[i] = rem
		dec = q
	end
	if dec ~= "0" then
		error("integer does not fit in target width")
	end
	return out
end

local function decimalMulAdd(dec: string, mul: number, add: number): string
	local carry = add
	local out = table.create(#dec)
	for i = #dec, 1, -1 do
		local digit = string.byte(dec, i) - 48
		local value = digit * mul + carry
		out[i] = string.char(48 + (value % 10))
		carry = math.floor(value / 10)
	end
	local prefix = {}
	while carry > 0 do
		table.insert(prefix, 1, string.char(48 + (carry % 10)))
		carry = math.floor(carry / 10)
	end
	return stripLeadingZeros(table.concat(prefix) .. table.concat(out))
end

local function bytesToDecimal(bytes: { number }): string
	local dec = "0"
	for i = 1, #bytes do
		dec = decimalMulAdd(dec, 256, bytes[i])
	end
	return dec
end

local function hextetsToBytes(hextets: { number }): { number }
	local bytes = table.create(16, 0)
	for i = 1, 8 do
		local h = hextets[i]
		bytes[(i - 1) * 2 + 1] = math.floor(h / 256) % 256
		bytes[(i - 1) * 2 + 2] = h % 256
	end
	return bytes
end

local function bytesToHextets(bytes: { number }): { number }
	local hextets = table.create(8, 0)
	for i = 1, 8 do
		hextets[i] = bytes[(i - 1) * 2 + 1] * 256 + bytes[(i - 1) * 2 + 2]
	end
	return hextets
end

local function hextetsToExpandedString(hextets: { number }): string
	local parts = table.create(8)
	for i = 1, 8 do
		parts[i] = string.format("%04x", hextets[i])
	end
	return table.concat(parts, ":")
end

local function hextetsToCompressedString(hextets: { number }): string
	local bestStart = -1
	local bestLen = 0
	local runStart = -1
	local runLen = 0
	for i = 1, 8 do
		if hextets[i] == 0 then
			if runStart == -1 then
				runStart = i
				runLen = 1
			else
				runLen += 1
			end
		else
			if runLen > bestLen then
				bestStart = runStart
				bestLen = runLen
			end
			runStart = -1
			runLen = 0
		end
	end
	if runLen > bestLen then
		bestStart = runStart
		bestLen = runLen
	end
	if bestLen < 2 then
		bestStart = -1
	end

	local out = {}
	local i = 1
	while i <= 8 do
		if bestStart ~= -1 and i == bestStart then
			table.insert(out, "")
			i += bestLen
		else
			table.insert(out, string.format("%x", hextets[i]))
			i += 1
		end
	end

	local s = table.concat(out, ":")
	if s == "" then
		return "::"
	end
	if string.sub(s, 1, 1) == ":" then
		s = ":" .. s
	end
	if string.sub(s, -1) == ":" then
		s = s .. ":"
	end
	return s
end

local function compareIPv6Address(a: IPv6Address, b: IPv6Address): number
	return compareHextets(ensureV6Address(a)._hextets, ensureV6Address(b)._hextets)
end

local function ipv6AddressString(self: IPv6Address): string
	return hextetsToCompressedString(ensureV6Address(self)._hextets)
end

function IPv6Address.sort(values: { IPv6Address | string }): { IPv6Address }
	local out: { IPv6Address } = {}
	for i = 1, #values do
		local value = values[i]
		if type(value) == "string" then
			local parsed = IPv6Address.parse(value)
			if not parsed then
				error("sortIPv6 expects IPv6 addresses only")
			end
			out[i] = parsed
		else
			out[i] = ensureV6Address(value)
		end
	end
	table.sort(out, function(x: IPv6Address, y: IPv6Address)
		return compareIPv6Address(x, y) < 0
	end)
	return out
end

function IPv6Address.parse(source: string, options: utils.ParseOptions?): IPv6Address?
	local hextets = parseIPv6Hextets(trim(source), options)
	if not hextets then
		return nil
	end
	return createIPv6Address(hextets)
end

--- IPv6 Constructors
function IPv6Address.fromBytes(val: buffer | { number }): IPv6Address
	local bytes: { number }
	if typeof(val) == "buffer" then
		if buffer.len(val) ~= 16 then
			error("IPv6 buffer must be 16 bytes")
		end
		bytes = table.create(16, 0)
		for i = 1, 16 do
			bytes[i] = buffer.readu8(val, i - 1)
		end
	else
		bytes = val
		if #bytes ~= 16 then
			error("IPv6 byte array must be length 16")
		end
	end
	return createIPv6Address(bytesToHextets(bytes))
end

function IPv6Address.fromPacked(val: buffer | { number }): IPv6Address
	return IPv6Address.fromBytes(val)
end

function IPv6Address.fromInteger(val: number | string): IPv6Address
	local dec: string
	if type(val) == "number" then
		if val < 0 or val ~= math.floor(val) then
			error("IPv6 integer must be a non-negative integer")
		end
		dec = tostring(val)
	elseif type(val) == "string" then
		dec = val
	else
		error("IPv6 integer must be a number or decimal string")
	end
	return createIPv6Address(bytesToHextets(decimalToBytes(dec, 16)))
end

function IPv6Address.__string(self: IPv6Address): string
	return ipv6AddressString(self)
end

function IPv6Address.compressed(self: IPv6Address): string
	return IPv6Address.__string(self)
end

function IPv6Address.expanded(self: IPv6Address): string
	return hextetsToExpandedString(ensureV6Address(self)._hextets)
end

function IPv6Address.toUriHost(self: IPv6Address): string
	return "[" .. IPv6Address.compressed(self) .. "]"
end

function IPv6Address.reverseUri(self: IPv6Address): string
	local bytes = hextetsToBytes(ensureV6Address(self)._hextets)
	local nibbles = table.create(32)
	for i = 1, 16 do
		nibbles[(i - 1) * 2 + 1] = string.format("%x", math.floor(bytes[i] / 16))
		nibbles[(i - 1) * 2 + 2] = string.format("%x", bytes[i] % 16)
	end
	local out = {}
	for i = 32, 1, -1 do
		table.insert(out, nibbles[i])
	end
	return table.concat(out, ".") .. ".ip6.arpa"
end

function IPv6Address.toBytes(self: IPv6Address): buffer
	local bytes = hextetsToBytes(ensureV6Address(self)._hextets)
	local out = buffer.create(16)
	for i = 1, 16 do
		buffer.writeu8(out, i - 1, bytes[i])
	end
	return out
end

function IPv6Address.toPacked(self: IPv6Address): buffer
	return IPv6Address.toBytes(self)
end

function IPv6Address.toInteger(self: IPv6Address): string
	return bytesToDecimal(hextetsToBytes(ensureV6Address(self)._hextets))
end

function IPv6Address.isPrivate(self: IPv6Address): boolean
	return IPv6Address.isUniqueLocal(self)
end

function IPv6Address.ipPublic(self: IPv6Address): boolean
	return IPv6Address.isGlobal(self)
end

function IPv6Address.isLoopback(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	for i = 1, 7 do
		if h[i] ~= 0 then
			return false
		end
	end
	return h[8] == 1
end

function IPv6Address.isMulticast(self: IPv6Address): boolean
	return bit32.rshift(ensureV6Address(self)._hextets[1], 8) == 0xFF
end

function IPv6Address.isLinkLocal(self: IPv6Address): boolean
	local h1 = ensureV6Address(self)._hextets[1]
	return bit32.band(h1, 0xFFC0) == 0xFE80
end

function IPv6Address.isUnspecified(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	for i = 1, 8 do
		if h[i] ~= 0 then
			return false
		end
	end
	return true
end

function IPv6Address.isReserved(self: IPv6Address): boolean
	return false
end

function IPv6Address.isDocumentation(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0x0DB8
end

function IPv6Address.isBenchmarking(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0x0002 and h[3] == 0
end

function IPv6Address.isShared(self: IPv6Address): boolean
	return false
end

function IPv6Address.isGlobal(self: IPv6Address): boolean
	return not IPv6Address.isPrivate(self)
		and not IPv6Address.isLoopback(self)
		and not IPv6Address.isMulticast(self)
		and not IPv6Address.isLinkLocal(self)
		and not IPv6Address.isUnspecified(self)
		and not IPv6Address.isDocumentation(self)
		and not IPv6Address.isBenchmarking(self)
end

-- TODO: Replace string with a union of all categories
function IPv6Address.category(self: IPv6Address): string
	if IPv6Address.isUnspecified(self) then
		return "unspecified"
	elseif IPv6Address.isLoopback(self) then
		return "loopback"
	elseif IPv6Address.isPrivate(self) then
		return "private"
	elseif IPv6Address.isLinkLocal(self) then
		return "link-local"
	elseif IPv6Address.isMulticast(self) then
		return "multicast"
	elseif IPv6Address.isDocumentation(self) then
		return "documentation"
	elseif IPv6Address.isBenchmarking(self) then
		return "benchmarking"
	elseif IPv6Address.isGlobal(self) then
		return "global"
	end
	return "other"
end

function IPv6Address.isUniqueLocal(self: IPv6Address): boolean
	local h1 = ensureV6Address(self)._hextets[1]
	return bit32.band(h1, 0xFE00) == 0xFC00
end

function IPv6Address.isIPv4Mapped(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0 and h[2] == 0 and h[3] == 0 and h[4] == 0 and h[5] == 0 and h[6] == 0xFFFF
end

function IPv6Address.isIPv4Compatible(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0 and h[2] == 0 and h[3] == 0 and h[4] == 0 and h[5] == 0 and h[6] == 0
end

-- TODO: Expand return enum
function IPv6Address.scope(self: IPv6Address): "interface-local" | "link-local" | "global"
	if IPv6Address.isLinkLocal(self) then
		return "link-local"
	end
	if IPv6Address.isLoopback(self) or IPv6Address.isUnspecified(self) then
		return "interface-local"
	end
	return "global"
end

function IPv6Address.is6to4(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2002
end

function IPv6Address.isTeredo(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0
end

function IPv6Address.next(self: IPv6Address): IPv6Address
	local n = ipv6Increment(ensureV6Address(self)._hextets)
	if not n then
		error("IPv6 overflow")
	end
	return createIPv6Address(n)
end

function IPv6Address.previous(self: IPv6Address): IPv6Address
	local n = ipv6Decrement(ensureV6Address(self)._hextets)
	if not n then
		error("IPv6 underflow")
	end
	return createIPv6Address(n)
end

-- Implemented in network6.luau (needs IPv6Network) and init.luau (needs IPv4Address).
-- Stubs here so the sealed table type includes these properties before patching.
function IPv6Address.inNetwork(_self: IPv6Address, _net: any): boolean
	error("ip/network6 not loaded")
end

function IPv6Address.__div(_a: IPv6Address, _b: number): any
	error("ip/network6 not loaded")
end

function IPv6Address.getEmbeddedIPv4(_self: IPv6Address): any
	error("ip module not fully loaded")
end

function IPv6Address.toIPv4(_self: IPv6Address): any
	error("ip module not fully loaded")
end

function IPv6Address.__eq(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		return false
	end
	return compareIPv6Address(a, b) == 0
end

function IPv6Address.__lt(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		error("IPv6Address comparison requires two IPv6Address values")
	end
	return compareIPv6Address(a, b) < 0
end

function IPv6Address.__le(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		error("IPv6Address comparison requires two IPv6Address values")
	end
	return compareIPv6Address(a, b) <= 0
end

function IPv6Address.__tostring(self: IPv6Address): string
	return ipv6AddressString(self)
end

IPv6Address._create = createIPv6Address
IPv6Address._ensure = ensureV6Address

return IPv6Address
