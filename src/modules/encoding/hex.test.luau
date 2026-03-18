local hex = require("@eryx/encoding/hex")
local test = require("@eryx/test")
local suite = test.Suite.new("hex")

suite:Test("encode: empty", function()
	test.expect(hex.encode(buffer.fromstring(""))):ToBe("")
end)

suite:Test("encode: known bytes", function()
	test.expect(hex.encode(buffer.fromstring("\xff\x0a"))):ToBe("ff0a")
end)

suite:Test("encode: ASCII string", function()
	test.expect(hex.encode(buffer.fromstring("Hello"))):ToBe("48656c6c6f")
end)

suite:Test("encode: accepts string directly", function()
	test.expect(hex.encode("Hello")):ToBe("48656c6c6f")
end)

suite:Test("decode: empty", function()
	test.expect(buffer.tostring(hex.decode(""))):ToBe("")
end)

suite:Test("decode: known bytes", function()
	test.expect(buffer.tostring(hex.decode("ff0a"))):ToBe("\xff\x0a")
end)

suite:Test("decode: uppercase accepted", function()
	test.expect(buffer.tostring(hex.decode("FF0A"))):ToBe("\xff\x0a")
end)

suite:Test("round-trip", function()
	local data = "The quick brown fox"
	test.expect(buffer.tostring(hex.decode(hex.encode(buffer.fromstring(data))))):ToBe(data)
end)

suite:Test("decode: odd length errors", function()
	test.expect(function()
		hex.decode("abc")
	end):ToError()
end)

return suite
