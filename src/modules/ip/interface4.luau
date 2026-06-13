local utils = require("./utils")
local IPv4Address = require("./address4")
local IPv4Network = require("./network4")

local IPv4Interface = {}
IPv4Interface.__index = IPv4Interface

export type IPv4Interface = setmetatable<
	{
		--- Assigned IPv4 address.
		read address: IPv4Address.IPv4Address,
		--- Containing IPv4 network.
		read network: IPv4Network.IPv4Network,
		--- Interface prefix length.
		read _prefix: number,
	},
	typeof(IPv4Interface)
>

function IPv4Interface.parse(source: string, options: utils.ParseOptions?): IPv4Interface?
	local addrPart, prefixPart = utils.splitOnce(utils.trim(source), "/")
	if not prefixPart then
		return nil
	end
	local octets = utils.parseIPv4Octets(addrPart)
	if not octets then
		return nil
	end
	local prefix = utils.parsePrefixPart(prefixPart, 4)
	if prefix == nil then
		return nil
	end
	local addr = IPv4Address._newFromOctets(octets)
	local iface = setmetatable({
		address = addr,
		network = IPv4Network._create(addr._int, prefix),
		_prefix = prefix,
	}, IPv4Interface)
	return table.freeze(iface :: IPv4Interface)
end

function IPv4Interface.prefixLength(self: IPv4Interface): number
	return self._prefix
end

function IPv4Interface.netmask(self: IPv4Interface): IPv4Address.IPv4Address
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

function IPv4Interface.hostmask(self: IPv4Interface): IPv4Address.IPv4Address
	return self.network:hostmask()
end

function IPv4Interface.__eq(a: IPv4Interface, b: IPv4Interface): boolean
	if getmetatable(a) ~= IPv4Interface or getmetatable(b) ~= IPv4Interface then
		return false
	end
	return a._prefix == b._prefix and (a.address == b.address)
end

IPv4Interface.__tostring = IPv4Interface.withPrefixLength

return IPv4Interface
