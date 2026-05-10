local ip = {}

local IPv4Address = {}
IPv4Address.__index = IPv4Address
--[=[
Represents an IPv4 address.
@return Metatable-backed type representing an IPv4 address object.
]=]
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

local IPv6Address = {}
IPv6Address.__index = IPv6Address
--[=[
Represents an IPv6 address.
@return Metatable-backed type representing an IPv6 address object.
]=]
export type IPv6Address = setmetatable<
	{
		--- IP version number (`6`). This value is a string for type narrowing
		read version: "6",
		--- IPv6 hextets in network order.
		read _hextets: { number },
	},
	typeof(IPv6Address)
>

local IPv4Network = {}
IPv4Network.__index = IPv4Network
--[=[
Represents an IPv4 CIDR network.
@return Metatable-backed type representing an IPv4 network object.
]=]
export type IPv4Network = setmetatable<
	{
		--- IP version number (`4`). This value is a string for type narrowing
		read version: "4",
		--- CIDR prefix length.
		read _prefix: number,
		--- Packed network address as 32-bit integer.
		read _network: number,
	},
	typeof(IPv4Network)
>

local IPv6Network = {}
IPv6Network.__index = IPv6Network
--[=[
Represents an IPv6 CIDR network.
@return Metatable-backed type representing an IPv6 network object.
]=]
export type IPv6Network = setmetatable<
	{
		--- IP version number (`6`). This value is a string for type narrowing
		read version: "6",
		--- CIDR prefix length.
		read _prefix: number,
		--- Network address as hextets.
		read _network: { number },
	},
	typeof(IPv6Network)
>

local IPv4Interface = {}
IPv4Interface.__index = IPv4Interface
--[=[
Represents an IPv4 interface assignment (`address/prefix`).
@return Metatable-backed type representing an IPv4 interface object.
]=]
export type IPv4Interface = setmetatable<
	{
		--- Assigned IPv4 address.
		read address: IPv4Address,
		--- Containing IPv4 network.
		read network: IPv4Network,
		--- Interface prefix length.
		read _prefix: number,
	},
	typeof(IPv4Interface)
>
local IPv6Interface = {}

IPv6Interface.__index = IPv6Interface
--[=[
Represents an IPv6 interface assignment (`address/prefix`).
@return Metatable-backed type representing an IPv6 interface object.
]=]
export type IPv6Interface = setmetatable<
	{
		--- Assigned IPv6 address.
		read address: IPv6Address,
		--- Containing IPv6 network.
		read network: IPv6Network,
		--- Interface prefix length.
		read _prefix: number,
	},
	typeof(IPv6Interface)
>

local IPv4Range = {}
IPv4Range.__index = IPv4Range
--[=[
Represents a normalized set of IPv4 segments.
@return Metatable-backed type representing an IPv4 range object.
]=]
export type IPv4Range = setmetatable<
	{
		--- IP version number (`4`). This value is a string for type narrowing
		read version: "4",
		--- Sorted, non-overlapping inclusive segments.
		read _segments: { { start: number, finish: number } },
	},
	typeof(IPv4Range)
>

local IPv6Range = {}
IPv6Range.__index = IPv6Range
--[=[
Represents a normalized set of IPv6 segments.
@return Metatable-backed type representing an IPv6 range object.
]=]
export type IPv6Range = setmetatable<
	{
		--- IP version number (`6`). This value is a string for type narrowing
		read version: "6",
		--- Sorted, non-overlapping inclusive segments.
		read _segments: { { start: { number }, finish: { number } } },
	},
	typeof(IPv6Range)
>

local MAX_IPV4 = 0xFFFFFFFF
local MAX_ITER = 65536

type ParseOptions = {
	strict: boolean?,
	allowZoneId: boolean?,
}

--[=[
Trim leading and trailing ASCII whitespace from a string.
@param source Source text to parse, validate, or classify.
@return Whitespace-trimmed copy of the input string.
]=]
local function trim(source: string): string
	return string.match(source, "^%s*(.-)%s*$") or ""
end

local function parseOptions(options: ParseOptions?): ParseOptions
	return options or {}
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

--[=[
Split a string once on the first occurrence of a separator.
@param source Source text to parse, validate, or classify.
@param sep Separator string used for the split operation.
@return Tuple containing left token and optional right remainder.
]=]
local function splitOnce(source: string, sep: string): (string, string?)
	local i = string.find(source, sep, 1, true)
	if not i then
		return source, nil
	end
	return string.sub(source, 1, i - 1), string.sub(source, i + #sep)
end

--[=[
Create a shallow copy of an array-like table.
@param arr Array/table values to clone or iterate over.
@return New array containing the same values in the same order.
]=]
local function cloneArray<T>(arr: { T }): { T }
	local out = table.create(#arr)
	for i = 1, #arr do
		out[i] = arr[i]
	end
	return out
end

--[=[
Convert a 32-bit IPv4 integer into four octets.
@param value Numeric, string, or IP value used by this operation.
@return Four IPv4 octets derived from the packed integer.
]=]
local function intToOctets(value: number): { number }
	return {
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256,
	}
end

--[=[
Pack four IPv4 octets into a 32-bit integer.
@param octets IPv4 octet values in network order.
@return Numeric result produced by the operation.
]=]
local function octetsToInt(octets: { number }): number
	return (((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4])
end

--[=[
Split a colon-delimited string into tokens, preserving empty edges.
@param source Source text to parse, validate, or classify.
@return Sequence of colon-separated segments.
]=]
local function splitColon(source: string): { string }
	if source == "" then
		return {}
	end
	local parts = {}
	local start = 1
	while true do
		local i = string.find(source, ":", start, true)
		if not i then
			table.insert(parts, string.sub(source, start))
			break
		end
		table.insert(parts, string.sub(source, start, i - 1))
		start = i + 1
		if start > #source + 1 then
			break
		end
	end
	return parts
end

--[=[
Parse an IPv4 literal into four validated octets.
@param source Source text to parse, validate, or classify.
@return IPv4 octets plus optional parse error message.
]=]
local function parseIPv4Octets(source: string): ({ number }?, string?)
	local a, b, c, d = string.match(trim(source), "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a or not b or not c or not d then
		return nil, "invalid IPv4 format"
	end
	local octets = table.create(4, 0)
	local parts = { a, b, c, d }
	for i = 1, 4 do
		local part = parts[i]
		if #part > 1 and string.sub(part, 1, 1) == "0" then
			return nil, "invalid IPv4 octet"
		end
		local n = tonumber(part)
		if n == nil or n < 0 or n > 255 or n ~= math.floor(n) then
			return nil, "invalid IPv4 octet"
		end
		octets[i] = n
	end
	return octets, nil
end

--[=[
Parse one side of an IPv6 literal into hextet groups.
@param side One side of a split IPv6 address around :: compression.
@param allowEmbeddedV4 Whether an embedded IPv4 tail is allowed in IPv6 parsing.
@return Parsed IPv6 groups plus optional parse error message.
]=]
local function parseIPv6GroupsPart(side: string, allowEmbeddedV4: boolean): ({ number }?, string?)
	local groups = {}
	local tokens = splitColon(side)
	for i = 1, #tokens do
		local token = tokens[i]
		if token == "" then
			return nil, "invalid IPv6 group"
		end
		if string.find(token, ".", 1, true) then
			if not allowEmbeddedV4 or i ~= #tokens then
				return nil, "invalid embedded IPv4"
			end
			local octets, err = parseIPv4Octets(token)
			if octets == nil then
				return nil, err
			end
			table.insert(groups, octets[1] * 256 + octets[2])
			table.insert(groups, octets[3] * 256 + octets[4])
		else
			if #token < 1 or #token > 4 or not string.match(token, "^[0-9A-Fa-f]+$") then
				return nil, "invalid IPv6 group"
			end
			local n = tonumber(token, 16)
			if n == nil then
				return nil, "invalid IPv6 group"
			end
			table.insert(groups, n)
		end
	end
	return groups, nil
end

--[=[
Parse an IPv6 literal (including :: compression) into eight hextets.
@param source Source text to parse, validate, or classify.
@return Eight IPv6 hextets plus optional parse error message.
]=]
local function parseIPv6Hextets(source: string, options: ParseOptions?): ({ number }?, string?)
	local opts = parseOptions(options)
	local input = trim(source)
	if input == "" then
		return nil, "empty IPv6"
	end
	local zoneIndex = string.find(input, "%", 1, true)
	if zoneIndex then
		if not opts.allowZoneId then
			return nil, "zones not supported"
		end
		input = string.sub(input, 1, zoneIndex - 1)
		if input == "" then
			return nil, "invalid zone-qualified IPv6"
		end
	end
	local dcStart, dcEnd = string.find(input, "::", 1, true)
	local left: { number }
	local right: { number }
	if dcStart and dcEnd then
		if string.find(input, "::", dcEnd + 1, true) then
			return nil, "too many '::'"
		end
		local leftPart = string.sub(input, 1, dcStart - 1)
		local rightPart = string.sub(input, dcEnd + 1)
		local leftParsed, leftErr = parseIPv6GroupsPart(leftPart, false)
		if leftParsed == nil then
			return nil, leftErr
		end
		local rightParsed, rightErr = parseIPv6GroupsPart(rightPart, true)
		if rightParsed == nil then
			return nil, rightErr
		end
		left = leftParsed
		right = rightParsed
		local missing = 8 - (#left + #right)
		if missing < 1 then
			return nil, "invalid IPv6 compression"
		end
		local out = {}
		for _, v in left do
			table.insert(out, v)
		end
		for _ = 1, missing do
			table.insert(out, 0)
		end
		for _, v in right do
			table.insert(out, v)
		end
		if #out ~= 8 then
			return nil, "invalid IPv6 length"
		end
		return out, nil
	end
	local whole, err = parseIPv6GroupsPart(input, true)
	if whole == nil then
		return nil, err
	end
	if #whole ~= 8 then
		return nil, "invalid IPv6 length"
	end
	return whole, nil
end

--[=[
Check whether two IPv6 hextet arrays are exactly equal.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
local function hextetsEqual(a: { number }, b: { number }): boolean
	for i = 1, 8 do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

--[=[
Lexicographically compare two IPv6 hextet arrays.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Numeric result produced by the operation.
]=]
local function compareHextets(a: { number }, b: { number }): number
	for i = 1, 8 do
		if a[i] < b[i] then
			return -1
		elseif a[i] > b[i] then
			return 1
		end
	end
	return 0
end

--[=[
Convert IPv6 hextets into a 16-byte array.
@param hextets IPv6 16-bit group values in network order.
@return Sixteen bytes representing the IPv6 address.
]=]
local function hextetsToBytes(hextets: { number }): { number }
	local bytes = table.create(16, 0)
	for i = 1, 8 do
		local h = hextets[i]
		bytes[(i - 1) * 2 + 1] = math.floor(h / 256) % 256
		bytes[(i - 1) * 2 + 2] = h % 256
	end
	return bytes
end

--[=[
Convert a 16-byte IPv6 array into eight hextets.
@param bytes Raw byte values representing an address.
@return Eight 16-bit IPv6 groups derived from raw bytes.
]=]
local function bytesToHextets(bytes: { number }): { number }
	local hextets = table.create(8, 0)
	for i = 1, 8 do
		hextets[i] = bytes[(i - 1) * 2 + 1] * 256 + bytes[(i - 1) * 2 + 2]
	end
	return hextets
end

--[=[
Format an IPv6 address in fully expanded canonical form.
@param hextets IPv6 16-bit group values in network order.
@return representation or textual result.
]=]
local function hextetsToExpandedString(hextets: { number }): string
	local parts = table.create(8)
	for i = 1, 8 do
		parts[i] = string.format("%04x", hextets[i])
	end
	return table.concat(parts, ":")
end

--[=[
Format an IPv6 address in compressed canonical form.
@param hextets IPv6 16-bit group values in network order.
@return representation or textual result.
]=]
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
			if i > 8 then
				table.insert(out, "")
			end
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

--[=[
Parse CIDR prefix text or IPv4 netmask text into a prefix length.
@param prefixPart Prefix text from CIDR notation or dotted netmask text.
@param version IP version selector (4 or 6).
@return Parsed prefix length plus optional parse error message.
]=]
local function parsePrefixPart(prefixPart: string, version: number): (number?, string?)
	local source = trim(prefixPart)
	if version == 4 and string.find(source, ".", 1, true) then
		local octets, err = parseIPv4Octets(source)
		if octets == nil then
			return nil, err
		end
		local mask = octetsToInt(octets)
		local seenZero = false
		local bits = 0
		for i = 31, 0, -1 do
			local bit = bit32.band(mask, bit32.lshift(1, i)) ~= 0
			if bit then
				if seenZero then
					return nil, "invalid netmask"
				end
				bits += 1
			else
				seenZero = true
			end
		end
		return bits, nil
	end

	local prefix = tonumber(source)
	if prefix == nil or prefix ~= math.floor(prefix) then
		return nil, "invalid prefix"
	end
	if version == 4 then
		if prefix < 0 or prefix > 32 then
			return nil, "IPv4 prefix out of range"
		end
	else
		if prefix < 0 or prefix > 128 then
			return nil, "IPv6 prefix out of range"
		end
	end
	return prefix, nil
end

--[=[
Create an IPv4 subnet mask integer from a prefix length.
@param prefix CIDR prefix length controlling network mask width.
@return Numeric result produced by the operation.
]=]
local function ipv4Mask(prefix: number): number
	if prefix <= 0 then
		return 0
	end
	if prefix >= 32 then
		return MAX_IPV4
	end
	return bit32.band(bit32.lshift(MAX_IPV4, 32 - prefix), MAX_IPV4)
end

--[=[
Mask an IPv4 integer down to its network address for a prefix.
@param value Numeric, string, or IP value used by this operation.
@param prefix CIDR prefix length controlling network mask width.
@return Numeric result produced by the operation.
]=]
local function ipv4NetworkInt(value: number, prefix: number): number
	return bit32.band(value, ipv4Mask(prefix))
end

--[=[
Create an IPv4 host mask integer from a prefix length.
@param prefix CIDR prefix length controlling network mask width.
@return Numeric result produced by the operation.
]=]
local function ipv4Hostmask(prefix: number): number
	return bit32.band(bit32.bnot(ipv4Mask(prefix)), MAX_IPV4)
end

--[=[
Compute the IPv4 broadcast address integer for a network and prefix.
@param value Numeric, string, or IP value used by this operation.
@param prefix CIDR prefix length controlling network mask width.
@return Numeric result produced by the operation.
]=]
local function ipv4Broadcast(value: number, prefix: number): number
	return bit32.bor(ipv4NetworkInt(value, prefix), ipv4Hostmask(prefix))
end

--[=[
Apply an IPv6 prefix mask to hextets and return the network address.
@param hextets IPv6 16-bit group values in network order.
@param prefix CIDR prefix length controlling network mask width.
@return IPv6 network address after applying the prefix mask.
]=]
local function ipv6MaskHextets(hextets: { number }, prefix: number): { number }
	local out = cloneArray(hextets)
	if prefix <= 0 then
		for i = 1, 8 do
			out[i] = 0
		end
		return out
	end
	if prefix >= 128 then
		return out
	end
	local full = math.floor(prefix / 16)
	local rem = prefix % 16
	for i = full + 2, 8 do
		out[i] = 0
	end
	if rem == 0 then
		out[full + 1] = 0
	else
		local mask = bit32.band(bit32.lshift(0xFFFF, 16 - rem), 0xFFFF)
		out[full + 1] = bit32.band(out[full + 1], mask)
	end
	return out
end

--[=[
Create an IPv6 host mask (hextets) for a prefix length.
@param prefix CIDR prefix length controlling network mask width.
@return IPv6 hostmask expressed as eight hextets.
]=]
local function ipv6HostmaskHextets(prefix: number): { number }
	local out = table.create(8, 0)
	if prefix <= 0 then
		for i = 1, 8 do
			out[i] = 0xFFFF
		end
		return out
	end
	if prefix >= 128 then
		return out
	end
	local full = math.floor(prefix / 16)
	local rem = prefix % 16
	for i = full + 2, 8 do
		out[i] = 0xFFFF
	end
	if rem == 0 then
		out[full + 1] = 0xFFFF
	else
		local keep = bit32.band(bit32.lshift(0xFFFF, 16 - rem), 0xFFFF)
		out[full + 1] = bit32.band(bit32.bnot(keep), 0xFFFF)
	end
	return out
end

--[=[
Bitwise-OR two IPv6 hextet arrays.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Bitwise-OR result for each IPv6 hextet.
]=]
local function ipv6Or(a: { number }, b: { number }): { number }
	local out = table.create(8, 0)
	for i = 1, 8 do
		out[i] = bit32.bor(a[i], b[i])
	end
	return out
end

--[=[
Check whether two IPv6 addresses share the same prefix bits.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@param prefix CIDR prefix length controlling network mask width.
@return result indicating whether the condition is met.
]=]
local function ipv6PrefixMatch(a: { number }, b: { number }, prefix: number): boolean
	if prefix <= 0 then
		return true
	end
	if prefix >= 128 then
		return hextetsEqual(a, b)
	end
	local full = math.floor(prefix / 16)
	local rem = prefix % 16
	for i = 1, full do
		if a[i] ~= b[i] then
			return false
		end
	end
	if rem > 0 then
		local mask = bit32.band(bit32.lshift(0xFFFF, 16 - rem), 0xFFFF)
		return bit32.band(a[full + 1], mask) == bit32.band(b[full + 1], mask)
	end
	return true
end

--[=[
Increment an IPv6 hextet array by one address.
@param hextets IPv6 16-bit group values in network order.
@return Incremented IPv6 address, or nil on overflow.
]=]
local function ipv6Increment(hextets: { number }): { number }?
	local out = cloneArray(hextets)
	for i = 8, 1, -1 do
		if out[i] < 0xFFFF then
			out[i] += 1
			return out
		end
		out[i] = 0
	end
	return nil
end

--[=[
Decrement an IPv6 hextet array by one address.
@param hextets IPv6 16-bit group values in network order.
@return Decremented IPv6 address, or nil on underflow.
]=]
local function ipv6Decrement(hextets: { number }): { number }?
	local out = cloneArray(hextets)
	for i = 8, 1, -1 do
		if out[i] > 0 then
			out[i] -= 1
			return out
		end
		out[i] = 0xFFFF
	end
	return nil
end

--[=[
Add 2^bitFromLsb to an IPv6 hextet array.
@param hextets IPv6 16-bit group values in network order.
@param bitFromLsb Bit index counted from least-significant bit for offset math.
@return Offset IPv6 address, or nil on overflow.
]=]
local function ipv6AddPowerOfTwo(hextets: { number }, bitFromLsb: number): { number }?
	if bitFromLsb < 0 or bitFromLsb > 127 then
		return nil
	end
	local out = cloneArray(hextets)
	local word = 8 - math.floor(bitFromLsb / 16)
	local add = bit32.lshift(1, bitFromLsb % 16)
	local carry = add
	for i = word, 1, -1 do
		local sum = out[i] + carry
		out[i] = sum % 65536
		carry = math.floor(sum / 65536)
		if carry == 0 then
			return out
		end
	end
	if carry > 0 then
		return nil
	end
	return out
end

--[=[
Construct and freeze an IPv4Address from octets.
@param octets IPv4 octet values in network order.
@return Frozen IPv4Address built from octet values.
]=]
local function createIPv4AddressFromOctets(octets: { number }): IPv4Address
	local v = setmetatable({
		version = "4",
		_octets = { octets[1], octets[2], octets[3], octets[4] },
		_int = octetsToInt(octets),
	}, IPv4Address)
	return table.freeze(v)
end

--[=[
Construct and freeze an IPv4Address from a 32-bit integer.
@param value Numeric, string, or IP value used by this operation.
@return Frozen IPv4Address built from a packed integer.
]=]
local function createIPv4AddressFromInt(value: number): IPv4Address
	local v = setmetatable({
		version = "4",
		_octets = intToOctets(value),
		_int = value,
	}, IPv4Address)
	return table.freeze(v)
end

--[=[
Construct and freeze an IPv6Address from hextets.
@param hextets IPv6 16-bit group values in network order.
@return Frozen IPv6Address built from hextet values.
]=]
local function createIPv6Address(hextets: { number }): IPv6Address
	local v = setmetatable({
		version = "6",
		_hextets = cloneArray(hextets),
	}, IPv6Address)
	return table.freeze(v)
end

--[=[
Construct and freeze an IPv4Network from address and prefix.
@param value Numeric, string, or IP value used by this operation.
@param prefix CIDR prefix length controlling network mask width.
@return Frozen IPv4Network at the requested prefix.
]=]
local function createIPv4Network(value: number, prefix: number): IPv4Network
	local v = setmetatable({
		version = "4",
		_prefix = prefix,
		_network = ipv4NetworkInt(value, prefix),
	}, IPv4Network)
	return table.freeze(v)
end

--[=[
Construct and freeze an IPv6Network from address and prefix.
@param hextets IPv6 16-bit group values in network order.
@param prefix CIDR prefix length controlling network mask width.
@return Frozen IPv6Network at the requested prefix.
]=]
local function createIPv6Network(hextets: { number }, prefix: number): IPv6Network
	local v = setmetatable({
		version = "6",
		_prefix = prefix,
		_network = ipv6MaskHextets(hextets, prefix),
	}, IPv6Network)
	return table.freeze(v)
end

--[=[
Parse a string into either an IPv4Address or IPv6Address.
@param source Source text to parse, validate, or classify.
@return Parsed IPv4/IPv6 address object, or nil when invalid.
]=]
local function parseAddressInternal(source: string, options: ParseOptions?): (IPv4Address | IPv6Address)?
	local v4 = parseIPv4Octets(source)
	if v4 then
		return createIPv4AddressFromOctets(v4)
	end
	local v6 = parseIPv6Hextets(source, options)
	if v6 then
		return createIPv6Address(v6)
	end
	return nil
end

--[=[
Parse a string into either an IPv4Network or IPv6Network.
@param source Source text to parse, validate, or classify.
@return Parsed IPv4/IPv6 network object, or nil when invalid.
]=]
local function parseNetworkInternal(source: string, options: ParseOptions?): (IPv4Network | IPv6Network)?
	local opts = parseOptions(options)
	local addrPart, prefixPart = splitOnce(trim(source), "/")
	if not prefixPart then
		return nil
	end
	local addr = parseAddressInternal(addrPart, options)
	if not addr then
		return nil
	end
	if getmetatable(addr) == IPv4Address then
		local prefix = parsePrefixPart(prefixPart, 4)
		if prefix == nil then
			return nil
		end
		if opts.strict and ipv4NetworkInt((addr :: IPv4Address)._int, prefix) ~= (addr :: IPv4Address)._int then
			return nil
		end
		return createIPv4Network((addr :: IPv4Address)._int, prefix)
	end
	local prefix = parsePrefixPart(prefixPart, 6)
	if prefix == nil then
		return nil
	end
	if opts.strict then
		local masked = ipv6MaskHextets((addr :: IPv6Address)._hextets, prefix)
		if not hextetsEqual(masked, (addr :: IPv6Address)._hextets) then
			return nil
		end
	end
	return createIPv6Network((addr :: IPv6Address)._hextets, prefix)
end

--[=[
Parse a string into either an IPv4Interface or IPv6Interface.
@param source Source text to parse, validate, or classify.
@return Parsed IPv4/IPv6 interface object, or nil when invalid.
]=]
local function parseInterfaceInternal(source: string, options: ParseOptions?): (IPv4Interface | IPv6Interface)?
	local addrPart, prefixPart = splitOnce(trim(source), "/")
	if not prefixPart then
		return nil
	end
	local addr = parseAddressInternal(addrPart, options)
	if not addr then
		return nil
	end
	if getmetatable(addr) == IPv4Address then
		local prefix = parsePrefixPart(prefixPart, 4)
		if prefix == nil then
			return nil
		end
		local iface = setmetatable({
			address = addr :: IPv4Address,
			network = createIPv4Network((addr :: IPv4Address)._int, prefix),
			_prefix = prefix,
		}, IPv4Interface)
		return table.freeze(iface :: IPv4Interface)
	end
	local prefix = parsePrefixPart(prefixPart, 6)
	if prefix == nil then
		return nil
	end
	local iface = setmetatable({
		address = addr :: IPv6Address,
		network = createIPv6Network((addr :: IPv6Address)._hextets, prefix),
		_prefix = prefix,
	}, IPv6Interface)
	return table.freeze(iface :: IPv6Interface)
end

--[=[
Assert a value is an IPv4Address and return it.
@param v Value to validate and coerce into the expected IP type.
@return The validated IPv4Address value.
]=]
local function ensureV4Address(v: any): IPv4Address
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Address then
		error("expected IPv4Address")
	end
	return v
end

--[=[
Assert a value is an IPv6Address and return it.
@param v Value to validate and coerce into the expected IP type.
@return The validated IPv6Address value.
]=]
local function ensureV6Address(v: any): IPv6Address
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Address then
		error("expected IPv6Address")
	end
	return v
end

--[=[
Assert a value is an IPv4Network and return it.
@param v Value to validate and coerce into the expected IP type.
@return The validated IPv4Network value.
]=]
local function ensureV4Network(v: any): IPv4Network
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Network then
		error("expected IPv4Network")
	end
	return v
end

--[=[
Assert a value is an IPv6Network and return it.
@param v Value to validate and coerce into the expected IP type.
@return The validated IPv6Network value.
]=]
local function ensureV6Network(v: any): IPv6Network
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Network then
		error("expected IPv6Network")
	end
	return v
end

--[=[
Assert a value is an IPv4Range and return it.
@param v Value to validate and coerce into an IPv4Range.
@return The validated IPv4Range value.
]=]
local function ensureV4Range(v: any): IPv4Range
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Range then
		error("expected IPv4Range")
	end
	return v
end

--[=[
Assert a value is an IPv6Range and return it.
@param v Value to validate and coerce into an IPv6Range.
@return The validated IPv6Range value.
]=]
local function ensureV6Range(v: any): IPv6Range
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Range then
		error("expected IPv6Range")
	end
	return v
end

--[=[
Coerce a value into an IPv4Address.
@param value IPv4Address instance or parseable IPv4 address string.
@return Parsed/coerced IPv4Address.
]=]
local function coerceV4Address(value: IPv4Address | string): IPv4Address
	if type(value) == "string" then
		local parsed = ip.address(value)
		if not parsed or getmetatable(parsed) ~= IPv4Address then
			error("expected IPv4 address")
		end
		return parsed :: IPv4Address
	end
	return ensureV4Address(value)
end

--[=[
Coerce a value into an IPv6Address.
@param value IPv6Address instance or parseable IPv6 address string.
@return Parsed/coerced IPv6Address.
]=]
local function coerceV6Address(value: IPv6Address | string): IPv6Address
	if type(value) == "string" then
		local parsed = ip.address(value)
		if not parsed or getmetatable(parsed) ~= IPv6Address then
			error("expected IPv6 address")
		end
		return parsed :: IPv6Address
	end
	return ensureV6Address(value)
end

--[=[
Coerce a value into an IPv4Network.
@param value IPv4Network instance or parseable IPv4 CIDR string.
@return Parsed/coerced IPv4Network.
]=]
local function coerceV4Network(value: IPv4Network | string): IPv4Network
	if type(value) == "string" then
		local parsed = ip.network(value)
		if not parsed or getmetatable(parsed) ~= IPv4Network then
			error("expected IPv4 network")
		end
		return parsed :: IPv4Network
	end
	return ensureV4Network(value)
end

--[=[
Coerce a value into an IPv6Network.
@param value IPv6Network instance or parseable IPv6 CIDR string.
@return Parsed/coerced IPv6Network.
]=]
local function coerceV6Network(value: IPv6Network | string): IPv6Network
	if type(value) == "string" then
		local parsed = ip.network(value)
		if not parsed or getmetatable(parsed) ~= IPv6Network then
			error("expected IPv6 network")
		end
		return parsed :: IPv6Network
	end
	return ensureV6Network(value)
end

local function normalizeV4Segments(
	segments: { { start: number, finish: number } }
): { { start: number, finish: number } }
	table.sort(segments, function(a: { start: number, finish: number }, b: { start: number, finish: number })
		return a.start < b.start
	end)
	local out = {}
	for _, seg in segments do
		if #out == 0 then
			table.insert(out, { start = seg.start, finish = seg.finish })
		else
			local last = out[#out]
			if seg.start <= last.finish + 1 then
				if seg.finish > last.finish then
					last.finish = seg.finish
				end
			else
				table.insert(out, { start = seg.start, finish = seg.finish })
			end
		end
	end
	return out
end

local function normalizeV6Segments(
	segments: { { start: { number }, finish: { number } } }
): { { start: { number }, finish: { number } } }
	table.sort(segments, function(a, b)
		return compareHextets(a.start, b.start) < 0
	end)
	local out = {}
	for _, seg in segments do
		if #out == 0 then
			table.insert(out, { start = cloneArray(seg.start), finish = cloneArray(seg.finish) })
		else
			local last = out[#out]
			local nextOfLast = ipv6Increment(last.finish)
			local overlaps = compareHextets(seg.start, last.finish) <= 0
			local adjacent = nextOfLast and compareHextets(seg.start, nextOfLast) == 0
			if overlaps or adjacent then
				if compareHextets(seg.finish, last.finish) > 0 then
					last.finish = cloneArray(seg.finish)
				end
			else
				table.insert(out, { start = cloneArray(seg.start), finish = cloneArray(seg.finish) })
			end
		end
	end
	return out
end

local function subtractV4Segment(
	segment: { start: number, finish: number },
	cut: { start: number, finish: number }
): { { start: number, finish: number } }
	if cut.finish < segment.start or cut.start > segment.finish then
		return { { start = segment.start, finish = segment.finish } }
	end
	local out = {}
	if cut.start > segment.start then
		table.insert(out, { start = segment.start, finish = cut.start - 1 })
	end
	if cut.finish < segment.finish then
		table.insert(out, { start = cut.finish + 1, finish = segment.finish })
	end
	return out
end

local function subtractV6Segment(
	segment: { start: { number }, finish: { number } },
	cut: { start: { number }, finish: { number } }
): { { start: { number }, finish: { number } } }
	if compareHextets(cut.finish, segment.start) < 0 or compareHextets(cut.start, segment.finish) > 0 then
		return { { start = cloneArray(segment.start), finish = cloneArray(segment.finish) } }
	end
	local out = {}
	if compareHextets(cut.start, segment.start) > 0 then
		local leftEnd = ipv6Decrement(cut.start)
		if leftEnd then
			table.insert(out, { start = cloneArray(segment.start), finish = leftEnd })
		end
	end
	if compareHextets(cut.finish, segment.finish) < 0 then
		local rightStart = ipv6Increment(cut.finish)
		if rightStart then
			table.insert(out, { start = rightStart, finish = cloneArray(segment.finish) })
		end
	end
	return out
end

local function createIPv4Range(segments: { { start: number, finish: number } }): IPv4Range
	local normalized = normalizeV4Segments(segments)
	local value = setmetatable({
		version = "4",
		_segments = normalized,
	}, IPv4Range)
	return table.freeze(value)
end

local function createIPv6Range(segments: { { start: { number }, finish: { number } } }): IPv6Range
	local normalized = normalizeV6Segments(segments)
	local value = setmetatable({
		version = "6",
		_segments = normalized,
	}, IPv6Range)
	return table.freeze(value)
end

local function arrayIterator<T>(arr: { T }): () -> T?
	local i = 0
	return function()
		i += 1
		return arr[i]
	end
end

--[=[
Compare two IPv4 addresses by numeric value.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Numeric result produced by the operation.
]=]
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

--[=[
Compare two IPv6 addresses lexicographically by hextets.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Numeric result produced by the operation.
]=]
local function compareIPv6Address(a: IPv6Address, b: IPv6Address): number
	return compareHextets(ensureV6Address(a)._hextets, ensureV6Address(b)._hextets)
end

local function compareIPv4NetworkOrder(a: IPv4Network, b: IPv4Network): number
	if a._network < b._network then
		return -1
	elseif a._network > b._network then
		return 1
	end
	if a._prefix < b._prefix then
		return -1
	elseif a._prefix > b._prefix then
		return 1
	end
	return 0
end

local function compareIPv6NetworkOrder(a: IPv6Network, b: IPv6Network): number
	local cmp = compareHextets(a._network, b._network)
	if cmp ~= 0 then
		return cmp
	end
	if a._prefix < b._prefix then
		return -1
	elseif a._prefix > b._prefix then
		return 1
	end
	return 0
end

--[=[
Count trailing zero bits in a 32-bit unsigned integer.
@param value IPv4 integer value to inspect.
@return Number of trailing zero bits in the 32-bit representation.
]=]
local function countTrailingZeroBitsIPv4(value: number): number
	if value == 0 then
		return 32
	end
	local bits = 0
	while bits < 32 and bit32.band(value, bit32.lshift(1, bits)) == 0 do
		bits += 1
	end
	return bits
end

--[=[
Count trailing zero bits in an IPv6 hextet array.
@param hextets IPv6 address represented as eight hextets.
@return Number of trailing zero bits in the 128-bit representation.
]=]
local function countTrailingZeroBitsIPv6(hextets: { number }): number
	local bits = 0
	for i = 8, 1, -1 do
		local word = hextets[i]
		if word == 0 then
			bits += 16
		else
			for bit = 0, 15 do
				if bit32.band(word, bit32.lshift(1, bit)) ~= 0 then
					return bits
				end
				bits += 1
			end
		end
	end
	return bits
end

--[=[
Count shared leading bits between two IPv4 integers.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Numeric result produced by the operation.
]=]
local function countLeadingCommonBitsIPv4(a: number, b: number): number
	local x = bit32.bxor(a, b)
	if x == 0 then
		return 32
	end
	local bits = 0
	for i = 31, 0, -1 do
		if bit32.band(x, bit32.lshift(1, i)) ~= 0 then
			return bits
		end
		bits += 1
	end
	return bits
end

--[=[
Count shared leading bits between two IPv6 addresses.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Numeric result produced by the operation.
]=]
local function countLeadingCommonBitsIPv6(a: { number }, b: { number }): number
	local bits = 0
	for i = 1, 8 do
		local x = bit32.bxor(a[i], b[i])
		if x == 0 then
			bits += 16
		else
			for bit = 15, 0, -1 do
				if bit32.band(x, bit32.lshift(1, bit)) ~= 0 then
					return bits
				end
				bits += 1
			end
		end
	end
	return bits
end

--[=[
Format an IPv4Address as canonical dotted-decimal text.
@param self Current object instance on which the method operates.
@return representation or textual result.
]=]
local function ipv4AddressString(self: IPv4Address): string
	local inner = ensureV4Address(self)
	return string.format("%d.%d.%d.%d", inner._octets[1], inner._octets[2], inner._octets[3], inner._octets[4])
end

--[=[
Format an IPv6Address as canonical compressed text.
@param self Current object instance on which the method operates.
@return representation or textual result.
]=]
local function ipv6AddressString(self: IPv6Address): string
	return hextetsToCompressedString(ensureV6Address(self)._hextets)
end

--[=[
Parse an address or network string into the corresponding IP object.
@param source Source text to parse, validate, or classify.
@param options Optional parse behavior flags (for example `strict`).
@return Parsed address/network object when the input is valid.
]=]
function ip.parse(source: string, options: ParseOptions?): (IPv4Address | IPv6Address | IPv4Network | IPv6Network)?
	if string.find(source, "/", 1, true) then
		return parseNetworkInternal(source, options)
	end
	return parseAddressInternal(source, options)
end
--[=[
Parse a string into an IPv4Address or IPv6Address.
@param source Source text to parse, validate, or classify.
@param options Optional parse behavior flags (for example `allowZoneId`).
@return Parsed IPv4 or IPv6 address object when valid.
]=]
function ip.address(source: string, options: ParseOptions?): (IPv4Address | IPv6Address)?
	return parseAddressInternal(source, options)
end
--[=[
Parse a string into an IPv4Network or IPv6Network.
@param source Source text to parse, validate, or classify.
@param options Optional parse behavior flags (for example `strict` host-bit checks).
@return Parsed IPv4 or IPv6 network object when valid.
]=]
function ip.network(source: string, options: ParseOptions?): (IPv4Network | IPv6Network)?
	return parseNetworkInternal(source, options)
end
--[=[
Parse a string into an IPv4Interface or IPv6Interface.
@param source Source text to parse, validate, or classify.
@param options Optional parse behavior flags forwarded to address parsing.
@return Parsed IPv4 or IPv6 interface object when valid.
]=]
function ip.interface(source: string, options: ParseOptions?): (IPv4Interface | IPv6Interface)?
	return parseInterfaceInternal(source, options)
end

--[=[
Return true when the input is a valid IP address string.
@param source Source text to parse, validate, or classify.
@return True when the input is recognized as a valid address.
]=]
function ip.isAddress(source: string): boolean
	return parseAddressInternal(source) ~= nil
end
--[=[
Return true when the input is a valid CIDR/network string.
@param source Source text to parse, validate, or classify.
@return True when the input is recognized as a valid network.
]=]
function ip.isNetwork(source: string): boolean
	return parseNetworkInternal(source) ~= nil
end
--[=[
Return true when the input parses as an IPv4 address or network.
@param source Source text to parse, validate, or classify.
@return True when input resolves to an IPv4 address or network.
]=]
function ip.isIPv4(source: string): boolean
	local parsed = ip.parse(source)
	if not parsed then
		return false
	end
	local mt = getmetatable(parsed)
	if mt == IPv4Address or mt == IPv4Network then
		return true
	end
	local iface = ip.interface(source)
	return iface ~= nil and getmetatable(iface) == IPv4Interface
end
--[=[
Return true when the input parses as an IPv6 address or network.
@param source Source text to parse, validate, or classify.
@return True when input resolves to an IPv6 address or network.
]=]
function ip.isIPv6(source: string): boolean
	local parsed = ip.parse(source)
	if not parsed then
		return false
	end
	local mt = getmetatable(parsed)
	if mt == IPv6Address or mt == IPv6Network then
		return true
	end
	local iface = ip.interface(source)
	return iface ~= nil and getmetatable(iface) == IPv6Interface
end

--[=[
Return the smallest IPv4 network containing both IPv4 addresses.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Smallest IPv4 CIDR block containing both inputs.
]=]
function ip.smallestEnclosingIPv4Network(a: IPv4Address, b: IPv4Address): IPv4Network
	return IPv4Network.smallestContaining(a, b)
end

--[=[
Return the smallest IPv6 network containing both IPv6 addresses.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return Smallest IPv6 CIDR block containing both inputs.
]=]
function ip.smallestEnclosingIPv6Network(a: IPv6Address, b: IPv6Address): IPv6Network
	return IPv6Network.smallestContaining(a, b)
end

--[=[
Return the smallest IPv4 network containing both addresses.
@param a First IPv4 address endpoint.
@param b Second IPv4 address endpoint.
@return Minimal IPv4 CIDR block that covers both addresses.
]=]
function IPv4Network.smallestContaining(a: IPv4Address, b: IPv4Address): IPv4Network
	local left = ensureV4Address(a)
	local right = ensureV4Address(b)
	local prefix = countLeadingCommonBitsIPv4(left._int, right._int)
	local base = if left._int < right._int then left._int else right._int
	return createIPv4Network(base, prefix)
end

--[=[
Return the smallest IPv6 network containing both addresses.
@param a First IPv6 address endpoint.
@param b Second IPv6 address endpoint.
@return Minimal IPv6 CIDR block that covers both addresses.
]=]
function IPv6Network.smallestContaining(a: IPv6Address, b: IPv6Address): IPv6Network
	local left = ensureV6Address(a)
	local right = ensureV6Address(b)
	local prefix = countLeadingCommonBitsIPv6(left._hextets, right._hextets)
	local base = if compareHextets(left._hextets, right._hextets) <= 0 then left._hextets else right._hextets
	return createIPv6Network(base, prefix)
end

--[=[
Parse/coerce and sort a list of IPv4 addresses in ascending order.
@param values Collection of address values to parse/coerce and sort.
@return IPv4 address list sorted in ascending numeric order.
]=]
function ip.sortIPv4(values: { IPv4Address | string }): { IPv4Address }
	return IPv4Address.sort(values)
end

--[=[
Parse/coerce and sort a list of IPv6 addresses in ascending order.
@param values Collection of address values to parse/coerce and sort.
@return IPv6 address list sorted in ascending lexical order.
]=]
function ip.sortIPv6(values: { IPv6Address | string }): { IPv6Address }
	return IPv6Address.sort(values)
end

--[=[
Sort a collection of IPv4 address values.
@param values IPv4Address instances or parseable IPv4 strings.
@return Parsed and sorted IPv4 addresses.
]=]
function IPv4Address.sort(values: { IPv4Address | string }): { IPv4Address }
	local out: { IPv4Address } = {}
	for i = 1, #values do
		local value = values[i]
		if type(value) == "string" then
			local parsed = ip.address(value)
			if not parsed or getmetatable(parsed) ~= IPv4Address then
				error("sortIPv4 expects IPv4 addresses only")
			end
			out[i] = parsed :: IPv4Address
		else
			out[i] = ensureV4Address(value)
		end
	end
	table.sort(out, function(x: IPv4Address, y: IPv4Address)
		return compareIPv4Address(x, y) < 0
	end)
	return out
end

--[=[
Sort a collection of IPv6 address values.
@param values IPv6Address instances or parseable IPv6 strings.
@return Parsed and sorted IPv6 addresses.
]=]
function IPv6Address.sort(values: { IPv6Address | string }): { IPv6Address }
	local out: { IPv6Address } = {}
	for i = 1, #values do
		local value = values[i]
		if type(value) == "string" then
			local parsed = ip.address(value)
			if not parsed or getmetatable(parsed) ~= IPv6Address then
				error("sortIPv6 expects IPv6 addresses only")
			end
			out[i] = parsed :: IPv6Address
		else
			out[i] = ensureV6Address(value)
		end
	end
	table.sort(out, function(x: IPv6Address, y: IPv6Address)
		return compareIPv6Address(x, y) < 0
	end)
	return out
end

--[=[
Parse an IPv4 address string with optional parse options.
@param source IPv4 address text to parse.
@param options Optional parse behavior flags.
@return Parsed IPv4Address when the input is valid.
]=]
function IPv4Address.parse(source: string, options: ParseOptions?): IPv4Address?
	local parsed = parseAddressInternal(source, options)
	if parsed and getmetatable(parsed) == IPv4Address then
		return parsed :: IPv4Address
	end
	return nil
end

--[=[
Parse an IPv6 address string with optional parse options.
@param source IPv6 address text to parse.
@param options Optional parse behavior flags.
@return Parsed IPv6Address when the input is valid.
]=]
function IPv6Address.parse(source: string, options: ParseOptions?): IPv6Address?
	local parsed = parseAddressInternal(source, options)
	if parsed and getmetatable(parsed) == IPv6Address then
		return parsed :: IPv6Address
	end
	return nil
end

--[=[
Parse an IPv4 CIDR network string with optional parse options.
@param source IPv4 network text to parse.
@param options Optional parse behavior flags.
@return Parsed IPv4Network when the input is valid.
]=]
function IPv4Network.parse(source: string, options: ParseOptions?): IPv4Network?
	local parsed = parseNetworkInternal(source, options)
	if parsed and getmetatable(parsed) == IPv4Network then
		return parsed :: IPv4Network
	end
	return nil
end

--[=[
Parse an IPv6 CIDR network string with optional parse options.
@param source IPv6 network text to parse.
@param options Optional parse behavior flags.
@return Parsed IPv6Network when the input is valid.
]=]
function IPv6Network.parse(source: string, options: ParseOptions?): IPv6Network?
	local parsed = parseNetworkInternal(source, options)
	if parsed and getmetatable(parsed) == IPv6Network then
		return parsed :: IPv6Network
	end
	return nil
end

--[=[
Parse an IPv4 interface string with optional parse options.
@param source IPv4 interface text (`address/prefix`) to parse.
@param options Optional parse behavior flags.
@return Parsed IPv4Interface when the input is valid.
]=]
function IPv4Interface.parse(source: string, options: ParseOptions?): IPv4Interface?
	local parsed = parseInterfaceInternal(source, options)
	if parsed and getmetatable(parsed) == IPv4Interface then
		return parsed :: IPv4Interface
	end
	return nil
end

--[=[
Parse an IPv6 interface string with optional parse options.
@param source IPv6 interface text (`address/prefix`) to parse.
@param options Optional parse behavior flags.
@return Parsed IPv6Interface when the input is valid.
]=]
function IPv6Interface.parse(source: string, options: ParseOptions?): IPv6Interface?
	local parsed = parseInterfaceInternal(source, options)
	if parsed and getmetatable(parsed) == IPv6Interface then
		return parsed :: IPv6Interface
	end
	return nil
end

--[=[
Merge and collapse overlapping/adjacent IPv4 networks.
@param networks IPv4Network instances or parseable IPv4 CIDR strings.
@return Minimal merged set of IPv4 networks.
]=]
function IPv4Network.mergeNetworks(networks: { IPv4Network | string }): { IPv4Network }
	local parsed: { IPv4Network } = {}
	for _, value in networks do
		local netValue = nil :: IPv4Network?
		if type(value) == "string" then
			netValue = IPv4Network.parse(value)
		else
			netValue = ensureV4Network(value)
		end
		if not netValue then
			error("mergeNetworks expects IPv4 networks only")
		end
		table.insert(parsed, netValue)
	end
	table.sort(parsed, function(a, b)
		return compareIPv4NetworkOrder(a, b) < 0
	end)
	local reduced: { IPv4Network } = {}
	for _, net in parsed do
		if #reduced == 0 then
			table.insert(reduced, net)
		else
			local last = reduced[#reduced]
			if last:containsNetwork(net) then
				continue
			end
			table.insert(reduced, net)
		end
	end
	local changed = true
	while changed do
		changed = false
		local out = {}
		local i = 1
		while i <= #reduced do
			local a = reduced[i]
			local b = reduced[i + 1]
			if a and b and a._prefix == b._prefix and a._prefix > 0 then
				local size = 2 ^ (32 - a._prefix)
				if a._network + size == b._network then
					local parent = createIPv4Network(a._network, a._prefix - 1)
					if parent:containsNetwork(a) and parent:containsNetwork(b) then
						table.insert(out, parent)
						i += 2
						changed = true
						continue
					end
				end
			end
			table.insert(out, a)
			i += 1
		end
		reduced = out
	end
	return reduced
end

--[=[
Merge and collapse overlapping/adjacent IPv6 networks.
@param networks IPv6Network instances or parseable IPv6 CIDR strings.
@return Minimal merged set of IPv6 networks.
]=]
function IPv6Network.mergeNetworks(networks: { IPv6Network | string }): { IPv6Network }
	local parsed: { IPv6Network } = {}
	for _, value in networks do
		local netValue = nil :: IPv6Network?
		if type(value) == "string" then
			netValue = IPv6Network.parse(value)
		else
			netValue = ensureV6Network(value)
		end
		if not netValue then
			error("mergeNetworks expects IPv6 networks only")
		end
		table.insert(parsed, netValue)
	end
	table.sort(parsed, function(a, b)
		return compareIPv6NetworkOrder(a, b) < 0
	end)
	local reduced: { IPv6Network } = {}
	for _, net in parsed do
		if #reduced == 0 then
			table.insert(reduced, net)
		else
			local last = reduced[#reduced]
			if last:containsNetwork(net) then
				continue
			end
			table.insert(reduced, net)
		end
	end
	local changed = true
	while changed do
		changed = false
		local out = {}
		local i = 1
		while i <= #reduced do
			local a = reduced[i]
			local b = reduced[i + 1]
			if a and b and a._prefix == b._prefix and a._prefix > 0 then
				local sizeBit = 128 - a._prefix
				local nextAddr = ipv6AddPowerOfTwo(a._network, sizeBit)
				if nextAddr and hextetsEqual(nextAddr, b._network) then
					local parent = createIPv6Network(a._network, a._prefix - 1)
					if parent:containsNetwork(a) and parent:containsNetwork(b) then
						table.insert(out, parent)
						i += 2
						changed = true
						continue
					end
				end
			end
			table.insert(out, a)
			i += 1
		end
		reduced = out
	end
	return reduced
end

--[=[
Build an IPv4 range from start and end addresses (inclusive).
@param startValue Start address for the range, as IPv4Address or IPv4 string.
@param endValue End address for the range, as IPv4Address or IPv4 string.
@return IPv4Range covering the inclusive start/end interval.
]=]
function IPv4Range.new(startValue: IPv4Address | string, endValue: IPv4Address | string): IPv4Range
	local startAddr = coerceV4Address(startValue)
	local endAddr = coerceV4Address(endValue)
	if endAddr._int < startAddr._int then
		error("IPv4Range end address must be >= start address")
	end
	return createIPv4Range({
		{
			start = startAddr._int,
			finish = endAddr._int,
		},
	})
end

--[=[
Create an IPv4 range that exactly matches a CIDR network.
@param networkValue IPv4Network instance or parseable IPv4 CIDR string.
@return IPv4Range covering every address in the network.
]=]
function IPv4Range.fromNetwork(networkValue: IPv4Network | string): IPv4Range
	local network = coerceV4Network(networkValue)
	return createIPv4Range({
		{
			start = network._network,
			finish = ipv4Broadcast(network._network, network._prefix),
		},
	})
end

--[=[
Build an IPv6 range from start and end addresses (inclusive).
@param startValue Start address for the range, as IPv6Address or IPv6 string.
@param endValue End address for the range, as IPv6Address or IPv6 string.
@return IPv6Range covering the inclusive start/end interval.
]=]
function IPv6Range.new(startValue: IPv6Address | string, endValue: IPv6Address | string): IPv6Range
	local startAddr = coerceV6Address(startValue)
	local endAddr = coerceV6Address(endValue)
	if compareHextets(endAddr._hextets, startAddr._hextets) < 0 then
		error("IPv6Range end address must be >= start address")
	end
	return createIPv6Range({
		{
			start = cloneArray(startAddr._hextets),
			finish = cloneArray(endAddr._hextets),
		},
	})
end

--[=[
Create an IPv6 range that exactly matches a CIDR network.
@param networkValue IPv6Network instance or parseable IPv6 CIDR string.
@return IPv6Range covering every address in the network.
]=]
function IPv6Range.fromNetwork(networkValue: IPv6Network | string): IPv6Range
	local network = coerceV6Network(networkValue)
	return createIPv6Range({
		{
			start = cloneArray(network._network),
			finish = ipv6Or(network._network, ipv6HostmaskHextets(network._prefix)),
		},
	})
end

--[=[
Return true when an IPv4 integer lies in any segment.
@param segments Normalized IPv4 range segments.
@param value IPv4 integer value to test.
@return True when the value is contained in the segment set.
]=]
local function v4SegmentsContainInt(segments: { { start: number, finish: number } }, value: number): boolean
	for _, seg in segments do
		if value < seg.start then
			return false
		end
		if value <= seg.finish then
			return true
		end
	end
	return false
end

--[=[
Return true when an IPv6 address lies in any segment.
@param segments Normalized IPv6 range segments.
@param value IPv6 hextet array to test.
@return True when the value is contained in the segment set.
]=]
local function v6SegmentsContainHextets(
	segments: { { start: { number }, finish: { number } } },
	value: { number }
): boolean
	for _, seg in segments do
		if compareHextets(value, seg.start) < 0 then
			return false
		end
		if compareHextets(value, seg.finish) <= 0 then
			return true
		end
	end
	return false
end

--[=[
Determine whether one IPv4 segment list fully covers another.
@param outer Candidate superset segment list.
@param inner Candidate subset segment list.
@return True when every inner segment is fully covered by outer.
]=]
local function v4SegmentsContainSegments(
	outer: { { start: number, finish: number } },
	inner: { { start: number, finish: number } }
): boolean
	local oi = 1
	for _, target in inner do
		while oi <= #outer and outer[oi].finish < target.start do
			oi += 1
		end
		if oi > #outer then
			return false
		end
		local carrier = outer[oi]
		if carrier.start > target.start or carrier.finish < target.finish then
			return false
		end
	end
	return true
end

--[=[
Determine whether one IPv6 segment list fully covers another.
@param outer Candidate superset segment list.
@param inner Candidate subset segment list.
@return True when every inner segment is fully covered by outer.
]=]
local function v6SegmentsContainSegments(
	outer: { { start: { number }, finish: { number } } },
	inner: { { start: { number }, finish: { number } } }
): boolean
	local oi = 1
	for _, target in inner do
		while oi <= #outer and compareHextets(outer[oi].finish, target.start) < 0 do
			oi += 1
		end
		if oi > #outer then
			return false
		end
		local carrier = outer[oi]
		if compareHextets(carrier.start, target.start) > 0 or compareHextets(carrier.finish, target.finish) < 0 then
			return false
		end
	end
	return true
end

--[=[
Return an IPv4 segment list representing the exclusion target.
@param value IPv4 address, network, range, or parseable string form of those.
@return Normalized IPv4 segments to subtract.
]=]
local function coerceV4CutSegments(
	value: IPv4Address | IPv4Network | IPv4Range | string
): { { start: number, finish: number } }
	if type(value) == "string" then
		if string.find(value, "/", 1, true) then
			local net = coerceV4Network(value)
			return {
				{
					start = net._network,
					finish = ipv4Broadcast(net._network, net._prefix),
				},
			}
		end
		local addr = coerceV4Address(value)
		return {
			{
				start = addr._int,
				finish = addr._int,
			},
		}
	end

	local mt = getmetatable(value)
	if mt == IPv4Address then
		local addr = ensureV4Address(value)
		return {
			{
				start = addr._int,
				finish = addr._int,
			},
		}
	elseif mt == IPv4Network then
		local net = ensureV4Network(value)
		return {
			{
				start = net._network,
				finish = ipv4Broadcast(net._network, net._prefix),
			},
		}
	elseif mt == IPv4Range then
		return cloneArray(ensureV4Range(value)._segments)
	end

	error("exclude expects IPv4 address, network, range, or string")
end

--[=[
Return an IPv6 segment list representing the exclusion target.
@param value IPv6 address, network, range, or parseable string form of those.
@return Normalized IPv6 segments to subtract.
]=]
local function coerceV6CutSegments(
	value: IPv6Address | IPv6Network | IPv6Range | string
): { { start: { number }, finish: { number } } }
	if type(value) == "string" then
		if string.find(value, "/", 1, true) then
			local net = coerceV6Network(value)
			return {
				{
					start = cloneArray(net._network),
					finish = ipv6Or(net._network, ipv6HostmaskHextets(net._prefix)),
				},
			}
		end
		local addr = coerceV6Address(value)
		return {
			{
				start = cloneArray(addr._hextets),
				finish = cloneArray(addr._hextets),
			},
		}
	end

	local mt = getmetatable(value)
	if mt == IPv6Address then
		local addr = ensureV6Address(value)
		return {
			{
				start = cloneArray(addr._hextets),
				finish = cloneArray(addr._hextets),
			},
		}
	elseif mt == IPv6Network then
		local net = ensureV6Network(value)
		return {
			{
				start = cloneArray(net._network),
				finish = ipv6Or(net._network, ipv6HostmaskHextets(net._prefix)),
			},
		}
	elseif mt == IPv6Range then
		return cloneArray(ensureV6Range(value)._segments)
	end

	error("exclude expects IPv6 address, network, range, or string")
end

--[=[
Check whether an IPv4 range contains the supplied value.
@param self Current IPv4Range instance.
@param value IPv4Address, IPv4Network, IPv4Range, or parseable string input.
@return True when the entire value is contained by this range.
]=]
function IPv4Range.contains(self: IPv4Range, value: IPv4Address | IPv4Network | IPv4Range | string): boolean
	local range = ensureV4Range(self)
	if type(value) == "string" then
		if string.find(value, "/", 1, true) then
			local net = coerceV4Network(value)
			local startValue = net._network
			local finishValue = ipv4Broadcast(net._network, net._prefix)
			return v4SegmentsContainSegments(range._segments, { { start = startValue, finish = finishValue } })
		end
		local addr = coerceV4Address(value)
		return v4SegmentsContainInt(range._segments, addr._int)
	end

	local mt = getmetatable(value)
	if mt == IPv4Address then
		return v4SegmentsContainInt(range._segments, ensureV4Address(value)._int)
	elseif mt == IPv4Network then
		local net = ensureV4Network(value)
		local startValue = net._network
		local finishValue = ipv4Broadcast(net._network, net._prefix)
		return v4SegmentsContainSegments(range._segments, { { start = startValue, finish = finishValue } })
	elseif mt == IPv4Range then
		return v4SegmentsContainSegments(range._segments, ensureV4Range(value)._segments)
	end

	error("contains expects IPv4 address, network, range, or string")
end

--[=[
Check whether an IPv6 range contains the supplied value.
@param self Current IPv6Range instance.
@param value IPv6Address, IPv6Network, IPv6Range, or parseable string input.
@return True when the entire value is contained by this range.
]=]
function IPv6Range.contains(self: IPv6Range, value: IPv6Address | IPv6Network | IPv6Range | string): boolean
	local range = ensureV6Range(self)
	if type(value) == "string" then
		if string.find(value, "/", 1, true) then
			local net = coerceV6Network(value)
			return v6SegmentsContainSegments(range._segments, {
				{
					start = cloneArray(net._network),
					finish = ipv6Or(net._network, ipv6HostmaskHextets(net._prefix)),
				},
			})
		end
		local addr = coerceV6Address(value)
		return v6SegmentsContainHextets(range._segments, addr._hextets)
	end

	local mt = getmetatable(value)
	if mt == IPv6Address then
		return v6SegmentsContainHextets(range._segments, ensureV6Address(value)._hextets)
	elseif mt == IPv6Network then
		local net = ensureV6Network(value)
		return v6SegmentsContainSegments(range._segments, {
			{
				start = cloneArray(net._network),
				finish = ipv6Or(net._network, ipv6HostmaskHextets(net._prefix)),
			},
		})
	elseif mt == IPv6Range then
		return v6SegmentsContainSegments(range._segments, ensureV6Range(value)._segments)
	end

	error("contains expects IPv6 address, network, range, or string")
end

--[=[
Return a new IPv4 range with the supplied address/network/range removed.
@param self Current IPv4Range instance.
@param value IPv4Address, IPv4Network, IPv4Range, or parseable string input.
@return New IPv4Range after subtraction.
]=]
function IPv4Range.exclude(self: IPv4Range, value: IPv4Address | IPv4Network | IPv4Range | string): IPv4Range
	local range = ensureV4Range(self)
	local cuts = normalizeV4Segments(coerceV4CutSegments(value))
	local remaining = cloneArray(range._segments)
	for _, cut in cuts do
		local nextSegments = {}
		for _, seg in remaining do
			for _, part in subtractV4Segment(seg, cut) do
				table.insert(nextSegments, part)
			end
		end
		remaining = nextSegments
	end
	return createIPv4Range(remaining)
end

--[=[
Return a new IPv6 range with the supplied address/network/range removed.
@param self Current IPv6Range instance.
@param value IPv6Address, IPv6Network, IPv6Range, or parseable string input.
@return New IPv6Range after subtraction.
]=]
function IPv6Range.exclude(self: IPv6Range, value: IPv6Address | IPv6Network | IPv6Range | string): IPv6Range
	local range = ensureV6Range(self)
	local cuts = normalizeV6Segments(coerceV6CutSegments(value))
	local remaining = cloneArray(range._segments)
	for _, cut in cuts do
		local nextSegments = {}
		for _, seg in remaining do
			for _, part in subtractV6Segment(seg, cut) do
				table.insert(nextSegments, part)
			end
		end
		remaining = nextSegments
	end
	return createIPv6Range(remaining)
end

--[=[
Lazily iterate all IPv4 addresses in this range.
@param self Current IPv4Range instance.
@return -> IPv4Address? Iterator yielding IPv4 addresses in ascending order.
]=]
function IPv4Range.iter(self: IPv4Range): () -> IPv4Address?
	local range = ensureV4Range(self)
	local index = 1
	local current = nil :: number?
	local finish = nil :: number?
	return function()
		while true do
			if current == nil then
				local seg = range._segments[index]
				if not seg then
					return nil
				end
				current = seg.start
				finish = seg.finish
			end
			if (current :: number) <= (finish :: number) then
				local out = createIPv4AddressFromInt(current :: number)
				current = (current :: number) + 1
				return out
			end
			index += 1
			current = nil
			finish = nil
		end
	end
end

--[=[
Lazily iterate all IPv6 addresses in this range.
@param self Current IPv6Range instance.
@return -> IPv6Address? Iterator yielding IPv6 addresses in ascending order.
]=]
function IPv6Range.iter(self: IPv6Range): () -> IPv6Address?
	local range = ensureV6Range(self)
	local index = 1
	local current = nil :: { number }?
	local finish = nil :: { number }?
	return function()
		while true do
			if current == nil then
				local seg = range._segments[index]
				if not seg then
					return nil
				end
				current = cloneArray(seg.start)
				finish = seg.finish
			end
			if compareHextets(current :: { number }, finish :: { number }) <= 0 then
				local out = createIPv6Address(current :: { number })
				current = ipv6Increment(current :: { number })
				return out
			end
			index += 1
			current = nil
			finish = nil
		end
	end
end

--[=[
Lazily enumerate exact covering IPv4 CIDR blocks for this range.
@param self Current IPv4Range instance.
@return -> IPv4Network? Iterator yielding minimal IPv4 CIDR blocks.
]=]
function IPv4Range.toNetworks(self: IPv4Range): () -> IPv4Network?
	local range = ensureV4Range(self)
	local index = 1
	local current = nil :: number?
	local finish = nil :: number?
	return function()
		while true do
			if current == nil then
				local seg = range._segments[index]
				if not seg then
					return nil
				end
				current = seg.start
				finish = seg.finish
			end
			if current :: number > finish :: number then
				index += 1
				current = nil
				finish = nil
				continue
			end

			local prefix = 32 - countTrailingZeroBitsIPv4(current :: number)
			if prefix < 0 then
				prefix = 0
			end
			while true do
				local size = 2 ^ (32 - prefix)
				local last = (current :: number) + size - 1
				if last <= finish :: number then
					local net = createIPv4Network(current :: number, prefix)
					current = (current :: number) + size
					return net
				end
				prefix += 1
			end
		end
	end
end

--[=[
Lazily enumerate exact covering IPv6 CIDR blocks for this range.
@param self Current IPv6Range instance.
@return -> IPv6Network? Iterator yielding minimal IPv6 CIDR blocks.
]=]
function IPv6Range.toNetworks(self: IPv6Range): () -> IPv6Network?
	local range = ensureV6Range(self)
	local index = 1
	local current = nil :: { number }?
	local finish = nil :: { number }?
	return function()
		while true do
			if current == nil then
				local seg = range._segments[index]
				if not seg then
					return nil
				end
				current = cloneArray(seg.start)
				finish = seg.finish
			end
			if compareHextets(current :: { number }, finish :: { number }) > 0 then
				index += 1
				current = nil
				finish = nil
				continue
			end

			local prefix = 128 - countTrailingZeroBitsIPv6(current :: { number })
			if prefix < 0 then
				prefix = 0
			end
			while true do
				local base = ipv6MaskHextets(current :: { number }, prefix)
				local last = ipv6Or(base, ipv6HostmaskHextets(prefix))
				if compareHextets(last, finish :: { number }) <= 0 then
					local net = createIPv6Network(base, prefix)
					current = ipv6Increment(last)
					return net
				end
				prefix += 1
			end
		end
	end
end

--[=[
Return the single smallest IPv4 CIDR that contains this entire range.
@param self Current IPv4Range instance.
@return Smallest containing IPv4 network, potentially including extra addresses.
]=]
function IPv4Range.smallestContainingNetwork(self: IPv4Range): IPv4Network
	local range = ensureV4Range(self)
	if #range._segments == 0 then
		error("cannot compute smallestContainingNetwork for an empty IPv4Range")
	end
	local first = range._segments[1]
	local last = range._segments[#range._segments]
	return IPv4Network.smallestContaining(createIPv4AddressFromInt(first.start), createIPv4AddressFromInt(last.finish))
end

--[=[
Return the single smallest IPv6 CIDR that contains this entire range.
@param self Current IPv6Range instance.
@return Smallest containing IPv6 network, potentially including extra addresses.
]=]
function IPv6Range.smallestContainingNetwork(self: IPv6Range): IPv6Network
	local range = ensureV6Range(self)
	if #range._segments == 0 then
		error("cannot compute smallestContainingNetwork for an empty IPv6Range")
	end
	local first = range._segments[1]
	local last = range._segments[#range._segments]
	return IPv6Network.smallestContaining(createIPv6Address(first.start), createIPv6Address(last.finish))
end

--[=[
Metamethod: compare two IPv4 ranges for exact segment equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return True when both ranges have identical normalized segments.
]=]
IPv4Range.__eq = function(a: IPv4Range, b: IPv4Range): boolean
	if getmetatable(a) ~= IPv4Range or getmetatable(b) ~= IPv4Range then
		return false
	end
	if #a._segments ~= #b._segments then
		return false
	end
	for i = 1, #a._segments do
		local as = a._segments[i]
		local bs = b._segments[i]
		if as.start ~= bs.start or as.finish ~= bs.finish then
			return false
		end
	end
	return true
end

--[=[
Metamethod: compare two IPv6 ranges for exact segment equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return True when both ranges have identical normalized segments.
]=]
IPv6Range.__eq = function(a: IPv6Range, b: IPv6Range): boolean
	if getmetatable(a) ~= IPv6Range or getmetatable(b) ~= IPv6Range then
		return false
	end
	if #a._segments ~= #b._segments then
		return false
	end
	for i = 1, #a._segments do
		local as = a._segments[i]
		local bs = b._segments[i]
		if compareHextets(as.start, bs.start) ~= 0 or compareHextets(as.finish, bs.finish) ~= 0 then
			return false
		end
	end
	return true
end

--[=[
Metamethod: render IPv4 range segments as canonical text.
@param self Current IPv4Range instance.
@return Comma-separated IPv4 segment list.
]=]
IPv4Range.__tostring = function(self: IPv4Range): string
	local range = ensureV4Range(self)
	local parts = table.create(#range._segments)
	for i = 1, #range._segments do
		local seg = range._segments[i]
		local startText = tostring(createIPv4AddressFromInt(seg.start))
		if seg.start == seg.finish then
			parts[i] = startText
		else
			parts[i] = startText .. "-" .. tostring(createIPv4AddressFromInt(seg.finish))
		end
	end
	return table.concat(parts, ",")
end

--[=[
Metamethod: render IPv6 range segments as canonical text.
@param self Current IPv6Range instance.
@return Comma-separated IPv6 segment list.
]=]
IPv6Range.__tostring = function(self: IPv6Range): string
	local range = ensureV6Range(self)
	local parts = table.create(#range._segments)
	for i = 1, #range._segments do
		local seg = range._segments[i]
		local startText = tostring(createIPv6Address(seg.start))
		if compareHextets(seg.start, seg.finish) == 0 then
			parts[i] = startText
		else
			parts[i] = startText .. "-" .. tostring(createIPv6Address(seg.finish))
		end
	end
	return table.concat(parts, ",")
end

--[=[
Metamethod: allow direct `for ... in range` address iteration for IPv4.
@param self Current IPv4Range instance.
@return -> IPv4Address? Iterator yielding IPv4 addresses.
]=]
IPv4Range.__iter = IPv4Range.iter

--[=[
Metamethod: allow direct `for ... in range` address iteration for IPv6.
@param self Current IPv6Range instance.
@return -> IPv6Address? Iterator yielding IPv6 addresses.
]=]
IPv6Range.__iter = IPv6Range.iter

--- ===== IPv4 =====

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
--[=[
Create an IPv4Address from a 32-bit integer.
@param val Raw integer or packed bytes used to construct an address.
@return IPv4Address built from the packed integer.
]=]
function IPv4Address.fromInteger(val: number): IPv4Address
	if val ~= math.floor(val) or val < 0 or val > MAX_IPV4 then
		error("IPv4 integer must be in [0, 4294967295]")
	end
	return createIPv4AddressFromInt(val)
end
--[=[
Create an IPv4Address from a 4-byte buffer or byte array.
@param val Raw integer or packed bytes used to construct an address.
@return IPv4Address built from 4-byte input.
]=]
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

--[=[
Create an IPv4Address from packed byte input.
@param val Buffer or byte array containing exactly four bytes.
@return Parsed IPv4Address from packed input.
]=]
function IPv4Address.fromPacked(val: buffer | { number }): IPv4Address
	return IPv4Address.fromBytes(val)
end

--- Return a canonical IPv4 string
function IPv4Address.__string(self: IPv4Address): string
	return ipv4AddressString(self)
end
--- Return the PTR/arpa form of the IP
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
--- Pack the four octets into a 32 bit integer
function IPv4Address.toInteger(self: IPv4Address): number
	return ensureV4Address(self)._int
end
--- Pack the four octets into four bytes in a buffer
function IPv4Address.toBytes(self: IPv4Address): buffer
	local inner = ensureV4Address(self)
	local out = buffer.create(4)
	for i = 1, 4 do
		buffer.writeu8(out, i - 1, inner._octets[i])
	end
	return out
end

--[=[
Return packed IPv4 bytes for this address.
@param self Current IPv4Address instance.
@return containing four network-order bytes.
]=]
function IPv4Address.toPacked(self: IPv4Address): buffer
	return IPv4Address.toBytes(self)
end

--[=[
Return true for RFC1918 private IPv4 ranges.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isPrivate(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 10 or (a[1] == 172 and a[2] >= 16 and a[2] <= 31) or (a[1] == 192 and a[2] == 168)
end
--[=[
Return true when the IPv4 address is globally reachable.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.ipPublic(self: IPv4Address): boolean
	return IPv4Address.isGlobal(self)
end
--[=[
Return true for 127.0.0.0/8 loopback addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isLoopback(self: IPv4Address): boolean
	return ensureV4Address(self)._octets[1] == 127
end
--[=[
Return true for 224.0.0.0/4 multicast addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isMulticast(self: IPv4Address): boolean
	local o1 = ensureV4Address(self)._octets[1]
	return o1 >= 224 and o1 <= 239
end
--[=[
Return true for 169.254.0.0/16 link-local addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isLinkLocal(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 169 and a[2] == 254
end
--[=[
Return true for 0.0.0.0.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isUnspecified(self: IPv4Address): boolean
	return ensureV4Address(self)._int == 0
end
--[=[
Return true for reserved Class E IPv4 addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isReserved(self: IPv4Address): boolean
	local inner = ensureV4Address(self)
	local o1 = inner._octets[1]
	return o1 >= 240 and inner._int ~= MAX_IPV4
end
--[=[
Return true for TEST-NET documentation ranges.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isDocumentation(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return (a[1] == 192 and a[2] == 0 and a[3] == 2)
		or (a[1] == 198 and a[2] == 51 and a[3] == 100)
		or (a[1] == 203 and a[2] == 0 and a[3] == 113)
end
--[=[
Return true for IPv4 benchmarking ranges.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isBenchmarking(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 198 and (a[2] == 18 or a[2] == 19)
end
--[=[
Return true for shared CGNAT space (100.64.0.0/10).
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isShared(self: IPv4Address): boolean
	local a = ensureV4Address(self)._octets
	return a[1] == 100 and a[2] >= 64 and a[2] <= 127
end
--[=[
Return true when IPv4 address is considered globally reachable.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
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
-- TODO: Replace string with a union of all categories (loopback, multicast, LL, reserved, etc)
--[=[
Return a coarse category label describing this IPv4 address.
@param self Current object instance on which the method operates.
@return representation or textual result.
]=]
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

--[=[
Return true for 255.255.255.255.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv4Address.isBroadcast(self: IPv4Address): boolean
	return ensureV4Address(self)._int == MAX_IPV4
end

--[=[
Return true if this IPv4 address is inside the given network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv4Address.inNetwork(self: IPv4Address, net: IPv4Network): boolean
	local addr = ensureV4Address(self)
	local n = ensureV4Network(net)
	return ipv4NetworkInt(addr._int, n._prefix) == n._network
end
--[=[
Return the next IPv4 address.
@param self Current object instance on which the method operates.
@return Next IPv4 address value.
]=]
function IPv4Address.next(self: IPv4Address): IPv4Address
	local inner = ensureV4Address(self)
	if inner._int >= MAX_IPV4 then
		error("IPv4 overflow")
	end
	return createIPv4AddressFromInt(inner._int + 1)
end
--[=[
Return the previous IPv4 address.
@param self Current object instance on which the method operates.
@return Previous IPv4 address value.
]=]
function IPv4Address.previous(self: IPv4Address): IPv4Address
	local inner = ensureV4Address(self)
	if inner._int <= 0 then
		error("IPv4 underflow")
	end
	return createIPv4AddressFromInt(inner._int - 1)
end

--[=[
Return the IPv4-mapped IPv6 form of this IPv4 address.
@param self Current object instance on which the method operates.
@return IPv4-mapped IPv6 equivalent of this address.
]=]
function IPv4Address.toIPv6Mapped(self: IPv4Address): IPv6Address
	local octets = ensureV4Address(self)._octets
	return createIPv6Address({
		0,
		0,
		0,
		0,
		0,
		0xFFFF,
		octets[1] * 256 + octets[2],
		octets[3] * 256 + octets[4],
	})
end

--- ===== IPv6 =====

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

--[=[
Create an IPv6Address from packed byte input.
@param val Buffer or byte array containing exactly sixteen bytes.
@return Parsed IPv6Address from packed input.
]=]
function IPv6Address.fromPacked(val: buffer | { number }): IPv6Address
	return IPv6Address.fromBytes(val)
end

--[=[
Create an IPv6Address from a non-negative integer value.
@param val Number or decimal string representation of a 128-bit integer.
@return Parsed IPv6Address from integer input.
]=]
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

--- Return a canonical IPv6 string (compressed)
function IPv6Address.__string(self: IPv6Address): string
	return ipv6AddressString(self)
end
--- Return the fully compressed IPv6
function IPv6Address.compressed(self: IPv6Address): string
	return IPv6Address.__string(self)
end
--- Return the fully expanded IPv6
function IPv6Address.expanded(self: IPv6Address): string
	return hextetsToExpandedString(ensureV6Address(self)._hextets)
end
--- Return `[compressed]`
function IPv6Address.toUriHost(self: IPv6Address): string
	return "[" .. IPv6Address.compressed(self) .. "]"
end
--- Return the PTR/arpa form of the IP
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
--- Pack the bytes into a buffer
function IPv6Address.toBytes(self: IPv6Address): buffer
	local bytes = hextetsToBytes(ensureV6Address(self)._hextets)
	local out = buffer.create(16)
	for i = 1, 16 do
		buffer.writeu8(out, i - 1, bytes[i])
	end
	return out
end

--[=[
Return packed IPv6 bytes for this address.
@param self Current IPv6Address instance.
@return containing sixteen network-order bytes.
]=]
function IPv6Address.toPacked(self: IPv6Address): buffer
	return IPv6Address.toBytes(self)
end

--[=[
Return the integer representation of this IPv6 address.
@param self Current IPv6Address instance.
@return Decimal string representing the 128-bit address value.
]=]
function IPv6Address.toInteger(self: IPv6Address): string
	return bytesToDecimal(hextetsToBytes(ensureV6Address(self)._hextets))
end

--[=[
Return true for private (unique local) IPv6 addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isPrivate(self: IPv6Address): boolean
	return IPv6Address.isUniqueLocal(self)
end
--[=[
Return true when the IPv6 address is globally reachable.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.ipPublic(self: IPv6Address): boolean
	return IPv6Address.isGlobal(self)
end
--[=[
Return true for ::1.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isLoopback(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	for i = 1, 7 do
		if h[i] ~= 0 then
			return false
		end
	end
	return h[8] == 1
end
--[=[
Return true for ff00::/8 multicast addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isMulticast(self: IPv6Address): boolean
	return bit32.rshift(ensureV6Address(self)._hextets[1], 8) == 0xFF
end
--[=[
Return true for fe80::/10 link-local addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isLinkLocal(self: IPv6Address): boolean
	local h1 = ensureV6Address(self)._hextets[1]
	return bit32.band(h1, 0xFFC0) == 0xFE80
end
--[=[
Return true for ::.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isUnspecified(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	for i = 1, 8 do
		if h[i] ~= 0 then
			return false
		end
	end
	return true
end
--[=[
Return true for reserved IPv6 blocks (placeholder).
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isReserved(self: IPv6Address): boolean
	return false
end
--[=[
Return true for 2001:db8::/32 documentation space.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isDocumentation(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0x0DB8
end
--[=[
Return true for IPv6 benchmarking space.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isBenchmarking(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0x0002 and h[3] == 0
end
--[=[
Return true for shared IPv6 ranges (placeholder).
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isShared(self: IPv6Address): boolean
	return false
end
--[=[
Return true when IPv6 address is considered globally reachable.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isGlobal(self: IPv6Address): boolean
	return not IPv6Address.isPrivate(self)
		and not IPv6Address.isLoopback(self)
		and not IPv6Address.isMulticast(self)
		and not IPv6Address.isLinkLocal(self)
		and not IPv6Address.isUnspecified(self)
		and not IPv6Address.isDocumentation(self)
		and not IPv6Address.isBenchmarking(self)
end
-- TODO: Replace string with a union of all categories (loopback, multicast, LL, reserved, etc)
--[=[
Return a coarse category label describing this IPv6 address.
@param self Current object instance on which the method operates.
@return representation or textual result.
]=]
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

--[=[
Return true for fc00::/7 unique local addresses.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isUniqueLocal(self: IPv6Address): boolean
	local h1 = ensureV6Address(self)._hextets[1]
	return bit32.band(h1, 0xFE00) == 0xFC00
end
--[=[
Return true if this is an IPv4-mapped IPv6 address.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isIPv4Mapped(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0 and h[2] == 0 and h[3] == 0 and h[4] == 0 and h[5] == 0 and h[6] == 0xFFFF
end
--[=[
Return true if this is an IPv4-compatible IPv6 address.
@param self Current object instance on which the method operates.
@return result indicating whether the condition is met.
]=]
function IPv6Address.isIPv4Compatible(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0 and h[2] == 0 and h[3] == 0 and h[4] == 0 and h[5] == 0 and h[6] == 0
end
-- TODO: Expand return enum
--[=[
Return a coarse IPv6 scope classification.
@param self Current object instance on which the method operates.
@return "link-local" | "global" Derived scope classification for this IPv6 address.
]=]
function IPv6Address.scope(self: IPv6Address): "interface-local" | "link-local" | "global"
	if IPv6Address.isLinkLocal(self) then
		return "link-local"
	end
	if IPv6Address.isLoopback(self) or IPv6Address.isUnspecified(self) then
		return "interface-local"
	end
	return "global"
end

--[=[
Extract embedded IPv4 address from mapped/compatible IPv6 forms.
@param self Current object instance on which the method operates.
@return Embedded IPv4 address when present, otherwise nil.
]=]
function IPv6Address.getEmbeddedIPv4(self: IPv6Address): IPv4Address?
	local h = ensureV6Address(self)._hextets
	if IPv6Address.isIPv4Mapped(self) or IPv6Address.isIPv4Compatible(self) then
		local octets = {
			math.floor(h[7] / 256),
			h[7] % 256,
			math.floor(h[8] / 256),
			h[8] % 256,
		}
		return createIPv4AddressFromOctets(octets)
	end
	return nil
end

--[=[
Convert mapped/compatible IPv6 addresses back to IPv4.
@param self Current IPv6Address instance.
@return Extracted IPv4Address when conversion is possible.
]=]
function IPv6Address.toIPv4(self: IPv6Address): IPv4Address?
	return IPv6Address.getEmbeddedIPv4(self)
end

--[=[
Return true for 6to4 IPv6 addresses (`2002::/16`).
@param self Current IPv6Address instance.
@return True when the address belongs to 6to4 space.
]=]
function IPv6Address.is6to4(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2002
end

--[=[
Return true for Teredo IPv6 addresses (`2001:0000::/32`).
@param self Current IPv6Address instance.
@return True when the address belongs to Teredo space.
]=]
function IPv6Address.isTeredo(self: IPv6Address): boolean
	local h = ensureV6Address(self)._hextets
	return h[1] == 0x2001 and h[2] == 0
end

--[=[
Return true if this IPv6 address is inside the given network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv6Address.inNetwork(self: IPv6Address, net: IPv6Network): boolean
	local addr = ensureV6Address(self)
	local n = ensureV6Network(net)
	return ipv6PrefixMatch(addr._hextets, n._network, n._prefix)
end
--[=[
Return the next IPv6 address.
@param self Current object instance on which the method operates.
@return Next IPv6 address value.
]=]
function IPv6Address.next(self: IPv6Address): IPv6Address
	local n = ipv6Increment(ensureV6Address(self)._hextets)
	if not n then
		error("IPv6 overflow")
	end
	return createIPv6Address(n)
end
--[=[
Return the previous IPv6 address.
@param self Current object instance on which the method operates.
@return Previous IPv6 address value.
]=]
function IPv6Address.previous(self: IPv6Address): IPv6Address
	local n = ipv6Decrement(ensureV6Address(self)._hextets)
	if not n then
		error("IPv6 underflow")
	end
	return createIPv6Address(n)
end

--- ===== IPv4 Network =====
function IPv4Network.networkAddress(self: IPv4Network): IPv4Address
	local n = ensureV4Network(self)
	return createIPv4AddressFromInt(n._network)
end
--[=[
Return the broadcast address of this IPv4 CIDR block.
@param self Current object instance on which the method operates.
@return Broadcast address for this IPv4 network.
]=]
function IPv4Network.broadcastAddress(self: IPv4Network): IPv4Address
	local n = ensureV4Network(self)
	return createIPv4AddressFromInt(ipv4Broadcast(n._network, n._prefix))
end
--[=[
Return the IPv4 netmask address for this prefix.
@param self Current object instance on which the method operates.
@return Netmask address for this IPv4 network.
]=]
function IPv4Network.netmask(self: IPv4Network): IPv4Address
	return createIPv4AddressFromInt(ipv4Mask(ensureV4Network(self)._prefix))
end
--[=[
Return the IPv4 hostmask address for this prefix.
@param self Current object instance on which the method operates.
@return Hostmask address for this IPv4 network.
]=]
function IPv4Network.hostmask(self: IPv4Network): IPv4Address
	return createIPv4AddressFromInt(ipv4Hostmask(ensureV4Network(self)._prefix))
end
--[=[
Return the CIDR prefix length for this IPv4 network.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv4Network.prefixLength(self: IPv4Network): number
	return ensureV4Network(self)._prefix
end
--[=[
Return the first usable host address in this IPv4 network.
@param self Current object instance on which the method operates.
@return First usable host address in this network.
]=]
function IPv4Network.firstHost(self: IPv4Network): IPv4Address
	local n = ensureV4Network(self)
	if n._prefix >= 31 then
		return createIPv4AddressFromInt(n._network)
	end
	return createIPv4AddressFromInt(n._network + 1)
end
--[=[
Return the last usable host address in this IPv4 network.
@param self Current object instance on which the method operates.
@return Last usable host address in this network.
]=]
function IPv4Network.lastHost(self: IPv4Network): IPv4Address
	local n = ensureV4Network(self)
	local b = ipv4Broadcast(n._network, n._prefix)
	if n._prefix >= 31 then
		return createIPv4AddressFromInt(b)
	end
	return createIPv4AddressFromInt(b - 1)
end
--[=[
Return the usable host count for this IPv4 network.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv4Network.hostCount(self: IPv4Network): number
	local p = ensureV4Network(self)._prefix
	local addresses = 2 ^ (32 - p)
	if p <= 30 then
		return addresses - 2
	end
	return addresses
end
--[=[
Return true if an IPv4 address belongs to this network.
@param self Current object instance on which the method operates.
@param ipAddr IP address value to test against the network.
@return result indicating whether the condition is met.
]=]
function IPv4Network.contains(self: IPv4Network, ipAddr: IPv4Address): boolean
	local n = ensureV4Network(self)
	local ipi = ensureV4Address(ipAddr)
	return ipv4NetworkInt(ipi._int, n._prefix) == n._network
end
--[=[
Return true if another IPv4 network is fully contained.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv4Network.containsNetwork(self: IPv4Network, net: IPv4Network): boolean
	local a = ensureV4Network(self)
	local b = ensureV4Network(net)
	if b._prefix < a._prefix then
		return false
	end
	return ipv4NetworkInt(b._network, a._prefix) == a._network
end
--[=[
Return true if two IPv4 networks overlap.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv4Network.overlaps(self: IPv4Network, net: IPv4Network): boolean
	local a = ensureV4Network(self)
	local b = ensureV4Network(net)
	local aStart = a._network
	local aEnd = ipv4Broadcast(a._network, a._prefix)
	local bStart = b._network
	local bEnd = ipv4Broadcast(b._network, b._prefix)
	return aStart <= bEnd and bStart <= aEnd
end
--[=[
Return true if this network is a subnet of another IPv4 network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv4Network.isSubnetOf(self: IPv4Network, net: IPv4Network): boolean
	return IPv4Network.containsNetwork(net, self)
end
--[=[
Return true if this network is a supernet of another IPv4 network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv4Network.isSupernetOf(self: IPv4Network, net: IPv4Network): boolean
	return IPv4Network.containsNetwork(self, net)
end

-- TODO: An __iter, not an array
--[=[
Iterate child IPv4 subnets at the requested target prefix.
@param self Current object instance on which the method operates.
@param newPrefix Target prefix length for subnetting or supernetting.
@return -> IPv4Network? Iterator yielding subnet networks at the requested prefix.
]=]
function IPv4Network.subnets(self: IPv4Network, newPrefix: number?): () -> IPv4Network?
	local n = ensureV4Network(self)
	local target = newPrefix or (n._prefix + 1)
	if target ~= math.floor(target) or target < n._prefix or target > 32 then
		error("invalid target prefix for IPv4 subnets")
	end
	local subnetCount = 2 ^ (target - n._prefix)
	local block = 2 ^ (32 - target)
	local i = 0
	return function()
		if i >= subnetCount then
			return nil
		end
		local netValue = createIPv4Network(n._network + i * block, target)
		i += 1
		return netValue
	end
end
-- TODO: An __iter, not an array
--[=[
Return the containing IPv4 supernet at the requested target prefix.
@param self Current object instance on which the method operates.
@param newPrefix Target prefix length for subnetting or supernetting.
@return Containing supernet at the requested prefix.
]=]
function IPv4Network.supernet(self: IPv4Network, newPrefix: number?): IPv4Network
	local n = ensureV4Network(self)
	local target = newPrefix or (n._prefix - 1)
	if target ~= math.floor(target) or target < 0 or target > n._prefix then
		error("invalid target prefix for IPv4 supernet")
	end
	return createIPv4Network(n._network, target)
end

--[=[
Return the IPv4 network mapped into IPv6 space.
@param self Current IPv4Network instance.
@return IPv4-mapped IPv6 network with prefix shifted by 96 bits.
]=]
function IPv4Network.toIPv6Mapped(self: IPv4Network): IPv6Network
	local n = ensureV4Network(self)
	local octets = intToOctets(n._network)
	local hextets = {
		0,
		0,
		0,
		0,
		0,
		0xFFFF,
		octets[1] * 256 + octets[2],
		octets[3] * 256 + octets[4],
	}
	return createIPv6Network(hextets, n._prefix + 96)
end
-- TODO: An __iter, not an array
--[=[
Iterate usable IPv4 host addresses in this network lazily.
@param self Current object instance on which the method operates.
@return -> IPv4Address? Iterator yielding usable IPv4 host addresses.
]=]
function IPv4Network.hosts(self: IPv4Network): () -> IPv4Address?
	local n = ensureV4Network(self)
	local count = IPv4Network.hostCount(n)
	local first = IPv4Network.firstHost(n)._int
	local i = 0
	return function()
		if i >= count then
			return nil
		end
		local addr = createIPv4AddressFromInt(first + i)
		i += 1
		return addr
	end
end
-- TODO: An __iter, not an array
--[=[
Iterate all IPv4 addresses in this network lazily.
@param self Current object instance on which the method operates.
@return -> IPv4Address? Iterator yielding all IPv4 addresses in range.
]=]
function IPv4Network.addresses(self: IPv4Network): () -> IPv4Address?
	local n = ensureV4Network(self)
	local count = 2 ^ (32 - n._prefix)
	local i = 0
	return function()
		if i >= count then
			return nil
		end
		local addr = createIPv4AddressFromInt(n._network + i)
		i += 1
		return addr
	end
end

--- ===== IPv6 Network =====
function IPv6Network.networkAddress(self: IPv6Network): IPv6Address
	return createIPv6Address(ensureV6Network(self)._network)
end
--[=[
Return the last address in this IPv6 CIDR block.
@param self Current object instance on which the method operates.
@return Last address in this IPv6 network range.
]=]
function IPv6Network.broadcastAddress(self: IPv6Network): IPv6Address
	local n = ensureV6Network(self)
	return createIPv6Address(ipv6Or(n._network, ipv6HostmaskHextets(n._prefix)))
end
--[=[
Return the IPv6 netmask address for this prefix.
@param self Current object instance on which the method operates.
@return Netmask address for this IPv6 network.
]=]
function IPv6Network.netmask(self: IPv6Network): IPv6Address
	local n = ensureV6Network(self)
	local mask = ipv6MaskHextets({ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF }, n._prefix)
	return createIPv6Address(mask)
end
--[=[
Return the IPv6 hostmask address for this prefix.
@param self Current object instance on which the method operates.
@return Hostmask address for this IPv6 network.
]=]
function IPv6Network.hostmask(self: IPv6Network): IPv6Address
	return createIPv6Address(ipv6HostmaskHextets(ensureV6Network(self)._prefix))
end
--[=[
Return the CIDR prefix length for this IPv6 network.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv6Network.prefixLength(self: IPv6Network): number
	return ensureV6Network(self)._prefix
end
--[=[
Return the first address in this IPv6 network.
@param self Current object instance on which the method operates.
@return First address in this IPv6 network.
]=]
function IPv6Network.firstHost(self: IPv6Network): IPv6Address
	return createIPv6Address(ensureV6Network(self)._network)
end
--[=[
Return the last address in this IPv6 network.
@param self Current object instance on which the method operates.
@return Last address in this IPv6 network.
]=]
function IPv6Network.lastHost(self: IPv6Network): IPv6Address
	local n = ensureV6Network(self)
	return createIPv6Address(ipv6Or(n._network, ipv6HostmaskHextets(n._prefix)))
end
--[=[
Return address count for this IPv6 network.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv6Network.hostCount(self: IPv6Network): number
	local p = ensureV6Network(self)._prefix
	return 2 ^ (128 - p)
end
--[=[
Return true if an IPv6 address belongs to this network.
@param self Current object instance on which the method operates.
@param ipAddr IP address value to test against the network.
@return result indicating whether the condition is met.
]=]
function IPv6Network.contains(self: IPv6Network, ipAddr: IPv6Address): boolean
	local n = ensureV6Network(self)
	local ipi = ensureV6Address(ipAddr)
	return ipv6PrefixMatch(ipi._hextets, n._network, n._prefix)
end
--[=[
Return true if another IPv6 network is fully contained.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv6Network.containsNetwork(self: IPv6Network, net: IPv6Network): boolean
	local a = ensureV6Network(self)
	local b = ensureV6Network(net)
	if b._prefix < a._prefix then
		return false
	end
	return ipv6PrefixMatch(b._network, a._network, a._prefix)
end
--[=[
Return true if two IPv6 networks overlap.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv6Network.overlaps(self: IPv6Network, net: IPv6Network): boolean
	local a = ensureV6Network(self)
	local b = ensureV6Network(net)
	local aStart = a._network
	local aEnd = ipv6Or(a._network, ipv6HostmaskHextets(a._prefix))
	local bStart = b._network
	local bEnd = ipv6Or(b._network, ipv6HostmaskHextets(b._prefix))
	return compareHextets(aStart, bEnd) <= 0 and compareHextets(bStart, aEnd) <= 0
end
--[=[
Return true if this network is a subnet of another IPv6 network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv6Network.isSubnetOf(self: IPv6Network, net: IPv6Network): boolean
	return IPv6Network.containsNetwork(net, self)
end
--[=[
Return true if this network is a supernet of another IPv6 network.
@param self Current object instance on which the method operates.
@param net Network to test membership, overlap, or containment against.
@return result indicating whether the condition is met.
]=]
function IPv6Network.isSupernetOf(self: IPv6Network, net: IPv6Network): boolean
	return IPv6Network.containsNetwork(self, net)
end
-- TODO: An __iter, not an array
--[=[
Iterate child IPv6 subnets at the requested target prefix.
@param self Current object instance on which the method operates.
@param newPrefix Target prefix length for subnetting or supernetting.
@return -> IPv6Network? Iterator yielding subnet networks at the requested prefix.
]=]
function IPv6Network.subnets(self: IPv6Network, newPrefix: number?): () -> IPv6Network?
	local n = ensureV6Network(self)
	local target = newPrefix or (n._prefix + 1)
	if target ~= math.floor(target) or target < n._prefix or target > 128 then
		error("invalid target prefix for IPv6 subnets")
	end
	local subnetCount = 2 ^ (target - n._prefix)
	local strideBit = 128 - target
	local current = cloneArray(n._network)
	local i = 0
	return function()
		if i >= subnetCount then
			return nil
		end
		local netValue = createIPv6Network(current, target)
		i += 1
		if i < subnetCount then
			local nextNet = ipv6AddPowerOfTwo(current, strideBit)
			if nextNet then
				current = nextNet
			else
				i = subnetCount
			end
		end
		return netValue
	end
end
-- TODO: An __iter, not an array
--[=[
Return the containing IPv6 supernet at the requested target prefix.
@param self Current object instance on which the method operates.
@param newPrefix Target prefix length for subnetting or supernetting.
@return Containing supernet at the requested prefix.
]=]
function IPv6Network.supernet(self: IPv6Network, newPrefix: number?): IPv6Network
	local n = ensureV6Network(self)
	local target = newPrefix or (n._prefix - 1)
	if target ~= math.floor(target) or target < 0 or target > n._prefix then
		error("invalid target prefix for IPv6 supernet")
	end
	return createIPv6Network(n._network, target)
end
-- TODO: An __iter, not an array
--[=[
Iterate IPv6 host addresses lazily (same sequence as addresses).
@param self Current object instance on which the method operates.
@return -> IPv6Address? Iterator yielding IPv6 host addresses in range.
]=]
function IPv6Network.hosts(self: IPv6Network): () -> IPv6Address?
	return IPv6Network.addresses(self)
end
-- TODO: An __iter, not an array
--[=[
Iterate IPv6 addresses in this network lazily.
@param self Current object instance on which the method operates.
@return -> IPv6Address? Iterator yielding IPv6 addresses in range.
]=]
function IPv6Network.addresses(self: IPv6Network): () -> IPv6Address?
	local n = ensureV6Network(self)
	local count = 2 ^ (128 - n._prefix)
	local current = cloneArray(n._network)
	local i = 0
	return function()
		if i >= count then
			return nil
		end
		local value = createIPv6Address(current)
		i += 1
		local nextAddr = ipv6Increment(current)
		if nextAddr then
			current = nextAddr
		else
			i = count
		end
		return value
	end
end

--- ===== IPv4 Interface =====

--[=[
Return interface prefix length.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv4Interface.prefixLength(self: IPv4Interface): number
	return self._prefix
end
--[=[
Return interface IPv4 netmask.
@param self Current object instance on which the method operates.
@return Netmask for this IPv4 interface.
]=]
function IPv4Interface.netmask(self: IPv4Interface): IPv4Address
	return self.network:netmask()
end
--- eg "192.168.1.10/24"
function IPv4Interface.withPrefixLength(self: IPv4Interface): string
	return tostring(self.address) .. "/" .. tostring(self._prefix)
end
--- eg "192.168.1.10/255.255.255.0"
function IPv4Interface.withNetmask(self: IPv4Interface): string
	return tostring(self.address) .. "/" .. tostring(self:netmask())
end
--[=[
Return interface IPv4 hostmask.
@param self Current object instance on which the method operates.
@return Hostmask for this IPv4 interface.
]=]
function IPv4Interface.hostmask(self: IPv4Interface): IPv4Address
	return self.network:hostmask()
end

--- ===== IPv6 Interface =====

--[=[
Return interface prefix length.
@param self Current object instance on which the method operates.
@return Numeric result produced by the operation.
]=]
function IPv6Interface.prefixLength(self: IPv6Interface): number
	return self._prefix
end
--[=[
Return interface IPv6 netmask.
@param self Current object instance on which the method operates.
@return Netmask for this IPv6 interface.
]=]
function IPv6Interface.netmask(self: IPv6Interface): IPv6Address
	return self.network:netmask()
end
--- eg "192.168.1.10/26" (but ipv6)
function IPv6Interface.withPrefixLength(self: IPv6Interface): string
	return tostring(self.address) .. "/" .. tostring(self._prefix)
end
--- eg "192.168.1.10/255.255.255.0" (but ipv6)
function IPv6Interface.withNetmask(self: IPv6Interface): string
	return tostring(self.address) .. "/" .. tostring(self:netmask())
end
--[=[
Return interface IPv6 hostmask.
@param self Current object instance on which the method operates.
@return Hostmask for this IPv6 interface.
]=]
function IPv6Interface.hostmask(self: IPv6Interface): IPv6Address
	return self.network:hostmask()
end

--[=[
Metamethod: compare two IPv4 addresses for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv4Address.__eq = function(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		return false
	end
	return compareIPv4Address(a, b) == 0
end
--[=[
Metamethod: compare IPv4 address ordering (less-than).
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv4Address.__lt = function(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		error("IPv4Address comparison requires two IPv4Address values")
	end
	return compareIPv4Address(a, b) < 0
end
--[=[
Metamethod: compare IPv4 address ordering (less-than-or-equal).
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv4Address.__le = function(a: IPv4Address, b: IPv4Address): boolean
	if getmetatable(a) ~= IPv4Address or getmetatable(b) ~= IPv4Address then
		error("IPv4Address comparison requires two IPv4Address values")
	end
	return compareIPv4Address(a, b) <= 0
end
--[=[
Metamethod: convert an IPv4 address into an IPv4 network by prefix.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return IPv4 network formed from address and prefix.
]=]
IPv4Address.__div = function(a: IPv4Address, b: number)
	if getmetatable(a) ~= IPv4Address then
		error("left operand must be IPv4Address")
	end
	if type(b) ~= "number" or b ~= math.floor(b) then
		error("right operand must be an integer prefix length")
	end
	if b < 0 or b > 32 then
		error("IPv4 prefix length must be in [0,32]")
	end
	return createIPv4Network(a._int, b)
end
--[=[
Metamethod: render IPv4 address as canonical text.
@param self Current object instance on which the method operates.
@return Canonical string form used by tostring().
]=]
IPv4Address.__tostring = function(self: IPv4Address): string
	return ipv4AddressString(self)
end

--[=[
Metamethod: compare two IPv6 addresses for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv6Address.__eq = function(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		return false
	end
	return compareIPv6Address(a, b) == 0
end
--[=[
Metamethod: compare IPv6 address ordering (less-than).
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv6Address.__lt = function(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		error("IPv6Address comparison requires two IPv6Address values")
	end
	return compareIPv6Address(a, b) < 0
end
--[=[
Metamethod: compare IPv6 address ordering (less-than-or-equal).
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv6Address.__le = function(a: IPv6Address, b: IPv6Address): boolean
	if getmetatable(a) ~= IPv6Address or getmetatable(b) ~= IPv6Address then
		error("IPv6Address comparison requires two IPv6Address values")
	end
	return compareIPv6Address(a, b) <= 0
end
--[=[
Metamethod: convert an IPv6 address into an IPv6 network by prefix.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return IPv6 network formed from address and prefix.
]=]
IPv6Address.__div = function(a: IPv6Address, b: number)
	if getmetatable(a) ~= IPv6Address then
		error("left operand must be IPv6Address")
	end
	if type(b) ~= "number" or b ~= math.floor(b) then
		error("right operand must be an integer prefix length")
	end
	if b < 0 or b > 128 then
		error("IPv6 prefix length must be in [0,128]")
	end
	return createIPv6Network(a._hextets, b)
end
--[=[
Metamethod: render IPv6 address as canonical text.
@param self Current object instance on which the method operates.
@return Canonical string form used by tostring().
]=]
IPv6Address.__tostring = function(self: IPv6Address): string
	return ipv6AddressString(self)
end

--[=[
Metamethod: compare two IPv4 networks for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv4Network.__eq = function(a: IPv4Network, b: IPv4Network): boolean
	if getmetatable(a) ~= IPv4Network or getmetatable(b) ~= IPv4Network then
		return false
	end
	return a._prefix == b._prefix and a._network == b._network
end
--[=[
Metamethod: return total address count in IPv4 network.
@param self Current object instance on which the method operates.
@return Total address count represented by this IPv4 network.
]=]
IPv4Network.__len = function(self: IPv4Network): number
	local n = ensureV4Network(self)
	return 2 ^ (32 - n._prefix)
end
--[=[
Metamethod: render IPv4 network as canonical CIDR text.
@param self Current object instance on which the method operates.
@return Canonical CIDR string form used by tostring().
]=]
IPv4Network.__tostring = function(self: IPv4Network): string
	local n = ensureV4Network(self)
	return tostring(IPv4Network.networkAddress(n)) .. "/" .. tostring(n._prefix)
end

--[=[
Metamethod: compare two IPv6 networks for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv6Network.__eq = function(a: IPv6Network, b: IPv6Network): boolean
	if getmetatable(a) ~= IPv6Network or getmetatable(b) ~= IPv6Network then
		return false
	end
	return a._prefix == b._prefix and hextetsEqual(a._network, b._network)
end
--[=[
Metamethod: return total address count in IPv6 network.
@param self Current object instance on which the method operates.
@return Total address count represented by this IPv6 network.
]=]
IPv6Network.__len = function(self: IPv6Network): number
	local n = ensureV6Network(self)
	return 2 ^ (128 - n._prefix)
end
--[=[
Metamethod: render IPv6 network as canonical CIDR text.
@param self Current object instance on which the method operates.
@return Canonical CIDR string form used by tostring().
]=]
IPv6Network.__tostring = function(self: IPv6Network): string
	local n = ensureV6Network(self)
	return tostring(IPv6Network.networkAddress(n)) .. "/" .. tostring(n._prefix)
end

--[=[
Metamethod: compare two IPv4 interfaces for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv4Interface.__eq = function(a: IPv4Interface, b: IPv4Interface): boolean
	if getmetatable(a) ~= IPv4Interface or getmetatable(b) ~= IPv4Interface then
		return false
	end
	return a._prefix == b._prefix and (a.address == b.address)
end
--[=[
IPv4 interface tostring metamethod.
@param self Current interface instance.
@return Canonical interface string form used by tostring().
]=]
IPv4Interface.__tostring = IPv4Interface.withPrefixLength

--[=[
Metamethod: compare two IPv6 interfaces for equality.
@param a Primary input value or left operand.
@param b Secondary input value or right operand.
@return result indicating whether the condition is met.
]=]
IPv6Interface.__eq = function(a: IPv6Interface, b: IPv6Interface): boolean
	if getmetatable(a) ~= IPv6Interface or getmetatable(b) ~= IPv6Interface then
		return false
	end
	return a._prefix == b._prefix and (a.address == b.address)
end
--[=[
IPv6 interface tostring metamethod.
@param self Current interface instance.
@return Canonical interface string form used by tostring().
]=]
IPv6Interface.__tostring = IPv6Interface.withPrefixLength

ip.IPv4Address = IPv4Address
ip.IPv6Address = IPv6Address
ip.IPv4Network = IPv4Network
ip.IPv6Network = IPv6Network
ip.IPv4Interface = IPv4Interface
ip.IPv6Interface = IPv6Interface
ip.IPv4Range = IPv4Range
ip.IPv6Range = IPv6Range

return table.freeze(ip)
