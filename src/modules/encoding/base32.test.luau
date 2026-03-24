local base32 = require("@eryx/encoding/base32")
local test = require("@eryx/test")
local suite = test.Suite.new("base32")

suite:test("encode: empty", function()
	test.expect(base32.encode(buffer.fromstring(""))):toBe("")
end)

suite:test("encode: known vector", function()
	-- RFC 4648: "Hello" -> "JBSWY3DP"
	test.expect(base32.encode(buffer.fromstring("Hello"))):toBe("JBSWY3DP")
end)

suite:test("encode: single byte 'f'", function()
	-- 'f' = 0x66 = 01100110; top 5 bits = 01100 = 12 = 'M'; remaining 3 bits = 110 << 2 = 11000 = 24 = 'Y'
	test.expect(base32.encode(buffer.fromstring("f"))):toBe("MY")
end)

suite:test("decode: empty", function()
	test.expect(buffer.tostring(base32.decode(""))):toBe("")
end)

suite:test("round-trip", function()
	local data = "The quick brown fox jumps"
	test.expect(buffer.tostring(base32.decode(base32.encode(buffer.fromstring(data))))):toBe(data)
end)

suite:test("decode: ignores padding =", function()
	-- JBSWY3DP== -> same as without padding
	test.expect(buffer.tostring(base32.decode("JBSWY3DP=="))):toBe("Hello")
end)

return suite
