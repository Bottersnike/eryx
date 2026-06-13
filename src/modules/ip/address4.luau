local utils = require("./utils")

local MAX_IPV4 = utils.MAX_IPV4
local trim = utils.trim
local octetsToInt = utils.octetsToInt
local intToOctets = utils.intToOctets
local parseIPv4Octets = utils.parseIPv4Octets

local IPv4Address = {}
IPv4Address.__index = IPv4Address

export type IPv4Address = setmetatable<
	{
		--- IP version number (`4`). This value is a string for type narrowing
		read version: "4",
		--- IPv4 octets in network order.
		read _octets: { number },
		--- Packed 32-bit integer representation.
		read _int: number,
	},
	typeof(IPv4Address)
>

local function ensureV4Address(v: any): IPv4Address
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Address then
		error("expected IPv4Address")
	end
	return v
end

local function createIPv4AddressFromOctets(octets: { number }): IPv4Address
	local v = setmetatable({
		version = "4",
		_octets = { octets[1], octets[2], octets[3], octets[4] },
		_int = octetsToInt(octets),
	}, IPv4Address)
	return table.freeze(v)
end

local function createIPv4AddressFromInt(value: number): IPv4Address
	local v = setmetatable({
		version = "4",
		_octets = intToOctets(value),
		_int = value,
	}, IPv4Address)
	return table.freeze(v)
end

local function compareIPv4Address(a: IPv4Address, b: IPv4Address): number
	local ai = ensureV4Address(a)._int
	local bi = ensureV4Address(b)._int
	if ai < bi then
		return -1
	elseif ai > bi then
		return 1
	end
	return 0
end

local function ipv4AddressString(self: IPv4Address): string
	local inner = ensureV4Address(self)
	return string.format("%d.%d.%d.%d", inner._octets[1], inner._octets[2], inner._octets[3], inner._octets[4])
end

function IPv4Address.sort(values: { IPv4Address | string }): { IPv4Address }
	local out: { IPv4Address } = {}
	for i = 1, #values do
		local value = values[i]
		if type(value) == "string" then
			local parsed = IPv4Address.parse(value)
			if not parsed then
				error("sortIPv4 expects IPv4 addresses only")
			end
			out[i] = parsed
		else
			out[i] = ensureV4Address(value)
		end
	end
	table.sort(out, function(x: IPv4Address, y: IPv4Address)
		return compareIPv4Address(x, y) < 0
	end)
	return out
end

function IPv4Address.parse(source: string, options: utils.ParseOptions?): IPv4Address?
	local octets = parseIPv4Octets(trim(source))
	if not octets then
		return nil
	end
	return createIPv4AddressFromOctets(octets)
end

--- IPv4 Constructors
function IPv4Address.fromOctets(octets: { number }): IPv4Address
	if #octets ~= 4 then
		error("IPv4 requires exactly 4 octets")
	end
	for i = 1, 4 do
		local n = octets[i]
		if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 255 then
			error("IPv4 octets must be integers in [0,255]")
		end
	end
	return createIPv4AddressFromOctets(octets)
end

function IPv4Address.fromInteger(val: number): IPv4Address
	if val ~= math.floor(val) or val < 0 or val > MAX_IPV4 then
		error("IPv4 integer must be in [0, 4294967295]")
	end
	return createIPv4AddressFromInt(val)
end

function IPv4Address.fromBytes(val: buffer | { number }): IPv4Address
	local octets: { number }
	if typeof(val) == "buffer" then
		if buffer.len(val) ~= 4 then
			error("IPv4 buffer must be 4 bytes")
		end
		octets = {
			buffer.readu8(val, 0),
			buffer.readu8(val, 1),
			buffer.readu8(val, 2),
			buffer.readu8(val, 3),
		}
	else
		octets = val
		if #octets ~= 4 then
			error("IPv4 byte array must be length 4")
		end
	end
	return IPv4Address.fromOctets(octets)
end

function IPv4Address.fromPacked(val: buffer | { number }): IPv4Address
	return IPv4Address.fromBytes(val)
end

function IPv4Address.__string(self: IPv4Address): string
	return ipv4AddressString(self)
end

function IPv4Address.reverseUri(self: IPv4Address): string
	local inner = ensureV4Address(self)
	return string.format(
		"%d.%d.%d.%d.in-addr.arpa",
		inner._octets[4],
		inner._octets[3],
		inner._octets[2],
		inner._octets[1]
	)
end

function IPv4Address.toInteger(self: IPv4Address): number
	return ensureV4Address(self)._int
end

function IPv4Address.toBytes(self: IPv4Address): buffer
	local inner = ensureV4Address(self)
	local out = buffer.create(4)
	for i = 1, 4 do
		buffer.writeu8(out, i - 1, inner._octets[i])
	end
	return out
end

function IPv4Address.toPacked(self: IPv4Address): buffer
	return IPv4Address.toBytes(self)
end

function IPv4Address.isPrivate(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 10 or (a[1] == 172 and a[2] >= 16 and a[2] <= 31) or (a[1] == 192 and a[2] == 168)
end

function IPv4Address.ipPublic(self: IPv4Address): boolean
	return IPv4Address.isGlobal(self)
end

function IPv4Address.isLoopback(self: IPv4Address): boolean
	return ensureV4Address(self)._octets[1] == 127
end

function IPv4Address.isMulticast(self: IPv4Address): boolean
	local o1 = ensureV4Address(self)._octets[1]
	return o1 >= 224 and o1 <= 239
end

function IPv4Address.isLinkLocal(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 169 and a[2] == 254
end

function IPv4Address.isUnspecified(self: IPv4Address): boolean
	return ensureV4Address(self)._int == 0
end

function IPv4Address.isReserved(self: IPv4Address): boolean
	local inner = ensureV4Address(self)
	local o1 = inner._octets[1]
	return o1 >= 240 and inner._int ~= MAX_IPV4
end

function IPv4Address.isDocumentation(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return (a[1] == 192 and a[2] == 0 and a[3] == 2)
		or (a[1] == 198 and a[2] == 51 and a[3] == 100)
		or (a[1] == 203 and a[2] == 0 and a[3] == 113)
end

function IPv4Address.isBenchmarking(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 198 and (a[2] == 18 or a[2] == 19)
end

function IPv4Address.isShared(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 100 and a[2] >= 64 and a[2] <= 127
end

function IPv4Address.isBroadcast(self: IPv4Address): boolean
	return ensureV4Address(self)._int == MAX_IPV4
end

function IPv4Address.isGlobal(self: IPv4Address): boolean
	return not IPv4Address.isPrivate(self)
		and not IPv4Address.isLoopback(self)
		and not IPv4Address.isMulticast(self)
		and not IPv4Address.isLinkLocal(self)
		and not IPv4Address.isUnspecified(self)
		and not IPv4Address.isReserved(self)
		and not IPv4Address.isDocumentation(self)
		and not IPv4Address.isBenchmarking(self)
		and not IPv4Address.isShared(self)
		and not IPv4Address.isBroadcast(self)
end

-- TODO: Replace string with a union of all categories
function IPv4Address.category(self: IPv4Address): string
	if IPv4Address.isUnspecified(self) then
		return "unspecified"
	elseif IPv4Address.isLoopback(self) then
		return "loopback"
	elseif IPv4Address.isPrivate(self) then
		return "private"
	elseif IPv4Address.isLinkLocal(self) then
		return "link-local"
	elseif IPv4Address.isMulticast(self) then
		return "multicast"
	elseif IPv4Address.isDocumentation(self) then
		return "documentation"
	elseif IPv4Address.isBenchmarking(self) then
		return "benchmarking"
	elseif IPv4Address.isShared(self) then
		return "shared"
	elseif IPv4Address.isReserved(self) then
		return "reserved"
	elseif IPv4Address.isBroadcast(self) then
		return "broadcast"
	elseif IPv4Address.isGlobal(self) then
		return "global"
	end
	return "other"
end

function IPv4Address.next(self: IPv4Address): IPv4Address
	local inner = ensureV4Address(self)
	if inner._int >= MAX_IPV4 then
		error("IPv4 overflow")
	end
	return createIPv4AddressFromInt(inner._int + 1)
end

function IPv4Address.previous(self: IPv4Address): IPv4Address
	local inner = ensureV4Address(self)
	if inner._int <= 0 then
		error("IPv4 underflow")
	end
	return createIPv4AddressFromInt(inner._int - 1)
end

-- Implemented in network4.luau (needs IPv4Network) and init.luau (needs IPv6Address).
-- Stubs here so the sealed table type includes these properties before patching.
function IPv4Address.inNetwork(_self: IPv4Address, _net: any): boolean
	error("ip/network4 not loaded")
end

function IPv4Address.__div(_a: IPv4Address, _b: number): any
	error("ip/network4 not loaded")
end

function IPv4Address.toIPv6Mapped(_self: IPv4Address): any
	error("ip module not fully loaded")
end

function IPv4Address.__eq(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		return false
	end
	return compareIPv4Address(a, b) == 0
end

function IPv4Address.__lt(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		error("IPv4Address comparison requires two IPv4Address values")
	end
	return compareIPv4Address(a, b) < 0
end

function IPv4Address.__le(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		error("IPv4Address comparison requires two IPv4Address values")
	end
	return compareIPv4Address(a, b) <= 0
end

function IPv4Address.__tostring(self: IPv4Address): string
	return ipv4AddressString(self)
end

IPv4Address._newFromOctets = createIPv4AddressFromOctets
IPv4Address._newFromInt = createIPv4AddressFromInt
IPv4Address._ensure = ensureV4Address

return IPv4Address
