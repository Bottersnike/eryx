local utils = require("./utils")
local IPv6Address = require("./address6")
local IPv6Network = require("./network6")

local cloneArray = utils.cloneArray
local compareHextets = utils.compareHextets
local ipv6Increment = utils.ipv6Increment
local ipv6Decrement = utils.ipv6Decrement
local ipv6Or = utils.ipv6Or
local ipv6HostmaskHextets = utils.ipv6HostmaskHextets
local ipv6MaskHextets = utils.ipv6MaskHextets

local IPv6Range = {}
IPv6Range.__index = IPv6Range

export type IPv6Range = setmetatable<
	{
		--- IP version number (`6`). This value is a string for type narrowing
		read version: "6",
		--- Sorted, non-overlapping inclusive segments.
		read _segments: { { start: { number }, finish: { number } } },
	},
	typeof(IPv6Range)
>

local function ensureV6Range(v: any): IPv6Range
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Range then
		error("expected IPv6Range")
	end
	return v
end

local function coerceV6Address(value: IPv6Address.IPv6Address | string): IPv6Address.IPv6Address
	if type(value) == "string" then
		local parsed = IPv6Address.parse(value)
		if not parsed then
			error("expected IPv6 address")
		end
		return parsed
	end
	return IPv6Address._ensure(value)
end

local function coerceV6Network(value: IPv6Network.IPv6Network | string): IPv6Network.IPv6Network
	if type(value) == "string" then
		local parsed = IPv6Network.parse(value)
		if not parsed then
			error("expected IPv6 network")
		end
		return parsed
	end
	return IPv6Network._ensure(value)
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

local function createIPv6Range(segments: { { start: { number }, finish: { number } } }): IPv6Range
	local normalized = normalizeV6Segments(segments)
	local value = setmetatable({
		version = "6",
		_segments = normalized,
	}, IPv6Range)
	return table.freeze(value)
end

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

local function coerceV6CutSegments(
	value: IPv6Address.IPv6Address | IPv6Network.IPv6Network | IPv6Range | string
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

	local mt = getmetatable(value :: any)
	if mt == IPv6Address then
		local addr = value :: IPv6Address.IPv6Address
		return {
			{
				start = cloneArray(addr._hextets),
				finish = cloneArray(addr._hextets),
			},
		}
	elseif mt == IPv6Network then
		local net = value :: IPv6Network.IPv6Network
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

function IPv6Range.new(
	startValue: IPv6Address.IPv6Address | string,
	endValue: IPv6Address.IPv6Address | string
): IPv6Range
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

function IPv6Range.fromNetwork(networkValue: IPv6Network.IPv6Network | string): IPv6Range
	local network = coerceV6Network(networkValue)
	return createIPv6Range({
		{
			start = cloneArray(network._network),
			finish = ipv6Or(network._network, ipv6HostmaskHextets(network._prefix)),
		},
	})
end

function IPv6Range.contains(
	self: IPv6Range,
	value: IPv6Address.IPv6Address | IPv6Network.IPv6Network | IPv6Range | string
): boolean
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

	local mt = getmetatable(value :: any)
	if mt == IPv6Address then
		return v6SegmentsContainHextets(range._segments, (value :: IPv6Address.IPv6Address)._hextets)
	elseif mt == IPv6Network then
		local net = value :: IPv6Network.IPv6Network
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

function IPv6Range.exclude(
	self: IPv6Range,
	value: IPv6Address.IPv6Address | IPv6Network.IPv6Network | IPv6Range | string
): IPv6Range
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

function IPv6Range.iter(self: IPv6Range): () -> IPv6Address.IPv6Address?
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
				local out = IPv6Address._create(current :: { number })
				current = ipv6Increment(current :: { number })
				return out
			end
			index += 1
			current = nil
			finish = nil
		end
	end
end

function IPv6Range.toNetworks(self: IPv6Range): () -> IPv6Network.IPv6Network?
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
					local net = IPv6Network._create(base, prefix)
					current = ipv6Increment(last)
					return net
				end
				prefix += 1
			end
		end
	end
end

function IPv6Range.smallestContainingNetwork(self: IPv6Range): IPv6Network.IPv6Network
	local range = ensureV6Range(self)
	if #range._segments == 0 then
		error("cannot compute smallestContainingNetwork for an empty IPv6Range")
	end
	local first = range._segments[1]
	local last = range._segments[#range._segments]
	return IPv6Network.smallestContaining(IPv6Address._create(first.start), IPv6Address._create(last.finish))
end

function IPv6Range.__eq(a: IPv6Range, b: IPv6Range): boolean
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

function IPv6Range.__tostring(self: IPv6Range): string
	local range = ensureV6Range(self)
	local parts = table.create(#range._segments)
	for i = 1, #range._segments do
		local seg = range._segments[i]
		local startText = tostring(IPv6Address._create(seg.start))
		if compareHextets(seg.start, seg.finish) == 0 then
			parts[i] = startText
		else
			parts[i] = startText .. "-" .. tostring(IPv6Address._create(seg.finish))
		end
	end
	return table.concat(parts, ",")
end

IPv6Range.__iter = IPv6Range.iter

return IPv6Range
