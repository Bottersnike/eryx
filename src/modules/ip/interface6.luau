local utils = require("./utils")
local IPv6Address = require("./address6")
local IPv6Network = require("./network6")

local IPv6Interface = {}
IPv6Interface.__index = IPv6Interface

export type IPv6Interface = setmetatable<
	{
		--- Assigned IPv6 address.
		read address: IPv6Address.IPv6Address,
		--- Containing IPv6 network.
		read network: IPv6Network.IPv6Network,
		--- Interface prefix length.
		read _prefix: number,
	},
	typeof(IPv6Interface)
>

function IPv6Interface.parse(source: string, options: utils.ParseOptions?): IPv6Interface?
	local addrPart, prefixPart = utils.splitOnce(utils.trim(source), "/")
	if not prefixPart then
		return nil
	end
	local hextets = utils.parseIPv6Hextets(addrPart, options)
	if not hextets then
		return nil
	end
	local prefix = utils.parsePrefixPart(prefixPart, 6)
	if prefix == nil then
		return nil
	end
	local addr = IPv6Address._create(hextets)
	local iface = setmetatable({
		address = addr,
		network = IPv6Network._create(hextets, prefix),
		_prefix = prefix,
	}, IPv6Interface)
	return table.freeze(iface :: IPv6Interface)
end

function IPv6Interface.prefixLength(self: IPv6Interface): number
	return self._prefix
end

function IPv6Interface.netmask(self: IPv6Interface): IPv6Address.IPv6Address
	return self.network:netmask()
end

--- eg "2001:db8::1/64"
function IPv6Interface.withPrefixLength(self: IPv6Interface): string
	return tostring(self.address) .. "/" .. tostring(self._prefix)
end

--- eg "2001:db8::1/ffff:ffff:ffff:ffff::"
function IPv6Interface.withNetmask(self: IPv6Interface): string
	return tostring(self.address) .. "/" .. tostring(self:netmask())
end

function IPv6Interface.hostmask(self: IPv6Interface): IPv6Address.IPv6Address
	return self.network:hostmask()
end

function IPv6Interface.__eq(a: IPv6Interface, b: IPv6Interface): boolean
	if getmetatable(a) ~= IPv6Interface or getmetatable(b) ~= IPv6Interface then
		return false
	end
	return a._prefix == b._prefix and (a.address == b.address)
end

IPv6Interface.__tostring = IPv6Interface.withPrefixLength

return IPv6Interface
