local utils = require("./utils")
local IPv6Address = require("./address6")

local cloneArray = utils.cloneArray
local hextetsEqual = utils.hextetsEqual
local compareHextets = utils.compareHextets
local ipv6MaskHextets = utils.ipv6MaskHextets
local ipv6HostmaskHextets = utils.ipv6HostmaskHextets
local ipv6Or = utils.ipv6Or
local ipv6PrefixMatch = utils.ipv6PrefixMatch
local ipv6Increment = utils.ipv6Increment
local parsePrefixPart = utils.parsePrefixPart
local parseIPv6Hextets = utils.parseIPv6Hextets
local trim = utils.trim
local splitOnce = utils.splitOnce

local IPv6Network = {}
IPv6Network.__index = IPv6Network

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

local function ensureV6Network(v: any): IPv6Network
	if type(v) ~= "table" or getmetatable(v) ~= IPv6Network then
		error("expected IPv6Network")
	end
	return v
end

local function createIPv6Network(hextets: { number }, prefix: number): IPv6Network
	local v = setmetatable({
		version = "6",
		_prefix = prefix,
		_network = ipv6MaskHextets(hextets, prefix),
	}, IPv6Network)
	return table.freeze(v)
end

local function createIPv6AddressFromHextets(hextets: { number }): IPv6Address.IPv6Address
	return IPv6Address._create(hextets)
end

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

function IPv6Network.smallestContaining(a: IPv6Address.IPv6Address, b: IPv6Address.IPv6Address): IPv6Network
	local left = IPv6Address._ensure(a)
	local right = IPv6Address._ensure(b)
	local prefix = countLeadingCommonBitsIPv6(left._hextets, right._hextets)
	local base = if compareHextets(left._hextets, right._hextets) <= 0 then left._hextets else right._hextets
	return createIPv6Network(base, prefix)
end

function IPv6Network.parse(source: string, options: utils.ParseOptions?): IPv6Network?
	local addrPart, prefixPart = splitOnce(trim(source), "/")
	if not prefixPart then
		return nil
	end
	local hextets = parseIPv6Hextets(addrPart, options)
	if not hextets then
		return nil
	end
	local prefix = parsePrefixPart(prefixPart, 6)
	if prefix == nil then
		return nil
	end
	local opts = utils.parseOptions(options)
	if opts.strict then
		local masked = ipv6MaskHextets(hextets, prefix)
		if not hextetsEqual(masked, hextets) then
			return nil
		end
	end
	return createIPv6Network(hextets, prefix)
end

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

function IPv6Network.networkAddress(self: IPv6Network): IPv6Address.IPv6Address
	return createIPv6AddressFromHextets(ensureV6Network(self)._network)
end

function IPv6Network.broadcastAddress(self: IPv6Network): IPv6Address.IPv6Address
	local n = ensureV6Network(self)
	return createIPv6AddressFromHextets(ipv6Or(n._network, ipv6HostmaskHextets(n._prefix)))
end

function IPv6Network.netmask(self: IPv6Network): IPv6Address.IPv6Address
	local n = ensureV6Network(self)
	local mask = ipv6MaskHextets({ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF }, n._prefix)
	return createIPv6AddressFromHextets(mask)
end

function IPv6Network.hostmask(self: IPv6Network): IPv6Address.IPv6Address
	return createIPv6AddressFromHextets(ipv6HostmaskHextets(ensureV6Network(self)._prefix))
end

function IPv6Network.prefixLength(self: IPv6Network): number
	return ensureV6Network(self)._prefix
end

function IPv6Network.firstHost(self: IPv6Network): IPv6Address.IPv6Address
	return createIPv6AddressFromHextets(ensureV6Network(self)._network)
end

function IPv6Network.lastHost(self: IPv6Network): IPv6Address.IPv6Address
	local n = ensureV6Network(self)
	return createIPv6AddressFromHextets(ipv6Or(n._network, ipv6HostmaskHextets(n._prefix)))
end

function IPv6Network.hostCount(self: IPv6Network): number
	local p = ensureV6Network(self)._prefix
	return 2 ^ (128 - p)
end

function IPv6Network.contains(self: IPv6Network, ipAddr: IPv6Address.IPv6Address): boolean
	local n = ensureV6Network(self)
	local ipi = IPv6Address._ensure(ipAddr)
	return ipv6PrefixMatch(ipi._hextets, n._network, n._prefix)
end

function IPv6Network.containsNetwork(self: IPv6Network, net: IPv6Network): boolean
	local a = ensureV6Network(self)
	local b = ensureV6Network(net)
	if b._prefix < a._prefix then
		return false
	end
	return ipv6PrefixMatch(b._network, a._network, a._prefix)
end

function IPv6Network.overlaps(self: IPv6Network, net: IPv6Network): boolean
	local a = ensureV6Network(self)
	local b = ensureV6Network(net)
	local aStart = a._network
	local aEnd = ipv6Or(a._network, ipv6HostmaskHextets(a._prefix))
	local bStart = b._network
	local bEnd = ipv6Or(b._network, ipv6HostmaskHextets(b._prefix))
	return compareHextets(aStart, bEnd) <= 0 and compareHextets(bStart, aEnd) <= 0
end

function IPv6Network.isSubnetOf(self: IPv6Network, net: IPv6Network): boolean
	return IPv6Network.containsNetwork(net, self)
end

function IPv6Network.isSupernetOf(self: IPv6Network, net: IPv6Network): boolean
	return IPv6Network.containsNetwork(self, net)
end

-- TODO: An __iter, not an array
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
function IPv6Network.supernet(self: IPv6Network, newPrefix: number?): IPv6Network
	local n = ensureV6Network(self)
	local target = newPrefix or (n._prefix - 1)
	if target ~= math.floor(target) or target < 0 or target > n._prefix then
		error("invalid target prefix for IPv6 supernet")
	end
	return createIPv6Network(n._network, target)
end

-- toIPv6Mapped on IPv4Network is patched in by init (needs both IPv4Network and IPv6Network)

-- TODO: An __iter, not an array
function IPv6Network.hosts(self: IPv6Network): () -> IPv6Address.IPv6Address?
	return IPv6Network.addresses(self)
end

-- TODO: An __iter, not an array
function IPv6Network.addresses(self: IPv6Network): () -> IPv6Address.IPv6Address?
	local n = ensureV6Network(self)
	local count = 2 ^ (128 - n._prefix)
	local current = cloneArray(n._network)
	local i = 0
	return function()
		if i >= count then
			return nil
		end
		local value = createIPv6AddressFromHextets(current)
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

function IPv6Network.__eq(a: IPv6Network, b: IPv6Network): boolean
	if getmetatable(a) ~= IPv6Network or getmetatable(b) ~= IPv6Network then
		return false
	end
	return a._prefix == b._prefix and hextetsEqual(a._network, b._network)
end

function IPv6Network.__len(self: IPv6Network): number
	local n = ensureV6Network(self)
	return 2 ^ (128 - n._prefix)
end

function IPv6Network.__tostring(self: IPv6Network): string
	local n = ensureV6Network(self)
	return tostring(IPv6Network.networkAddress(n)) .. "/" .. tostring(n._prefix)
end

-- Patch IPv6Address methods that require IPv6Network
function IPv6Address.inNetwork(self: IPv6Address.IPv6Address, net: IPv6Network): boolean
	local addr = IPv6Address._ensure(self)
	local n = ensureV6Network(net)
	return ipv6PrefixMatch(addr._hextets, n._network, n._prefix)
end

function IPv6Address.__div(a: IPv6Address.IPv6Address, b: number)
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

IPv6Network._create = createIPv6Network
IPv6Network._ensure = ensureV6Network

return IPv6Network
