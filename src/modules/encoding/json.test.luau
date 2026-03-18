local json = require("@eryx/encoding/json")
local test = require("@eryx/test")
local suite = test.Suite.new("json")

suite:Test("encode: nil -> null", function()
	test.expect(json.encode(nil)):ToBe("null")
end)

suite:Test("encode: boolean true", function()
	test.expect(json.encode(true)):ToBe("true")
end)

suite:Test("encode: boolean false", function()
	test.expect(json.encode(false)):ToBe("false")
end)

suite:Test("encode: integer", function()
	test.expect(json.encode(42)):ToBe("42")
end)

suite:Test("encode: float", function()
	test.expect(json.encode(1.5)):ToBe("1.5")
end)

suite:Test("encode: string", function()
	test.expect(json.encode("hello")):ToBe('"hello"')
end)

suite:Test("encode: string with escapes", function()
	test.expect(json.encode('say "hi"')):ToBe('"say \\"hi\\""')
end)

suite:Test("encode: empty array", function()
	test.expect(json.encode({})):ToBe("[]")
end)

suite:Test("encode: array", function()
	test.expect(json.encode({ 1, 2, 3 })):ToBe("[1,2,3]")
end)

suite:Test("encode: nested array", function()
	test.expect(json.encode({ { 1, 2 }, { 3, 4 } })):ToBe("[[1,2],[3,4]]")
end)

suite:Test("encode: object sorted keys", function()
	test.expect(json.encode({ a = 1, b = 2 }, { sortKeys = true })):ToBe('{"a":1,"b":2}')
end)

suite:Test("encode: NaN errors", function()
	test.expect(function()
		json.encode(0 / 0)
	end):ToError()
end)

suite:Test("encode: Infinity errors", function()
	test.expect(function()
		json.encode(math.huge)
	end):ToError()
end)

suite:Test("decode: null -> nil", function()
	test.expect(json.decode("null")):ToBeNil()
end)

suite:Test("decode: true", function()
	test.expect(json.decode("true")):ToBeTrue()
end)

suite:Test("decode: false", function()
	test.expect(json.decode("false")):ToBeFalse()
end)

suite:Test("decode: integer", function()
	test.expect(json.decode("42")):ToBe(42)
end)

suite:Test("decode: float", function()
	test.expect(json.decode("3.14")):ToBe(3.14)
end)

suite:Test("decode: string", function()
	test.expect(json.decode('"hello"')):ToBe("hello")
end)

suite:Test("decode: escape sequences", function()
	test.expect(json.decode('"a\\nb"')):ToBe("a\nb")
end)

suite:Test("decode: array", function()
	local t = json.decode("[1,2,3]")
	test.expect(t[1]):ToBe(1)
	test.expect(t[2]):ToBe(2)
	test.expect(t[3]):ToBe(3)
end)

suite:Test("decode: object", function()
	local t = json.decode('{"x":10,"y":20}')
	test.expect(t.x):ToBe(10)
	test.expect(t.y):ToBe(20)
end)

suite:Test("decode: nested", function()
	local t = json.decode('{"a":{"b":42}}')
	test.expect(t.a.b):ToBe(42)
end)

suite:Test("round-trip: complex value", function()
	local original = { name = "Alice", scores = { 100, 97 }, active = true }
	local decoded = json.decode(json.encode(original))
	test.expect(decoded.name):ToBe("Alice")
	test.expect(decoded.active):ToBeTrue()
	test.expect(decoded.scores[1]):ToBe(100)
	test.expect(decoded.scores[2]):ToBe(97)
end)

suite:Test("decode: empty string errors", function()
	test.expect(function()
		json.decode("")
	end):ToError()
end)

suite:Test("decode: trailing data errors", function()
	test.expect(function()
		json.decode("1 2")
	end):ToError()
end)

return suite
