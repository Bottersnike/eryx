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

suite:test("encode: empty table defaults to object", function()
	test.expect(json.encode({})):toBe("{}")
end)

suite:test("encode: explicitly marked empty array", function()
	test.expect(json.encode(json.tableAsArray({}))):toBe("[]")
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

suite:test("decode: raw control characters in strings error", function()
	test.expect(function()
		json.decode('"' .. string.char(1) .. '"')
	end):toError()
end)

suite:test("decode: JSON5 extra whitespace", function()
	local nbsp = utf8.char(0x00A0)
	local emSpace = utf8.char(0x2003)
	local bom = utf8.char(0xFEFF)
	local lineSeparator = utf8.char(0x2028)
	local source = bom .. emSpace .. "[" .. nbsp .. "1," .. lineSeparator .. "2" .. emSpace .. "]"
	local t = json.decode(source, { json5Whitespace = true })
	test.expect(t[1]):toBe(1)
	test.expect(t[2]):toBe(2)
end)

suite:test("decode: JSON5 extra whitespace requires option", function()
	local nbsp = utf8.char(0x00A0)
	test.expect(function()
		json.decode("[" .. nbsp .. "1]")
	end):toError()
end)

suite:test("decode: JSON5 string escapes", function()
	test.expect(json.decode('"\\x41\\v\\0"', { json5Escapes = true })):toBe("A\v\0")
end)

suite:test("decode: JSON5 arbitrary escaped characters", function()
	test.expect(json.decode('"\\a\\\'"', { json5Escapes = true })):toBe("a'")
end)

suite:test("decode: JSON5 \\0 escape rejects following decimal digit", function()
	test.expect(function()
		json.decode('"\\01"', { json5Escapes = true })
	end):toError()
end)

suite:test("decode: JSON5 \\x escape requires option", function()
	test.expect(function()
		json.decode('"\\x41"')
	end):toError()
	test.expect(function()
		json.decode('"\\v"')
	end):toError()
	test.expect(function()
		json.decode('"\\0"', {})
	end):toError()
	test.expect(function()
		json.decode('"\\a"')
	end):toError()
	test.expect(function()
		json.decode('"\\\'"')
	end):toError()
end)

suite:test("decode: multiline string", function()
	test.expect(json.decode('"a\\\nb"', { multilineStrings = true })):toBe("ab")
end)

suite:test("decode: multiline strings require option", function()
	test.expect(function()
		json.decode('"a\\\nb"')
	end):toError()
end)

suite:test("decode: multiline string with JSON5 line separators", function()
	local ls = utf8.char(0x2028)
	local ps = utf8.char(0x2029)
	test.expect(json.decode('"a\\' .. ls .. 'b"', { multilineStrings = true })):toBe("ab")
	test.expect(json.decode('"a\\' .. ps .. 'b"', { multilineStrings = true })):toBe("ab")
end)

suite:test("decode: unescaped line terminators in strings error", function()
	local ls = utf8.char(0x2028)
	local ps = utf8.char(0x2029)
	test.expect(function()
		json.decode('"' .. "\n" .. '"')
	end):toError()
	test.expect(function()
		json.decode('"' .. ls .. '"', { json5Whitespace = true })
	end):toError()
	test.expect(function()
		json.decode('"' .. ps .. '"', { json5Whitespace = true })
	end):toError()
end)

suite:test("decode: array", function()
	local t = json.decode("[1,2,3]")
	test.expect(t[1]):toBe(1)
	test.expect(t[2]):toBe(2)
	test.expect(t[3]):toBe(3)
	test.expect(json.tableIsArray(t)):toBeTrue()
end)

suite:test("decode: object", function()
	local t = json.decode('{"x":10,"y":20}')
	test.expect(t.x):toBe(10)
	test.expect(t.y):toBe(20)
	test.expect(json.tableIsArray(t)):toBeFalse()
end)

suite:test("decode: empty array identity", function()
	local t = json.decode("[]")
	test.expect(json.tableIsArray(t)):toBeTrue()
end)

suite:test("decode: empty object identity", function()
	local t = json.decode("{}")
	test.expect(json.tableIsArray(t)):toBeFalse()
end)

suite:test("tableAsArray: non-empty object errors", function()
	test.expect(function()
		json.tableAsArray({ a = 1 } :: any)
	end):toError()
end)

suite:test("decode: nested", function()
	local t = json.decode('{"a":{"b":42}}')
	test.expect(t.a.b):toBe(42)
end)

suite:test("decode: comments", function()
	local t = json.decode(
		[[
// comment
{"a" //comment
	: /* comment */
	{"b": /* comment */
42
} // comment
}
]],
		{ comments = true }
	)
	test.expect(t.a.b):toBe(42)
end)

suite:test("decode: JSON5 comments end at Unicode line separators", function()
	local ls = utf8.char(0x2028)
	local t = json.decode("// comment" .. ls .. '{"a":1}', { comments = true, json5Whitespace = true })
	test.expect(t.a):toBe(1)
end)

suite:test("decode: comments require option", function()
	test.expect(function()
		json.decode("// comment\n1")
	end):toError()
	test.expect(function()
		json.decode("/* comment */1")
	end):toError()
end)

suite:test("decode: single-quoted", function()
	local t = json.decode("{'a':{'b':'c'}}", { singleQuotedStrings = true })
	test.expect(t.a.b):toBe("c")
end)

suite:test("decode: single-quoted strings require option", function()
	test.expect(function()
		json.decode("'hello'")
	end):toError()
end)

suite:test("decode: single-quoted strings still need JSON5 escape flag for extra escapes", function()
	test.expect(function()
		json.decode("'\\a'", { singleQuotedStrings = true })
	end):toError()
end)

suite:test("decode: unquoted ASCII keys", function()
	local t = json.decode("{foo:1, bar_baz:2, $qux9:3}", { unquotedKeys = true })
	test.expect(t.foo):toBe(1)
	test.expect(t.bar_baz):toBe(2)
	test.expect(t["$qux9"]):toBe(3)
end)

suite:test("decode: unquoted reserved-word-style keys", function()
	local t = json.decode("{null:1, true:2, while:3}", { unquotedKeys = true })
	test.expect(t["null"]):toBe(1)
	test.expect(t["true"]):toBe(2)
	test.expect(t["while"]):toBe(3)
end)

suite:test("decode: unquoted Unicode keys", function()
	local t = json.decode("{π:1, mañana:2, e\u{0301}:3, a١:4}", { unquotedKeys = true })
	test.expect(t["π"]):toBe(1)
	test.expect(t["mañana"]):toBe(2)
	test.expect(t["e\u{0301}"]):toBe(3)
	test.expect(t["a١"]):toBe(4)
end)

suite:test("decode: unquoted keys with Unicode escapes", function()
	local t = json.decode("{\\u03C0:1, ma\\u00F1ana:2, a\\u0661:3}", { unquotedKeys = true })
	test.expect(t["π"]):toBe(1)
	test.expect(t["mañana"]):toBe(2)
	test.expect(t["a١"]):toBe(3)
end)

suite:test("decode: unquoted keys require option", function()
	test.expect(function()
		json.decode("{foo:1}")
	end):toError()
	test.expect(function()
		json.decode("{\\u03C0:1}")
	end):toError()
end)

suite:test("decode: unquoted keys reject invalid ASCII start", function()
	test.expect(function()
		json.decode("{1abc:1}", { unquotedKeys = true })
	end):toError()
end)

suite:test("decode: unquoted keys reject invalid Unicode start", function()
	test.expect(function()
		json.decode("{١abc:1}", { unquotedKeys = true })
	end):toError()
end)

suite:test("decode: unquoted keys reject invalid Unicode escapes", function()
	test.expect(function()
		json.decode("{\\u0030abc:1}", { unquotedKeys = true })
	end):toError()
	test.expect(function()
		json.decode("{ab\\u002Dcd:1}", { unquotedKeys = true })
	end):toError()
	test.expect(function()
		json.decode("{\\u00G0:1}", { unquotedKeys = true })
	end):toError()
end)

suite:test("decode: JSON5 leading-dot number", function()
	test.expect(json.decode(".5", { json5Numbers = true })):toBe(0.5)
end)

suite:test("decode: JSON5 trailing-dot number", function()
	test.expect(json.decode("5.", { json5Numbers = true })):toBe(5)
end)

suite:test("decode: JSON5 exponent after trailing dot", function()
	test.expect(json.decode("5.e2", { json5Numbers = true })):toBe(500)
end)

suite:test("decode: JSON5 signed leading-dot number", function()
	test.expect(json.decode("+.5", { json5Numbers = true })):toBe(0.5)
	test.expect(json.decode("-.5", { json5Numbers = true })):toBe(-0.5)
end)

suite:test("decode: JSON5 hex number", function()
	test.expect(json.decode("0x2A", { json5Numbers = true })):toBe(42)
	test.expect(json.decode("-0X2A", { json5Numbers = true })):toBe(-42)
end)

suite:test("decode: JSON5 bare dot errors", function()
	test.expect(function()
		json.decode(".", { json5Numbers = true })
	end):toError()
end)

suite:test("decode: JSON5 number forms require option", function()
	test.expect(function()
		json.decode(".5")
	end):toError()
	test.expect(function()
		json.decode("5.")
	end):toError()
	test.expect(function()
		json.decode("+1")
	end):toError()
	test.expect(function()
		json.decode("0x2A")
	end):toError()
	test.expect(function()
		json.decode("Infinity")
	end):toError()
	test.expect(function()
		json.decode("NaN")
	end):toError()
end)

suite:test("decode: leading-dot number requires JSON5 option", function()
	test.expect(function()
		json.decode(".5")
	end):toError()
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

suite:test("decode: trailing commas require option", function()
	test.expect(function()
		json.decode("[1,2,]")
	end):toError()
	test.expect(function()
		json.decode('{"a":1,}')
	end):toError()
end)

suite:test("decode: JSON5 preset enables JSON5 feature bundle", function()
	local value = json.decode("{foo: 'bar', hex: 0x2A, trailing: [1,2,], // hi\n more: +.5}", json.JSON5)
	test.expect(value.foo):toBe("bar")
	test.expect(value.hex):toBe(42)
	test.expect(value.trailing[2]):toBe(2)
	test.expect(value.more):toBe(0.5)
end)

suite:test("decode: JSONC preset enables comments and trailing commas only", function()
	local value = json.decode(
		[[// hi
{"a": 1,}
]],
		json.JSONC
	)
	test.expect(value.a):toBe(1)

	test.expect(function()
		json.decode("{foo:1}", json.JSONC)
	end):toError()
	test.expect(function()
		json.decode("'hi'", json.JSONC)
	end):toError()
end)

return suite
