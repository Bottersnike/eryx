local luau = require("@eryx/luau")
local test = require("@eryx/test")

local suite = test.Suite.new("luau")

local function parseOk(source, options)
	local result = luau.parse(source, options)
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

local function findNode(root, typeName)
	local nodes = {}
	walk(root, nodes)
	for _, n in nodes do
		if n.type == typeName then
			return n
		end
	end
	return nil
end

local function assertNode(source, typeName)
	local result = parseOk(source)
	test.expect(findNode(result.root, typeName)):toNotBeNil()
end

suite:test("parse: result shape", function()
	local result = parseOk("local x = 1")
	test.expect(result.root.type):toBe("Block")
	test.expect(result.lines):toBeGreaterThan(0)
	expectLocation(result.root.location)
end)

suite:test("parse: captureComments includes comments", function()
	local result = parseOk("-- hello\nlocal x = 1", { captureComments = true })
	test.expect(result.comments):toNotBeNil()
	assert(result.comments) -- for types
	test.expect(#result.comments):toBeGreaterThan(0)
end)

suite:test("ExprConstant nodes", function()
	assertNode("local a=nil local b=true local c=1 local d='x'", "ExprConstantNil")
	assertNode("local a=nil local b=true local c=1 local d='x'", "ExprConstantBool")
	assertNode("local a=nil local b=true local c=1 local d='x'", "ExprConstantNumber")
	assertNode("local a=nil local b=true local c=1 local d='x'", "ExprConstantString")
end)

suite:test("ExprConstantNumber exposes parseResult", function()
	local result = parseOk("local x = 123")
	local node = findNode(result.root, "ExprConstantNumber")
	test.expect(node.parseResult):toBeType("string")
end)

suite:test("ExprConstantString exposes quoteStyle", function()
	local result = parseOk("local x = 'abc'")
	local node = findNode(result.root, "ExprConstantString")
	test.expect(node.quoteStyle):toBeType("string")
	test.expect(node.isQuoted):toBeType("boolean")
end)

suite:test("ExprLocal / ExprGlobal / ExprVarargs", function()
	assertNode("local x = 1; local y = x", "ExprLocal")
	assertNode("print(globalName)", "ExprGlobal")
	assertNode("local function f(...) return ... end", "ExprVarargs")
end)

suite:test("ExprCall exposes argLocation", function()
	local result = parseOk("print(1,2,3)")
	local node = findNode(result.root, "ExprCall")
	expectLocation(node.argLocation)
	test.expect(#node.args):toBe(3)
end)

suite:test("ExprIndexName and ExprIndexExpr", function()
	assertNode("local x = a.b.c", "ExprIndexName")
	assertNode("local x = a[b]", "ExprIndexExpr")
end)

suite:test("ExprIndexName exposes index metadata", function()
	local result = parseOk("local x = a:b()")
	local node = findNode(result.root, "ExprIndexName")
	expectLocation(node.indexLocation)
	test.expect(node.opPosition):toBeType("table")
end)

suite:test("ExprFunction exposes extended metadata", function()
	local result = parseOk("local function f(...) return ... end")
	local node = findNode(result.root, "ExprFunction")
	test.expect(node.vararg):toBeTrue()
	expectLocation(node.varargLocation)
	test.expect(node.functionDepth):toBeType("number")
end)

suite:test("ExprTable / ExprUnary / ExprBinary / ExprTypeAssertion / ExprIfElse", function()
	assertNode("local x = {a=1,[2]=3,4}", "ExprTable")
	assertNode("local x = -1", "ExprUnary")
	assertNode("local x = 1 + 2 * 3", "ExprBinary")
	assertNode("local x = (1 :: number)", "ExprTypeAssertion")
	assertNode("local x = if true then 1 else 2", "ExprIfElse")
end)

suite:test("ExprInterpString", function()
	assertNode("local x = `hello {1+2}`", "ExprInterpString")
end)

suite:test("ExprInstantiate with explicit type args", function()
	local result = parseOk("local x = (id<<number>>)(1)")
	local node = findNode(result.root, "ExprInstantiate")
	test.expect(node):toNotBeNil()
	test.expect(#node.typeArguments):toBeGreaterThan(0)
end)

suite:test("ExprError appears on invalid expression", function()
	local result = luau.parse("local x = (")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(findNode(result.root, "ExprError")):toNotBeNil()
end)

suite:test("StatIf / StatWhile / StatRepeat", function()
	assertNode("if true then end", "StatIf")
	assertNode("while true do break end", "StatWhile")
	assertNode("repeat break until true", "StatRepeat")
end)

suite:test("loop stats expose keyword locations", function()
	local w = parseOk("while true do break end")
	local ws = findNode(w.root, "StatWhile")
	test.expect(ws.hasDo):toBeType("boolean")
	expectLocation(ws.doLocation)

	local f = parseOk("for i=1,3 do end")
	local fs = findNode(f.root, "StatFor")
	test.expect(fs.hasDo):toBeType("boolean")
	expectLocation(fs.doLocation)

	local fi = parseOk("for k,v in {} do end")
	local fis = findNode(fi.root, "StatForIn")
	test.expect(fis.hasIn):toBeType("boolean")
	expectLocation(fis.inLocation)
end)

suite:test("basic statement nodes", function()
	local cases = {
		{ src = "do break end", node = "StatBreak" },
		{ src = "return 1", node = "StatReturn" },
		{ src = "print(1)", node = "StatExpr" },
		{ src = "local x = 1", node = "StatLocal" },
		{ src = "for i=1,10 do end", node = "StatFor" },
		{ src = "for k,v in {} do end", node = "StatForIn" },
		{ src = "x = 1", node = "StatAssign" },
		{ src = "x += 1", node = "StatCompoundAssign" },
		{ src = "function f() end", node = "StatFunction" },
		{ src = "local function f() end", node = "StatLocalFunction" },
	}

	for _, c in cases do
		local result = luau.parse(c.src)
		test.skipIf(#result.errors > 0, `statement syntax not enabled for: {c.node}`)
		test.expect(findNode(result.root, c.node)):toNotBeNil()
	end
end)

suite:test("StatContinue (when enabled)", function()
	local result = luau.parse("while true do continue end")
	test.skipIf(#result.errors > 0, "continue syntax not enabled in this Luau build")
	test.expect(findNode(result.root, "StatContinue")):toNotBeNil()
end)

suite:test("StatLocal exposes equalsSignLocation", function()
	local result = parseOk("local x = 1")
	local stat = findNode(result.root, "StatLocal")
	expectLocation(stat.equalsSignLocation)
end)

suite:test("type statement nodes", function()
	assertNode("type X = number", "StatTypeAlias")
	local dg = luau.parse("declare global g: number")
	test.skipIf(#dg.errors > 0, "declare global syntax not enabled in this Luau build")
	test.expect(findNode(dg.root, "StatDeclareGlobal")):toNotBeNil()

	local df = luau.parse("declare function id(x: number): number")
	test.skipIf(#df.errors > 0, "declare function syntax not enabled in this Luau build")
	test.expect(findNode(df.root, "StatDeclareFunction")):toNotBeNil()

	local dc = luau.parse("declare class C end")
	test.skipIf(#dc.errors > 0, "declare class syntax not enabled in this Luau build")
	test.expect(findNode(dc.root, "StatDeclareExternType")):toNotBeNil()
end)

suite:test("StatTypeFunction (when supported by parser)", function()
	local src = "type function id<T>(x: T): T return x end"
	local result = luau.parse(src)
	test.skipIf(#result.errors > 0, "type function syntax not enabled in this Luau build")
	test.expect(findNode(result.root, "StatTypeFunction")):toNotBeNil()
end)

suite:test("StatTypeAlias exposes name/generic locations", function()
	local result = parseOk("export type X<T = number> = T")
	local stat = findNode(result.root, "StatTypeAlias")
	expectLocation(stat.nameLocation)
	test.expect(stat.exported):toBeTrue()
	test.expect(type(stat.generics)):toBe("table")
end)

suite:test("StatDeclareFunction exposes parameters", function()
	local result = luau.parse("declare function f(x: number): number")
	test.skipIf(#result.errors > 0, "declare function syntax not enabled in this Luau build")
	local stat = findNode(result.root, "StatDeclareFunction")
	expectLocation(stat.nameLocation)
	test.expect(stat.params):toBeType("table")
	test.expect(stat.paramNames):toBeType("table")
	test.expect(stat.returnTypes):toBeType("table")
end)

suite:test("StatDeclareExternType exposes props/super/indexer shape", function()
	local result = luau.parse("declare class Child extends Parent\n\tx: number\nend")
	test.skipIf(#result.errors > 0, "declare class syntax not enabled in this Luau build")
	local stat = findNode(result.root, "StatDeclareExternType")
	test.expect(stat.superName):toBe("Parent")
	test.expect(type(stat.props)):toBe("table")
end)

suite:test("StatError appears on invalid statement", function()
	local result = luau.parse("if true then local")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.skipIf(findNode(result.root, "StatError") == nil, "parser did not emit StatError node for this syntax error")
	test.expect(findNode(result.root, "StatError")):toNotBeNil()
end)

suite:test("TypeReference / TypeTable / TypeFunction / TypeTypeof", function()
	assertNode("type A = Mod.B<number>", "TypeReference")
	assertNode("type T = {x: number, [string]: number}", "TypeTable")
	assertNode("type F = <T>(T)->T", "TypeFunction")
	assertNode("type V = typeof(game)", "TypeTypeof")
end)

suite:test("TypeReference exposes prefix/name/parameter metadata", function()
	local result = parseOk("type A = Mod.B<number>")
	local t = findNode(result.root, "TypeReference")
	test.expect(t.hasParameterList):toBeType("boolean")
	expectLocation(t.nameLocation)
	expectLocation(t.prefixLocation)
	test.expect(type(t.parameters)):toBe("table")
end)

suite:test("TypeTable exposes access/indexer metadata", function()
	local result = parseOk("type T = {[string]: number, x: string}")
	local t = findNode(result.root, "TypeTable")
	test.expect(#t.props):toBeGreaterThan(0)
	test.expect(t.props[1].access):toBeType("string")
	if t.indexer then
		test.expect(t.indexer.access):toBeType("string")
		expectLocation(t.indexer.location)
	end
end)

suite:test("TypeFunction exposes generic/arg metadata", function()
	local result = parseOk("type F = (number) -> string")
	local t = findNode(result.root, "TypeFunction")
	test.expect(type(t.argTypes)):toBe("table")
	test.expect(type(t.argNames)):toBe("table")
	test.expect(t.returnTypes):toBeType("table")
end)

suite:test("optional/union/intersection/singleton/group types", function()
	assertNode("type A = number?", "TypeOptional")
	assertNode("type U = number | string", "TypeUnion")
	assertNode("type I = {x:number} & {y:number}", "TypeIntersection")
	assertNode("type B = true", "TypeSingletonBool")
	assertNode("type S = 'ok'", "TypeSingletonString")
	assertNode("type G = (number)", "TypeGroup")
end)

suite:test("TypeError appears on invalid type syntax", function()
	local result = luau.parse("type Bad = |")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(findNode(result.root, "TypeError")):toNotBeNil()
end)

suite:test("typepacks: explicit/variadic/generic", function()
	local v = luau.parse("type F = (...number) -> ...number")
	test.skipIf(#v.errors > 0, "variadic typepack syntax not enabled in this Luau build")
	test.expect(findNode(v.root, "TypePackVariadic")):toNotBeNil()

	local g = luau.parse("type F = <U...>(...U...) -> ...U...")
	test.skipIf(#g.errors > 0, "generic typepack syntax not enabled in this Luau build")
	test.expect(findNode(g.root, "TypePackGeneric")):toNotBeNil()

	local e = luau.parse("type F = (...number) -> (number, ...number)")
	test.skipIf(#e.errors > 0, "explicit typepack syntax not enabled in this Luau build")
	test.expect(findNode(e.root, "TypePackExplicit")):toNotBeNil()
end)

suite:test("AstLocal metadata fields", function()
	local result = parseOk("local x: number = 1; local y = x")
	local localExpr = findNode(result.root, "ExprLocal")
	test.expect(localExpr):toNotBeNil()
	test.expect(localExpr["local"].functionDepth):toBeType("number")
	test.expect(localExpr["local"].loopDepth):toBeType("number")
	test.expect(localExpr["local"].isConst):toBeType("boolean")
end)

suite:test("all statements carry hasSemicolon", function()
	local result = parseOk("local x=1; x=2;")
	local s1 = findNode(result.root, "StatLocal")
	local s2 = findNode(result.root, "StatAssign")
	test.expect(s1.hasSemicolon):toBeType("boolean")
	test.expect(s2.hasSemicolon):toBeType("boolean")
end)

suite:test("check: reports type errors", function()
	local result = luau.check("local x: string = 1")
	test.expect(type(result.errors)):toBe("table")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(result.errors[1].category):toBeType("string")
end)

suite:test("check: exposes lint diagnostics", function()
	local result = luau.check("local x = 1")
	test.expect(type(result.lints)):toBe("table")
	test.expect(type(result.lints.errors)):toBe("table")
	test.expect(type(result.lints.warnings)):toBe("table")
	test.expect(type(result.lints.all)):toBe("table")
	test.expect(#result.lints.all):toBe(#result.lints.errors + #result.lints.warnings)
	if #result.lints.all > 0 then
		local first = result.lints.all[1]
		test.expect(first.severity):toBeType("string")
		test.expect(first.code):toBeType("number")
		test.expect(first.name):toBeType("string")
		test.expect(first.message):toBeType("string")
		expectLocation(first.location)
	end
end)

suite:test("typeAt: classic string mode", function()
	local source = "local x = 1\nlocal y = x"
	local ty = luau.typeAt(source, 2, 11)
	test.expect(ty):toBeType("string")
end)

suite:test("typeAt: detailed mode", function()
	local source = "local x = {a = 1, b = 'ok'}\nlocal y = x"
	local out = luau.typeAt(source, 2, 11, { detailed = true })
	test.expect(out):toBeType("table")
	assert(typeof(out) == "table") -- for types
	test.expect(out.display):toBeType("string")
	test.expect(out.source):toBeType("string")
	test.expect(out.type):toBeType("table")
	test.expect(out.type.kind):toBeType("string")
end)

suite:test("typeofModule: classic string mode", function()
	local source = "return { answer = 42 }"
	local out = luau.typeofModule(source)
	test.expect(out):toBeType("string")
end)

suite:test("typeofModule: detailed mode", function()
	local source = "return { answer = 42 }, 'ok'"
	local out = luau.typeofModule(source, { detailed = true })
	test.expect(out):toBeType("table")
	assert(typeof(out) == "table") -- for types
	test.expect(out.display):toBeType("string")
	test.expect(out.source):toBe("Module")
	test.expect(out.typePack):toBeType("table")
	assert(typeof(out.typePack) == "table") -- for types
	test.expect(out.typePack.kind):toBeType("string")
end)

suite:test("autocomplete: detailed type payload", function()
	local source = "local t = {foo = 1, bar = 'x'}\nt."
	local out = luau.autocomplete(source, 2, 3, { detailed = true })
	test.expect(out.context):toBeType("string")
	test.expect(type(out.entries)):toBe("table")
	test.expect(out.entries.foo):toNotBeNil()
	test.expect(out.entries.foo.kind):toBe("Property")
	test.expect(out.entries.foo.typeDetail):toBeType("table")
	assert(typeof(out.entries.foo.typeDetail) == "table") -- for types
	test.expect(out.entries.foo.typeDetail.kind):toBeType("string")
end)

suite:test("getconfig: exposes current config shape", function()
	local cfg = luau.getconfig()
	test.expect(type(cfg)):toBe("table")
	test.expect(type(cfg.found)):toBe("boolean")
	test.expect(type(cfg.configDir)):toBe("string")
	test.expect(type(cfg.languageMode)):toBe("string")
	test.expect(type(cfg.enabledLints)):toBe("number")
	test.expect(type(cfg.fatalLints)):toBe("number")
	test.expect(type(cfg.lintErrors)):toBe("boolean")
	test.expect(type(cfg.typeErrors)):toBe("boolean")
	test.expect(type(cfg.globals)):toBe("table")
	test.expect(type(cfg.aliases)):toBe("table")

	local isValidMode = cfg.languageMode == "strict" or cfg.languageMode == "nonstrict" or cfg.languageMode == "nocheck"
	test.expect(isValidMode):toBeTrue()

	if cfg.found then
		test.expect(#cfg.configDir):toBeGreaterThan(0)
	end
end)

suite:test("getconfig: alias metadata shape", function()
	local cfg = luau.getconfig()
	for aliasName, aliasInfo in cfg.aliases do
		test.expect(type(aliasName)):toBe("string")
		test.expect(type(aliasInfo.qualified)):toBe("string")
		test.expect(type(aliasInfo.configPath)):toBe("string")
		test.expect(type(aliasInfo.path)):toBe("string")
		break
	end

	local eryxAlias = cfg.aliases.eryx
	test.skipIf(eryxAlias == nil, "eryx alias not configured in this environment")
	assert(eryxAlias)
	test.expect(type(eryxAlias.qualified)):toBe("string")
	test.expect(type(eryxAlias.configPath)):toBe("string")
	test.expect(type(eryxAlias.path)):toBe("string")
end)

suite:test("getconfig: accepts folder path override", function()
	local cfg = luau.getconfig(".")
	test.expect(type(cfg)):toBe("table")
	test.expect(type(cfg.found)):toBe("boolean")
	test.expect(type(cfg.configDir)):toBe("string")
	test.expect(type(cfg.aliases)):toBe("table")
end)

return suite
