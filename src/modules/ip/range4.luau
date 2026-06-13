local utils = require("./utils")
local IPv4Address = require("./address4")
local IPv4Network = require("./network4")

local cloneArray = utils.cloneArray
local ipv4Broadcast = utils.ipv4Broadcast

local IPv4Range = {}
IPv4Range.__index = IPv4Range

export type IPv4Range = setmetatable<
	{
		--- IP version number (`4`). This value is a string for type narrowing
		read version: "4",
		--- Sorted, non-overlapping inclusive segments.
		read _segments: { { start: number, finish: number } },
	},
	typeof(IPv4Range)
>

local function ensureV4Range(v: any): IPv4Range
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Range then
		error("expected IPv4Range")
	end
	return v
end

local function coerceV4Address(value: IPv4Address.IPv4Address | string): IPv4Address.IPv4Address
	if type(value) == "string" then
		local parsed = IPv4Address.parse(value)
		if not parsed then
			error("expected IPv4 address")
		end
		return parsed
	end
	return IPv4Address._ensure(value)
end

local function coerceV4Network(value: IPv4Network.IPv4Network | string): IPv4Network.IPv4Network
	if type(value) == "string" then
		local parsed = IPv4Network.parse(value)
		if not parsed then
			error("expected IPv4 network")
		end
		return parsed
	end
	return IPv4Network._ensure(value)
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

local function createIPv4Range(segments: { { start: number, finish: number } }): IPv4Range
	local normalized = normalizeV4Segments(segments)
	local value = setmetatable({
		version = "4",
		_segments = normalized,
	}, IPv4Range)
	return table.freeze(value)
end

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

local function coerceV4CutSegments(
	value: IPv4Address.IPv4Address | IPv4Network.IPv4Network | IPv4Range | string
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

	local mt = getmetatable(value :: any)
	if mt == IPv4Address then
		local addr = value :: IPv4Address.IPv4Address
		return {
			{
				start = addr._int,
				finish = addr._int,
			},
		}
	elseif mt == IPv4Network then
		local net = value :: IPv4Network.IPv4Network
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

function IPv4Range.new(
	startValue: IPv4Address.IPv4Address | string,
	endValue: IPv4Address.IPv4Address | string
): IPv4Range
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

function IPv4Range.fromNetwork(networkValue: IPv4Network.IPv4Network | string): IPv4Range
	local network = coerceV4Network(networkValue)
	return createIPv4Range({
		{
			start = network._network,
			finish = ipv4Broadcast(network._network, network._prefix),
		},
	})
end

function IPv4Range.contains(
	self: IPv4Range,
	value: IPv4Address.IPv4Address | IPv4Network.IPv4Network | IPv4Range | string
): boolean
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

	local mt = getmetatable(value :: any)
	if mt == IPv4Address then
		return v4SegmentsContainInt(range._segments, (value :: IPv4Address.IPv4Address)._int)
	elseif mt == IPv4Network then
		local net = value :: IPv4Network.IPv4Network
		local startValue = net._network
		local finishValue = ipv4Broadcast(net._network, net._prefix)
		return v4SegmentsContainSegments(range._segments, { { start = startValue, finish = finishValue } })
	elseif mt == IPv4Range then
		return v4SegmentsContainSegments(range._segments, ensureV4Range(value)._segments)
	end

	error("contains expects IPv4 address, network, range, or string")
end

function IPv4Range.exclude(
	self: IPv4Range,
	value: IPv4Address.IPv4Address | IPv4Network.IPv4Network | IPv4Range | string
): IPv4Range
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

function IPv4Range.iter(self: IPv4Range): () -> IPv4Address.IPv4Address?
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
				local out = IPv4Address._newFromInt(current :: number)
				current = (current :: number) + 1
				return out
			end
			index += 1
			current = nil
			finish = nil
		end
	end
end

function IPv4Range.toNetworks(self: IPv4Range): () -> IPv4Network.IPv4Network?
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
					local net = IPv4Network._create(current :: number, prefix)
					current = (current :: number) + size
					return net
				end
				prefix += 1
			end
		end
	end
end

function IPv4Range.smallestContainingNetwork(self: IPv4Range): IPv4Network.IPv4Network
	local range = ensureV4Range(self)
	if #range._segments == 0 then
		error("cannot compute smallestContainingNetwork for an empty IPv4Range")
	end
	local first = range._segments[1]
	local last = range._segments[#range._segments]
	return IPv4Network.smallestContaining(IPv4Address._newFromInt(first.start), IPv4Address._newFromInt(last.finish))
end

function IPv4Range.__eq(a: IPv4Range, b: IPv4Range): boolean
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

function IPv4Range.__tostring(self: IPv4Range): string
	local range = ensureV4Range(self)
	local parts = table.create(#range._segments)
	for i = 1, #range._segments do
		local seg = range._segments[i]
		local startText = tostring(IPv4Address._newFromInt(seg.start))
		if seg.start == seg.finish then
			parts[i] = startText
		else
			parts[i] = startText .. "-" .. tostring(IPv4Address._newFromInt(seg.finish))
		end
	end
	return table.concat(parts, ",")
end

IPv4Range.__iter = IPv4Range.iter

return IPv4Range
