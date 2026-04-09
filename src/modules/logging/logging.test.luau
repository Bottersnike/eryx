local fs = require("@eryx/fs")
local json = require("@eryx/encoding/json")
local logging = require("@eryx/logging")
local test = require("@eryx/test")

local suite = test.Suite.new("logging")

local function newCollector()
	local records: { logging.LogRecord } = {}
	local handler: logging.Handler = {
		write = function(record)
			table.insert(records, record)
		end,
	}
	return records, handler
end

suite.beforeEach = function()
	logging.config({
		reset = true,
		captureSource = false,
		sourceDepth = 4,
	})
	-- Keep tests deterministic/noiseless; tests that validate defaults can re-enable them.
	logging.clearHandlers()
end

suite:test("parseLevel: parses aliases and numbers", function()
	test.expect(logging.parseLevel("debug")):toBe(10)
	test.expect(logging.parseLevel("warn")):toBe(30)
	test.expect(logging.parseLevel(25)):toBe(25)
	test.expect(function()
		logging.parseLevel("unknown" :: any)
	end):toError("Unknown log level")
end)

suite:test("default root handler is console on reset", function()
	logging.config({
		reset = true,
	})

	local logger = logging.getLogger("default")
	test.expect(logger:info("default-console-active")):toBeTrue()
end)

suite:test("level gating: default info filters debug", function()
	local records, handler = newCollector()
	logging.addHandler(handler)

	local logger = logging.getLogger("app")
	test.expect(logger:debug("hello")):toBeFalse()
	test.expect(#records):toBe(0)

	test.expect(logger:error("boom")):toBeTrue()
	test.expect(#records):toBe(1)
	test.expect(records[1].message):toBe("boom")
end)

suite:test("hierarchy propagation: child emits to parent and root handlers", function()
	logging.config({
		level = "debug",
	})

	local rootRecords, rootHandler = newCollector()
	local appRecords, appHandler = newCollector()

	logging.addHandler(rootHandler)
	local app = logging.getLogger("app")
	app:addHandler(appHandler)
	local child = logging.getLogger("app.http")

	child:info("first")
	test.expect(#appRecords):toBe(1)
	test.expect(#rootRecords):toBe(1)

	app:setPropagation(false)
	child:info("second")
	test.expect(#appRecords):toBe(2)
	test.expect(#rootRecords):toBe(1)
end)

suite:test("context merge: per-call attrs override logger context", function()
	logging.config({
		level = "debug",
	})

	local records, handler = newCollector()
	logging.addHandler(handler)

	local logger = logging.getLogger("api"):withContext({
		service = "billing",
		env = "dev",
	})

	logger:info("request", {
		env = "prod",
		requestId = "abc123",
	})

	test.expect(#records):toBe(1)
	local attrs = records[1].attrs
	test.expect(attrs.service):toBe("billing")
	test.expect(attrs.env):toBe("prod")
	test.expect(attrs.requestId):toBe("abc123")
end)

suite:test("handler filters and levels are applied", function()
	logging.config({
		level = "debug",
	})

	local records: { logging.LogRecord } = {}
	local handler: logging.Handler = {
		level = "error",
		filter = function(record)
			return record.logger == "svc"
		end,
		write = function(record)
			table.insert(records, record)
		end,
	}

	logging.addHandler(handler)

	logging.getLogger("svc"):warning("skip-warning")
	logging.getLogger("other"):error("skip-filter")
	logging.getLogger("svc"):error("keep")

	test.expect(#records):toBe(1)
	test.expect(records[1].message):toBe("keep")
end)

suite:test("removeHandler and clearHandlers stop dispatch", function()
	logging.config({
		level = "debug",
	})

	local oneRecords, one = newCollector()
	local twoRecords, two = newCollector()

	logging.addHandler(one)
	logging.addHandler(two)
	logging.removeHandler(one)

	local logger = logging.getLogger("x")
	logger:info("a")
	test.expect(#oneRecords):toBe(0)
	test.expect(#twoRecords):toBe(1)

	logging.clearHandlers()
	logger:info("b")
	test.expect(#twoRecords):toBe(1)
end)

suite:test("handler failures do not block other handlers", function()
	logging.config({
		level = "debug",
	})

	local okRecords, okHandler = newCollector()
	logging.addHandler({
		write = function()
			error("fail")
		end,
	})
	logging.addHandler(okHandler)

	local logger = logging.getLogger("svc")
	test.expect(logger:error("continue")):toBeTrue()
	test.expect(#okRecords):toBe(1)
	test.expect(okRecords[1].message):toBe("continue")
end)

suite:test("ConsoleHandler.new supports custom write sink", function()
	logging.config({
		level = "debug",
	})

	local lines = {}
	local handler = logging.ConsoleHandler.new({
		write = function(line)
			table.insert(lines, line)
		end,
	})

	logging.addHandler(handler)
	logging.getLogger("console"):info("hello")

	test.expect(#lines):toBe(1)
	test.expect(lines[1]):toContain("hello")
end)

suite:test("ConsoleHandler.new supports ANSI colours", function()
	logging.config({
		level = "debug",
	})

	local lines = {}
	local handler = logging.ConsoleHandler.new({
		color = true,
		write = function(line)
			table.insert(lines, line)
		end,
	})

	logging.addHandler(handler)
	logging.getLogger("console"):error("colour")

	test.expect(#lines):toBe(1)
	test.expect(lines[1]):toContain("\27[")
end)

suite:test("JsonHandler.new writes NDJSON lines", function()
	logging.config({
		level = "debug",
	})

	local lines = {}
	local handler = logging.JsonHandler.new({
		write = function(line)
			table.insert(lines, line)
		end,
	})

	logging.addHandler(handler)
	logging.getLogger("json"):warning("payload", {
		code = 42,
	})

	test.expect(#lines):toBe(1)
	local decoded = json.decode((lines[1]:gsub("%s+$", "")))
	test.expect(decoded.message):toBe("payload")
	test.expect(decoded.attrs.code):toBe(42)
end)

suite:test("FileHandler.new writes to file and can be closed", function()
	logging.config({
		level = "debug",
	})

	local outputPath = "logging_test_output.log"
	if fs.exists(outputPath) then
		fs.remove(outputPath)
	end

	local handler = logging.FileHandler.new(outputPath, {
		flushEachWrite = true,
	})

	logging.addHandler(handler)
	logging.getLogger("file"):error("saved")
	if handler.close then
		handler.close()
	end

	local readFile = fs.openSync(outputPath, "r")
	local content = readFile:readSync()
	readFile:closeSync()
	test.expect(content):toContain("saved")

	fs.remove(outputPath)
end)

suite:test("captureSource includes source metadata when enabled", function()
	test.skipIf(debug == nil or debug.info == nil, "debug.info unavailable")

	logging.config({
		level = "debug",
		captureSource = true,
		sourceDepth = 4,
	})

	local records, handler = newCollector()
	logging.addHandler(handler)

	logging.getLogger("src"):info("where")
	test.expect(#records):toBe(1)
	test.expect(records[1].sourcePath):toNotBeNil()
end)

return suite
