local utils = require("@self/utils")
local addr4 = require("@self/address4")
local addr6 = require("@self/address6")
local net4 = require("@self/network4")
local net6 = require("@self/network6")
local iface4 = require("@self/interface4")
local iface6 = require("@self/interface6")
local range4 = require("@self/range4")
local range6 = require("@self/range6")

export type IPv4Address = addr4.IPv4Address
export type IPv6Address = addr6.IPv6Address
export type IPv4Network = net4.IPv4Network
export type IPv6Network = net6.IPv6Network
export type IPv4Interface = iface4.IPv4Interface
export type IPv6Interface = iface6.IPv6Interface
export type IPv4Range = range4.IPv4Range
export type IPv6Range = range6.IPv6Range
export type ParseOptions = utils.ParseOptions

-- Patch cross-class conversions that couldn't live in their home modules

function addr4.toIPv6Mapped(self: addr4.IPv4Address): addr6.IPv6Address
	local octets = addr4._ensure(self)._octets
	return addr6._create({
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

function net4.toIPv6Mapped(self: net4.IPv4Network): net6.IPv6Network
	local n = net4._ensure(self)
	local octets = utils.intToOctets(n._network)
	return net6._create({
		0,
		0,
		0,
		0,
		0,
		0xFFFF,
		octets[1] * 256 + octets[2],
		octets[3] * 256 + octets[4],
	}, n._prefix + 96)
end

function addr6.getEmbeddedIPv4(self: addr6.IPv6Address): addr4.IPv4Address?
	local h = addr6._ensure(self)._hextets
	if addr6.isIPv4Mapped(self) or addr6.isIPv4Compatible(self) then
		return addr4._newFromOctets({
			math.floor(h[7] / 256),
			h[7] % 256,
			math.floor(h[8] / 256),
			h[8] % 256,
		})
	end
	return nil
end

function addr6.toIPv4(self: addr6.IPv6Address): addr4.IPv4Address?
	return addr6.getEmbeddedIPv4(self)
end

-- Public API

local ip = {}

function ip.address(source: string, options: ParseOptions?): (addr4.IPv4Address | addr6.IPv6Address)?
	local v4 = addr4.parse(source, options)
	if v4 then
		return v4
	end
	return addr6.parse(source, options)
end

function ip.network(source: string, options: ParseOptions?): (net4.IPv4Network | net6.IPv6Network)?
	local v4 = net4.parse(source, options)
	if v4 then
		return v4
	end
	return net6.parse(source, options)
end

function ip.interface(source: string, options: ParseOptions?): (iface4.IPv4Interface | iface6.IPv6Interface)?
	local v4 = iface4.parse(source, options)
	if v4 then
		return v4
	end
	return iface6.parse(source, options)
end

function ip.parse(
	source: string,
	options: ParseOptions?
): (addr4.IPv4Address | addr6.IPv6Address | net4.IPv4Network | net6.IPv6Network)?
	if string.find(source, "/", 1, true) then
		return ip.network(source, options) :: any
	end
	return ip.address(source, options) :: any
end

function ip.isAddress(source: string): boolean
	return ip.address(source) ~= nil
end

function ip.isNetwork(source: string): boolean
	return ip.network(source) ~= nil
end

function ip.isIPv4(source: string): boolean
	local parsed = ip.parse(source)
	if not parsed then
		return false
	end
	local mt = getmetatable(parsed :: any)
	if mt == addr4 or mt == net4 then
		return true
	end
	local iface = ip.interface(source)
	return iface ~= nil and getmetatable(iface :: any) == iface4
end

function ip.isIPv6(source: string): boolean
	local parsed = ip.parse(source)
	if not parsed then
		return false
	end
	local mt = getmetatable(parsed :: any)
	if mt == addr6 or mt == net6 then
		return true
	end
	local iface = ip.interface(source)
	return iface ~= nil and getmetatable(iface :: any) == iface6
end

function ip.smallestEnclosingIPv4Network(a: addr4.IPv4Address, b: addr4.IPv4Address): net4.IPv4Network
	return net4.smallestContaining(a, b)
end

function ip.smallestEnclosingIPv6Network(a: addr6.IPv6Address, b: addr6.IPv6Address): net6.IPv6Network
	return net6.smallestContaining(a, b)
end

function ip.sortIPv4(values: { addr4.IPv4Address | string }): { addr4.IPv4Address }
	return addr4.sort(values)
end

function ip.sortIPv6(values: { addr6.IPv6Address | string }): { addr6.IPv6Address }
	return addr6.sort(values)
end

ip.IPv4Address = addr4
ip.IPv6Address = addr6
ip.IPv4Network = net4
ip.IPv6Network = net6
ip.IPv4Interface = iface4
ip.IPv6Interface = iface6
ip.IPv4Range = range4
ip.IPv6Range = range6

return table.freeze(ip)
