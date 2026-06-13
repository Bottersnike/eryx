local MAX_IPV4 = 0xFFFFFFFF
local MAX_ITER = 65536

export type ParseOptions = {
	strict: boolean?,
	allowZoneId: boolean?,
}

local function parseOptions(options: ParseOptions?): ParseOptions
	return options or {}
end

local function trim(source: string): string
	return string.match(source, "^%s*(.-)%s*$") or ""
end

local function splitOnce(source: string, sep: string): (string, string?)
	local i = string.find(source, sep, 1, true)
	if not i then
		return source, nil
	end
	return string.sub(source, 1, i - 1), string.sub(source, i + #sep)
end

local function cloneArray<T>(arr: { T }): { T }
	local out = table.create(#arr)
	for i = 1, #arr do
		out[i] = arr[i]
	end
	return out
end

local function intToOctets(value: number): { number }
	return {
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256,
	}
end

local function octetsToInt(octets: { number }): number
	return (((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4])
end

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

local function hextetsEqual(a: { number }, b: { number }): boolean
	for i = 1, 8 do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

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

local function ipv4Mask(prefix: number): number
	if prefix <= 0 then
		return 0
	end
	if prefix >= 32 then
		return MAX_IPV4
	end
	return bit32.band(bit32.lshift(MAX_IPV4, 32 - prefix), MAX_IPV4)
end

local function ipv4NetworkInt(value: number, prefix: number): number
	return bit32.band(value, ipv4Mask(prefix))
end

local function ipv4Hostmask(prefix: number): number
	return bit32.band(bit32.bnot(ipv4Mask(prefix)), MAX_IPV4)
end

local function ipv4Broadcast(value: number, prefix: number): number
	return bit32.bor(ipv4NetworkInt(value, prefix), ipv4Hostmask(prefix))
end

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

local function ipv6Or(a: { number }, b: { number }): { number }
	local out = table.create(8, 0)
	for i = 1, 8 do
		out[i] = bit32.bor(a[i], b[i])
	end
	return out
end

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

return {
	MAX_IPV4 = MAX_IPV4,
	MAX_ITER = MAX_ITER,
	trim = trim,
	splitOnce = splitOnce,
	splitColon = splitColon,
	cloneArray = cloneArray,
	parseOptions = parseOptions,
	parseIPv4Octets = parseIPv4Octets,
	octetsToInt = octetsToInt,
	intToOctets = intToOctets,
	parseIPv6GroupsPart = parseIPv6GroupsPart,
	parseIPv6Hextets = parseIPv6Hextets,
	hextetsEqual = hextetsEqual,
	compareHextets = compareHextets,
	parsePrefixPart = parsePrefixPart,
	ipv4Mask = ipv4Mask,
	ipv4NetworkInt = ipv4NetworkInt,
	ipv4Hostmask = ipv4Hostmask,
	ipv4Broadcast = ipv4Broadcast,
	ipv6MaskHextets = ipv6MaskHextets,
	ipv6HostmaskHextets = ipv6HostmaskHextets,
	ipv6Or = ipv6Or,
	ipv6PrefixMatch = ipv6PrefixMatch,
	ipv6Increment = ipv6Increment,
	ipv6Decrement = ipv6Decrement,
}
