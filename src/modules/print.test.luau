local fs = require("@eryx/fs")
local os = require("@eryx/os")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("print")

local function normalizeNewlines(s: string): string
	return (s:gsub("\r\n", "\n"))
end

local function writeFile(path: string, content: string)
	local file = fs.openSync(path, "w")
	file:writeSync(content)
	file:closeSync()
end

local function runPrintScript(source: string, envOverrides: { [string]: string? }): os.ExecResult
	return tempfile.withTempDir(function(dir)
		local scriptPath = fs.path.join(dir, "print-smoke.luau")
		writeFile(scriptPath, source)

		local parentEnv = os.environ()
		local env = {
			PATH = parentEnv.PATH,
			Path = parentEnv.Path,
			SystemRoot = parentEnv.SystemRoot,
			WINDIR = parentEnv.WINDIR,
			TEMP = parentEnv.TEMP,
			TMP = parentEnv.TMP,
			ERYX_EXE_PATH = tostring(os.currentEryxBinary()),
		}
		for key, value in envOverrides do
			env[key] = value
		end

		return os.exec(os.currentEryxBinary(), { scriptPath }, {
			cwd = dir,
			env = env,
		})
	end, "eryx-print-test")
end

local function runPlain(source: string): string
	local result = runPrintScript(source, {
		NO_COLOR = "1",
		FORCE_COLOR = nil,
	})

	test.expect(result.code):toBe(0)
	test.expect(result.stderr):toBe("")
	return normalizeNewlines(result.stdout)
end

suite:test("formats primitive multi-values", function()
	test.expect(runPlain([[print("hello", nil, true, false, 12)]])):toBe("hello nil true false 12\n")
end)

suite:test("prints top-level strings plain and nested strings quoted", function()
	test.expect(runPlain([[print("plain", { message = "hello\nworld", tab = "\t" })]]))
		:toBe(
			"plain {\n"
				.. '    message = "hello\\n" ..\n'
				.. '              "world",\n'
				.. '    tab = "\\t",\n'
				.. "}\n"
		)
end)

suite:test("formats arrays and maps deterministically", function()
	test.expect(runPlain([[print({ "a", "b" }, { b = 2, a = 1, ["end"] = "keyword", [3] = "three" })]])):toBe(
		"{\n"
			.. '    "a",\n'
			.. '    "b",\n'
			.. "} {\n"
			.. '    [3] = "three",\n'
			.. "    a = 1,\n"
			.. "    b = 2,\n"
			.. '    ["end"] = "keyword",\n'
			.. "}\n"
	)
end)

suite:test("prints empty and deeply nested acyclic tables", function()
	local output = runPlain([[
local t = { child = { child = { value = "leaf" } } }
print({}, t)
]])

	test.expect(output):toBe(
		"{ } {\n"
			.. "    child = {\n"
			.. "        child = {\n"
			.. '            value = "leaf",\n'
			.. "        },\n"
			.. "    },\n"
			.. "}\n"
	)
	test.expect(output:find("{ ... }", 1, true)):toBeNil()
end)

suite:test("prints recursive tables as ellipsis", function()
	test.expect(runPlain([[
local t = { name = "Ada" }
t.self = t
print(t)
]])):toBe("{\n" .. '    name = "Ada",\n' .. "    self = { ... },\n" .. "}\n")
end)

suite:test("uses table __type and __tostring metadata", function()
	test.expect(runPlain([[
local typed = setmetatable({}, { __type = "Box" })
local both = setmetatable({}, {
    __type = "Label",
    __tostring = function()
        return "primary"
    end,
})
local stringMeta = setmetatable({}, { __tostring = "literal" })
print(typed, both, stringMeta)
]])):toBe("<Box> <Label(primary)> literal\n")
end)

suite:test("prints table metatables as synthetic red keys", function()
	test.expect(runPlain([[
local t = setmetatable({ value = 1 }, { tag = "meta" })
print(t)
]])):toBe("{\n" .. "    value = 1,\n" .. "    @metatable = {\n" .. '        tag = "meta",\n' .. "    },\n" .. "}\n")
end)

suite:test("marks locked table metatables", function()
	test.expect(runPlain([[
local t = setmetatable({ value = 1 }, { __metatable = "locked", secret = true })
print(t)
]])):toBe(
		"{\n"
			.. "    value = 1,\n"
			.. "    @metatable<locked> = {\n"
			.. '        __metatable = "locked",\n'
			.. "        secret = true,\n"
			.. "    },\n"
			.. "}\n"
	)
end)

suite:test("marks frozen tables", function()
	test.expect(runPlain([[
print(table.freeze({ value = 1 }))
]])):toBe("{<frozen>\n" .. "    value = 1,\n" .. "}\n")
end)

suite:test("stdio.configurePrint can hide frozen markers", function()
	test.expect(runPlain([[
local stdio = require("@eryx/stdio")
local config = stdio.configurePrint({ showFrozen = false })
print(config.showFrozen)
print(table.freeze({ value = 1 }))
]])):toBe("false\n" .. "{\n" .. "    value = 1,\n" .. "}\n")
end)

suite:test("formats named and anonymous functions with pointers", function()
	local output = runPlain([[
local function namedPrintTarget() end
print(namedPrintTarget, function() end)
]])

	test.expect(output):toMatch("^function namedPrintTarget<0x%x+> function<0x%x+>\n$")
end)

suite:test("formats threads and buffers with pointers", function()
	local output = runPlain([[
print(coroutine.create(function() end))
print(buffer.fromstring("hello"))
print(buffer.fromstring("0123456789abcdef0123456789abcdef"))
]])

	test.expect(output):toMatch("^thread<0x%x+>\n")
	test.expect(output):toMatch("\nbuffer<0x%x+>%(68656c6c6f%)\n")
	test.expect(output):toMatch("\nbuffer<0x%x+>%(30313233343536373839616263646566%.%.%.%)\n$")
end)

suite:test("emits ANSI colours when forced", function()
	local result = runPrintScript([[print({ n = 1, s = "x", ok = true })]], {
		NO_COLOR = nil,
		FORCE_COLOR = "1",
	})

	test.expect(result.code):toBe(0)
	local output = normalizeNewlines(result.stdout)
	test.expect(output):toContain("{")
	test.expect(output):toContain("\27[36m1\27[0m")
	test.expect(output):toContain('\27[32m"x"\27[0m')
	test.expect(output):toContain("\27[33mtrue\27[0m")
end)

suite:test("emits red functions and metatable keys when forced", function()
	local result = runPrintScript(
		[[
local function namedColorTarget() end
print(namedColorTarget)
print(setmetatable({}, { tag = "meta" }))
]],
		{
			NO_COLOR = nil,
			FORCE_COLOR = "1",
		}
	)

	test.expect(result.code):toBe(0)
	local output = normalizeNewlines(result.stdout)
	test.expect(output):toMatch("\27%[31mfunction namedColorTarget<0x%x+>\27%[0m")
	test.expect(output):toContain("\27[31m@metatable\27[0m")
end)

suite:test("stdio.configurePrint controls indentation and compact mode", function()
	local output = runPlain([[
local stdio = require("@eryx/stdio")
local config = stdio.configurePrint({ indentation = 2 })
print(config.indentation, config.multiline)
print({ child = { value = 1 } })
stdio.configurePrint({ multiline = false })
print({ child = { value = 1 } })
]])

	test.expect(output):toBe(
		"2 true\n"
			.. "{\n"
			.. "  child = {\n"
			.. "    value = 1,\n"
			.. "  },\n"
			.. "}\n"
			.. "{ child = { value = 1 } }\n"
	)
end)

suite:test("stdio.configurePrint controls entry and depth limits", function()
	local output = runPlain([[
local stdio = require("@eryx/stdio")
stdio.configurePrint({ maxEntries = 2, maxDepth = 2 })
print({ a = 1, b = 2, c = 3, child = { nested = { value = 4 } } })
local config = stdio.configurePrint({ maxEntries = -1, maxDepth = -1 })
print(config.maxEntries, config.maxDepth)
]])

	test.expect(output)
		:toBe("{\n" .. "    a = 1,\n" .. "    b = 2,\n" .. "    ... 2 entries omitted,\n" .. "}\n" .. "nil nil\n")
end)

return suite
