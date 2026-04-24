local json = require("@eryx/data/json")
local test = require("@eryx/test")
local suite = test.Suite.new("json")

suite:test("encode: nil -> null", function()
	test.expect(json.encode(nil)):toBe("null")
end)

suite:test("encode: boolean true", function()
	test.expect(json.encode(true)):toBe("true")
end)

suite:test("encode: boolean false", function()
	test.expect(json.encode(false)):toBe("false")
end)

suite:test("encode: integer", function()
	test.expect(json.encode(42)):toBe("42")
end)

suite:test("encode: float", function()
	test.expect(json.encode(1.5)):toBe("1.5")
end)

suite:test("encode: string", function()
	test.expect(json.encode("hello")):toBe('"hello"')
end)

suite:test("encode: string with escapes", function()
	test.expect(json.encode('say "hi"')):toBe('"say \\"hi\\""')
end)

suite:test("encode: empty array", function()
	test.expect(json.encode({})):toBe("[]")
end)

suite:test("encode: array", function()
	test.expect(json.encode({ 1, 2, 3 })):toBe("[1,2,3]")
end)

suite:test("encode: nested array", function()
	test.expect(json.encode({ { 1, 2 }, { 3, 4 } })):toBe("[[1,2],[3,4]]")
end)

suite:test("encode: object sorted keys", function()
	test.expect(json.encode({ a = 1, b = 2 }, { sortKeys = true })):toBe('{"a":1,"b":2}')
end)

suite:test("encode: NaN errors", function()
	test.expect(function()
		json.encode(0 / 0)
	end):toError()
end)

suite:test("encode: Infinity errors", function()
	test.expect(function()
		json.encode(math.huge)
	end):toError()
end)

suite:test("decode: null -> nil", function()
	test.expect(json.decode("null")):toBeNil()
end)

suite:test("decode: true", function()
	test.expect(json.decode("true")):toBeTrue()
end)

suite:test("decode: false", function()
	test.expect(json.decode("false")):toBeFalse()
end)

suite:test("decode: integer", function()
	test.expect(json.decode("42")):toBe(42)
end)

suite:test("decode: float", function()
	test.expect(json.decode("3.14")):toBe(3.14)
end)

suite:test("decode: string", function()
	test.expect(json.decode('"hello"')):toBe("hello")
end)

suite:test("decode: escape sequences", function()
	test.expect(json.decode('"a\\nb"')):toBe("a\nb")
end)

suite:test("decode: array", function()
	local t = json.decode("[1,2,3]")
	test.expect(t[1]):toBe(1)
	test.expect(t[2]):toBe(2)
	test.expect(t[3]):toBe(3)
end)

suite:test("decode: object", function()
	local t = json.decode('{"x":10,"y":20}')
	test.expect(t.x):toBe(10)
	test.expect(t.y):toBe(20)
end)

suite:test("decode: nested", function()
	local t = json.decode('{"a":{"b":42}}')
	test.expect(t.a.b):toBe(42)
end)

suite:test("round-trip: complex value", function()
	local original = { name = "Alice", scores = { 100, 97 }, active = true }
	local decoded = json.decode(json.encode(original))
	test.expect(decoded.name):toBe("Alice")
	test.expect(decoded.active):toBeTrue()
	test.expect(decoded.scores[1]):toBe(100)
	test.expect(decoded.scores[2]):toBe(97)
end)

suite:test("decode: empty string errors", function()
	test.expect(function()
		json.decode("")
	end):toError()
end)

suite:test("decode: trailing data errors", function()
	test.expect(function()
		json.decode("1 2")
	end):toError()
end)

return suite
