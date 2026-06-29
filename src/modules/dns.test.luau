local dns = require("@eryx/dns")
local test = require("@eryx/test")

local suite = test.Suite.new("dns")

local function withLiveDns(fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		return
	end

	local message = tostring(err)
	local lower = string.lower(message)
	if
		string.find(lower, "timed out", 1, true)
		or string.find(lower, "network", 1, true)
		or string.find(lower, "getaddrinfo", 1, true)
		or string.find(lower, "host not found", 1, true)
		or string.find(lower, "connection refused", 1, true)
		or string.find(lower, "unreachable", 1, true)
	then
		test.skip("live DNS network unavailable: " .. message)
	end

	error(err, 0)
end

local function hasAnswerType(packet: dns.Message, recordType: string): boolean
	for _, answer in packet.answers do
		if tostring(answer.type) == recordType then
			return true
		end
	end

	return false
end

local function hasOptRecord(packet: dns.Message): boolean
	for _, record in packet.additional do
		if record.rdata.kind == "OPT" then
			return true
		end
	end

	return false
end

suite:test("prepareQuery builds a recursive query with optional EDNS", function()
	local message = dns.query.prepareQuery({
		{ name = "example.com", type = "A", class = "IN" },
		{ name = "example.com", type = "AAAA", class = "IN" },
	}, {
		id = 0x1234,
		edns = {
			udpPayloadSize = 1232,
			dnssecOk = true,
		},
	})

	test.expect(message.header.id):toBe(0x1234)
	test.expect(message.header.qr):toBe("QUERY")
	test.expect(message.header.opcode):toBe("QUERY")
	test.expect(message.header.rd):toBeTrue()
	test.expect(message.header.cd):toBeFalse()
	test.expect(#message.questions):toBe(2)
	test.expect(#message.answers):toBe(0)
	test.expect(#message.authorities):toBe(0)
	test.expect(#message.additional):toBe(1)
	test.expect(message.additional[1].rdata.kind):toBe("OPT")
	test.expect((message.additional[1].rdata :: any).udpPayloadSize):toBe(1232)
	test.expect((message.additional[1].rdata :: any).dnssecOk):toBeTrue()
end)

suite:test("proto buildPacket and parsePacket roundtrip a query message", function()
	local message = dns.query.prepareQuery({
		{ name = "example.net", type = "TXT", class = "IN" },
	}, {
		id = 0x4567,
		recursive = false,
		checkingDisabled = true,
		edns = {
			udpPayloadSize = 1400,
			options = {
				{
					code = "PADDING",
					data = buffer.create(8),
				},
			},
		},
	})

	local packet = dns.proto.buildPacket(
		message.header,
		message.questions,
		message.answers,
		message.authorities,
		message.additional
	)
	local parsed = dns.proto.parsePacket(packet)

	test.expect(parsed.header.id):toBe(0x4567)
	test.expect(parsed.header.rd):toBeFalse()
	test.expect(parsed.header.cd):toBeTrue()
	test.expect(#parsed.questions):toBe(1)
	test.expect(parsed.questions[1].name):toBe("example.net")
	test.expect(tostring(parsed.questions[1].type)):toBe("TXT")
	test.expect(#parsed.additional):toBe(1)
	test.expect(parsed.additional[1].rdata.kind):toBe("OPT")
	test.expect(((parsed.additional[1].rdata :: any).options)[1].code):toBe("PADDING")
end)

suite:test("queryUdp resolves example.com A via 1.1.1.1", function()
	withLiveDns(function()
		local message = dns.query.prepareQuery({
			{ name = "example.com", type = "A", class = "IN" },
		})
		local response = dns.query.queryUdp("1.1.1.1", message, {
			timeout = 10,
			useTcpIfTruncated = true,
		})

		test.expect(response.header.qr):toBe("RESPONSE")
		test.expect(response.header.id):toBe(message.header.id)
		test.expect(tostring(response.header.rcode)):toBe("NoError")
		test.expect(#response.questions):toBe(1)
		test.expect(#response.answers > 0):toBeTrue()
		test.expect(hasAnswerType(response, "A")):toBeTrue()
	end)
end)

suite:test("queryTcp resolves example.com MX via 8.8.8.8", function()
	withLiveDns(function()
		local message = dns.query.prepareQuery({
			{ name = "example.com", type = "MX", class = "IN" },
		})
		local response = dns.query.queryTcp("8.8.8.8", message, {
			timeout = 10,
		})

		test.expect(response.header.qr):toBe("RESPONSE")
		test.expect(response.header.id):toBe(message.header.id)
		test.expect(tostring(response.header.rcode)):toBe("NoError")
		test.expect(#response.answers > 0):toBeTrue()
		test.expect(hasAnswerType(response, "MX")):toBeTrue()
	end)
end)

suite:test("queryTls resolves example.com A via 1.1.1.1", function()
	withLiveDns(function()
		local message = dns.query.prepareQuery({
			{ name = "example.com", type = "A", class = "IN" },
		}, {
			edns = {
				udpPayloadSize = 1232,
			},
		})
		local response = dns.query.queryTls("1.1.1.1", message, {
			timeout = 10,
		})

		test.expect(response.header.qr):toBe("RESPONSE")
		test.expect(response.header.id):toBe(message.header.id)
		test.expect(tostring(response.header.rcode)):toBe("NoError")
		test.expect(#response.answers > 0):toBeTrue()
		test.expect(hasAnswerType(response, "A")):toBeTrue()
	end)
end)

suite:test("queryUdp can send EDNS and parse an OPT response", function()
	withLiveDns(function()
		local message = dns.query.prepareQuery({
			{ name = "example.org", type = "DNSKEY", class = "IN" },
		}, {
			edns = {
				udpPayloadSize = 1232,
				dnssecOk = true,
			},
		})
		local response = dns.query.queryUdp("1.1.1.1", message, {
			timeout = 10,
			useTcpIfTruncated = true,
		})

		test.expect(response.header.qr):toBe("RESPONSE")
		test.expect(response.header.id):toBe(message.header.id)
		test.expect(tostring(response.header.rcode)):toBe("NoError")
		test.expect(hasOptRecord(response)):toBeTrue()
	end)
end)

suite:test("zoneTransferAxfr returns records for zonetransfer.me", function()
	withLiveDns(function()
		local answers = dns.query.zoneTransferAxfr("nsztm1.digi.ninja", "zonetransfer.me", {
			timeout = 20,
		})

		test.expect(#answers > 0):toBeTrue()
		test.expect(tostring(answers[1].type)):toBe("SOA")

		local sawNs = false
		local sawTxt = false
		for _, answer in answers do
			if tostring(answer.type) == "NS" then
				sawNs = true
			elseif tostring(answer.type) == "TXT" then
				sawTxt = true
			end
		end

		test.expect(sawNs):toBeTrue()
		test.expect(sawTxt):toBeTrue()
	end)
end)

return suite
