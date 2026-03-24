local url = require("@eryx/encoding/url")
local test = require("@eryx/test")
local suite = test.Suite.new("url")

suite:test("encode: space as %20", function()
	test.expect(url.encode("hello world", false)):toBe("hello%20world")
end)

suite:test("encode: space as +", function()
	test.expect(url.encode("hello world", true)):toBe("hello+world")
end)

suite:test("encode: special characters", function()
	test.expect(url.encode("a&b=c", false)):toBe("a%26b%3Dc")
end)

suite:test("encode: unreserved chars unchanged", function()
	test.expect(url.encode("Hello-World_2.0~", false)):toBe("Hello-World_2.0~")
end)

suite:test("decode: %20 to space", function()
	test.expect(url.decode("hello%20world", false)):toBe("hello world")
end)

suite:test("decode: + to space when plusIsSpace", function()
	test.expect(url.decode("hello+world", true)):toBe("hello world")
end)

suite:test("decode: + unchanged when not plusIsSpace", function()
	test.expect(url.decode("hello+world", false)):toBe("hello+world")
end)

suite:test("round-trip", function()
	local orig = "foo bar/baz?q=1&r=2"
	test.expect(url.decode(url.encode(orig, false), false)):toBe(orig)
end)

return suite
