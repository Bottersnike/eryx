local csv = require("@eryx/data/csv")
local test = require("@eryx/test")
local suite = test.Suite.new("csv")

suite:test("parse: basic row", function()
	local rows = csv.parse("a,b,c\r\n")
	test.expect(#rows):toBe(1)
	test.expect(rows[1][1]):toBe("a")
	test.expect(rows[1][2]):toBe("b")
	test.expect(rows[1][3]):toBe("c")
end)

suite:test("parse: multiple rows", function()
	local rows = csv.parse("1,2\r\n3,4\r\n")
	test.expect(#rows):toBe(2)
	test.expect(rows[2][1]):toBe("3")
end)

suite:test("parse: quoted field with comma", function()
	local rows = csv.parse('"a,b",c\r\n')
	test.expect(rows[1][1]):toBe("a,b")
	test.expect(rows[1][2]):toBe("c")
end)

suite:test("parse: doubled-quote escape", function()
	local rows = csv.parse('"say ""hi""",x\r\n')
	test.expect(rows[1][1]):toBe('say "hi"')
end)

suite:test("parse: empty input returns empty table", function()
	local rows = csv.parse("")
	test.expect(#rows):toBe(0)
end)

suite:test("parse: unix dialect", function()
	local rows = csv.parse("a,b\n1,2\n", { dialect = "unix" })
	test.expect(#rows):toBe(2)
	test.expect(rows[2][1]):toBe("1")
end)

suite:test("parse: tab delimiter via tsv dialect", function()
	local rows = csv.parse("a\tb\t c\n", { dialect = "tsv" })
	test.expect(rows[1][2]):toBe("b")
end)

suite:test("parse: comment lines skipped", function()
	local rows = csv.parse("# comment\na,b\n", { comment = "#" })
	test.expect(#rows):toBe(1)
	test.expect(rows[1][1]):toBe("a")
end)

suite:test("parse: skip blank lines", function()
	local rows = csv.parse("a,b\n\n1,2\n", { skipblanklines = true })
	test.expect(#rows):toBe(2)
end)

suite:test("generate: basic", function()
	local s = csv.generate({ { "a", "b", "c" }, { "1", "2", "3" } })
	test.expect(s):toBe("a,b,c\r\n1,2,3\r\n")
end)

suite:test("generate: quotes field with comma", function()
	local s = csv.generate({ { "a,b", "c" } })
	test.expect(s):toBe('"a,b",c\r\n')
end)

suite:test("csv round-trip", function()
	local original = { { "name", "age" }, { "Alice", "30" }, { "Bob", "25" } }
	local s = csv.generate(original)
	local parsed = csv.parse(s)
	test.expect(#parsed):toBe(3)
	test.expect(parsed[1][1]):toBe("name")
	test.expect(parsed[2][1]):toBe("Alice")
	test.expect(parsed[3][2]):toBe("25")
end)

suite:test("parseDict: header from first row", function()
	local rows, fields = csv.parseDict("name,age\nAlice,30\nBob,25\n")
	test.expect(#fields):toBe(2)
	test.expect(fields[1]):toBe("name")
	test.expect(rows[1].name):toBe("Alice")
	test.expect(rows[2].age):toBe("25")
end)

suite:test("sniff: detects comma delimiter", function()
	local result = csv.sniff("a,b,c\n1,2,3\n")
	test.expect(result.delimiter):toBe(",")
end)

suite:test("sniff: detects tab delimiter", function()
	local result = csv.sniff("a\tb\tc\n1\t2\t3\n")
	test.expect(result.delimiter):toBe("\t")
end)

suite:test("listDialects: includes excel", function()
	test.expect(csv.listDialects()):toContain("excel")
end)

return suite
