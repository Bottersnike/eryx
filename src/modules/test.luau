local exception = require("@eryx/exception")
local fs = require("@eryx/fs")
local luau = require("@eryx/luau")
local pprint = require("@eryx/pprint")
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")

local test = {}

-- ── ANSI colour helpers ──────────────────────────────────────────────────────

local COLOR: boolean do
	-- Honour https://no-color.org/
	if os.getenv("NO_COLOR") then
		COLOR = false
	elseif os.getenv("FORCE_COLOR") then
		COLOR = true
	else
		COLOR = stdio.isatty().stdout
	end
end

local function ansi(code: string, s: string): string
	if not COLOR then return s end
	return `\27[{code}m{s}\27[0m`
end

local function green(s: string)  return ansi("32",   s) end
local function red(s: string)    return ansi("31",   s) end
local function cyan(s: string)   return ansi("36",   s) end
local function bold(s: string)   return ansi("1",    s) end
local function dim(s: string)    return ansi("2",    s) end

local function fmtErr(err: any): string
	return exception.format(err :: exception.Exception)
end

-- ── Types ────────────────────────────────────────────────────────────────────

type Test = {
	name: string,
	runner: () -> (),
}

type TestResult = {
	name: string,
	passed: boolean,
	err: string?,
	duration: number,
}

type RunTotals = { passed: number, failed: number }

-- ── Suite ────────────────────────────────────────────────────────────────────

local Suite = {}
Suite.__index = Suite
export type Suite = setmetatable<{
	read name: string,
	read tests: { Test },
	read results: { TestResult },
	beforeAll: (() -> ())?,
	afterAll: (() -> ())?,
	beforeEach: (() -> ())?,
	afterEach: (() -> ())?,
}, typeof(Suite)>

function Suite.new(name: string): Suite
	return setmetatable({
		name = name,
		tests = {},
		results = {},
		beforeAll = nil :: (() -> ())?,
		afterAll = nil :: (() -> ())?,
		beforeEach = nil :: (() -> ())?,
		afterEach = nil :: (() -> ())?,
	}, Suite)
end

--- Register a test case.
function Suite.Test(self: Suite, name: string, runner: () -> ())
	table.insert(self.tests, { name = name, runner = runner })
end

--- Run once before all tests in this suite.
function Suite.BeforeAll(self: Suite, fn: () -> ())
	self.beforeAll = fn
end

--- Run once after all tests in this suite.
function Suite.AfterAll(self: Suite, fn: () -> ())
	self.afterAll = fn
end

--- Run before each individual test.
function Suite.BeforeEach(self: Suite, fn: () -> ())
	self.beforeEach = fn
end

--- Run after each individual test.
function Suite.AfterEach(self: Suite, fn: () -> ())
	self.afterEach = fn
end

--- Execute all tests in the suite and print results.  Returns pass/fail totals.
function Suite.Run(self: Suite): RunTotals
	local passed = 0
	local failed = 0

	stdio.write(bold(cyan(`  > {self.name}\n`)))

	if self.beforeAll then
		local r = table.pack(pcall(self.beforeAll :: () -> ()))
		local ok, err = r[1], r[2]
		if not ok then
			stdio.write(red(`    beforeAll failed: {fmtErr(err)}\n\n`))
			return { passed = 0, failed = #self.tests }
		end
	end

	for _, t in self.tests do
		if self.beforeEach then
			pcall(self.beforeEach :: () -> ())
		end

		local t0 = os.clock()
		local ok, err = pcall(t.runner)
		local elapsed = string.format("%.2fms", (os.clock() - t0) * 1000)

		if ok then
			passed += 1
			stdio.write(`    {green("+")} {dim(t.name)} {dim(elapsed)}\n`)
			table.insert(self.results, { name = t.name, passed = true, duration = os.clock() - t0 })
		else
			failed += 1
			local msg = fmtErr(err)
			stdio.write(`    {red("!")} {bold(t.name)} {dim(elapsed)}\n`)
			-- Indent each line of the error message
			for line in msg:gmatch("[^\n]+") do
				stdio.write(`      {red(line)}\n`)
			end
			table.insert(self.results, { name = t.name, passed = false, err = msg, duration = os.clock() - t0 })
		end

		if self.afterEach then
			pcall(self.afterEach :: () -> ())
		end
	end

	if self.afterAll then
		pcall(self.afterAll :: () -> ())
	end

	return { passed = passed, failed = failed }
end

test.Suite = Suite

-- ── Expecter ─────────────────────────────────────────────────────────────────

local Expecter = {}
Expecter.__index = Expecter
type Expecter = setmetatable<{
	values: { [number]: any, n: number },
}, typeof(Expecter)>

local function fmt(v: any): string
	return pprint.format(v)
end

function Expecter.new(...: any): Expecter
	return setmetatable({ values = table.pack(...) }, Expecter)
end

-- Equality / inequality -------------------------------------------------------

--- Assert that the returned values equal `...` (via `==`).
function Expecter.ToBe(self: Expecter, ...: any)
	local expect = table.pack(...)
	if expect.n ~= self.values.n then
		error(`Expected {expect.n} return value(s) but got {self.values.n}`, 2)
	end
	for i = 1, expect.n do
		if expect[i] ~= self.values[i] then
			error(`Return {i}: expected {fmt(expect[i])} but got {fmt(self.values[i])}`, 2)
		end
	end
end

--- Assert that the first returned value does NOT equal `value`.
function Expecter.ToNotBe(self: Expecter, value: any)
	if self.values[1] == value then
		error(`Expected value to not be {fmt(value)}`, 2)
	end
end

-- Nil / existence -------------------------------------------------------------

--- Assert that at least one value was returned.
function Expecter.ToExist(self: Expecter)
	if self.values.n == 0 then
		error("Expected a return value but the function returned nothing", 2)
	end
end

--- Assert that the first returned value is not nil (and that something was returned).
function Expecter.ToNotBeNil(self: Expecter)
	if self.values.n == 0 then
		error("Expected a non-nil return but the function returned nothing", 2)
	end
	if self.values[1] == nil then
		error("Expected a non-nil return but got nil", 2)
	end
end

--- Assert that the first returned value is nil.
function Expecter.ToBeNil(self: Expecter)
	if self.values[1] ~= nil then
		error(`Expected nil but got {fmt(self.values[1])}`, 2)
	end
end

-- Boolean / truthy ------------------------------------------------------------

--- Assert that the first returned value is exactly `true`.
function Expecter.ToBeTrue(self: Expecter)
	if self.values[1] ~= true then
		error(`Expected true but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is exactly `false`.
function Expecter.ToBeFalse(self: Expecter)
	if self.values[1] ~= false then
		error(`Expected false but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is truthy (not nil and not false).
function Expecter.ToBeTruthy(self: Expecter)
	if not self.values[1] then
		error(`Expected a truthy value but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is falsy (nil or false).
function Expecter.ToBeFalsy(self: Expecter)
	if self.values[1] then
		error(`Expected a falsy value but got {fmt(self.values[1])}`, 2)
	end
end

-- Type checking ---------------------------------------------------------------

--- Assert that `type(value) == expected`.
function Expecter.ToBeType(self: Expecter, expected: string)
	local got = type(self.values[1])
	if got ~= expected then
		error(`Expected type "{expected}" but got "{got}"`, 2)
	end
end

-- Length / containment --------------------------------------------------------

--- Assert that `#value == length`.
function Expecter.ToHaveLength(self: Expecter, length: number)
	if self.values.n == 0 then
		error("Expected a return value but the function returned nothing", 2)
	end
	local actual = #self.values[1]
	if actual ~= length then
		error(`Expected length {length} but got {actual}`, 2)
	end
end

--- Assert that a string contains `item` as a plain substring, or that a table contains `item` as a value.
function Expecter.ToContain(self: Expecter, item: any)
	local val = self.values[1]
	if type(val) == "string" then
		if not string.find(val, tostring(item), 1, true) then
			error(`Expected string to contain {fmt(item)}`, 2)
		end
	elseif type(val) == "table" then
		for _, v in val do
			if v == item then return end
		end
		error(`Expected table to contain {fmt(item)}`, 2)
	else
		error(`ToContain is not supported for type "{type(val)}"`, 2)
	end
end

--- Assert that a string matches a Lua pattern.
function Expecter.ToMatch(self: Expecter, pattern: string)
	local val = self.values[1]
	if type(val) ~= "string" then
		error(`ToMatch requires a string but got "{type(val)}"`, 2)
	end
	if not string.match(val, pattern) then
		error(`Expected {fmt(val)} to match pattern {fmt(pattern)}`, 2)
	end
end

-- Numeric comparisons ---------------------------------------------------------

function Expecter.ToBeGreaterThan(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeGreaterThan requires a number but got "{type(val)}"`, 2)
	end
	if not (val > n) then
		error(`Expected {val} > {n}`, 2)
	end
end

function Expecter.ToBeLessThan(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeLessThan requires a number but got "{type(val)}"`, 2)
	end
	if not (val < n) then
		error(`Expected {val} < {n}`, 2)
	end
end

function Expecter.ToBeGreaterThanOrEqual(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeGreaterThanOrEqual requires a number but got "{type(val)}"`, 2)
	end
	if not (val >= n) then
		error(`Expected {val} >= {n}`, 2)
	end
end

function Expecter.ToBeLessThanOrEqual(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeLessThanOrEqual requires a number but got "{type(val)}"`, 2)
	end
	if not (val <= n) then
		error(`Expected {val} <= {n}`, 2)
	end
end

--- Assert that two numbers are within `epsilon` of each other (default 1e-9).
function Expecter.ToBeCloseTo(self: Expecter, expected: number, epsilon: number?)
	local eps = epsilon or 1e-9
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeCloseTo requires a number but got "{type(val)}"`, 2)
	end
	if math.abs(val - expected) > eps then
		error(`Expected {val} to be within {eps} of {expected}`, 2)
	end
end

-- Error handling --------------------------------------------------------------

--- Assert that a function throws.  If `match` is provided, the error message must match that Lua pattern.
function Expecter.ToError(self: Expecter, match: string?)
	if type(self.values[1]) ~= "function" then
		error("ToError() requires a function argument", 2)
	end
	local r = table.pack(pcall(self.values[1] :: () -> ()))
	local ok, err = r[1], r[2]
	if ok then
		error("Expected the function to throw an error but it succeeded", 2)
	end
	if match then
		local msg = ((err :: any) :: exception.Exception).message
		if not string.match(msg, match) then
			error(`Expected error matching pattern {fmt(match)} but got {fmt(msg)}`, 2)
		end
	end
end

--- Assert that a function does NOT throw.
function Expecter.ToNotError(self: Expecter)
	if type(self.values[1]) ~= "function" then
		error("ToNotError() requires a function argument", 2)
	end
	local r = table.pack(pcall(self.values[1] :: () -> ()))
	local ok, err = r[1], r[2]
	if not ok then
		error(`Expected the function not to throw but got: {fmtErr(err)}`, 2)
	end
end

function test.expect(...: any): Expecter
	return Expecter.new(...)
end

-- ── File loading ─────────────────────────────────────────────────────────────

-- Loads a .test.luau file and returns the Suite it returns, or errors.
local function load_test_file(path: string): Suite
	local source = fs.readFile(path)
	local fn = luau.load(source, `@{path}`)
	local suite = fn()
	if type(suite) ~= "table" or getmetatable(suite) ~= Suite then
		error(`{path} did not return a Suite`)
	end
	return suite :: Suite
end

-- ── runOne ────────────────────────────────────────────────────────────────────

--- Load and run a single `.test.luau` file. Exits with code 1 on failure
--- when `exitOnFail` is true (the default).
function test.runOne(path: string, exitOnFail: boolean?)
	if exitOnFail == nil then exitOnFail = true end

	local ok, result = pcall(load_test_file, path)
	if not ok then
		stdio.write(red(`Failed to load {path}:\n{fmtErr(result)}\n`))
		if exitOnFail then os.exit(1) end
		return { passed = 0, failed = 1 }
	end

	local totals = result:Run()
	stdio.write("\n")

	if totals.failed > 0 then
		stdio.write(bold(red("Failed:\n\n")))
		for _, r in result.results do
			if not r.passed then
				stdio.write(`  {red("!")} {bold(r.name)}\n`)
				for line in (r.err or ""):gmatch("[^\n]+") do
					stdio.write(`      {red(line)}\n`)
				end
				stdio.write("\n")
			end
		end
	end

	if exitOnFail and totals.failed > 0 then
		os.exit(1)
	end

	return totals
end

-- ── runAll ───────────────────────────────────────────────────────────────────

--[=[
	Walk `path` recursively for files matching `*.test.luau`.
	Each such file must `return` a `Suite`.

	If `exitOnFail` is true (the default), the process exits with code 1 when
	any test fails.
]=]
function test.runAll(path: string, exitOnFail: boolean?)
	if exitOnFail == nil then exitOnFail = true end

	local totalPassed = 0
	local totalFailed = 0
	local suiteCount = 0
	local t0 = os.clock()

	type FailEntry = { suite: string, name: string, err: string }
	local failures: { FailEntry } = {}

	stdio.write(bold(`\nRunning tests in {path}\n\n`))

	local function walk(dir: string)
		local entries = fs.listDir(dir)
		table.sort(entries)
		for _, entry in entries do
			local full = fs.join(dir, entry)
			if fs.isDirectory(full) then
				walk(full)
			elseif entry:match("%.test%.luau$") then
				local ok, suite = pcall(load_test_file, full)
				if not ok then
					stdio.write(red(`  Failed to load {full}:\n  {fmtErr(suite)}\n\n`))
					totalFailed += 1
					continue
				end
				local s = suite :: Suite
				local totals = s:Run()
				totalPassed += totals.passed
				totalFailed += totals.failed
				suiteCount += 1
				stdio.write("\n")
				for _, r in s.results do
					if not r.passed then
						local fe: FailEntry = { suite = s.name, name = r.name, err = (r.err or "") :: string }
					table.insert(failures, fe)
					end
				end
			end
		end
	end

	walk(path)

	-- ── Summary ──────────────────────────────────────────────────────────────
	local elapsed = string.format("%.2fms", (os.clock() - t0) * 1000)
	local total = totalPassed + totalFailed
	local sep = string.rep("-", 40)

	stdio.write(`{sep}\n`)
	stdio.write(bold(` Suites:  {suiteCount}\n`))
	if totalFailed > 0 then
		stdio.write(` Tests:   {green(`{totalPassed} passed`)}, {red(`{totalFailed} failed`)}, {total} total\n`)
	else
		stdio.write(` Tests:   {green(`{totalPassed} passed`)}, {total} total\n`)
	end
	stdio.write(` Time:    {elapsed}\n`)
	stdio.write(`{sep}\n`)

	if #failures > 0 then
		stdio.write(bold(red("\nFailed:\n\n")))
		for _, f in failures do
			stdio.write(`  {red("!")} {bold(f.suite)} > {bold(f.name)}\n`)
			for line in f.err:gmatch("[^\n]+") do
				stdio.write(`      {red(line)}\n`)
			end
			stdio.write("\n")
		end
	else
		stdio.write("\n")
	end

	if exitOnFail and totalFailed > 0 then
		os.exit(1)
	end

	return { passed = totalPassed, failed = totalFailed }
end

return test
