--[=[
	Public API integration tests for @eryx/schema.
	Exercises exposed constructors and helpers through real parse/validate flows.
]=]
local test = require("@eryx/test")
local schema = require("@eryx/schema")
local struct = require("@eryx/schema/struct")

local suite = test.Suite.new("schema")

-- Literal
suite:test("literal: string match succeeds", function()
	local s = schema.literal("x")
	local ok, parsed = s:parse("x")
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBe("x")
end)

suite:test("literal: mismatch fails", function()
	local s = schema.literal("x")
	local ok, err = s:parse("y")
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected literal")
end)

suite:test("literal: type mismatch fails", function()
	local s = schema.literal(true)
	local ok, err = s:parse("true")
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected boolean")
end)

suite:test("literal: nil literal parses nil", function()
	local s = schema.literal(nil)
	local ok, parsed = s:parse(nil :: any)
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBeNil()
end)

-- Boolean
suite:test("boolean: true parses", function()
	local s = schema.boolean()
	local ok, parsed = s:parse(true)
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBeTrue()
end)

suite:test("boolean: non-boolean fails", function()
	local s = schema.boolean()
	local ok, err = s:parse(1)
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected boolean")
end)

-- Number
suite:test("number: non-number fails", function()
	local s = schema.number()
	local ok, err = s:parse("1")
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected number")
end)

suite:test("number: gt/gte/lt/lte constraints", function()
	local s = schema.number():gt(1):lt(5)
	local ok1 = s:validate(3)
	local ok2 = s:validate(1)
	local ok3 = s:validate(5)
	test.expect(ok1):toBeTrue()
	test.expect(ok2):toBeFalse()
	test.expect(ok3):toBeFalse()
end)

suite:test("number: positive clears previous gte", function()
	local s = schema.number():gte(100):positive()
	local ok = s:validate(1)
	test.expect(ok):toBeTrue()
end)

suite:test("number: nonnegative clears previous gt", function()
	local s = schema.number():gt(5):nonnegative()
	local ok = s:validate(0)
	test.expect(ok):toBeTrue()
end)

suite:test("number: negative clears previous lte", function()
	local s = schema.number():lte(-10):negative()
	local ok = s:validate(-1)
	test.expect(ok):toBeTrue()
end)

suite:test("number: nonpositive clears previous lt", function()
	local s = schema.number():lt(-10):nonpositive()
	local ok = s:validate(0)
	test.expect(ok):toBeTrue()
end)

suite:test("number: multipleOf works", function()
	local s = schema.number():multipleOf(3)
	test.expect(s:validate(9)):toBeTrue()
	test.expect(s:validate(10)):toBeFalse()
end)

suite:test("number: multipleOf(0) throws", function()
	test.expect(function()
		schema.number():multipleOf(0)
	end):toError("multipleOf cannot be 0")
end)

suite:test("number: int validates integers only", function()
	local s = schema.number():int()
	test.expect(s:validate(7)):toBeTrue()
	test.expect(s:validate(7.1)):toBeFalse()
end)

-- String
suite:test("string: parse non-string fails", function()
	local s = schema.string()
	local ok, err = s:parse(1)
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected string")
end)

suite:test("string: maxLen/minLen/length", function()
	local s = schema.string():minLen(2):maxLen(4)
	test.expect(s:validate("ab")):toBeTrue()
	test.expect(s:validate("a")):toBeFalse()
	test.expect(s:validate("abcde")):toBeFalse()

	local exact = s:length(3)
	test.expect(exact:validate("abc")):toBeTrue()
	test.expect(exact:validate("ab")):toBeFalse()
end)

suite:test("string: negative length guards throw", function()
	test.expect(function()
		schema.string():minLen(-1)
	end):toError("minLen cannot be negative")
	test.expect(function()
		schema.string():maxLen(-1)
	end):toError("maxLen cannot be negative")
	test.expect(function()
		schema.string():length(-1)
	end):toError("length cannot be negative")
end)

suite:test("string: match uses Lua patterns", function()
	local s = schema.string():match("^a%d+$")
	test.expect(s:validate("a123")):toBeTrue()
	test.expect(s:validate("b123")):toBeFalse()
end)

suite:test("string: startsWith/endsWith/includes", function()
	local s = schema.string():startsWith("pre"):endsWith("post"):includes("middle")
	test.expect(s:validate("pre-middle-post")):toBeTrue()
	test.expect(s:validate("xpre-middle-post")):toBeFalse()
	test.expect(s:validate("pre-middle-posx")):toBeFalse()
	test.expect(s:validate("pre-nope-post")):toBeFalse()
end)

suite:test("string: endsWith empty pattern always true", function()
	local s = schema.string():endsWith("")
	test.expect(s:validate("anything")):toBeTrue()
end)

suite:test("string: isUpperCase/isLowerCase conflict resolution", function()
	local upper = schema.string():isLowerCase():isUpperCase()
	test.expect(upper:validate("ABC")):toBeTrue()
	test.expect(upper:validate("abc")):toBeFalse()

	local lower = schema.string():isUpperCase():isLowerCase()
	test.expect(lower:validate("abc")):toBeTrue()
	test.expect(lower:validate("ABC")):toBeFalse()
end)

suite:test("string: mutators apply in order", function()
	local s = schema.string():trimWhitespace():toUpperCase():toLowerCase()
	local ok, parsed = s:parse("  HeLLo  ")
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBe("hello")
end)

suite:test("string: regex path handles availability", function()
	local s = schema.string():regex("^a+$")
	local okLoad = pcall(require, "@eryx/regex")
	local ok, errOrParsed = s:parse("bbb")
	if okLoad then
		test.expect(ok):toBeFalse()
		test.expect(errOrParsed):toContain("Expected string to match regex")
	else
		test.expect(ok):toBeFalse()
		test.expect(errOrParsed):toContain("Regex validator unavailable")
	end
end)

-- Optional
suite:test("optional: nil parses as nil", function()
	local s = schema.optional(schema.number())
	local ok, parsed = s:parse(nil :: any)
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBeNil()
end)

suite:test("optional: default fills nil", function()
	local s = schema.optional(schema.number()):default(5)
	local ok, parsed = s:parse(nil :: any)
	test.expect(ok):toBeTrue()
	test.expect(parsed):toBe(5)
end)

suite:test("optional: non-nil validated by child", function()
	local s = schema.optional(schema.number():int())
	test.expect(s:validate(4)):toBeTrue()
	test.expect(s:validate(4.5)):toBeFalse()
end)

-- AnyOf
suite:test("anyOf: schema alternatives match", function()
	local s = schema.anyOf(schema.number(), schema.string())
	test.expect(s:validate(1)):toBeTrue()
	test.expect(s:validate("x")):toBeTrue()
	test.expect(s:validate(true)):toBeFalse()
end)

suite:test("anyOf: raw literals are normalized", function()
	local s = schema.anyOf("ok", 5, true)
	test.expect(s:validate("ok")):toBeTrue()
	test.expect(s:validate(5)):toBeTrue()
	test.expect(s:validate(true)):toBeTrue()
	test.expect(s:validate(false)):toBeFalse()
end)

suite:test("anyOf: empty call throws", function()
	test.expect(function()
		(schema.anyOf :: any)()
	end):toError("anyOf requires at least one schema")
end)

suite:test("anyOf: fails with generic error message", function()
	local s = schema.anyOf(schema.number(), schema.string())
	local ok, err = s:parse({})
	test.expect(ok):toBeFalse()
	test.expect(err):toBe("Failed to match any schemas")
end)

-- Array
suite:test("array: parses valid child elements", function()
	local s = schema.array(schema.number():int())
	local ok, parsed = s:parse({ 1, 2, 3 })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed[2]):toBe(2)
end)

suite:test("array: non-table fails", function()
	local s = schema.array(schema.number())
	local ok, err = s:parse("x")
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected array")
end)

suite:test("array: non-numeric keys fail", function()
	local s = schema.array(schema.number())
	local ok, err = s:parse({ foo = 1 })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Non-numeric key")
end)

suite:test("array: child errors get index prefix", function()
	local s = schema.array(schema.number():int())
	local ok, err = s:parse({ 1, 2.5 })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("#2")
end)

suite:test("array: length constraints and nonempty", function()
	local s = schema.array(schema.number()):minLen(2):maxLen(3)
	test.expect(s:validate({ 1, 2 })):toBeTrue()
	test.expect(s:validate({ 1 })):toBeFalse()
	test.expect(s:validate({ 1, 2, 3, 4 })):toBeFalse()

	local exact = s:length(1)
	test.expect(exact:validate({ 1 })):toBeTrue()
	test.expect(exact:validate({ 1, 2 })):toBeFalse()

	local nonempty = schema.array(schema.number()):nonempty()
	test.expect(nonempty:validate({ 1 })):toBeTrue()
	test.expect(nonempty:validate({})):toBeFalse()
end)

suite:test("array: negative length guards throw", function()
	test.expect(function()
		schema.array(schema.number()):minLen(-1)
	end):toError("minLen cannot be negative")
	test.expect(function()
		schema.array(schema.number()):maxLen(-1)
	end):toError("maxLen cannot be negative")
	test.expect(function()
		schema.array(schema.number()):length(-1)
	end):toError("length cannot be negative")
end)

suite:test("array: sparse numeric keys count by entries", function()
	local s = schema.array(schema.number()):minLen(1)
	local ok = s:validate({ [2] = 10 })
	test.expect(ok):toBeTrue()
end)

-- Map
suite:test("map: parses valid map", function()
	local s = schema.map(schema.string(), schema.number():int())
	local ok, parsed = s:parse({ a = 1, b = 2 })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.a):toBe(1)
end)

suite:test("map: non-table fails", function()
	local s = schema.map(schema.string(), schema.number())
	local ok, err = s:parse("x")
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Expected map")
end)

suite:test("map: invalid key fails", function()
	local s = schema.map(schema.number(), schema.string())
	local ok, err = s:parse({ a = "x" })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Map key")
end)

suite:test("map: invalid value fails", function()
	local s = schema.map(schema.string(), schema.number())
	local ok, err = s:parse({ a = "x" })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Map value")
end)

suite:test("map: raw key/value literals are normalized", function()
	local s = schema.map("k", 5)
	test.expect(s:validate({ k = 5 })):toBeTrue()
	test.expect(s:validate({ z = 5 })):toBeFalse()
	test.expect(s:validate({ k = 6 })):toBeFalse()
end)

suite:test("map: parsed key/value can transform", function()
	local s = schema.map(schema.string():toUpperCase(), schema.string():trimWhitespace())
	local ok, parsed = s:parse({ a = "  x " })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.A):toBe("x")
	test.expect(parsed.a):toBeNil()
end)

-- Struct
suite:test("struct: table parse succeeds for valid object", function()
	local s = schema.table({
		name = schema.string(),
		age = schema.number():int(),
	})
	local ok, parsed = s:parse({ name = "Ada", age = 42 })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.name):toBe("Ada")
	test.expect(parsed.age):toBe(42)
end)

suite:test("struct: default mode strict rejects unknown keys", function()
	local s = schema.table({ a = schema.number() })
	local ok, err = s:parse({ a = 1, extra = "x" })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain("Unexpected key")
end)

suite:test("struct: strip removes unknown keys", function()
	local s = struct.strip(schema.table({ a = schema.number() }))
	local ok, parsed = s:parse({ a = 1, extra = "x" })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect((parsed :: any).a):toBe(1)
	test.expect((parsed :: any).extra):toBeNil()
end)

suite:test("struct: passthrough keeps unknown keys", function()
	local s = struct.passthrough(schema.table({ a = schema.number() }))
	local ok, parsed = s:parse({ a = 1, extra = "x" })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect((parsed :: any).extra):toBe("x")
end)

suite:test("struct: catchall validates unknown keys", function()
	local s = struct.catchall(struct.passthrough(schema.table({ a = schema.number() })), schema.string())
	local okGood = s:validate({ a = 1, tag = "ok" })
	local okBad, errBad = s:parse({ a = 1, tag = 123 })
	test.expect(okGood):toBeTrue()
	test.expect(okBad):toBeFalse()
	test.expect(errBad):toContain(".tag")
end)

suite:test("struct: catchall with strip drops parsed extras", function()
	local s = struct.strip(struct.catchall(schema.table({ a = schema.number() }), schema.string():trimWhitespace()))
	local ok, parsed = s:parse({ a = 1, extra = "  hi " })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect((parsed :: any).extra):toBeNil()
end)

suite:test("struct: missing required field fails", function()
	local s = schema.table({ a = schema.number(), b = schema.string() })
	local ok, err = s:parse({ a = 1 })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain(".b: Field missing")
end)

suite:test("struct: optional default applied for missing field", function()
	local s = schema.table({
		count = schema.optional(schema.number():int()):default(10),
	})
	local ok, parsed = s:parse({})
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.count):toBe(10)
end)

suite:test("struct: nested parse error includes field path", function()
	local s = schema.table({
		users = schema.array(schema.table({ id = schema.number():int() })),
	})
	local ok, err = s:parse({ users = { { id = 1 }, { id = 2.5 } } })
	test.expect(ok):toBeFalse()
	test.expect(err):toContain(".users")
	test.expect(err):toContain("#2")
end)

suite:test("struct: partial makes all fields optional", function()
	local base = schema.table({ a = schema.number(), b = schema.string() })
	local s = struct.partial(base)
	local ok, parsed = s:parse({})
	test.expect(ok):toBeTrue()
	test.expect(parsed.a):toBeNil()
	test.expect(parsed.b):toBeNil()
end)

suite:test("struct: partial preserves unknown mode", function()
	local base = struct.strip(schema.table({ a = schema.number() }))
	local s = struct.partial(base)
	local ok, parsed = s:parse({ extra = true })
	test.expect(ok):toBeTrue()
	test.expect(parsed.extra):toBeNil()
end)

suite:test("struct: pick keeps selected fields only", function()
	local base = schema.table({ a = schema.number(), b = schema.string(), c = schema.boolean() })
	local s = struct.pick(base, { "a", "c" })
	local ok, parsed = s:parse({ a = 1, c = true })
	test.expect(ok):toBeTrue()
	test.expect(parsed.a):toBe(1)
	test.expect(parsed.c):toBeTrue()
	test.expect(parsed.b):toBeNil()
end)

suite:test("struct: omit drops selected fields", function()
	local base = schema.table({ a = schema.number(), b = schema.string(), c = schema.boolean() })
	local s = struct.omit(base, { "b" })
	local ok, parsed = s:parse({ a = 1, c = false })
	test.expect(ok):toBeTrue()
	test.expect(parsed.b):toBeNil()
end)

suite:test("struct: required(all) removes optional wrappers", function()
	local base = schema.table({ a = schema.optional(schema.number()), b = schema.optional(schema.string()) })
	local s = struct.required(base)
	local ok, err = s:parse({})
	test.expect(ok):toBeFalse()
	test.expect(err):toContain(".a")
end)

suite:test("struct: required(keys) only for selected keys", function()
	local base = schema.table({ a = schema.optional(schema.number()), b = schema.optional(schema.string()) })
	local s = struct.required(base, { "b" })

	local ok1, err1 = s:parse({})
	test.expect(ok1):toBeFalse()
	test.expect(err1):toContain(".b")

	local ok2, parsed2 = s:parse({ b = "x" })
	test.expect(ok2):toBeTrue()
	test.expect(parsed2.b):toBe("x")
end)

suite:test("struct: readonly freezes parsed table", function()
	local s = struct.readonly(schema.table({ a = schema.number() }))
	local ok, parsed = s:parse({ a = 1 })
	test.expect(ok):toBeTrue()
	test.expect(table.isfrozen(parsed :: any)):toBeTrue()
end)

suite:test("struct: freeze aliases readonly", function()
	local s = struct.freeze(schema.table({ a = schema.number() }))
	local ok, parsed = s:parse({ a = 1 })
	test.expect(ok):toBeTrue()
	test.expect(table.isfrozen(parsed :: any)):toBeTrue()
end)

suite:test("struct: extend merges fields", function()
	local first = schema.table({ a = schema.number() })
	local second = schema.table({ b = schema.string() })
	local s = struct.extend(first, second)
	local ok, parsed = s:parse({ a = 1, b = "x" })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.a):toBe(1)
	test.expect(parsed.b):toBe("x")
end)

suite:test("struct: extend keeps first unknown-key settings", function()
	local first = struct.strip(schema.table({ a = schema.number() }))
	local second = struct.passthrough(schema.table({ b = schema.string() }))
	local s = (struct.extend :: any)(first, second)
	local ok, parsed = s:parse({ a = 1, b = "x", extra = true })
	test.expect(ok):toBeTrue()
	test.expect(parsed.extra):toBeNil()
end)

suite:test("struct: union+optional field treated optional in missing-field check", function()
	local maybeString = schema.anyOf(schema.optional(schema.string()), schema.number())
	local s = schema.table({ id = schema.number(), nick = maybeString })
	local ok, parsed = s:parse({ id = 5 })
	test.expect(ok):toBeTrue()
	assert(typeof(parsed) ~= "string")
	test.expect(parsed.nick):toBeNil()
end)

-- Facade API
suite:test("init facade exposes expected constructors", function()
	test.expect(type(schema.literal)):toBe("function")
	test.expect(type(schema.number)):toBe("function")
	test.expect(type(schema.string)):toBe("function")
	test.expect(type(schema.boolean)):toBe("function")
	test.expect(type(schema.array)):toBe("function")
	test.expect(type(schema.table)):toBe("function")
	test.expect(type(schema.optional)):toBe("function")
	test.expect(type(schema.anyOf)):toBe("function")
	test.expect(type(schema.map)):toBe("function")
end)

suite:test("weird scenario: deeply composed schemas still parse deterministically", function()
	local s = struct.passthrough(struct.catchall(
		schema.table({
			id = schema.number():int():positive(),
			name = schema.string():trimWhitespace():toUpperCase():minLen(2),
			tags = schema.array(schema.string():trimWhitespace():toLowerCase()):nonempty(),
			meta = schema.optional(
				schema.map(schema.string():toUpperCase(), schema.anyOf(schema.number(), schema.string()))
			),
		}),
		schema.string()
	))

	local ok, parsed = s:parse({
		id = 7,
		name = "  Ada  ",
		tags = { "  X ", " Y  " },
		meta = { score = 10, label = "Hi" },
		extra = "allowed",
	})

	test.expect(ok):toBeTrue()
	test.expect((parsed :: any).id):toBe(7)
	test.expect((parsed :: any).name):toBe("ADA")
	test.expect((parsed :: any).tags[1]):toBe("x")
	test.expect((parsed :: any).tags[2]):toBe("y")
	test.expect((parsed :: any).meta.SCORE):toBe(10)
	test.expect((parsed :: any).meta.LABEL):toBe("Hi")
	test.expect((parsed :: any).extra):toBe("allowed")
end)

return suite
