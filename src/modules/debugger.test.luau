local dbg = require("@eryx/debugger")
local fs = require("@eryx/fs")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("debugger")

local function contains(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function writeFile(path: string, source: string)
	local handle = fs.openSync(path, "w")
	handle:writeSync(source)
	handle:closeSync()
end

local function writeProgram(root: string, name: string, source: string): string
	local path = fs.path.join(root, name)
	writeFile(path, source)
	return path
end

local function readFile(path: string): string
	local handle = fs.openSync(path, "r")
	local source = handle:readSync()
	handle:closeSync()
	return source
end

local function findLine(path: string, marker: string): number
	local source = readFile(path)
	local lineNumber = 0

	for line in string.gmatch(source, "([^\n]*)\n?") do
		lineNumber += 1
		if contains(line, marker) then
			return lineNumber
		end
	end

	error(`could not find marker "{marker}" in {path}`)
end

local function findByName<T>(list: { T & { name: string } }, name: string): T?
	for _, item in list do
		if item.name == name then
			return item
		end
	end

	return nil
end

local function closeSession(session: dbg.Session)
	local closed = pcall(function()
		session:close(false)
	end)
	if not closed then
		pcall(function()
			session:close(true)
		end)
	end
end

local function withSession(options: dbg.SessionOptions, run: (dbg.Session) -> ())
	local session = dbg.open(options)
	local ok, err = xpcall(function()
		run(session)
	end, function(message)
		return tostring(message)
	end)

	closeSession(session)

	if not ok then
		error(err, 0)
	end
end

local function waitForEvent(
	session: dbg.Session,
	predicate: (dbg.SessionEvent) -> boolean,
	description: string,
	outputEvents: { dbg.SessionEvent }?
): dbg.SessionEvent
	while true do
		local event = session:wait()
		if event == nil then
			error("session ended while waiting for " .. description)
		end

		if outputEvents ~= nil and event.kind == "output" then
			table.insert(outputEvents, event)
		end

		if predicate(event) then
			return event
		end
	end
end

local function waitForTermination(session: dbg.Session, outputEvents: { dbg.SessionEvent }?): dbg.SessionEvent
	local terminated = waitForEvent(session, function(event)
		return event.kind == "terminated"
	end, "termination", outputEvents)
	for _ = 1, 1000 do
		if session:state() == "terminated" then
			break
		end
		local event = session:wait()
		if event == nil then
			break
		end
		if outputEvents ~= nil and event.kind == "output" then
			table.insert(outputEvents, event)
		end
	end
	return terminated
end

local function waitForTerminatedState(session: dbg.Session, outputEvents: { dbg.SessionEvent }?)
	for _ = 1, 1000 do
		if session:state() == "terminated" then
			return
		end
		local event = session:wait()
		if event == nil then
			return
		end
		if outputEvents ~= nil and event.kind == "output" then
			table.insert(outputEvents, event)
		end
	end
end

local function expectSuccessfulEvaluate(result: dbg.EvaluateResult, summary: string)
	test.expect(result.ok):toBeTrue()
	if result.ok then
		test.expect(result.value.summary):toBe(summary)
	end
end

local function expectFailedEvaluate(result: dbg.EvaluateResult)
	test.expect(result.ok):toBeFalse()
	if not result.ok then
		test.expect(type(result.error.message)):toBe("string")
		test.expect(#result.error.message > 0):toBeTrue()
	end
end

local function joinedOutput(events: { dbg.SessionEvent }): string
	local parts = {}
	for _, event in events do
		if event.kind == "output" then
			table.insert(parts, event.text)
		end
	end
	return table.concat(parts, "")
end

suite:test("open, start, sources, threads, and source breakpoints", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"lifecycle_debuggee.luau",
			[[
local value = 10
-- DEBUGGER_FIRST_BREAKPOINT
value += 1
-- DEBUGGER_SECOND_BREAKPOINT
value += 1
print("lifecycle-value", value)
]]
		)

		local firstLine = findLine(program, "DEBUGGER_FIRST_BREAKPOINT")
		local secondLine = findLine(program, "DEBUGGER_SECOND_BREAKPOINT")
		local outputEvents: { dbg.SessionEvent } = {}

		withSession({
			program = program,
			stopOnEntry = true,
			args = { "alpha", "beta" },
			nativeCodegen = false,
			optimisationLevel = 0,
		}, function(session)
			test.expect(session:state()):toBe("idle")

			local initialSources = session:sources()
			test.expect(#initialSources):toBe(1)
			test.expect(initialSources[1].path):toBe(program)
			test.expect(session:readSource(initialSources[1])):toContain("lifecycle-value")

			local resolved = session:setBreakpoints(initialSources[1], {
				{ line = firstLine },
				{ line = secondLine },
			})
			test.expect(#resolved):toBe(2)
			test.expect(resolved[1].verified):toBeFalse()

			session:clearBreakpoints(initialSources[1])
			resolved = session:setBreakpoints(initialSources[1], {
				{ line = firstLine },
				{ line = secondLine },
			})
			test.expect(#resolved):toBe(2)

			session:start()

			local entryStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "entry"
			end, "entry stop", outputEvents)
			test.expect(entryStop.threadId):toBe(1)
			test.expect(session:state()):toBe("paused")

			local threads = session:threads()
			test.expect(#threads):toBe(1)
			test.expect(threads[1].state):toBe("paused")
			test.expect(threads[1].stopReason):toBe("entry")

			local loadedSources = session:sources()
			test.expect(#loadedSources >= 1):toBeTrue()
			test.expect(session:readSource()):toContain("DEBUGGER_FIRST_BREAKPOINT")

			session:pause()
			session:resume()

			local breakpointStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "first breakpoint", outputEvents)
			test.expect(breakpointStop.line ~= nil and breakpointStop.line >= firstLine):toBeTrue()
			test.expect(#(breakpointStop.breakpoints or {})):toBe(1)

			session:clearBreakpoints()
			session:resume()

			while true do
				local event = session:wait()
				if event == nil then
					error("session ended before termination")
				end
				if event.kind == "output" then
					table.insert(outputEvents, event)
				elseif event.kind == "stopped" and event.reason == "breakpoint" then
					error("clearBreakpoints() without a source left a user breakpoint active")
				elseif event.kind == "terminated" then
					test.expect(event.exitCode):toBe(0)
					break
				end
			end
			waitForTerminatedState(session, outputEvents)

			test.expect(session:state()):toBe("terminated")
		end)
	end)
end)

suite:test("frames, scopes, inspect, and evaluate while paused", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"inspect_debuggee.luau",
			[[
local seed = 4
local numbers = { seed, seed + 1, seed + 2 }
local record = {
	seed = seed,
	total = numbers[1] + numbers[2] + numbers[3],
	nested = {
		label = "inner",
		count = #numbers,
	},
	numbers = numbers,
}
-- DEBUGGER_INSPECT_BREAKPOINT
local snapshot = record.total
print("inspect-snapshot", snapshot)
]]
		)

		local breakpointLine = findLine(program, "DEBUGGER_INSPECT_BREAKPOINT")

		withSession({
			program = program,
		}, function(session)
			expectFailedEvaluate(session:evaluate("1 + 1"))

			session:setBreakpoints(program, {
				{ line = breakpointLine },
			})
			session:start()

			local breakpointStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "inspect breakpoint", nil)
			test.expect(breakpointStop.source ~= nil):toBeTrue()
			if breakpointStop.source ~= nil then
				test.expect(breakpointStop.source.path):toBe(program)
			end

			local invalidThreadFrames = session:frames(99)
			test.expect(#invalidThreadFrames.frames):toBe(0)
			test.expect(invalidThreadFrames.total):toBe(0)

			local framesResult = session:frames()
			test.expect(framesResult.total ~= nil and framesResult.total >= 1):toBeTrue()
			test.expect(#framesResult.frames >= 1):toBeTrue()

			local pagedFrames = session:frames(1, 0, 1)
			test.expect(#pagedFrames.frames):toBe(1)

			local topFrame = framesResult.frames[1]
			test.expect(topFrame.threadId):toBe(1)
			test.expect(topFrame.source ~= nil):toBeTrue()
			if topFrame.source ~= nil then
				test.expect(topFrame.source.path):toBe(program)
			end

			local scopes = session:scopes(topFrame.id)
			test.expect(#scopes >= 1):toBeTrue()
			test.expect(#(session:scopes(-1))):toBe(0)

			local localsScope = findByName(scopes, "Locals")
			test.expect(localsScope ~= nil):toBeTrue()
			if localsScope == nil then
				return
			end

			local locals = session:inspect({
				ref = localsScope.ref,
			})
			test.expect(#locals >= 3):toBeTrue()

			local recordValue = findByName(locals, "record")
			test.expect(recordValue ~= nil):toBeTrue()
			if recordValue == nil then
				return
			end
			test.expect(recordValue.ref > 0):toBeTrue()
			test.expect((recordValue.namedCount or 0) >= 3):toBeTrue()

			local namedFields = session:inspect({
				ref = recordValue.ref,
				filter = "named",
			})
			local totalField = findByName(namedFields, "total")
			test.expect(totalField ~= nil):toBeTrue()
			if totalField ~= nil then
				test.expect(totalField.summary):toBe("15")
			end

			local nestedField = findByName(namedFields, "nested")
			test.expect(nestedField ~= nil):toBeTrue()
			if nestedField ~= nil then
				local nestedFields = session:inspect({
					ref = nestedField.ref,
					filter = "named",
				})
				local countField = findByName(nestedFields, "count")
				test.expect(countField ~= nil):toBeTrue()
				if countField ~= nil then
					test.expect(countField.summary):toBe("3")
				end
			end

			local numbersField = findByName(namedFields, "numbers")
			test.expect(numbersField ~= nil):toBeTrue()
			if numbersField ~= nil then
				local indexedNumbers = session:inspect({
					ref = numbersField.ref,
					filter = "indexed",
				})
				test.expect(#indexedNumbers):toBe(3)
				test.expect(indexedNumbers[1].summary):toBe("4")
				test.expect(indexedNumbers[3].summary):toBe("6")

				local pagedHexNumbers = session:inspect({
					ref = numbersField.ref,
					filter = "indexed",
					start = 1,
					count = 1,
					hex = true,
				})
				test.expect(#pagedHexNumbers):toBe(1)
				test.expect(pagedHexNumbers[1].summary):toBe("0x5")
			end

			test.expect(#(session:inspect({ ref = -1 }))):toBe(0)
			expectSuccessfulEvaluate(
				session:evaluate("record.total", {
					frame = topFrame.id,
				}),
				"15"
			)
			expectSuccessfulEvaluate(
				session:setVariable(localsScope.ref, "seed", "10", {
					frame = topFrame.id,
				}),
				"10"
			)
			expectSuccessfulEvaluate(
				session:evaluate("seed", {
					frame = topFrame.id,
				}),
				"10"
			)
			expectSuccessfulEvaluate(
				session:setVariable(recordValue.ref, "total", "99", {
					frame = topFrame.id,
				}),
				"99"
			)
			expectSuccessfulEvaluate(
				session:evaluate("record.total", {
					frame = topFrame.id,
				}),
				"99"
			)
			expectSuccessfulEvaluate(
				session:evaluate("local copy = record.total\nreturn copy + 1", {
					frame = topFrame.id,
					context = "repl",
				}),
				"100"
			)
			expectSuccessfulEvaluate(
				session:evaluate("255", {
					frame = topFrame.id,
					hex = true,
				}),
				"0xff"
			)
			expectFailedEvaluate(session:evaluate("missingName + 1", {
				frame = topFrame.id,
			}))
			expectFailedEvaluate(session:evaluate("record.total", {
				frame = -1,
			}))
			expectFailedEvaluate(session:setVariable(-1, "missing", "1"))

			session:resume()
			test.expect(waitForTermination(session, nil).exitCode):toBe(0)
		end)
	end)
end)

suite:test("coroutine threads have distinct ids and route debugger requests", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"coroutine_threads_debuggee.luau",
			[[
local dbg = require("@eryx/debugger")

local co = coroutine.create(function()
	local label = "worker"
	dbg.breakpoint()
	label = label .. "-done"
end)

local ok, err = coroutine.resume(co)
if not ok then
	error(err)
end

local label = "main"
dbg.breakpoint()
print("coroutine-debugger-done", label)
]]
		)

		withSession({
			program = program,
		}, function(session)
			session:start()

			local workerStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "manual"
			end, "worker coroutine stop", nil)
			test.expect(workerStop.threadId ~= 1):toBeTrue()

			local threads = session:threads()
			test.expect(#threads >= 2):toBeTrue()
			local workerThread = nil :: dbg.Thread?
			for _, thread in threads do
				if thread.id == workerStop.threadId then
					workerThread = thread
				end
			end
			test.expect(workerThread ~= nil):toBeTrue()
			if workerThread ~= nil then
				test.expect(workerThread.state):toBe("paused")
				test.expect(workerThread.stopReason):toBe("manual")
			end

			local workerFrames = session:frames(workerStop.threadId)
			test.expect(#workerFrames.frames >= 1):toBeTrue()
			local workerFrame = workerFrames.frames[1]
			test.expect(workerFrame.threadId):toBe(workerStop.threadId)
			expectSuccessfulEvaluate(
				session:evaluate("label", {
					frame = workerFrame.id,
				}),
				'"worker"'
			)

			local mainFramesWhileWorkerPaused = session:frames(1)
			test.expect(#mainFramesWhileWorkerPaused.frames):toBe(0)

			session:resume(workerStop.threadId)

			local mainStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "manual"
			end, "main coroutine stop", nil)
			test.expect(mainStop.threadId):toBe(1)
			local mainFrame = session:frames(mainStop.threadId).frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("label", {
					frame = mainFrame.id,
				}),
				'"main"'
			)

			session:resume(1)
			test.expect(waitForTermination(session, nil).exitCode):toBe(0)
		end)
	end)
end)

suite:test("conditions, hit counts, and logpoints share a source line", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"breakpoint_variants_debuggee.luau",
			[[
local total = 0
for i = 1, 4 do
	total += i
	-- DEBUGGER_VARIANT_BREAKPOINT
	local snapshot = total
	print("variant", i, snapshot)
end
print("variant-total", total)
]]
		)

		local breakpointLine = findLine(program, "DEBUGGER_VARIANT_BREAKPOINT")
		local outputEvents: { dbg.SessionEvent } = {}

		withSession({
			program = program,
		}, function(session)
			local resolved = session:setBreakpoints(program, {
				{ line = breakpointLine, condition = "i % 2 == 0", hitCondition = "2" },
				{ line = breakpointLine, logMessage = "logpoint i={i} total={total}" },
			})
			test.expect(#resolved):toBe(2)

			session:start()

			local stop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "conditional hit-count breakpoint", outputEvents)
			test.expect(stop.line ~= nil and stop.line >= breakpointLine):toBeTrue()
			test.expect(#(stop.breakpoints or {})):toBe(1)
			if resolved[1].id ~= nil then
				test.expect((stop.breakpoints or {})[1]):toBe(resolved[1].id)
			end

			local topFrame = session:frames().frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("total", {
					frame = topFrame.id,
				}),
				"10"
			)

			session:resume()
			test.expect(waitForTermination(session, outputEvents).exitCode):toBe(0)

			local logOutput = joinedOutput(outputEvents)
			test.expect(logOutput):toContain("logpoint i=1 total=1")
			test.expect(logOutput):toContain("logpoint i=4 total=10")
		end)
	end)
end)

suite:test("step in, step over, and step out report expected frames", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"step_debuggee.luau",
			[[
local function addOne(x: number): number
	local y = x + 1 -- DEBUGGER_STEP_INNER
	return y
end

local function run(): number
	local base = 40
	local value = addOne(base) -- DEBUGGER_STEP_CALL
	local doubled = value * 2 -- DEBUGGER_STEP_AFTER_CALL
	return doubled
end

print("step-result", run())
]]
		)

		local callLine = findLine(program, "DEBUGGER_STEP_CALL")
		local innerLine = findLine(program, "DEBUGGER_STEP_INNER")
		local afterCallLine = findLine(program, "DEBUGGER_STEP_AFTER_CALL")

		withSession({
			program = program,
		}, function(session)
			session:setBreakpoints(program, {
				{ line = callLine },
			})
			session:start()

			local breakpointStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "step call breakpoint", nil)
			test.expect(breakpointStop.line):toBe(callLine)

			session:step("in")
			local stepInStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "step"
			end, "step in", nil)
			test.expect(stepInStop.line):toBe(innerLine)

			local innerFrame = session:frames().frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("x", {
					frame = innerFrame.id,
				}),
				"40"
			)

			session:step("out")
			local stepOutStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "step"
			end, "step out", nil)
			test.expect(stepOutStop.line):toBe(afterCallLine)

			local afterFrame = session:frames().frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = afterFrame.id,
				}),
				"41"
			)

			session:terminate()
			waitForTermination(session, nil)
		end)

		withSession({
			program = program,
		}, function(session)
			session:setBreakpoints(program, {
				{ line = callLine },
			})
			session:start()

			waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "step-over breakpoint", nil)

			session:step("over")
			local stepOverStop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "step"
			end, "step over", nil)
			test.expect(stepOverStop.line):toBe(afterCallLine)

			local topFrame = session:frames().frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = topFrame.id,
				}),
				"41"
			)

			session:resume()
			test.expect(waitForTermination(session, nil).exitCode):toBe(0)
		end)
	end)
end)

suite:test("manual debugger breakpoint and exception details", function()
	tempfile.withTempDir(function(root)
		local manualProgram = writeProgram(
			root,
			"manual_debuggee.luau",
			[[
local dbg = require("@eryx/debugger")
local value = 21
dbg.breakpoint()
print("manual-value", value * 2)
]]
		)

		withSession({
			program = manualProgram,
		}, function(session)
			session:start()

			local stop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "manual"
			end, "manual breakpoint", nil)
			test.expect(stop.threadId):toBe(1)

			local frame = session:frames().frames[1]
			expectSuccessfulEvaluate(
				session:evaluate("value * 2", {
					frame = frame.id,
				}),
				"42"
			)
			test.expect(session:exception()):toBeNil()

			session:resume()
			test.expect(waitForTermination(session, nil).exitCode):toBe(0)
		end)

		local exceptionProgram = writeProgram(
			root,
			"exception_debuggee.luau",
			[[
local payload = {
	message = "debugger exception payload",
}
error(payload.message)
]]
		)

		local outputEvents: { dbg.SessionEvent } = {}
		withSession({
			program = exceptionProgram,
		}, function(session)
			session:start()

			local stop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "exception"
			end, "exception stop", outputEvents)
			test.expect(stop.text or ""):toContain("debugger exception payload")

			local exceptionInfo = session:exception()
			test.expect(exceptionInfo ~= nil):toBeTrue()
			if exceptionInfo ~= nil then
				test.expect(exceptionInfo.message or ""):toContain("debugger exception payload")
				test.expect(exceptionInfo.source ~= nil):toBeTrue()
				if exceptionInfo.source ~= nil then
					test.expect(exceptionInfo.source.path):toBe(exceptionProgram)
				end
				test.expect((exceptionInfo.line or 0) > 0):toBeTrue()
			end

			session:resume()
			test.expect(waitForTermination(session, outputEvents).exitCode):toBe(1)
			test.expect(joinedOutput(outputEvents)):toContain("debugger exception payload")
		end)
	end)
end)

suite:test("argument validation and close behavior", function()
	test.expect(function()
		dbg.open({} :: any)
	end):toError("session options require a program path")

	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"close_debuggee.luau",
			[[
print("close-target")
]]
		)

		local session = dbg.open({
			program = program,
		})

		test.expect(function()
			session:close(false)
		end):toError("cannot close a live debug session without terminating the debuggee")

		session:terminate()
		closeSession(session)
	end)
end)

suite:test("state, running, source-added, and drained wait events", function()
	tempfile.withTempDir(function(root)
		writeProgram(
			root,
			"helper_module.luau",
			[[
return {
	value = 7,
}
]]
		)
		local program = writeProgram(
			root,
			"events_debuggee.luau",
			[[
local helper = require("./helper_module")
print("helper-value", helper.value)
]]
		)

		withSession({
			program = program,
			stopOnEntry = true,
		}, function(session)
			test.expect(#session:threads()):toBe(0)

			session:start()

			local sawStarting = false
			local entryStop = nil :: dbg.SessionEvent?
			while entryStop == nil do
				local event = session:wait()
				if event == nil then
					error("session ended before entry stop")
				end
				if event.kind == "state" and event.state == "starting" then
					sawStarting = true
				elseif event.kind == "stopped" and event.reason == "entry" then
					entryStop = event
				end
			end

			test.expect(sawStarting):toBeTrue()
			test.expect(session:state()):toBe("paused")

			session:resume(1)

			local sawRunning = false
			local sawHelperSource = false
			while true do
				local event = session:wait()
				if event == nil then
					error("session ended before termination")
				end

				if event.kind == "state" and event.state == "running" then
					sawRunning = true
				elseif event.kind == "source-added" then
					if event.source.path ~= nil and contains(event.source.path, "helper_module.luau") then
						sawHelperSource = true
					end
				elseif event.kind == "terminated" then
					test.expect(event.exitCode):toBe(0)
					break
				end
			end

			test.expect(sawRunning):toBeTrue()
			test.expect(sawHelperSource):toBeTrue()
			test.expect(session:state()):toBe("terminated")
			test.expect(session:wait()):toBeNil()
			test.expect(#session:threads()):toBe(1)
			test.expect(session:threads()[1].state):toBe("terminated")
		end)
	end)
end)

suite:test("pause requests and thread id parameters are accepted", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"pause_debuggee.luau",
			[[
local total = 0
for i = 1, 200000 do
	total += i
end
print("pause-total", total)
]]
		)

		withSession({
			program = program,
		}, function(session)
			session:pause(1)
			session:start()

			local stop = waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "pause"
			end, "pause request", nil)
			test.expect(stop.threadId):toBe(1)
			test.expect(session:threads()[1].stopReason):toBe("pause")

			test.expect(function()
				session:step("sideways" :: any, 1)
			end):toError("step mode must be 'in', 'over', or 'out'")

			session:terminate()
			waitForTermination(session, nil)
		end)
	end)
end)

suite:test("breakpoint verification and hit-condition operators", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"hit_conditions_debuggee.luau",
			[[
local total = 0
for i = 1, 6 do
	total += i
	-- DEBUGGER_HIT_CONDITION
	local snapshot = total
end
print("hit-total", total)
]]
		)

		local breakpointLine = findLine(program, "DEBUGGER_HIT_CONDITION")

		local function expectHit(hitCondition: string, expectedI: string)
			withSession({
				program = program,
			}, function(session)
				local resolved = session:setBreakpoints(program, {
					{ line = breakpointLine, hitCondition = hitCondition },
				})
				test.expect(#resolved):toBe(1)

				session:start()
				waitForEvent(session, function(event)
					return event.kind == "stopped" and event.reason == "breakpoint"
				end, "hit condition " .. hitCondition, nil)

				local frame = session:frames().frames[1]
				expectSuccessfulEvaluate(
					session:evaluate("i", {
						frame = frame.id,
					}),
					expectedI
				)

				session:terminate()
				waitForTermination(session, nil)
			end)
		end

		expectHit(">= 3", "3")
		expectHit("> 3", "4")
		expectHit("<= 1", "1")
		expectHit("< 2", "1")
		expectHit("% 3", "3")
		expectHit("not a hit condition", "1")

		withSession({
			program = program,
			stopOnEntry = true,
		}, function(session)
			local missingLine = 100000
			local resolved = session:setBreakpoints(program, {
				{ line = missingLine, column = 99 },
			})
			test.expect(#resolved):toBe(1)

			session:start()
			waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "entry"
			end, "entry stop before unverified breakpoint check", nil)

			local verifiedAfterRun = session:setBreakpoints(program, {
				{ line = missingLine, column = 99 },
			})
			test.expect(#verifiedAfterRun):toBe(1)
			test.expect(verifiedAfterRun[1].verified):toBeFalse()
			test.expect(verifiedAfterRun[1].message or ""):toContain("No executable code")

			session:terminate()
			waitForTermination(session, nil)
		end)
	end)
end)

suite:test("breakpoint condition failures and logpoint fallback text", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"logpoint_fallback_debuggee.luau",
			[[
local total = 0
for i = 1, 2 do
	total += i
	-- DEBUGGER_LOGPOINT_FALLBACK
	local snapshot = total
end
print("fallback-total", total)
]]
		)

		local breakpointLine = findLine(program, "DEBUGGER_LOGPOINT_FALLBACK")
		local outputEvents: { dbg.SessionEvent } = {}

		withSession({
			program = program,
		}, function(session)
			session:setBreakpoints(program, {
				{ line = breakpointLine, condition = "missingName == true" },
				{ line = breakpointLine, logMessage = "bad expression {missingName + 1}" },
			})

			session:start()
			local terminated = waitForTermination(session, outputEvents)
			test.expect(terminated.exitCode):toBe(0)

			local output = joinedOutput(outputEvents)
			test.expect(output):toContain("bad expression {missingName + 1}")
		end)
	end)
end)

suite:test("source and evaluation edge cases", function()
	tempfile.withTempDir(function(root)
		local program = writeProgram(
			root,
			"edge_debuggee.luau",
			[[
local value = 9
-- DEBUGGER_EDGE_BREAKPOINT
local snapshot = value
]]
		)

		local breakpointLine = findLine(program, "DEBUGGER_EDGE_BREAKPOINT")

		withSession({
			program = program,
		}, function(session)
			test.expect(session:readSource(fs.path.join(root, "missing.luau"))):toBe("")
			test.expect(session:disassemble(program)):toContain("LOAD")

			test.expect(function()
				session:setBreakpoints({} :: any, {
					{ line = breakpointLine },
				})
			end):toError("setBreakpoints requires a source path or source id")

			session:setBreakpoints(program, {
				{ line = breakpointLine },
			})
			session:start()
			waitForEvent(session, function(event)
				return event.kind == "stopped" and event.reason == "breakpoint"
			end, "edge breakpoint", nil)

			local frame = session:frames().frames[1]
			local listing = session:disassemble({
				frame = frame.id,
				showLocals = true,
			})
			test.expect(listing):toContain("LOAD")
			test.expect(session:readSource(frame.source)):toContain("DEBUGGER_EDGE_BREAKPOINT")

			expectSuccessfulEvaluate(
				session:evaluate("local copy = value\nreturn copy + 2", {
					frame = frame.id,
					allowStatements = true,
					context = "watch",
				}),
				"11"
			)
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = frame.id,
					context = "hover",
				}),
				"9"
			)
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = frame.id,
					context = "clipboard",
				}),
				"9"
			)
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = frame.id,
					context = "variables",
				}),
				"9"
			)
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = frame.id,
					context = "condition",
				}),
				"9"
			)
			expectSuccessfulEvaluate(
				session:evaluate("value", {
					frame = frame.id,
					context = "logpoint",
				}),
				"9"
			)

			test.expect(session:exception(99)):toBeNil()

			session:resume(99)
			test.expect(waitForTermination(session, nil).exitCode):toBe(0)
		end)

		local closeProgram = writeProgram(
			root,
			"explicit_close_debuggee.luau",
			[[
print("explicit-close")
]]
		)
		local session = dbg.open({
			program = closeProgram,
		})
		session:close(true)
	end)
end)

return suite
