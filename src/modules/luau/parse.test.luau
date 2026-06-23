local luauParse = require("@eryx/luau/parse")
local test = require("@eryx/test")

local suite = test.Suite.new("luau/parse")

local function parseOk(source, options)
	local result = luauParse.parse(source, options)
	test.expect(#result.errors):toBe(0)
	return result
end

local function walk(node, out)
	if type(node) ~= "table" then
		return
	end
	if type(node.type) == "string" and node.location ~= nil then
		table.insert(out, node)
	end
	for _, v in node do
		walk(v, out)
	end
	for k, v in node do
		if type(k) ~= "number" then
			walk(v, out)
		end
	end
end

local function expectLocation(loc)
	test.expect(loc):toNotBeNil()
	test.expect(type(loc.beginline)):toBe("number")
	test.expect(type(loc.begincolumn)):toBe("number")
	test.expect(type(loc.endline)):toBe("number")
	test.expect(type(loc.endcolumn)):toBe("number")
end

-- Nodes are now discriminated by `category` (e.g. "expr", "stat", "type",
-- "typePack") plus a lowercase `type`. The `type` alone is no longer unique
-- (e.g. both ExprLocal and StatLocal serialize as type "local"), so lookups
-- must match on the pair.
local function findNode(root, category, typeName)
	local nodes = {}
	walk(root, nodes)
	for _, n in nodes do
		if n.category == category and n.type == typeName then
			return n
		end
	end
	return nil
end

local function assertNode(source, category, typeName)
	local result = parseOk(source)
	test.expect(findNode(result.root, category, typeName)):toNotBeNil()
end

suite:test("parse: result shape", function()
	local result = parseOk("local x = 1")
	test.expect(result.root.category):toBe("stat")
	test.expect(result.root.type):toBe("block")
	expectLocation(result.root.location)
end)

suite:test("parse: collectComments includes comments", function()
	local result = parseOk("-- hello\nlocal x = 1", { collectComments = true })
	test.expect(result.comments):toNotBeNil()
	assert(result.comments) -- for types
	test.expect(#result.comments):toBeGreaterThan(0)
	test.expect(result.comments[1].type):toBe("line")
	expectLocation(result.comments[1].location)
end)

suite:test("CST tokens carry owned leading/trailing trivia text", function()
	local result = parseOk("-- lead\nlocal x = 1 -- tail\n\n-- next\nlocal y = 2")
	local firstStat = result.root.body[1] :: any
	local secondStat = result.root.body[2] :: any

	-- Leading trivia before the very first token attaches as leadingText.
	test.expect(firstStat.localKeywordToken.leadingText):toBe("-- lead\n")

	-- Trailing trivia up to and including the first newline stays on the
	-- previous token (here the `1` literal); the remainder moves to the next
	-- token's leadingText.
	local firstValueToken = firstStat.values[1].token
	test.expect(firstValueToken.trailingText):toBe(" -- tail\n")
	test.expect(secondStat.localKeywordToken.leadingText):toBe("\n-- next\n")
end)

suite:test("extractComments: supports merge modes and multiline unindent", function()
	local text = "-- one\n-- two\n--[[\n\tthree\n\tfour\n]]"

	local same = luauParse.extractComments(text, {
		merge = "same",
		unindentMultiLineContent = true,
		stripLineLeadingWhitespace = true,
	})
	test.expect(#same):toBe(2)
	test.expect(same[1]):toBe("one\ntwo")
	test.expect(same[2]):toBe("three\nfour")

	local all = luauParse.extractComments(text, {
		merge = "all",
		unindentMultiLineContent = true,
		stripLineLeadingWhitespace = true,
	})
	test.expect(#all):toBe(1)
	test.expect(all[1]):toBe("one\ntwo\nthree\nfour")
end)

suite:test("expr constant nodes", function()
	assertNode("local a=nil local b=true local c=1 local d='x'", "expr", "constantNil")
	assertNode("local a=nil local b=true local c=1 local d='x'", "expr", "constantBool")
	assertNode("local a=nil local b=true local c=1 local d='x'", "expr", "constantNumber")
	assertNode("local a=nil local b=true local c=1 local d='x'", "expr", "constantString")
end)

suite:test("constantNumber exposes value and token", function()
	local result = parseOk("local x = 123.5")
	local node = findNode(result.root, "expr", "constantNumber")
	test.expect(node.value):toBe(123.5)
	test.expect(node.token.type):toBe("token")
end)

suite:test("constantInteger exposes value and token", function()
	local result = parseOk("local x = 123i")
	local node = findNode(result.root, "expr", "constantInteger")
	test.expect(node):toNotBeNil()
	-- Integer literals deserialize to the fork's native integer type, not a float.
	test.expect(node.value):toBe(123i)
	test.expect(node.token.type):toBe("token")
end)

suite:test("constantString exposes quoteStyle", function()
	local result = parseOk("local x = 'abc'")
	local node = findNode(result.root, "expr", "constantString")
	test.expect(node.quoteStyle):toBeType("string")
	test.expect(node.isQuoted):toBeType("boolean")
end)

suite:test("expr local / global / varargs", function()
	assertNode("local x = 1; local y = x", "expr", "local")
	assertNode("print(globalName)", "expr", "global")
	assertNode("local function f(...) return ... end", "expr", "varargs")
end)

suite:test("expr call exposes argLocation", function()
	local result = parseOk("print(1,2,3)")
	local node = findNode(result.root, "expr", "call")
	expectLocation(node.argLocation)
	test.expect(#node.args):toBe(3)
end)

suite:test("expr indexName and indexExpr", function()
	assertNode("local x = a.b.c", "expr", "indexName")
	assertNode("local x = a[b]", "expr", "indexExpr")
end)

suite:test("expr indexName exposes index metadata", function()
	local result = parseOk("local x = a:b()")
	local node = findNode(result.root, "expr", "indexName")
	expectLocation(node.indexLocation)
	test.expect(node.opPosition):toBeType("table")
end)

suite:test("expr function exposes extended metadata", function()
	local result = parseOk("local function f(...) return ... end")
	local node = findNode(result.root, "expr", "function")
	test.expect(node.vararg):toBeTrue()
	expectLocation(node.varargLocation)
	test.expect(node.functionDepth):toBeType("number")
end)

suite:test("expr table / unary / binary / typeAssertion / ifElse", function()
	assertNode("local x = {a=1,[2]=3,4}", "expr", "table")
	assertNode("local x = -1", "expr", "unary")
	assertNode("local x = 1 + 2 * 3", "expr", "binary")
	assertNode("local x = (1 :: number)", "expr", "typeAssertion")
	assertNode("local x = if true then 1 else 2", "expr", "ifElse")
end)

suite:test("expr interpString", function()
	assertNode("local x = `hello {1+2}`", "expr", "interpString")
end)

suite:test("expr instantiate with explicit type args", function()
	local result = parseOk("local x = (id<<number>>)(1)")
	local node = findNode(result.root, "expr", "instantiate")
	test.expect(node):toNotBeNil()
	test.expect(#node.typeArguments):toBeGreaterThan(0)
end)

suite:test("expr error appears on invalid expression", function()
	local result = luauParse.parse("local x = (")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(findNode(result.root, "expr", "error")):toNotBeNil()
end)

suite:test("stat if / while / repeat", function()
	assertNode("if true then end", "stat", "if")
	assertNode("while true do break end", "stat", "while")
	assertNode("repeat break until true", "stat", "repeat")
end)

suite:test("loop stats expose keyword locations", function()
	local w = parseOk("while true do break end")
	local ws = findNode(w.root, "stat", "while")
	expectLocation(ws.doLocation)

	local f = parseOk("for i=1,3 do end")
	local fs = findNode(f.root, "stat", "for")
	expectLocation(fs.doLocation)

	local fi = parseOk("for k,v in {} do end")
	local fis = findNode(fi.root, "stat", "forIn")
	expectLocation(fis.inLocation)
end)

suite:test("basic statement nodes", function()
	local cases = {
		{ src = "while true do break end", node = "break" },
		{ src = "return 1", node = "return" },
		{ src = "print(1)", node = "expr" },
		{ src = "local x = 1", node = "local" },
		{ src = "for i=1,10 do end", node = "for" },
		{ src = "for k,v in {} do end", node = "forIn" },
		{ src = "x = 1", node = "assign" },
		{ src = "x += 1", node = "compoundAssign" },
		{ src = "function f() end", node = "function" },
		{ src = "local function f() end", node = "localFunction" },
	}

	for _, c in cases do
		local result = parseOk(c.src)
		test.expect(findNode(result.root, "stat", c.node)):toNotBeNil()
	end
end)

suite:test("stat continue", function()
	local result = parseOk("while true do continue end")
	test.expect(findNode(result.root, "stat", "continue")):toNotBeNil()
end)

suite:test("stat local exposes equalsSignLocation", function()
	local result = parseOk("local x = 1")
	local stat = findNode(result.root, "stat", "local")
	expectLocation(stat.equalsSignLocation)
end)

suite:test("stat local exposes const/export metadata", function()
	local localResult = parseOk("const x = 1")
	local localStat = findNode(localResult.root, "stat", "local")
	test.expect(localStat.isConst):toBeTrue()
	test.expect(localStat.vars[1].isConst):toBeTrue()
	test.expect(localStat.vars[1].isExported):toBeFalse()

	local exportResult = parseOk("export local y = 2")
	local exportStat = findNode(exportResult.root, "stat", "local")
	test.expect(exportStat.vars[1].isExported):toBeTrue()

	local exportConstResult = parseOk("export const z = 3")
	local exportConstStat = findNode(exportConstResult.root, "stat", "local")
	test.expect(exportConstStat.isConst):toBeTrue()
	test.expect(exportConstStat.vars[1].isConst):toBeTrue()
	test.expect(exportConstStat.vars[1].isExported):toBeTrue()
end)

suite:test("stat localFunction exposes const/export metadata", function()
	local constResult = parseOk("const function f() end")
	local constStat = findNode(constResult.root, "stat", "localFunction")
	test.expect(constStat.isConst):toBeTrue()
	test.expect(constStat.name.isConst):toBeTrue()

	local exportResult = parseOk("export function g() end")
	local exportStat = findNode(exportResult.root, "stat", "localFunction")
	test.expect(exportStat.isConst):toBeTrue()
	test.expect(exportStat.name.isConst):toBeTrue()
	test.expect(exportStat.name.isExported):toBeTrue()
end)

suite:test("type statement nodes", function()
	assertNode("type X = number", "stat", "typeAlias")

	local dg = parseOk("declare g: number")
	test.expect(findNode(dg.root, "stat", "declareGlobal")):toNotBeNil()

	local df = parseOk("declare function id(x: number): number")
	test.expect(findNode(df.root, "stat", "declareFunction")):toNotBeNil()

	local dc = parseOk("declare class C end")
	test.expect(findNode(dc.root, "stat", "declareExternType")):toNotBeNil()
end)

suite:test("stat typeFunction", function()
	local src = "type function id<T>(x: T): T return x end"
	local result = parseOk(src)
	test.expect(findNode(result.root, "stat", "typeFunction")):toNotBeNil()
end)

suite:test("stat typeAlias exposes name/generic locations", function()
	local result = parseOk("export type X<T = number> = T")
	local stat = findNode(result.root, "stat", "typeAlias")
	expectLocation(stat.nameLocation)
	test.expect(stat.exported):toBeTrue()
	test.expect(type(stat.generics)):toBe("table")
end)

suite:test("stat declareFunction exposes parameters", function()
	local result = parseOk("declare function f(x: number): number")
	local stat = findNode(result.root, "stat", "declareFunction")
	expectLocation(stat.nameLocation)
	test.expect(stat.params):toBeType("table")
	test.expect(stat.paramNames):toBeType("table")
	test.expect(stat.returnTypes):toBeType("table")
end)

suite:test("stat declareExternType exposes props/super/indexer shape", function()
	local result = parseOk("declare class Child extends Parent\n\tread x: number\n\twrite y: string\n\tz: boolean\nend")
	local stat = findNode(result.root, "stat", "declareExternType")
	test.expect(stat.superName):toBe("Parent")
	test.expect(type(stat.props)):toBe("table")
	test.expect(stat.props[1].access):toBe("Read")
	test.expect(stat.props[2].access):toBe("Write")
	test.expect(stat.props[3].access):toBe("ReadWrite")
end)

suite:test("stat error appears on invalid statement", function()
	local result = luauParse.parse("game:")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(findNode(result.root, "stat", "error")):toNotBeNil()
end)

suite:test("type reference / table / function / typeof", function()
	assertNode("type A = Mod.B<number>", "type", "reference")
	assertNode("type T = {x: number, [string]: number}", "type", "table")
	assertNode("type F = <T>(T)->T", "type", "function")
	assertNode("type V = typeof(game)", "type", "typeof")
end)

suite:test("type reference exposes prefix/name/parameter metadata", function()
	local result = parseOk("type A = Mod.B<number>")
	local t = findNode(result.root, "type", "reference")
	test.expect(t.hasParameterList):toBeType("boolean")
	expectLocation(t.nameLocation)
	expectLocation(t.prefixLocation)
	test.expect(type(t.parameters)):toBe("table")
end)

suite:test("type table exposes access/indexer metadata", function()
	local result = parseOk("type T = {[string]: number, x: string}")
	local t = findNode(result.root, "type", "table")
	test.expect(#t.props):toBeGreaterThan(0)
	test.expect(t.props[1].access):toBeType("string")
	if t.indexer then
		test.expect(t.indexer.access):toBeType("string")
		expectLocation(t.indexer.location)
	end
end)

suite:test("type function exposes generic/arg metadata", function()
	local result = parseOk("type F = (number) -> string")
	local t = findNode(result.root, "type", "function")
	test.expect(type(t.argTypes)):toBe("table")
	test.expect(type(t.argNames)):toBe("table")
	test.expect(t.returnTypes):toBeType("table")
end)

suite:test("optional/union/intersection/singleton/group types", function()
	assertNode("type A = number?", "type", "optional")
	assertNode("type U = number | string", "type", "union")
	assertNode("type I = {x:number} & {y:number}", "type", "intersection")
	assertNode("type B = true", "type", "singletonBool")
	assertNode("type S = 'ok'", "type", "singletonString")
	assertNode("type G = (number)", "type", "group")
end)

suite:test("type error appears on invalid type syntax", function()
	local result = luauParse.parse("type Bad = |")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(findNode(result.root, "type", "error")):toNotBeNil()
end)

suite:test("typepacks: explicit/variadic/generic", function()
	local v = parseOk("type Foo = (string, number, ...number) -> ...boolean")
	test.expect(findNode(v.root, "typePack", "variadic")):toNotBeNil()

	local g = parseOk("type A = (a...) -> b...")
	test.expect(findNode(g.root, "typePack", "generic")):toNotBeNil()

	local e = parseOk("type Bar = () -> (number, ...boolean)")
	test.expect(findNode(e.root, "typePack", "explicit")):toNotBeNil()
end)

suite:test("AstLocal metadata fields", function()
	local result = parseOk("local x: number = 1; local y = x")
	local localExpr = findNode(result.root, "expr", "local")
	test.expect(localExpr):toNotBeNil()
	test.expect(localExpr["local"].functionDepth):toBeType("number")
	test.expect(localExpr["local"].loopDepth):toBeType("number")
	test.expect(localExpr["local"].isConst):toBeType("boolean")
end)

suite:test("all statements carry hasSemicolon", function()
	local result = parseOk("local x=1; x=2;")
	local s1 = findNode(result.root, "stat", "local")
	local s2 = findNode(result.root, "stat", "assign")
	test.expect(s1.hasSemicolon):toBeType("boolean")
	test.expect(s2.hasSemicolon):toBeType("boolean")
end)

return suite
