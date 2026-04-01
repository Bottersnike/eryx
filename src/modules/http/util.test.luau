local test = require("@eryx/test")
local util = require("./util")

local suite = test.Suite.new("http util")

suite:test("encodeQuery: percent-encodes values and repeats array entries", function()
	local encoded = util.encodeQuery({
		page = 2,
		q = "hello world",
		tag = { "alpha", "beta/gamma" },
	})

	test.expect(encoded):toBe("page=2&q=hello%20world&tag=alpha&tag=beta%2Fgamma")
end)

suite:test("appendQuery: appends parameters onto an existing URL", function()
	local url = util.appendQuery("https://example.com/search?lang=en", {
		page = 2,
		q = "hello world",
	})

	test.expect(url):toBe("https://example.com/search?lang=en&page=2&q=hello%20world")
end)

suite:test("encodeForm: uses plus for spaces", function()
	local encoded = util.encodeForm({
		name = "Jane Doe",
		role = "site admin",
	})

	test.expect(encoded):toBe("name=Jane+Doe&role=site+admin")
end)

suite:test("decodeForm: decodes repeated keys into arrays", function()
	local decoded = util.decodeForm("name=Jane+Doe&tag=a&tag=b")

	test.expect(decoded.name):toBe("Jane Doe")
	test.expect(type(decoded.tag)):toBe("table")
	test.expect((decoded.tag :: { string })[1]):toBe("a")
	test.expect((decoded.tag :: { string })[2]):toBe("b")
end)

suite:test("parseRequestTarget: splits path and query string", function()
	local parsed = util.parseRequestTarget("/submit?name=Jane+Doe&tag=a&tag=b")

	test.expect(parsed.path):toBe("/submit")
	test.expect(parsed.queryString):toBe("name=Jane+Doe&tag=a&tag=b")
	test.expect(parsed.query.name):toBe("Jane Doe")
	test.expect(type(parsed.query.tag)):toBe("table")
end)

suite:test("parseContentType: extracts media type and parameters", function()
	local parsed = util.parseContentType('multipart/form-data; boundary="abc123"; charset=utf-8')

	test.expect(parsed.mediaType):toBe("multipart/form-data")
	test.expect(parsed.params.boundary):toBe("abc123")
	test.expect(parsed.params.charset):toBe("utf-8")
end)

return suite
