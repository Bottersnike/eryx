local test = require("@eryx/test")
local luauAnalysis = require("@eryx/luau/analysis")

local suite = test.Suite.new("luau/analysis")

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

suite:test("check: reports type errors", function()
	local result = luauAnalysis.check("local x: string = 1")
	test.expect(type(result.errors)):toBe("table")
	test.expect(#result.errors):toBeGreaterThan(0)
	test.expect(result.errors[1].category):toBeType("string")
end)

suite:test("check: exposes lint diagnostics", function()
	local result = luauAnalysis.check("local x = 1")
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
	local ty = luauAnalysis.typeAt(source, 2, 11)
	test.expect(ty):toBeType("string")
end)

suite:test("typeAt: detailed mode", function()
	local source = "local x = {a = 1, b = 'ok'}\nlocal y = x"
	local out = luauAnalysis.typeAt(source, 2, 11, { detailed = true })
	test.expect(out):toBeType("table")
	assert(typeof(out) == "table") -- for types
	test.expect(out.display):toBeType("string")
	test.expect(out.source):toBeType("string")
	test.expect(out.type):toBeType("table")
	test.expect(out.type.kind):toBeType("string")
end)

suite:test("typeofModule: classic string mode", function()
	local source = "return { answer = 42 }"
	local out = luauAnalysis.typeofModule(source)
	test.expect(out):toBeType("string")
end)

suite:test("typeofModule: detailed mode", function()
	local source = "return { answer = 42 }, 'ok'"
	local out = luauAnalysis.typeofModule(source, { detailed = true })
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
	local out = luauAnalysis.autocomplete(source, 2, 3, { detailed = true })
	test.expect(out.context):toBeType("string")
	test.expect(type(out.entries)):toBe("table")
	test.expect(out.entries.foo):toNotBeNil()
	test.expect(out.entries.foo.kind):toBe("Property")
	test.expect(out.entries.foo.typeDetail):toBeType("table")
	assert(typeof(out.entries.foo.typeDetail) == "table") -- for types
	test.expect(out.entries.foo.typeDetail.kind):toBeType("string")
end)

suite:test("getconfig: exposes current config shape", function()
	local cfg = luauAnalysis.getconfig()
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
	local cfg = luauAnalysis.getconfig()
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
	local cfg = luauAnalysis.getconfig(".")
	test.expect(type(cfg)):toBe("table")
	test.expect(type(cfg.found)):toBe("boolean")
	test.expect(type(cfg.configDir)):toBe("string")
	test.expect(type(cfg.aliases)):toBe("table")
end)

return suite
