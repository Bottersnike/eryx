local base85 = require("@eryx/encoding/base85")
local test = require("@eryx/test")
local suite = test.Suite.new("base85")

suite:Test("encode: empty", function()
	test.expect(base85.encode(buffer.fromstring(""))):ToBe("")
end)

suite:Test("round-trip: 4 bytes", function()
	local data = "\x86\x4f\xd2\x6f"
	local encoded = base85.encode(buffer.fromstring(data))
	test.expect(#encoded):ToBe(5)
	test.expect(buffer.tostring(base85.decode(encoded))):ToBe(data)
end)

suite:Test("round-trip: 8 bytes", function()
	local data = "abcdefgh"
	local encoded = base85.encode(buffer.fromstring(data))
	test.expect(#encoded):ToBe(10)
	test.expect(buffer.tostring(base85.decode(encoded))):ToBe(data)
end)

suite:Test("encode: non-multiple-of-4 errors", function()
	test.expect(function()
		base85.encode(buffer.fromstring("abc"))
	end):ToError()
end)

suite:Test("decode: non-multiple-of-5 errors", function()
	test.expect(function()
		base85.decode("abcd")
	end):ToError()
end)

return suite
