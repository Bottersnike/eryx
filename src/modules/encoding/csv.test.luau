local csv = require("@eryx/encoding/csv")
local test = require("@eryx/test")
local suite = test.Suite.new("csv")

suite:Test("parse: basic row", function()
	local rows = csv.parse("a,b,c\r\n")
	test.expect(#rows):ToBe(1)
	test.expect(rows[1][1]):ToBe("a")
	test.expect(rows[1][2]):ToBe("b")
	test.expect(rows[1][3]):ToBe("c")
end)

suite:Test("parse: multiple rows", function()
	local rows = csv.parse("1,2\r\n3,4\r\n")
	test.expect(#rows):ToBe(2)
	test.expect(rows[2][1]):ToBe("3")
end)

suite:Test("parse: quoted field with comma", function()
	local rows = csv.parse('"a,b",c\r\n')
	test.expect(rows[1][1]):ToBe("a,b")
	test.expect(rows[1][2]):ToBe("c")
end)

suite:Test("parse: doubled-quote escape", function()
	local rows = csv.parse('"say ""hi""",x\r\n')
	test.expect(rows[1][1]):ToBe('say "hi"')
end)

suite:Test("parse: empty input returns empty table", function()
	local rows = csv.parse("")
	test.expect(#rows):ToBe(0)
end)

suite:Test("parse: unix dialect", function()
	local rows = csv.parse("a,b\n1,2\n", { dialect = "unix" })
	test.expect(#rows):ToBe(2)
	test.expect(rows[2][1]):ToBe("1")
end)

suite:Test("parse: tab delimiter via tsv dialect", function()
	local rows = csv.parse("a\tb\t c\n", { dialect = "tsv" })
	test.expect(rows[1][2]):ToBe("b")
end)

suite:Test("parse: comment lines skipped", function()
	local rows = csv.parse("# comment\na,b\n", { comment = "#" })
	test.expect(#rows):ToBe(1)
	test.expect(rows[1][1]):ToBe("a")
end)

suite:Test("parse: skip blank lines", function()
	local rows = csv.parse("a,b\n\n1,2\n", { skipblanklines = true })
	test.expect(#rows):ToBe(2)
end)

suite:Test("generate: basic", function()
	local s = csv.generate({ { "a", "b", "c" }, { "1", "2", "3" } })
	test.expect(s):ToBe("a,b,c\r\n1,2,3\r\n")
end)

suite:Test("generate: quotes field with comma", function()
	local s = csv.generate({ { "a,b", "c" } })
	test.expect(s):ToBe('"a,b",c\r\n')
end)

suite:Test("csv round-trip", function()
	local original = { { "name", "age" }, { "Alice", "30" }, { "Bob", "25" } }
	local s = csv.generate(original)
	local parsed = csv.parse(s)
	test.expect(#parsed):ToBe(3)
	test.expect(parsed[1][1]):ToBe("name")
	test.expect(parsed[2][1]):ToBe("Alice")
	test.expect(parsed[3][2]):ToBe("25")
end)

suite:Test("parseDict: header from first row", function()
	local rows, fields = csv.parseDict("name,age\nAlice,30\nBob,25\n")
	test.expect(#fields):ToBe(2)
	test.expect(fields[1]):ToBe("name")
	test.expect(rows[1].name):ToBe("Alice")
	test.expect(rows[2].age):ToBe("25")
end)

suite:Test("sniff: detects comma delimiter", function()
	local result = csv.sniff("a,b,c\n1,2,3\n")
	test.expect(result.delimiter):ToBe(",")
end)

suite:Test("sniff: detects tab delimiter", function()
	local result = csv.sniff("a\tb\tc\n1\t2\t3\n")
	test.expect(result.delimiter):ToBe("\t")
end)

suite:Test("listDialects: includes excel", function()
	test.expect(csv.listDialects()):ToContain("excel")
end)

return suite
