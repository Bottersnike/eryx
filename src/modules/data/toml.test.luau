local test = require("@eryx/test")
local toml = require("@eryx/data/toml") :: any

local suite = test.Suite.new("toml")

local function expectNaN(value: number)
	test.expect(value ~= value):toBeTrue()
end

suite:test("decode: parse alias", function()
	local value = toml.parse("x = 1")
	test.expect(value.x):toBe(1)
end)

suite:test("decodeCST: behaves like decoded table", function()
	local value = toml.decodeCST("foo.bar = 5")
	test.expect(value.foo.bar):toBe(5)
	test.expect(toml.isCSTObject(value)):toBeTrue()
end)

suite:test("decodeCST: untouched encode preserves exact whitespace", function()
	local source = "foo.bar=5\n"
	local value = toml.decodeCST(source)
	local encoded = toml.encode(value)
	test.expect(encoded):toBe(source)
end)

suite:test("decodeCST: scalar rewrite preserves line whitespace and inline comment", function()
	local source = "foo.bar=5 # note\n"
	local value = toml.decodeCST(source)
	value.foo.bar = 7
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("foo.bar=7 # note\n")
end)

suite:test("decodeCST: scalar rewrite preserves header formatting", function()
	local source = "[foo]\nbar\t=\t5\n"
	local value = toml.decodeCST(source)
	value.foo.bar = 9
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("[foo]\nbar\t=\t9\n")
end)

suite:test("decodeCST: scalar deletion patches line in place", function()
	local source = "a=1\nb=2\n"
	local value = toml.decodeCST(source)
	value.b = nil
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("a=1\n")
end)

suite:test("decodeCST: top-level scalar insertion appends", function()
	local source = "a=1\n"
	local value = toml.decodeCST(source)
	value.c = 3
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("a=1\nc = 3")
end)

suite:test("decodeCST: nested scalar insertion goes into existing header section", function()
	local source = "[foo]\nbar=1\n[bar]\nx=2\n"
	local value = toml.decodeCST(source)
	value.foo.baz = 3
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("[foo]\nbar=1\nbaz = 3\n[bar]\nx=2\n")
end)

suite:test("decodeCST: multiple nested insertions preserve assignment order", function()
	local source = "[foo]\nbar=1\n"
	local value = toml.decodeCST(source)
	value.foo.b = 2
	value.foo.c = 3
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("[foo]\nbar=1\nb = 2\nc = 3\n")
end)

suite:test("decodeCST: comment metadata patches existing line without full reencode", function()
	local source = "x=1\n"
	local value = toml.decodeCST(source)
	toml.cstSetComment(value, "x", "patched", "inline")
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("x=1 # patched\n")
end)

suite:test("decodeCST: comment metadata before/after patches existing line", function()
	local source = "x=1\n"
	local value = toml.decodeCST(source)
	toml.cstSetComment(value, "x", "before", "before")
	toml.cstSetComment(value, "x", "after", "after")
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("# before\nx=1\n# after\n")
end)

suite:test("decodeCST: nested insertion creates missing section header when needed", function()
	local source = "foo.bar=1\n"
	local value = toml.decodeCST(source)
	value.foo.baz = 2
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("foo.bar=1\n[foo]\nbaz = 2\n")
end)

suite:test("decodeCST: deletion cleanup avoids extra blank-line gaps", function()
	local source = "a=1\n\nb=2\n\n[foo]\nx=1\n"
	local value = toml.decodeCST(source)
	value.b = nil
	local encoded = toml.encode(value)
	test.expect(encoded):toBe("a=1\n\n[foo]\nx=1\n")
end)

suite:test("decodeCST: mutations remain table-like and default to header style", function()
	local value = toml.decodeCST("[foo]\nbar=5\nbaz = 2\n")
	value.foo.meow = 5

	local encoded = toml.encode(value)
	test.expect(encoded:find("%[foo%]") ~= nil):toBeTrue()
	test.expect(encoded:find("foo%.meow") == nil):toBeTrue()

	local reparsed = toml.decode(encoded)
	test.expect(reparsed.foo.meow):toBe(5)
end)

suite:test("newCST: construct document using table operations", function()
	local value = toml.newCST()
	value.foo = {}
	value.foo.bar = 5

	local encoded = toml.encode(value)
	test.expect(encoded):toBe("[foo]\nbar = 5")
end)

suite:test("CST API: toTable returns detached plain clone", function()
	local value = toml.decodeCST("[foo]\nbar = 5\n")
	local plain = toml.cstToTable(value)
	test.expect(plain.foo.bar):toBe(5)
	plain.foo.bar = 9
	test.expect(value.foo.bar):toBe(5)
end)

suite:test("CST API: style metadata set/get", function()
	local value = toml.newCST()
	toml.cstSetStyle(value, "foo.bar", "dotted")
	test.expect(toml.cstGetStyle(value, { "foo", "bar" })):toBe("dotted")
end)

suite:test("CST API: comment metadata set/get", function()
	local value = toml.newCST()
	toml.cstSetComment(value, { "foo", "bar" }, "hello", "inline")
	test.expect(toml.cstGetComment(value, "foo.bar", "inline")):toBe("hello")
end)

suite:test("CST encode: dotted style can force dotted output for isolated key", function()
	local value = toml.newCST()
	value.foo = {}
	value.foo.bar = 5
	toml.cstSetStyle(value, "foo.bar", "dotted")

	local encoded = toml.encode(value)
	test.expect(encoded):toBe("foo.bar = 5")
end)

suite:test("CST encode: inline comments are emitted", function()
	local value = toml.newCST()
	value.foo = {}
	value.foo.bar = 5
	toml.cstSetComment(value, "foo.bar", "keep me", "inline")

	local encoded = toml.encode(value)
	test.expect(encoded):toBe("[foo]\nbar = 5 # keep me")
end)

suite:test("CST encode: before comments are emitted", function()
	local value = toml.newCST()
	value.foo = {}
	value.foo.bar = 5
	toml.cstSetComment(value, "foo", "section comment", "before")

	local encoded = toml.encode(value)
	test.expect(encoded):toBe("# section comment\n[foo]\nbar = 5")
end)

suite:test("decode: dotted key creates nested table", function()
	local value = toml.decode("foo.bar = 5")
	test.expect(value.foo.bar):toBe(5)
end)

suite:test("decode: table header creates same structure as dotted key", function()
	local dotted = toml.decode("foo.bar = 5")
	local header = toml.decode("[foo]\nbar = 5")

	test.expect(dotted.foo.bar):toBe(5)
	test.expect(header.foo.bar):toBe(5)
	test.expect(toml.encode(dotted)):toBe(toml.encode(header))
end)

suite:test("encode: prefers explicit table headers", function()
	local source = toml.encode({
		foo = {
			bar = 5,
		},
	})
	test.expect(source):toBe("[foo]\nbar = 5")
end)

suite:test("decode: integers in decimal and bases", function()
	local value = toml.decode("a = +10\nb = -17\nc = 1_000\nd = 0xDEAD_BEEF\ne = 0o755\nf = 0b1011")
	test.expect(value.a):toBe(10)
	test.expect(value.b):toBe(-17)
	test.expect(value.c):toBe(1000)
	test.expect(value.d):toBe(3735928559)
	test.expect(value.e):toBe(493)
	test.expect(value.f):toBe(11)
end)

suite:test("decode: floats and exponents", function()
	local value = toml.decode("a = 3.1415\nb = -2E-2\nc = 6.626e-34\nd = 224_617.445_991_228")
	test.expect(value.a):toBe(3.1415)
	test.expect(value.b):toBe(-0.02)
	test.expect(value.c):toBe(6.626e-34)
	test.expect(value.d):toBe(224617.445991228)
end)

suite:test("decode: special floats", function()
	local value = toml.decode("a = inf\nb = -inf\nc = nan\nd = +nan\ne = -nan")
	test.expect(value.a):toBe(math.huge)
	test.expect(value.b):toBe(-math.huge)
	expectNaN(value.c)
	expectNaN(value.d)
	expectNaN(value.e)
end)

suite:test("decode: booleans", function()
	local value = toml.decode("yes = true\nno = false")
	test.expect(value.yes):toBeTrue()
	test.expect(value.no):toBeFalse()
end)

suite:test("decode: datetime-like tokens preserved as strings", function()
	local value = toml.decode("odt = 1979-05-27T07:32:00Z\nldt = 1979-05-27T07:32:00\nld = 1979-05-27\nlt = 07:32:00")
	test.expect(value.odt):toBe("1979-05-27T07:32:00Z")
	test.expect(value.ldt):toBe("1979-05-27T07:32:00")
	test.expect(value.ld):toBe("1979-05-27")
	test.expect(value.lt):toBe("07:32:00")
end)

suite:test("decode: basic strings and escapes", function()
	local value = toml.decode('a = "line\\nnext"\nb = "tab\\tindent"\nc = "quote:\\""\nd = "\\x41\\u03B1"')
	test.expect(value.a):toBe("line\nnext")
	test.expect(value.b):toBe("tab\tindent")
	test.expect(value.c):toBe('quote:"')
	test.expect(value.d):toBe("Aα")
end)

suite:test("decode: literal strings", function()
	local value = toml.decode("a = 'C:\\Users\\name\\file'\nb = 'raw \\n text'")
	test.expect(value.a):toBe("C:\\Users\\name\\file")
	test.expect(value.b):toBe("raw \\n text")
end)

suite:test("decode: comments and whitespace", function()
	local value =
		toml.decode("# header\n foo . bar\t=\t5   # tail\n[foo.baz] # table tail comment\nx = 2 # x comment\n")
	test.expect(value.foo.bar):toBe(5)
	test.expect(value.foo.baz.x):toBe(2)
end)

suite:test("decode: arrays and inline tables", function()
	local value = toml.decode('items = [1, 2, { name = "x", count = 4 }]')
	test.expect(value.items[1]):toBe(1)
	test.expect(value.items[2]):toBe(2)
	test.expect(value.items[3].name):toBe("x")
	test.expect(value.items[3].count):toBe(4)
end)

suite:test("decode: multiline arrays with comments and trailing commas", function()
	local value = toml.decode("items = [\n  1,\n  2, # hi\n  3,\n]\n")
	test.expect(value.items[1]):toBe(1)
	test.expect(value.items[2]):toBe(2)
	test.expect(value.items[3]):toBe(3)
end)

suite:test("decode: inline table with dotted keys", function()
	local value = toml.decode("obj = { a.b = 1, c = 2 }")
	test.expect(value.obj.a.b):toBe(1)
	test.expect(value.obj.c):toBe(2)
end)

suite:test("decode: implied super tables from deep header", function()
	local value = toml.decode("[x.y.z]\na = 9")
	test.expect(value.x.y.z.a):toBe(9)
end)

suite:test("decode: quoted keys", function()
	local value = toml.decode('["foo.bar"]\n"baz qux" = true')
	test.expect(value["foo.bar"]["baz qux"]):toBeTrue()
end)

suite:test("encode: scalar root values", function()
	local encoded = toml.encode({ b = true, a = 1, c = "ok" })
	test.expect(encoded):toBe('a = 1\nb = true\nc = "ok"')
end)

suite:test("encode: escapes control characters", function()
	local encoded = toml.encode({ msg = 'line1\nline2\t"q"' })
	test.expect(encoded):toBe('msg = "line1\\nline2\\t\\"q\\""')
end)

suite:test("encode: quoted keys when needed", function()
	local encoded = toml.encode({
		["a b"] = 1,
		foo = {
			["bar.baz"] = 2,
		},
	})
	test.expect(encoded):toBe('"a b" = 1\n\n[foo]\n"bar.baz" = 2')
end)

suite:test("encode: arrays and inline tables", function()
	local encoded = toml.encode({
		items = {
			1,
			{ x = 1, y = 2 },
			"z",
		},
	})
	test.expect(encoded):toBe('items = [1, {x = 1, y = 2}, "z"]')
end)

suite:test("encode: non-string table keys error", function()
	test.expect(function()
		toml.encode({ [1] = "x" } :: any)
	end):toError()
end)

suite:test("encode: non-table top-level error", function()
	test.expect(function()
		toml.encode("x" :: any)
	end):toError()
end)

suite:test("round-trip: mixed root and nested", function()
	local original = {
		name = "config",
		enabled = true,
		numbers = { 1, 2, 3 },
		foo = {
			bar = 5,
			baz = "ok",
		},
	}

	local encoded = toml.encode(original)
	local decoded = toml.decode(encoded)

	test.expect(decoded.name):toBe("config")
	test.expect(decoded.enabled):toBeTrue()
	test.expect(decoded.numbers[1]):toBe(1)
	test.expect(decoded.numbers[2]):toBe(2)
	test.expect(decoded.numbers[3]):toBe(3)
	test.expect(decoded.foo.bar):toBe(5)
	test.expect(decoded.foo.baz):toBe("ok")
end)

suite:test("round-trip: dotted input canonicalizes to header output", function()
	local decoded = toml.decode("foo.bar = 5\nfoo.baz = true")
	test.expect(toml.encode(decoded)):toBe("[foo]\nbar = 5\nbaz = true")
end)

suite:test("decode: duplicate key errors", function()
	test.expect(function()
		toml.decode("x = 1\nx = 2")
	end):toError()
end)

suite:test("decode: duplicate dotted leaf errors", function()
	test.expect(function()
		toml.decode("x.y = 1\nx.y = 2")
	end):toError()
end)

suite:test("decode: scalar cannot become table via dotted key", function()
	test.expect(function()
		toml.decode("x = 1\nx.y = 2")
	end):toError()
end)

suite:test("decode: scalar cannot become table via header", function()
	test.expect(function()
		toml.decode("x = 1\n[x]\ny = 2")
	end):toError()
end)

suite:test("decode: header redefinition errors", function()
	test.expect(function()
		toml.decode("[x]\na = 1\n[x]\nb = 2")
	end):toError()
end)

suite:test("decode: invalid bare key errors", function()
	test.expect(function()
		toml.decode("bad! = 1")
	end):toError()
end)

suite:test("decode: invalid escape errors", function()
	test.expect(function()
		toml.decode('x = "\\q"')
	end):toError()
end)

suite:test("decode: unterminated string errors", function()
	test.expect(function()
		toml.decode('x = "abc')
	end):toError()
end)

suite:test("decode: unterminated literal string errors", function()
	test.expect(function()
		toml.decode("x = 'abc")
	end):toError()
end)

suite:test("decode: unterminated array errors", function()
	test.expect(function()
		toml.decode("x = [1, 2")
	end):toError()
end)

suite:test("decode: unterminated inline table errors", function()
	test.expect(function()
		toml.decode("x = { a = 1")
	end):toError()
end)

suite:test("decode: inline table duplicate key errors", function()
	test.expect(function()
		toml.decode("x = { a = 1, a = 2 }")
	end):toError()
end)

suite:test("decode: array-of-tables basic", function()
	local value = toml.decode('[[products]]\nname = "Hammer"\n\n[[products]]\nname = "Nail"\n')
	test.expect(value.products[1].name):toBe("Hammer")
	test.expect(value.products[2].name):toBe("Nail")
end)

suite:test("decode: nested tables under array-of-tables entry", function()
	local value = toml.decode('[[fruits]]\nname = "apple"\n[fruits.physical]\ncolor = "red"')
	test.expect(value.fruits[1].name):toBe("apple")
	test.expect(value.fruits[1].physical.color):toBe("red")
end)

suite:test("decode: nested array-of-tables under array-of-tables entry", function()
	local value = toml.decode(
		'[[fruits]]\nname = "apple"\n[[fruits.varieties]]\nname = "granny smith"\n[[fruits.varieties]]\nname = "red delicious"'
	)
	test.expect(value.fruits[1].varieties[1].name):toBe("granny smith")
	test.expect(value.fruits[1].varieties[2].name):toBe("red delicious")
end)

suite:test("decode: child header before first array entry errors", function()
	test.expect(function()
		toml.decode('[fruits.physical]\ncolor = "red"\n[[fruits]]\nname = "apple"')
	end):toError()
end)

suite:test("decode: table header conflicts with existing array-of-tables", function()
	test.expect(function()
		toml.decode('[[fruits]]\nname = "apple"\n[fruits]\nname = "banana"')
	end):toError()
end)

suite:test("encode: array-of-tables emits double-bracket headers", function()
	local encoded = toml.encode({
		fruits = {
			{ name = "apple" },
			{ name = "banana" },
		},
	})
	test.expect(encoded):toBe('[[fruits]]\nname = "apple"\n\n[[fruits]]\nname = "banana"')
end)

suite:test("round-trip: array-of-tables structure", function()
	local decoded = toml.decode('[[servers]]\nhost = "a"\n\n[[servers]]\nhost = "b"\n')
	local encoded = toml.encode(decoded)
	local decodedAgain = toml.decode(encoded)
	test.expect(decodedAgain.servers[1].host):toBe("a")
	test.expect(decodedAgain.servers[2].host):toBe("b")
end)

suite:test("decode: unexpected trailing characters after header errors", function()
	test.expect(function()
		toml.decode("[x] y")
	end):toError()
end)

suite:test("decode: unexpected trailing characters after key-value errors", function()
	test.expect(function()
		toml.decode("x = 1 y")
	end):toError()
end)

suite:test("decode: invalid value token errors", function()
	test.expect(function()
		toml.decode("x = nope")
	end):toError()
end)

return suite
