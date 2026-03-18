local url = require("@eryx/encoding/url")
local test = require("@eryx/test")
local suite = test.Suite.new("url")

suite:Test("encode: space as %20", function()
	test.expect(url.encode("hello world", false)):ToBe("hello%20world")
end)

suite:Test("encode: space as +", function()
	test.expect(url.encode("hello world", true)):ToBe("hello+world")
end)

suite:Test("encode: special characters", function()
	test.expect(url.encode("a&b=c", false)):ToBe("a%26b%3Dc")
end)

suite:Test("encode: unreserved chars unchanged", function()
	test.expect(url.encode("Hello-World_2.0~", false)):ToBe("Hello-World_2.0~")
end)

suite:Test("decode: %20 to space", function()
	test.expect(url.decode("hello%20world", false)):ToBe("hello world")
end)

suite:Test("decode: + to space when plusIsSpace", function()
	test.expect(url.decode("hello+world", true)):ToBe("hello world")
end)

suite:Test("decode: + unchanged when not plusIsSpace", function()
	test.expect(url.decode("hello+world", false)):ToBe("hello+world")
end)

suite:Test("round-trip", function()
	local orig = "foo bar/baz?q=1&r=2"
	test.expect(url.decode(url.encode(orig, false), false)):ToBe(orig)
end)

return suite
