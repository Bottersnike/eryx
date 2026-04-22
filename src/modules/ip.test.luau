local ip = require("@self/ip")
local test = require("@eryx/test")

local suite = test.Suite.new("ip")

local function collectStrings(iter: () -> any, limit: number?)
	local out = {}
	local n = limit or 256
	while #out < n do
		local value = iter()
		if value == nil then
			break
		end
		table.insert(out, tostring(value))
	end
	return out
end

local function join(values)
	return table.concat(values, "|")
end

local function n6(value)
	return (string.gsub(value, ":::+", "::"))
end

suite:test("module exports classes", function()
	test.expect(ip.IPv4Address):toNotBeNil()
	test.expect(ip.IPv6Address):toNotBeNil()
	test.expect(ip.IPv4Network):toNotBeNil()
	test.expect(ip.IPv6Network):toNotBeNil()
	test.expect(ip.IPv4Interface):toNotBeNil()
	test.expect(ip.IPv6Interface):toNotBeNil()
	test.expect(ip.IPv4Range):toNotBeNil()
	test.expect(ip.IPv6Range):toNotBeNil()
end)

suite:test("parse entry points and options", function()
	local v4 = ip.parse("192.168.1.10")
	test.expect(v4):toNotBeNil()
	assert(v4)
	test.expect(v4.version):toBe("4")

	local v6 = ip.parse("2001:db8::1")
	test.expect(v6):toNotBeNil()
	assert(v6)
	test.expect(v6.version):toBe("6")

	local n4 = ip.parse("192.168.1.0/24")
	test.expect(n4):toNotBeNil()
	test.expect(tostring(n4)):toBe("192.168.1.0/24")

	test.expect(ip.parse("not-an-ip")):toBeNil()
	test.expect(ip.network("192.168.1.10/24", { strict = true })):toBeNil()
	test.expect(tostring(ip.network("192.168.1.10/24", { strict = false }))):toBe("192.168.1.0/24")

	test.expect(ip.address("fe80::1%eth0")):toBeNil()
	local zoned = ip.address("fe80::1%eth0", { allowZoneId = true })
	test.expect(zoned):toNotBeNil()
	assert(zoned)
	test.expect(tostring(zoned)):toBe("fe80::1")
end)

suite:test("predicates and class parse helpers", function()
	test.expect(ip.isAddress("1.2.3.4")):toBeTrue()
	test.expect(ip.isAddress("bad")):toBeFalse()
	test.expect(ip.isNetwork("1.2.3.0/24")):toBeTrue()
	test.expect(ip.isNetwork("1.2.3.4/99")):toBeFalse()
	test.expect(ip.isIPv4("::1")):toBeFalse()
	test.expect(ip.isIPv6("::1")):toBeTrue()
	test.expect(ip.isIPv4("1.2.3.4/24")):toBeTrue()
	test.expect(ip.isIPv6("1.2.3.4/24")):toBeFalse()

	test.expect(ip.IPv4Address.parse("10.0.0.1")):toNotBeNil()
	test.expect(ip.IPv4Address.parse("::1")):toBeNil()
	test.expect(ip.IPv6Address.parse("::1")):toNotBeNil()
	test.expect(ip.IPv4Network.parse("10.0.0.0/24")):toNotBeNil()
	test.expect(ip.IPv6Network.parse("2001:db8::/64")):toNotBeNil()
	test.expect(ip.IPv4Interface.parse("10.0.0.1/24")):toNotBeNil()
	test.expect(ip.IPv6Interface.parse("2001:db8::1/64")):toNotBeNil()
end)

suite:test("IPv4 constructors and conversions", function()
	local a = ip.IPv4Address.fromOctets({ 1, 2, 3, 4 })
	test.expect(tostring(a)):toBe("1.2.3.4")
	test.expect(a:toInteger()):toBe(16909060)

	local fromInt = ip.IPv4Address.fromInteger(3232235777)
	test.expect(tostring(fromInt)):toBe("192.168.1.1")

	local b = ip.IPv4Address.fromBytes({ 10, 0, 0, 1 })
	test.expect(tostring(b)):toBe("10.0.0.1")

	local packed = a:toPacked()
	local unpacked = ip.IPv4Address.fromPacked(packed)
	test.expect(tostring(unpacked)):toBe("1.2.3.4")

	local bytes = a:toBytes()
	test.expect(buffer.len(bytes)):toBe(4)
	test.expect(buffer.readu8(bytes, 0)):toBe(1)
	test.expect(buffer.readu8(bytes, 3)):toBe(4)
end)

suite:test("IPv6 constructors and conversions", function()
	local a = ip.IPv6Address.fromBytes({ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })
	test.expect(tostring(a)):toBe("2001:db8::1")

	local b = ip.IPv6Address.fromInteger("1")
	test.expect(tostring(b)):toBe("::1")
	test.expect(b:toInteger()):toBe("1")

	local packed = a:toPacked()
	local unpacked = ip.IPv6Address.fromPacked(packed)
	test.expect(tostring(unpacked)):toBe("2001:db8::1")

	local bytes = a:toBytes()
	test.expect(buffer.len(bytes)):toBe(16)
	test.expect(buffer.readu8(bytes, 0)):toBe(0x20)
	test.expect(buffer.readu8(bytes, 15)):toBe(1)

	test.expect(a:compressed()):toBe("2001:db8::1")
	test.expect(a:expanded()):toBe("2001:0db8:0000:0000:0000:0000:0000:0001")
	test.expect(a:toUriHost()):toBe("[2001:db8::1]")
end)

suite:test("IPv4 address methods and metamethods", function()
	local a = ip.address("10.0.0.1")
	local b = ip.address("10.0.0.2")
	assert(a and b)
	assert(a.version == "4")
	assert(b.version == "4")

	test.expect(a == ip.address("10.0.0.1")):toBeTrue()
	test.expect(a < b):toBeTrue()
	test.expect(a <= b):toBeTrue()
	test.expect(tostring(a / 24)):toBe("10.0.0.0/24")
	test.expect(tostring(a)):toBe("10.0.0.1")

	test.expect(a:isPrivate()):toBeTrue()
	test.expect(a:isLoopback()):toBeFalse()
	test.expect((ip.address("127.0.0.1") :: ip.IPv4Address):isLoopback()):toBeTrue()
	test.expect((ip.address("239.1.1.1") :: ip.IPv4Address):isMulticast()):toBeTrue()
	test.expect((ip.address("169.254.1.1") :: ip.IPv4Address):isLinkLocal()):toBeTrue()
	test.expect((ip.address("0.0.0.0") :: ip.IPv4Address):isUnspecified()):toBeTrue()
	test.expect((ip.address("240.0.0.1") :: ip.IPv4Address):isReserved()):toBeTrue()
	test.expect((ip.address("198.19.0.1") :: ip.IPv4Address):isBenchmarking()):toBeTrue()
	test.expect((ip.address("100.64.0.1") :: ip.IPv4Address):isShared()):toBeTrue()
	test.expect((ip.address("255.255.255.255") :: ip.IPv4Address):isBroadcast()):toBeTrue()
	test.expect((ip.address("8.8.8.8") :: ip.IPv4Address):ipPublic()):toBeTrue()
	test.expect((ip.address("8.8.8.8") :: ip.IPv4Address):isGlobal()):toBeTrue()
	test.expect((ip.address("10.0.0.1") :: ip.IPv4Address):category()):toBe("private")

	test.expect(tostring(a:next())):toBe("10.0.0.2")
	test.expect(tostring(b:previous())):toBe("10.0.0.1")
	test.expect(a:inNetwork(ip.network("10.0.0.0/24") :: ip.IPv4Network)):toBeTrue()
	test.expect(a:reverseUri()):toBe("1.0.0.10.in-addr.arpa")
	test.expect(tostring(a:toIPv6Mapped())):toBe("::ffff:a00:1")
end)

suite:test("IPv6 address methods and metamethods", function()
	local a = ip.address("2001:db8::1")
	local b = ip.address("2001:db8::2")
	assert(a and b)
	assert(a.version == "6")
	assert(b.version == "6")

	test.expect(a == ip.address("2001:db8::1")):toBeTrue()
	test.expect(a < b):toBeTrue()
	test.expect(a <= b):toBeTrue()
	test.expect(n6(tostring(a / 64))):toBe("2001:db8::/64")

	test.expect((ip.address("fd00::1") :: ip.IPv6Address):isUniqueLocal()):toBeTrue()
	test.expect((ip.address("fd00::1") :: ip.IPv6Address):isPrivate()):toBeTrue()
	test.expect((ip.address("::1") :: ip.IPv6Address):isLoopback()):toBeTrue()
	test.expect((ip.address("ff02::1") :: ip.IPv6Address):isMulticast()):toBeTrue()
	test.expect((ip.address("fe80::1") :: ip.IPv6Address):isLinkLocal()):toBeTrue()
	test.expect((ip.address("::") :: ip.IPv6Address):isUnspecified()):toBeTrue()
	test.expect((ip.address("2001:db8::1") :: ip.IPv6Address):isDocumentation()):toBeTrue()
	test.expect((ip.address("2001:2::1") :: ip.IPv6Address):isBenchmarking()):toBeTrue()
	test.expect((ip.address("2001:4860:4860::8888") :: ip.IPv6Address):isGlobal()):toBeTrue()
	test.expect((ip.address("fd00::1") :: ip.IPv6Address):category()):toBe("private")
	test.expect((ip.address("fe80::1") :: ip.IPv6Address):scope()):toBe("link-local")

	local mapped = ip.address("::ffff:192.168.1.1")
	assert(mapped)
	assert(mapped.version == "6")
	test.expect(mapped:isIPv4Mapped()):toBeTrue()
	test.expect(mapped:isIPv4Compatible()):toBeFalse()
	test.expect(tostring(mapped:getEmbeddedIPv4())):toBe("192.168.1.1")
	test.expect(tostring(mapped:toIPv4())):toBe("192.168.1.1")

	local compatible = ip.address("::192.0.2.1")
	assert(compatible)
	assert(compatible.version == "6")
	test.expect(compatible:isIPv4Compatible()):toBeTrue()
	test.expect(tostring(compatible:getEmbeddedIPv4())):toBe("192.0.2.1")
	test.expect(tostring(compatible:toIPv4())):toBe("192.0.2.1")

	test.expect((ip.address("2002::1") :: ip.IPv6Address):is6to4()):toBeTrue()
	test.expect((ip.address("2001:0::1") :: ip.IPv6Address):isTeredo()):toBeTrue()
	test.expect(a:inNetwork(ip.network("2001:db8::/64") :: ip.IPv6Network)):toBeTrue()
	test.expect(tostring(a:next())):toBe("2001:db8::2")
	test.expect(tostring(b:previous())):toBe("2001:db8::1")
	test.expect(a:ipPublic()):toBeFalse()
end)

suite:test("IPv4 network surface", function()
	local net = ip.network("192.168.1.0/24")
	local sub = ip.network("192.168.1.128/25")
	assert(net and sub)
	assert(net.version == "4")
	assert(sub.version == "4")

	test.expect(tostring(net:networkAddress())):toBe("192.168.1.0")
	test.expect(tostring(net:broadcastAddress())):toBe("192.168.1.255")
	test.expect(tostring(net:netmask())):toBe("255.255.255.0")
	test.expect(tostring(net:hostmask())):toBe("0.0.0.255")
	test.expect(net:prefixLength()):toBe(24)
	test.expect(tostring(net:firstHost())):toBe("192.168.1.1")
	test.expect(tostring(net:lastHost())):toBe("192.168.1.254")
	test.expect(net:hostCount()):toBe(254)
	test.expect(net:contains(ip.address("192.168.1.42") :: ip.IPv4Address)):toBeTrue()
	test.expect(net:containsNetwork(sub)):toBeTrue()
	test.expect(net:overlaps(sub)):toBeTrue()
	test.expect(sub:isSubnetOf(net)):toBeTrue()
	test.expect(net:isSupernetOf(sub)):toBeTrue()

	test.expect(#net):toBe(256)
	test.expect(tostring(net)):toBe("192.168.1.0/24")
	test.expect(net == ip.network("192.168.1.0/24")):toBeTrue()

	local s = net:subnets(25)
	test.expect(tostring(s())):toBe("192.168.1.0/25")
	test.expect(tostring(s())):toBe("192.168.1.128/25")
	test.expect(s()):toBeNil()
	test.expect(tostring(net:supernet(23))):toBe("192.168.0.0/23")

	test.expect(join(collectStrings((ip.network("192.168.1.0/30") :: ip.IPv4Network):hosts())))
		:toBe("192.168.1.1|192.168.1.2")
	test.expect(join(collectStrings((ip.network("192.168.1.0/30") :: ip.IPv4Network):addresses())))
		:toBe("192.168.1.0|192.168.1.1|192.168.1.2|192.168.1.3")
	test.expect(tostring(net:toIPv6Mapped())):toBe("::ffff:c0a8:100/120")
end)

suite:test("IPv6 network surface", function()
	local net = ip.network("2001:db8::/126")
	local other = ip.network("2001:db8::2/127")
	assert(net and other)
	assert(net.version == "6")
	assert(other.version == "6")

	test.expect(n6(tostring(net:networkAddress()))):toBe("2001:db8::")
	test.expect(tostring(net:broadcastAddress())):toBe("2001:db8::3")
	test.expect(tostring(net:netmask())):toBe("ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffc")
	test.expect(tostring(net:hostmask())):toBe("::3")
	test.expect(net:prefixLength()):toBe(126)
	test.expect(n6(tostring(net:firstHost()))):toBe("2001:db8::")
	test.expect(tostring(net:lastHost())):toBe("2001:db8::3")
	test.expect(net:hostCount()):toBe(4)
	test.expect(net:contains(ip.address("2001:db8::1") :: ip.IPv6Address)):toBeTrue()
	test.expect(net:containsNetwork(other)):toBeTrue()
	test.expect(net:overlaps(other)):toBeTrue()
	test.expect(other:isSubnetOf(net)):toBeTrue()
	test.expect(net:isSupernetOf(other)):toBeTrue()

	test.expect(#net):toBe(4)
	test.expect(n6(tostring(net))):toBe("2001:db8::/126")
	test.expect(net == ip.network("2001:db8::/126")):toBeTrue()

	local s = (ip.network("2001:db8::/126") :: ip.IPv6Network):subnets(127)
	test.expect(n6(tostring(s()))):toBe("2001:db8::/127")
	test.expect(tostring(s())):toBe("2001:db8::2/127")
	test.expect(s()):toBeNil()
	test.expect(n6(tostring((ip.network("2001:db8::/126") :: ip.IPv6Network):supernet(125)))):toBe("2001:db8::/125")

	test.expect(n6(join(collectStrings((ip.network("2001:db8::/126") :: ip.IPv6Network):hosts()))))
		:toBe("2001:db8::|2001:db8::1|2001:db8::2|2001:db8::3")
	test.expect(n6(join(collectStrings((ip.network("2001:db8::/126") :: ip.IPv6Network):addresses()))))
		:toBe("2001:db8::|2001:db8::1|2001:db8::2|2001:db8::3")
end)

suite:test("network merge operations", function()
	local merged4 = ip.IPv4Network.mergeNetworks({ "10.0.0.0/24", "10.0.1.0/24", "10.0.1.0/24" })
	test.expect(#merged4):toBe(1)
	test.expect(tostring(merged4[1])):toBe("10.0.0.0/23")

	local merged6 = ip.IPv6Network.mergeNetworks({ "2001:db8::/127", "2001:db8::2/127" })
	test.expect(#merged6):toBe(1)
	test.expect(n6(tostring(merged6[1]))):toBe("2001:db8::/126")
end)

suite:test("sorting and smallest containing helpers", function()
	local s4 = ip.sortIPv4({ "10.0.0.2", "10.0.0.1" })
	test.expect(tostring(s4[1])):toBe("10.0.0.1")

	local s6 = ip.sortIPv6({ "2001:db8::2", "2001:db8::1" })
	test.expect(tostring(s6[1])):toBe("2001:db8::1")

	local a4 = ip.address("10.0.0.1") :: ip.IPv4Address
	local b4 = ip.address("10.0.0.129") :: ip.IPv4Address
	test.expect(tostring(ip.smallestEnclosingIPv4Network(a4, b4))):toBe("10.0.0.0/24")
	test.expect(tostring(ip.IPv4Network.smallestContaining(a4, b4))):toBe("10.0.0.0/24")

	local a6 = ip.address("2001:db8::1") :: ip.IPv6Address
	local b6 = ip.address("2001:db8::ff") :: ip.IPv6Address
	test.expect(n6(tostring(ip.smallestEnclosingIPv6Network(a6, b6)))):toBe("2001:db8::/120")
	test.expect(n6(tostring(ip.IPv6Network.smallestContaining(a6, b6)))):toBe("2001:db8::/120")
end)

suite:test("interfaces and metamethods", function()
	local i4 = ip.interface("192.168.1.10/255.255.255.0") :: ip.IPv4Interface?
	local i4b = ip.interface("192.168.1.10/24") :: ip.IPv4Interface?
	assert(i4 and i4b)

	test.expect(i4:prefixLength()):toBe(24)
	test.expect(tostring(i4:netmask())):toBe("255.255.255.0")
	test.expect(tostring(i4:hostmask())):toBe("0.0.0.255")
	test.expect(i4:withPrefixLength()):toBe("192.168.1.10/24")
	test.expect(i4:withNetmask()):toBe("192.168.1.10/255.255.255.0")
	test.expect(i4 == i4b):toBeTrue()
	test.expect(tostring(i4)):toBe("192.168.1.10/24")

	local i6 = ip.interface("2001:db8::1/64") :: ip.IPv6Interface?
	local i6b = ip.interface("2001:db8::1/64") :: ip.IPv6Interface?
	assert(i6 and i6b)
	test.expect(i6:prefixLength()):toBe(64)
	test.expect(n6(tostring(i6:netmask()))):toBe("ffff:ffff:ffff:ffff::")
	test.expect(tostring(i6:hostmask())):toBe("::ffff:ffff:ffff:ffff")
	test.expect(i6:withPrefixLength()):toBe("2001:db8::1/64")
	test.expect(n6(i6:withNetmask())):toBe("2001:db8::1/ffff:ffff:ffff:ffff::")
	test.expect(i6 == i6b):toBeTrue()
	test.expect(n6(tostring(i6))):toBe("2001:db8::1/64")
end)

suite:test("IPv4 range surface", function()
	local r = ip.IPv4Range.new("192.168.1.10", "192.168.1.15")
	test.expect(r:contains("192.168.1.10")):toBeTrue()
	test.expect(r:contains(ip.address("192.168.1.12") :: ip.IPv4Address)):toBeTrue()
	test.expect(r:contains("192.168.1.0/31")):toBeFalse()

	local byNet = ip.IPv4Range.fromNetwork("192.168.1.0/30")
	test.expect(join(collectStrings(byNet:iter()))):toBe("192.168.1.0|192.168.1.1|192.168.1.2|192.168.1.3")

	local excluded = r:exclude("192.168.1.12")
	test.expect(excluded:contains("192.168.1.12")):toBeFalse()
	test.expect(join(collectStrings(excluded:iter())))
		:toBe("192.168.1.10|192.168.1.11|192.168.1.13|192.168.1.14|192.168.1.15")

	local toNets = collectStrings(r:toNetworks())
	test.expect(join(toNets)):toBe("192.168.1.10/31|192.168.1.12/30")
	test.expect(tostring(r:smallestContainingNetwork())):toBe("192.168.1.8/29")

	local itered = {}
	for addr in r do
		table.insert(itered, tostring(addr))
	end
	test.expect(join(itered)):toBe("192.168.1.10|192.168.1.11|192.168.1.12|192.168.1.13|192.168.1.14|192.168.1.15")

	test.expect(r == ip.IPv4Range.new("192.168.1.10", "192.168.1.15")):toBeTrue()
	test.expect(tostring(r)):toBe("192.168.1.10-192.168.1.15")
end)

suite:test("IPv6 range surface", function()
	local r = ip.IPv6Range.new("2001:db8::1", "2001:db8::4")
	test.expect(r:contains("2001:db8::2")):toBeTrue()
	test.expect(r:contains(ip.address("2001:db8::1") :: ip.IPv6Address)):toBeTrue()
	test.expect(r:contains("2001:db8::/126")):toBeFalse()

	local byNet = ip.IPv6Range.fromNetwork("2001:db8::/126")
	test.expect(n6(join(collectStrings(byNet:iter())))):toBe("2001:db8::|2001:db8::1|2001:db8::2|2001:db8::3")

	local excluded = r:exclude("2001:db8::3")
	test.expect(excluded:contains("2001:db8::3")):toBeFalse()
	test.expect(n6(join(collectStrings(excluded:iter())))):toBe("2001:db8::1|2001:db8::2|2001:db8::4")

	local toNets = collectStrings(r:toNetworks())
	test.expect(n6(join(toNets))):toBe("2001:db8::1/128|2001:db8::2/127|2001:db8::4/128")
	test.expect(n6(tostring(r:smallestContainingNetwork()))):toBe("2001:db8::/125")

	local itered = {}
	for addr in r do
		table.insert(itered, tostring(addr))
	end
	test.expect(n6(join(itered))):toBe("2001:db8::1|2001:db8::2|2001:db8::3|2001:db8::4")

	test.expect(r == ip.IPv6Range.new("2001:db8::1", "2001:db8::4")):toBeTrue()
	test.expect(n6(tostring(r))):toBe("2001:db8::1-2001:db8::4")
end)

suite:test("error cases for invalid operators and bounds", function()
	local ok1 = pcall(function()
		local _ = (ip.address("1.2.3.4") :: ip.IPv4Address) / 33
	end)
	test.expect(ok1):toBeFalse()

	local ok2 = pcall(function()
		local _ = (ip.address("::1") :: ip.IPv6Address) / 129
	end)
	test.expect(ok2):toBeFalse()

	local ok3 = pcall(function()
		local _ = (ip.address("255.255.255.255") :: ip.IPv4Address):next()
	end)
	test.expect(ok3):toBeFalse()

	local ok4 = pcall(function()
		local _ = (ip.address("::") :: ip.IPv6Address):previous()
	end)
	test.expect(ok4):toBeFalse()

	local ok5 = pcall(function()
		local _ = ip.IPv4Range.new("10.0.0.2", "10.0.0.1")
	end)
	test.expect(ok5):toBeFalse()

	local ok6 = pcall(function()
		local _ = ip.IPv6Range.new("2001:db8::2", "2001:db8::1")
	end)
	test.expect(ok6):toBeFalse()
end)

return suite
