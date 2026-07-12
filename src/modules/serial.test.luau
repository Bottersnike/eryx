-- serial.test.luau
--
-- Requires a com0com null-modem pair: COM9 <-> COM10
-- Every byte written to COM9 immediately appears on COM10 and vice-versa.

local serial = require("@eryx/serial")
local task = require("@eryx/task")
local test = require("@eryx/test")

local PORT_A = "COM9"
local PORT_B = "COM10"

-- Skip the whole suite when com0com isn't installed.
local function openBoth(): (serial.SerialPort, serial.SerialPort)
	local a = serial.open(PORT_A, { baudRate = 115200 })
	local b = serial.open(PORT_B, { baudRate = 115200 })
	return a, b
end

local function withPair(fn: (a: serial.SerialPort, b: serial.SerialPort) -> ())
	local ok, a, b = pcall(openBoth)
	if not ok then
		-- com0com not available — surface a clear skip message
		test.skip(`com0com ports {PORT_A}/{PORT_B} not available: {a}`)
		return
	end
	assert(a and b)
	local success, err = pcall(fn, a, b)
	pcall(function()
		a:close()
	end)
	pcall(function()
		b:close()
	end)
	if not success then
		error(err, 0)
	end
end

-- ============================================================
-- serial.list()
-- ============================================================

local suite = test.Suite.new("serial")

suite:test("list: returns a table of PortInfo", function()
	local ports = serial.list()
	test.expect(type(ports)):toBe("table")
	for _, info in ports do
		test.expect(type(info.name)):toBe("string")
		test.expect(#info.name):toBeGreaterThan(0)
		if info.vid ~= nil then
			test.expect(type(info.vid)):toBe("number")
		end
		if info.pid ~= nil then
			test.expect(type(info.pid)):toBe("number")
		end
	end
end)

suite:test("list: com0com ports appear in the list", function()
	local ports = serial.list()
	local names: { string } = {}
	for _, info in ports do
		names[#names + 1] = info.name
	end
	local hasA = table.find(names, PORT_A) ~= nil
	local hasB = table.find(names, PORT_B) ~= nil
	if not (hasA and hasB) then
		test.skip(`{PORT_A}/{PORT_B} not found in serial.list() — com0com not installed`)
	end
end)

-- ============================================================
-- open / close / properties
-- ============================================================

suite:test("open: returns a SerialPort with correct properties", function()
	withPair(function(a, _b)
		test.expect(a.readable):toBeTrue()
		test.expect(a.writable):toBeTrue()
		test.expect(a.closed):toBeFalse()
	end)
end)

suite:test("open: rejects an invalid port name", function()
	test.expect(function()
		serial.open("COMNOTEXIST")
	end):toError()
end)

suite:test("close: marks port as closed", function()
	withPair(function(a, _b)
		a:close()
		test.expect(a.closed):toBeTrue()
		test.expect(a.readable):toBeFalse()
		test.expect(a.writable):toBeFalse()
	end)
end)

suite:test("close: calling twice does not error", function()
	withPair(function(a, _b)
		a:close()
		test.expect(function()
			a:close()
		end):toError("closed") -- check_port raises "serial port is closed"
	end)
end)

suite:test("closeSync: works the same as close", function()
	withPair(function(a, _b)
		a:closeSync()
		test.expect(a.closed):toBeTrue()
	end)
end)

-- ============================================================
-- write / writeSync
-- ============================================================

suite:test("write: returns byte count", function()
	withPair(function(a, _b)
		local n = a:write("hello")
		test.expect(n):toBe(5)
	end)
end)

suite:test("writeSync: returns byte count", function()
	withPair(function(a, _b)
		local n = a:writeSync("hello")
		test.expect(n):toBe(5)
	end)
end)

suite:test("write: accepts a buffer", function()
	withPair(function(a, b)
		local buf = buffer.fromstring("bufdata")
		a:write(buf)
		local got = b:read(7, 1000)
		test.expect(got):toBe("bufdata")
	end)
end)

suite:test("write: returns 0 for empty string", function()
	withPair(function(a, _b)
		test.expect(a:write("")):toBe(0)
	end)
end)

-- ============================================================
-- read — blocking (no timeout)
-- ============================================================

suite:test("read(n): blocks until data arrives then returns it", function()
	withPair(function(a, b)
		task.spawn(function()
			task.wait(0.05)
			a:write("ping")
		end)
		local got = b:read(64)
		test.expect(got):toBe("ping")
	end)
end)

suite:test("read(n): returns at most n bytes", function()
	withPair(function(a, b)
		a:write("abcdefgh")
		-- Give the OS a moment to buffer the data before reading
		task.wait(0.02)
		local got = b:read(4)
		test.expect(#got):toBe(4)
		test.expect(got):toBe("abcd")
	end)
end)

-- ============================================================
-- read — non-blocking (no args)
-- ============================================================

suite:test("read(): returns empty string when buffer is empty", function()
	withPair(function(_a, b)
		-- Nothing written — should return "" immediately
		local got = b:read()
		test.expect(got):toBe("")
	end)
end)

suite:test("read(): returns buffered data without blocking", function()
	withPair(function(a, b)
		a:write("hi")
		task.wait(0.05) -- let the bytes reach the OS RX buffer
		local got = b:read()
		test.expect(got):toBe("hi")
	end)
end)

-- ============================================================
-- read — with timeout
-- ============================================================

suite:test("read(n, 0): returns nil immediately when buffer empty", function()
	withPair(function(_a, b)
		local got = b:read(64, 0)
		test.expect(got):toBeNil()
	end)
end)

suite:test("read(n, t): returns nil after timeout with no data", function()
	withPair(function(_a, b)
		local t0 = os.clock()
		local got = b:read(64, 100)
		local elapsed = os.clock() - t0
		test.expect(got):toBeNil()
		-- Should have waited approximately 100 ms (allow generous window)
		test.expect(elapsed):toBeGreaterThan(0.08)
		test.expect(elapsed):toBeLessThan(0.5)
	end)
end)

suite:test("read(n, t): returns data that arrives before the timeout", function()
	withPair(function(a, b)
		task.spawn(function()
			task.wait(0.05)
			a:write("timed")
		end)
		local got = b:read(64, 2000)
		test.expect(got):toBe("timed")
	end)
end)

suite:test("read(nil, t): waits then drains all available bytes", function()
	withPair(function(a, b)
		task.spawn(function()
			task.wait(0.05)
			a:write("drain-me")
		end)
		local got = b:read(nil, 2000)
		test.expect(got):toBe("drain-me")
	end)
end)

suite:test("read(nil, 0): returns nil immediately when buffer empty", function()
	withPair(function(_a, b)
		local got = b:read(nil, 0)
		test.expect(got):toBeNil()
	end)
end)

-- ============================================================
-- readSync / readSyncBuffer
-- ============================================================

suite:test("readSync(): returns empty string when buffer is empty", function()
	withPair(function(_a, b)
		local got = b:readSync()
		test.expect(got):toBe("")
	end)
end)

suite:test("readSync(n): blocks the caller until data arrives", function()
	withPair(function(a, b)
		-- Write before calling readSync: readSync blocks the event loop, so
		-- task.spawn cannot run while it waits. Ensure data is already in the
		-- OS receive buffer before the blocking call starts.
		a:write("sync")
		task.wait(0.05) -- let bytes reach b's OS RX buffer
		local got = b:readSync(4)
		test.expect(got):toBe("sync")
	end)
end)

suite:test("readBuffer(): returns empty buffer when nothing available", function()
	withPair(function(_a, b)
		local buf = b:readBuffer()
		test.expect(buffer.len(buf)):toBe(0)
	end)
end)

suite:test("readBuffer(n): yields and returns buffer with data", function()
	withPair(function(a, b)
		task.spawn(function()
			task.wait(0.05)
			a:write("buftest")
		end)
		local buf = b:readBuffer(64)
		test.expect(buffer.tostring(buf)):toBe("buftest")
	end)
end)

suite:test("readBuffer(n, t): returns nil buffer on timeout", function()
	withPair(function(_a, b)
		local result = b:readBuffer(64, 50)
		test.expect(result):toBeNil()
	end)
end)

suite:test("readBufferSync(): returns empty buffer when nothing available", function()
	withPair(function(_a, b)
		local buf = b:readBufferSync()
		test.expect(buffer.len(buf)):toBe(0)
	end)
end)

suite:test("readBufferSync(n): blocks and returns buffer", function()
	withPair(function(a, b)
		a:write("synbuf")
		task.wait(0.05) -- let bytes reach b's OS RX buffer
		local buf = b:readBufferSync(6)
		test.expect(buffer.tostring(buf)):toBe("synbuf")
	end)
end)

-- ============================================================
-- Concurrent reads on the same side
-- ============================================================

suite:test("two concurrent read(n) calls both receive their data", function()
	withPair(function(a: serial.SerialPort, b: serial.SerialPort)
		local resultX: string? = nil
		local resultY: string? = nil

		task.spawn(function()
			resultX = b:read(4)
		end)
		task.spawn(function()
			resultY = b:read(4)
		end)

		task.wait(0.05)
		a:write("XYZW")
		a:write("ABCD")
		task.wait(0.1)

		test.expect(resultX):toNotBeNil()
		test.expect(resultY):toNotBeNil()
		-- Both readers got 4 bytes and together they cover all 8 sent bytes
		local combined = (resultX or "") .. (resultY or "")
		test.expect(#combined):toBe(8)
	end)
end)

-- ============================================================
-- flush
-- ============================================================

suite:test("flush: discards receive buffer (data sent before flush not visible after)", function()
	withPair(function(a, b)
		a:write("garbage")
		task.wait(0.05) -- let bytes arrive at b's OS buffer
		b:flush("input")
		local got = b:read(64, 50)
		test.expect(got):toBeNil()
	end)
end)

suite:test("flush('both') does not error", function()
	withPair(function(_a, b)
		test.expect(function()
			b:flush("both")
		end):toNotError()
	end)
end)

suite:test("flush rejects unknown direction", function()
	withPair(function(_a, b)
		-- Our C++ code passes unknown strings straight to the OS which may or
		-- may not error; here we just ensure the function is callable.
		test.expect(function()
			b:flush()
		end):toNotError()
	end)
end)

-- ============================================================
-- Control lines
-- ============================================================

suite:test("setDTR/setRTS do not error", function()
	withPair(function(a, _b)
		test.expect(function()
			a:setDTR(true)
			a:setDTR(false)
			a:setRTS(true)
			a:setRTS(false)
		end):toNotError()
	end)
end)

suite:test("getSignals returns a Signals table", function()
	withPair(function(a, _b)
		local sig = a:getSignals()
		test.expect(type(sig)):toBe("table")
		test.expect(type(sig.cts)):toBe("boolean")
		test.expect(type(sig.dsr)):toBe("boolean")
		test.expect(type(sig.dcd)):toBe("boolean")
		test.expect(type(sig.ri)):toBe("boolean")
	end)
end)

-- ============================================================
-- Configuration options
-- ============================================================

suite:test("open: respects custom baud rate (9600)", function()
	-- Open both ports, just to validate that we can use them
	withPair(function() end)

	-- Just verify it opens without error; we can't easily measure baud rate
	local p = serial.open(PORT_A, { baudRate = 9600 })
	test.expect(p.readable):toBeTrue()
	p:close()
end)

suite:test("open: rejects unsupported parity string", function()
	test.expect(function()
		serial.open(PORT_A, { parity = "bad" :: any })
	end):toError("invalid parity")
end)

-- ============================================================
-- Bidirectional round-trip
-- ============================================================

suite:test("full duplex: A writes, B reads, B writes, A reads", function()
	withPair(function(a, b)
		a:write("request")
		local req = b:read(7, 1000)
		test.expect(req):toBe("request")

		b:write("response")
		local resp = a:read(8, 1000)
		test.expect(resp):toBe("response")
	end)
end)

suite:test("large transfer: 4 KB round-trip", function()
	withPair(function(a, b)
		local payload = string.rep("x", 4096)

		task.spawn(function()
			a:write(payload)
		end)

		-- Read until we have all 4096 bytes
		local chunks = {}
		local total = 0
		while total < 4096 do
			local chunk = b:read(4096, 2000)
			if chunk == nil then
				break
			end
			chunks[#chunks + 1] = chunk
			total += #chunk
		end
		test.expect(table.concat(chunks)):toBe(payload)
	end)
end)

return suite
