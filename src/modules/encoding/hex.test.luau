local hex = require("@eryx/encoding/hex")
local test = require("@eryx/test")
local suite = test.Suite.new("hex")

suite:test("encode: empty", function()
	test.expect(hex.encode(buffer.fromstring(""))):toBe("")
end)

suite:test("encode: known bytes", function()
	test.expect(hex.encode(buffer.fromstring("\xff\x0a"))):toBe("ff0a")
end)

suite:test("encode: ASCII string", function()
	test.expect(hex.encode(buffer.fromstring("Hello"))):toBe("48656c6c6f")
end)

suite:test("encode: accepts string directly", function()
	test.expect(hex.encode("Hello")):toBe("48656c6c6f")
end)

suite:test("decode: empty", function()
	test.expect(buffer.tostring(hex.decode(""))):toBe("")
end)

suite:test("decode: known bytes", function()
	test.expect(buffer.tostring(hex.decode("ff0a"))):toBe("\xff\x0a")
end)

suite:test("decode: uppercase accepted", function()
	test.expect(buffer.tostring(hex.decode("FF0A"))):toBe("\xff\x0a")
end)

suite:test("round-trip", function()
	local data = "The quick brown fox"
	test.expect(buffer.tostring(hex.decode(hex.encode(buffer.fromstring(data))))):toBe(data)
end)

suite:test("decode: odd length errors", function()
	test.expect(function()
		hex.decode("abc")
	end):toError()
end)

return suite
