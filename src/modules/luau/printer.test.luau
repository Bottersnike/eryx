local luauParse = require("@eryx/luau/parse")
local luauPrinter = require("@eryx/luau/printer")
local test = require("@eryx/test")

local suite = test.Suite.new("luau/printer")

-- Representative syntax exercised by both modes: preserve must reproduce the
-- source byte-for-byte, pretty must emit something that re-parses cleanly.
local PRINTER_CASES = {
	"local a: number = 1; a += 2; a = a * 3",
	"local function f<T>(x: T) return x end",
	"function t:m(x, ...) return x, ... end",
	"for i = 1, 10, 2 do continue end",
	"for k, v in pairs({ a = 1, [2] = 3, 4 }) do print(k, v) end",
	"repeat local x = 1 until x > 0",
	"local x = if a and b then (a + b) * c else -d",
	"local s = `hello {name}`",
	"local y = (id<<number>>)(1)",
	"export type Pair<T> = { read first: T, second: T, [string]: number }",
	"type Fn = <T>(value: T, ...number) -> (T, ...number)",
	"declare g: number",
	"declare function id<T>(x: T): T",
	"declare class Child extends Parent\n\tfoo: string\n\tbar: number\nend",
	-- Trivia cases: leading/trailing whitespace and a load-bearing `;`.
	" print() ; print() ",
	" local a = b ; (a :: foo):bar()",
	" local a = b(a :: foo):bar()",
}

local function parseOk(source: string)
	local result = luauParse.parse(source)
	test.expect(#result.errors):toBe(0)
	return result
end

suite:test("preserve mode reproduces the original source from token trivia", function()
	local source = "-- lead\nlocal x = 1 + 2 -- tail\n\nreturn x"
	test.expect(luauPrinter.print(parseOk(source), { mode = "preserve" })):toBe(source)
end)

suite:test("pretty mode formats from AST shape", function()
	test.expect(luauPrinter.print(parseOk("local x=1+2\nreturn x"), { mode = "pretty" }))
		:toBe("local x = 1 + 2\nreturn x\n")
end)

suite:test("pretty mode formats block statements", function()
	local source = "if true then local x=1 elseif false then return 2 else while false do break end end"
	test.expect(luauPrinter.print(parseOk(source), { mode = "pretty" }))
		:toBe(
			"if true then\n\tlocal x = 1\nelseif false then\n\treturn 2\nelse\n\twhile false do\n\t\tbreak\n\tend\nend\n"
		)
end)

-- A `;` before a statement that begins with `(` is load-bearing: without it the
-- previous line's value would be called. Pretty mode discards original layout
-- but must still emit it, driven by the structural `hasSemicolon` flag.
suite:test("pretty mode keeps load-bearing semicolons", function()
	test.expect(luauPrinter.print(parseOk("local a = b ; (a :: foo):bar()"), { mode = "pretty" }))
		:toBe("local a = b\n;(a :: foo):bar()\n")

	test.expect(luauPrinter.print(parseOk('a.b() ; ("hi").bar()'), { mode = "pretty" })):toBe('a.b()\n;("hi").bar()\n')
end)

for n, source in PRINTER_CASES do
	suite:test(`preserve mode round-trips source ({n})`, function()
		test.expect(luauPrinter.print(parseOk(source), { mode = "preserve" })):toBe(source)
	end)

	suite:test(`pretty mode output re-parses ({n})`, function()
		local printed = luauPrinter.print(parseOk(source), { mode = "pretty" })
		test.expect(#luauParse.parse(printed).errors):toBe(0)
	end)
end

return suite
