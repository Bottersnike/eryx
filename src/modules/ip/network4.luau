local utils = require("./utils")
local IPv4Address = require("./address4")

local ipv4Mask = utils.ipv4Mask
local ipv4NetworkInt = utils.ipv4NetworkInt
local ipv4Hostmask = utils.ipv4Hostmask
local ipv4Broadcast = utils.ipv4Broadcast
local parsePrefixPart = utils.parsePrefixPart
local parseIPv4Octets = utils.parseIPv4Octets
local trim = utils.trim
local splitOnce = utils.splitOnce

local IPv4Network = {}
IPv4Network.__index = IPv4Network

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

local function ensureV4Network(v: any): IPv4Network
	if type(v) ~= "table" or getmetatable(v) ~= IPv4Network then
		error("expected IPv4Network")
	end
	return v
end

local function createIPv4Network(value: number, prefix: number): IPv4Network
	local v = setmetatable({
		version = "4",
		_prefix = prefix,
		_network = ipv4NetworkInt(value, prefix),
	}, IPv4Network)
	return table.freeze(v)
end

local function createIPv4AddressFromInt(value: number): IPv4Address.IPv4Address
	return IPv4Address._newFromInt(value)
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

function IPv4Network.smallestContaining(a: IPv4Address.IPv4Address, b: IPv4Address.IPv4Address): IPv4Network
	local left = IPv4Address._ensure(a)
	local right = IPv4Address._ensure(b)
	local prefix = countLeadingCommonBitsIPv4(left._int, right._int)
	local base = if left._int < right._int then left._int else right._int
	return createIPv4Network(base, prefix)
end

function IPv4Network.parse(source: string, options: utils.ParseOptions?): IPv4Network?
	local addrPart, prefixPart = splitOnce(trim(source), "/")
	if not prefixPart then
		return nil
	end
	local octets = parseIPv4Octets(addrPart)
	if not octets then
		return nil
	end
	local prefix = parsePrefixPart(prefixPart, 4)
	if prefix == nil then
		return nil
	end
	local opts = utils.parseOptions(options)
	local addrInt = utils.octetsToInt(octets)
	if opts.strict and ipv4NetworkInt(addrInt, prefix) ~= addrInt then
		return nil
	end
	return createIPv4Network(addrInt, prefix)
end

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

function IPv4Network.networkAddress(self: IPv4Network): IPv4Address.IPv4Address
	local n = ensureV4Network(self)
	return createIPv4AddressFromInt(n._network)
end

function IPv4Network.broadcastAddress(self: IPv4Network): IPv4Address.IPv4Address
	local n = ensureV4Network(self)
	return createIPv4AddressFromInt(ipv4Broadcast(n._network, n._prefix))
end

function IPv4Network.netmask(self: IPv4Network): IPv4Address.IPv4Address
	return createIPv4AddressFromInt(ipv4Mask(ensureV4Network(self)._prefix))
end

function IPv4Network.hostmask(self: IPv4Network): IPv4Address.IPv4Address
	return createIPv4AddressFromInt(ipv4Hostmask(ensureV4Network(self)._prefix))
end

function IPv4Network.prefixLength(self: IPv4Network): number
	return ensureV4Network(self)._prefix
end

function IPv4Network.firstHost(self: IPv4Network): IPv4Address.IPv4Address
	local n = ensureV4Network(self)
	if n._prefix >= 31 then
		return createIPv4AddressFromInt(n._network)
	end
	return createIPv4AddressFromInt(n._network + 1)
end

function IPv4Network.lastHost(self: IPv4Network): IPv4Address.IPv4Address
	local n = ensureV4Network(self)
	local b = ipv4Broadcast(n._network, n._prefix)
	if n._prefix >= 31 then
		return createIPv4AddressFromInt(b)
	end
	return createIPv4AddressFromInt(b - 1)
end

function IPv4Network.hostCount(self: IPv4Network): number
	local p = ensureV4Network(self)._prefix
	local addresses = 2 ^ (32 - p)
	if p <= 30 then
		return addresses - 2
	end
	return addresses
end

function IPv4Network.contains(self: IPv4Network, ipAddr: IPv4Address.IPv4Address): boolean
	local n = ensureV4Network(self)
	local ipi = IPv4Address._ensure(ipAddr)
	return ipv4NetworkInt(ipi._int, n._prefix) == n._network
end

function IPv4Network.containsNetwork(self: IPv4Network, net: IPv4Network): boolean
	local a = ensureV4Network(self)
	local b = ensureV4Network(net)
	if b._prefix < a._prefix then
		return false
	end
	return ipv4NetworkInt(b._network, a._prefix) == a._network
end

function IPv4Network.overlaps(self: IPv4Network, net: IPv4Network): boolean
	local a = ensureV4Network(self)
	local b = ensureV4Network(net)
	local aStart = a._network
	local aEnd = ipv4Broadcast(a._network, a._prefix)
	local bStart = b._network
	local bEnd = ipv4Broadcast(b._network, b._prefix)
	return aStart <= bEnd and bStart <= aEnd
end

function IPv4Network.isSubnetOf(self: IPv4Network, net: IPv4Network): boolean
	return IPv4Network.containsNetwork(net, self)
end

function IPv4Network.isSupernetOf(self: IPv4Network, net: IPv4Network): boolean
	return IPv4Network.containsNetwork(self, net)
end

-- TODO: An __iter, not an array
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
function IPv4Network.supernet(self: IPv4Network, newPrefix: number?): IPv4Network
	local n = ensureV4Network(self)
	local target = newPrefix or (n._prefix - 1)
	if target ~= math.floor(target) or target < 0 or target > n._prefix then
		error("invalid target prefix for IPv4 supernet")
	end
	return createIPv4Network(n._network, target)
end

-- Patched by init.luau (needs IPv6Network). Stub so the property exists in the sealed type.
function IPv4Network.toIPv6Mapped(_self: IPv4Network): any
	error("ip module not fully loaded")
end

-- TODO: An __iter, not an array
function IPv4Network.hosts(self: IPv4Network): () -> IPv4Address.IPv4Address?
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
function IPv4Network.addresses(self: IPv4Network): () -> IPv4Address.IPv4Address?
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

function IPv4Network.__eq(a: IPv4Network, b: IPv4Network): boolean
	if getmetatable(a) ~= IPv4Network or getmetatable(b) ~= IPv4Network then
		return false
	end
	return a._prefix == b._prefix and a._network == b._network
end

function IPv4Network.__len(self: IPv4Network): number
	local n = ensureV4Network(self)
	return 2 ^ (32 - n._prefix)
end

function IPv4Network.__tostring(self: IPv4Network): string
	local n = ensureV4Network(self)
	return tostring(IPv4Network.networkAddress(n)) .. "/" .. tostring(n._prefix)
end

-- Patch IPv4Address methods that require IPv4Network
function IPv4Address.inNetwork(self: IPv4Address.IPv4Address, net: IPv4Network): boolean
	local addr = IPv4Address._ensure(self)
	local n = ensureV4Network(net)
	return ipv4NetworkInt(addr._int, n._prefix) == n._network
end

function IPv4Address.__div(a: IPv4Address.IPv4Address, b: number)
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

IPv4Network._create = createIPv4Network
IPv4Network._ensure = ensureV4Network

return IPv4Network
