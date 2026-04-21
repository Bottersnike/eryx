local Signal = require("@eryx/signal")
local task = require("@eryx/task")
local test = require("@eryx/test")

local suite = test.Suite.new("signal")

suite:test("fire: returns false when there are no handlers", function()
	local signal = Signal.new()
	test.expect(signal:fire("hello")):toBeFalse()
end)

suite:test("fire: invokes connected handlers", function()
	local signal = Signal.new()
	local seen = nil

	signal:connect(function(value)
		seen = value
	end)

	test.expect(signal:fire("hello")):toBeTrue()
	task.wait()
	test.expect(seen):toBe("hello")
end)

suite:test("once: only fires a handler once", function()
	local signal = Signal.new()
	local count = 0

	signal:once(function()
		count += 1
	end)

	signal:fire()
	signal:fire()
	task.wait()
	test.expect(count):toBe(1)
end)

suite:test("disconnectAll: disconnects every handler", function()
	local signal = Signal.new()
	local count = 0

	signal:connect(function()
		count += 1
	end)
	signal:connect(function()
		count += 1
	end)

	signal:disconnectAll()
	test.expect(signal:fire()):toBeFalse()
	task.wait()
	test.expect(count):toBe(0)
end)

suite:test("errorSignal: receives handler failures", function()
	local signal = Signal.new()
	local seenErr = nil
	local seenConnection = nil

	signal:connect(function()
		error("boom")
	end)

	signal:connectError(function(err, connection)
		seenErr = err
		seenConnection = connection
	end)

	signal:fire()
	task.wait()

	test.expect(typeof(seenErr)):toBe("Exception")
	assert(seenErr)
	test.expect(seenErr.message):toMatch("boom")
	test.expect(seenConnection):toNotBeNil()
end)

suite:test("errorSignal: still allows healthy handlers to run", function()
	local signal = Signal.new()
	local count = 0
	local errors = 0

	signal:connect(function()
		count += 1
	end)

	signal:connect(function()
		error("boom")
	end)

	signal:connectError(function()
		errors += 1
	end)

	signal:fire()
	task.wait()

	test.expect(count):toBe(1)
	test.expect(errors):toBe(1)
end)

return suite
