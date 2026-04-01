local exception = require("@eryx/exception")
local fs = require("@eryx/fs")
local luau = require("@eryx/luau")
local pprint = require("@eryx/pprint")
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")

local test = {}

-- ── ANSI colour helpers ──────────────────────────────────────────────────────

local COLOR: boolean
do
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
	if not COLOR then
		return s
	end
	return `\27[{code}m{s}\27[0m`
end

local function green(s: string)
	return ansi("32", s)
end
local function red(s: string)
	return ansi("31", s)
end
local function cyan(s: string)
	return ansi("36", s)
end
local function bold(s: string)
	return ansi("1", s)
end
local function dim(s: string)
	return ansi("2", s)
end

local function fmtErr(err: any): string
	return exception.format(err :: exception.Exception, COLOR)
end

-- ── Types ────────────────────────────────────────────────────────────────────

type Test = {
	name: string,
	runner: () -> (),
}

type TestResult = {
	name: string,
	passed: boolean,
	skipped: boolean,
	skipReason: string?,
	err: string?,
	duration: number,
}

type RunTotals = { passed: number, failed: number, skipped: number }

--- Sentinel type thrown by test.skip() / test.skipIf() to signal a skip.
local SKIP_SENTINEL = newproxy(false)
type SkipSignal = { __skip: typeof(SKIP_SENTINEL), reason: string? }

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
function Suite.test(self: Suite, name: string, runner: () -> ())
	table.insert(self.tests, { name = name, runner = runner })
end

--- Run once before all tests in this suite.
function Suite.beforeAll(self: Suite, fn: () -> ())
	self.beforeAll = fn
end

--- Run once after all tests in this suite.
function Suite.afterAll(self: Suite, fn: () -> ())
	self.afterAll = fn
end

--- Run before each individual test.
function Suite.beforeEach(self: Suite, fn: () -> ())
	self.beforeEach = fn
end

--- Run after each individual test.
function Suite.afterEach(self: Suite, fn: () -> ())
	self.afterEach = fn
end

--[=[
	Execute all tests in the suite and print results.

	@param filter  Optional Lua pattern. When provided, only tests whose name
	               matches the pattern are executed; the rest are skipped.
	@return RunTotals -- pass/fail/skip counts.
]=]
function Suite.run(self: Suite, filter: string?): RunTotals
	local passed = 0
	local failed = 0
	local skipped = 0

	stdio.write(bold(cyan(`  > {self.name}\n`)))

	if self.beforeAll then
		local r = table.pack(pcall(self.beforeAll :: (self: Suite) -> (), self))
		local ok, err = r[1], r[2]
		if not ok then
			stdio.write(red(`    beforeAll failed: {fmtErr(err)}\n\n`))
			return { passed = 0, failed = #self.tests, skipped = 0 }
		end
	end

	for _, t in self.tests do
		-- Filter by name pattern
		if filter and not string.find(t.name, filter) then
			skipped += 1
			stdio.write(`    {dim("-")} {dim(t.name)} {dim("(filtered)")}\n`)
			table.insert(self.results, {
				name = t.name,
				passed = true,
				skipped = true,
				duration = 0,
			})
			continue
		end

		if self.beforeEach then
			pcall(self.beforeEach :: () -> ())
		end

		local t0 = os.clock()
		local ok, err = pcall(t.runner)
		local elapsed = string.format("%.2fms", (os.clock() - t0) * 1000)

		-- Check if the test called test.skip() / test.skipIf()
		if not ok and type(err.data) == "table" and (err.data :: SkipSignal).__skip == SKIP_SENTINEL then
			skipped += 1
			local reason = (err.data :: SkipSignal).reason
			local label = if reason then `(skipped: {reason})` else "(skipped)"
			stdio.write(`    {dim("-")} {dim(t.name)} {dim(label)}\n`)
			table.insert(self.results, {
				name = t.name,
				passed = true,
				skipped = true,
				skipReason = reason,
				duration = os.clock() - t0,
			})
		elseif ok then
			passed += 1
			stdio.write(`    {green("+")} {dim(t.name)} {dim(elapsed)}\n`)
			table.insert(self.results, {
				name = t.name,
				passed = true,
				skipped = false,
				duration = os.clock() - t0,
			})
		else
			failed += 1
			local msg = fmtErr(err)
			stdio.write(`    {red("!")} {bold(t.name)} {dim(elapsed)}\n`)
			for line in msg:gmatch("[^\n]+") do
				stdio.write(`      {red(line)}\n`)
			end
			table.insert(self.results, {
				name = t.name,
				passed = false,
				skipped = false,
				err = msg,
				duration = os.clock() - t0,
			})
		end

		if self.afterEach then
			pcall(self.afterEach :: () -> ())
		end
	end

	if self.afterAll then
		pcall(self.afterAll :: () -> ())
	end

	return { passed = passed, failed = failed, skipped = skipped }
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
function Expecter.toBe(self: Expecter, ...: any)
	local expect = table.pack(...)
	if expect.n ~= self.values.n then
		error(`Expected {expect.n} return value(s) but got {self.values.n}`, 2)
	end
	for i = 1, expect.n do
		if expect[i] ~= self.values[i] then
			if #self.values == 1 then
				error(`expected {fmt(expect[i])} but got {fmt(self.values[i])}`, 2)
			else
				error(`Return #{i}: expected {fmt(expect[i])} but got {fmt(self.values[i])}`, 2)
			end
		end
	end
end

--- Assert that the first returned value does NOT equal `value`.
function Expecter.toNotBe(self: Expecter, value: any)
	if self.values[1] == value then
		error(`Expected value to not be {fmt(value)}`, 2)
	end
end

-- Nil / existence -------------------------------------------------------------

--- Assert that at least one value was returned.
function Expecter.toExist(self: Expecter)
	if self.values.n == 0 then
		error("Expected a return value but the function returned nothing", 2)
	end
end

--- Assert that the first returned value is not nil (and that something was returned).
function Expecter.toNotBeNil(self: Expecter)
	if self.values.n == 0 then
		error("Expected a non-nil return but the function returned nothing", 2)
	end
	if self.values[1] == nil then
		error("Expected a non-nil return but got nil", 2)
	end
end

--- Assert that the first returned value is nil.
function Expecter.toBeNil(self: Expecter)
	if self.values[1] ~= nil then
		error(`Expected nil but got {fmt(self.values[1])}`, 2)
	end
end

-- Boolean / truthy ------------------------------------------------------------

--- Assert that the first returned value is exactly `true`.
function Expecter.toBeTrue(self: Expecter)
	if self.values[1] ~= true then
		error(`Expected true but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is exactly `false`.
function Expecter.toBeFalse(self: Expecter)
	if self.values[1] ~= false then
		error(`Expected false but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is truthy (not nil and not false).
function Expecter.toBeTruthy(self: Expecter)
	if not self.values[1] then
		error(`Expected a truthy value but got {fmt(self.values[1])}`, 2)
	end
end

--- Assert that the first returned value is falsy (nil or false).
function Expecter.toBeFalsy(self: Expecter)
	if self.values[1] then
		error(`Expected a falsy value but got {fmt(self.values[1])}`, 2)
	end
end

-- Type checking ---------------------------------------------------------------

--- Assert that `type(value) == expected`.
function Expecter.toBeType(self: Expecter, expected: string)
	local got = type(self.values[1])
	if got ~= expected then
		error(`Expected type "{expected}" but got "{got}"`, 2)
	end
end

-- Length / containment --------------------------------------------------------

--- Assert that `#value == length`.
function Expecter.toHaveLength(self: Expecter, length: number)
	if self.values.n == 0 then
		error("Expected a return value but the function returned nothing", 2)
	end
	local actual = #self.values[1]
	if actual ~= length then
		error(`Expected length {length} but got {actual}`, 2)
	end
end

--- Assert that a string contains `item` as a plain substring, or that a table contains `item` as a value.
function Expecter.toContain(self: Expecter, item: any)
	local val = self.values[1]
	if type(val) == "string" then
		if not string.find(val, tostring(item), 1, true) then
			error(`Expected string to contain {fmt(item)}`, 2)
		end
	elseif type(val) == "table" then
		for _, v in val do
			if v == item then
				return
			end
		end
		error(`Expected table to contain {fmt(item)}`, 2)
	else
		error(`ToContain is not supported for type "{type(val)}"`, 2)
	end
end

--- Assert that a string matches a Lua pattern.
function Expecter.toMatch(self: Expecter, pattern: string)
	local val = self.values[1]
	if type(val) ~= "string" then
		error(`ToMatch requires a string but got "{type(val)}"`, 2)
	end
	if not string.match(val, pattern) then
		error(`Expected {fmt(val)} to match pattern {fmt(pattern)}`, 2)
	end
end

-- Numeric comparisons ---------------------------------------------------------

function Expecter.toBeGreaterThan(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeGreaterThan requires a number but got "{type(val)}"`, 2)
	end
	if not (val > n) then
		error(`Expected {val} > {n}`, 2)
	end
end

function Expecter.toBeLessThan(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeLessThan requires a number but got "{type(val)}"`, 2)
	end
	if not (val < n) then
		error(`Expected {val} < {n}`, 2)
	end
end

function Expecter.toBeGreaterThanOrEqual(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeGreaterThanOrEqual requires a number but got "{type(val)}"`, 2)
	end
	if not (val >= n) then
		error(`Expected {val} >= {n}`, 2)
	end
end

function Expecter.toBeLessThanOrEqual(self: Expecter, n: number)
	local val = self.values[1]
	if type(val) ~= "number" then
		error(`ToBeLessThanOrEqual requires a number but got "{type(val)}"`, 2)
	end
	if not (val <= n) then
		error(`Expected {val} <= {n}`, 2)
	end
end

--- Assert that two numbers are within `epsilon` of each other (default 1e-9).
function Expecter.toBeCloseTo(self: Expecter, expected: number, epsilon: number?)
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
function Expecter.toError(self: Expecter, match: string?)
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
function Expecter.toNotError(self: Expecter)
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

--[=[
	Unconditionally skips the current test. Call at the top of a test body
	to mark it as not-yet-implemented or temporarily disabled.

	```luau
	suite:test("future feature", function()
	    test.skip("not implemented yet")
	end)
	```

	@param reason  Optional human-readable reason shown in the test output.
]=]
function test.skip(reason: string?)
	error({ __skip = SKIP_SENTINEL, reason = reason } :: SkipSignal)
end

--[=[
	Conditionally skips the current test when `condition` is truthy.
	Use this for platform-specific tests, tests that require external
	services, or environment-dependent checks.

	```luau
	suite:test("unix permissions", function()
	    test.skipIf(os.platform() == "windows", "unix-only test")
	    -- ... test code ...
	end)
	```

	@param condition  When truthy, the test is skipped.
	@param reason     Optional reason shown in the test output.
]=]
function test.skipIf(condition: any, reason: string?)
	if condition then
		error({ __skip = SKIP_SENTINEL, reason = reason } :: SkipSignal)
	end
end

-- ── File loading ─────────────────────────────────────────────────────────────

-- Loads a .test.luau file and returns the Suite it returns, or errors.
local function load_test_file(path: string): Suite
	local source = fs.openSync(path):readSync()
	local fn = luau.load(source, `@{path}`)
	local suite = fn()
	if type(suite) ~= "table" or getmetatable(suite) ~= Suite then
		error(`{path} did not return a Suite`)
	end
	return suite :: Suite
end

-- ── runOne ────────────────────────────────────────────────────────────────────

--[=[
	Options for [[runOne]] and [[runAll]].
]=]
export type RunOptions = {
	--- Exit the process with code 1 when any test fails. Defaults to true.
	exitOnFail: boolean?,
	--- Lua pattern matched against test names. Only matching tests run;
	--- the rest are skipped. Equivalent to Jest's `-t` / `--testNamePattern`.
	filter: string?,
}

--[=[
	Load and run a single `.test.luau` file.

	@param path The path to the test file.
	@param options Run options (exitOnFail, filter).
]=]
function test.runOne(path: string, options: RunOptions?)
	local opts: RunOptions = options or {}
	local exitOnFail = if opts.exitOnFail ~= nil then opts.exitOnFail else true

	local ok, result = pcall(load_test_file, path)
	if not ok then
		stdio.write(red(`Failed to load {path}:\n{fmtErr(result)}\n`))
		if exitOnFail then
			os.exit(1)
		end
		return { passed = 0, failed = 1, skipped = 0 }
	end

	local totals = result:run(opts.filter)
	stdio.write("\n")

	if totals.failed > 0 then
		stdio.write(bold(red("Failed:\n\n")))
		for _, r in result.results do
			if not r.passed and not r.skipped then
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

	```luau
	-- Run all tests:
	test.runAll("tests/")

	-- Run only tests with "crypto" in the name:
	test.runAll("tests/", { filter = "crypto" })
	```

	@param path The directory to search for test files.
	@param options Run options (exitOnFail, filter).
]=]
function test.runAll(path: string, options: RunOptions?)
	local opts: RunOptions = options or {}
	local exitOnFail = if opts.exitOnFail ~= nil then opts.exitOnFail else true

	local totalPassed = 0
	local totalFailed = 0
	local totalSkipped = 0
	local suiteCount = 0
	local t0 = os.clock()

	type FailEntry = { suite: string, name: string, err: string }
	local failures: { FailEntry } = {}

	stdio.write(bold(`\nRunning tests in {path}\n\n`))

	local function walk(dir: string)
		local entries = fs.listDir(dir)
		table.sort(entries)
		for _, entry in entries do
			local full = fs.path.join(dir, entry)
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
				local totals = s:run(opts.filter)
				totalPassed += totals.passed
				totalFailed += totals.failed
				totalSkipped += totals.skipped
				suiteCount += 1
				stdio.write("\n")
				for _, r in s.results do
					if not r.passed and not r.skipped then
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
	local total = totalPassed + totalFailed + totalSkipped
	local sep = string.rep("-", 40)

	stdio.write(`{sep}\n`)
	stdio.write(bold(` Suites:  {suiteCount}\n`))

	local testLine = ""
	if totalFailed > 0 then
		testLine = ` Tests:   {green(`{totalPassed} passed`)}, {red(`{totalFailed} failed`)}`
	else
		testLine = ` Tests:   {green(`{totalPassed} passed`)}`
	end
	if totalSkipped > 0 then
		testLine ..= `, {dim(`{totalSkipped} skipped`)}`
	end
	testLine ..= `, {total} total\n`
	stdio.write(testLine)

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

	return { passed = totalPassed, failed = totalFailed, skipped = totalSkipped }
end

return table.freeze(test)
