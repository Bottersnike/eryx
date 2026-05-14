local Stream = require("./stream")
local test = require("@eryx/test")

local suite = test.Suite.new("Stream")

local function readBufferString(buf: buffer): string
	return buffer.readstring(buf, 0, buffer.len(buf))
end

suite:test("new: supports empty, string, and buffer initial values", function()
	local empty = Stream.new()
	local fromString = Stream.new("hello")
	local fromBuffer = Stream.new(buffer.fromstring("world"))

	test.expect(empty:asString()):toBe("")
	test.expect(fromString:asString()):toBe("hello")
	test.expect(fromBuffer:asString()):toBe("world")
	test.expect(fromString:tell()):toBe(0)
	test.expect(fromBuffer:tell()):toBe(0)
end)

suite:test("read and readSync: consume data from the cursor", function()
	local stream = Stream.new("hello world")

	test.expect(stream:read(5)):toBe("hello")
	test.expect(stream:tell()):toBe(5)
	test.expect(stream:readSync(1)):toBe(" ")
	test.expect(stream:read()):toBe("world")
	test.expect(stream:read()):toBe("")
	test.expect(stream:tell()):toBe(11)
end)

suite:test("readBuffer and readBufferSync: return buffers and advance the cursor", function()
	local stream = Stream.new("abcdef")

	test.expect(readBufferString(stream:readBuffer(2))):toBe("ab")
	test.expect(readBufferString(stream:readBufferSync(3))):toBe("cde")
	test.expect(readBufferString(stream:readBuffer(10))):toBe("f")
	test.expect(buffer.len(stream:readBuffer())):toBe(0)
	test.expect(stream:tell()):toBe(6)
end)

suite:test("write and writeSync: accept strings and buffers", function()
	local stream = Stream.new()

	test.expect(stream:write("hello")):toBe(5)
	test.expect(stream:writeSync(buffer.fromstring(" world"))):toBe(6)
	test.expect(stream:tell()):toBe(11)
	test.expect(stream:asString()):toBe("hello world")
end)

suite:test("write: overwrites from the current cursor and grows as needed", function()
	local stream = Stream.new("abcdef")
	local longTail = string.rep("x", 70)

	test.expect(stream:seek(2, "set")):toBe(2)
	test.expect(stream:write("ZZ")):toBe(2)
	test.expect(stream:asString()):toBe("abZZef")

	test.expect(stream:seek(0, "end")):toBe(6)
	test.expect(stream:write(longTail)):toBe(70)
	test.expect(stream:asString()):toBe("abZZef" .. longTail)
end)

suite:test("seek and tell: support set, cur, end, and clamp to bounds", function()
	local stream = Stream.new("abcdef")

	test.expect(stream:seek(3, "set")):toBe(3)
	test.expect(stream:tell()):toBe(3)
	test.expect(stream:seek(10, "cur")):toBe(6)
	test.expect(stream:seek(-2, "end")):toBe(4)
	test.expect(stream:seek(-100, "cur")):toBe(0)
	test.expect(stream:tell()):toBe(0)
end)

suite:test("asBuffer: returns a copy of the current contents", function()
	local stream = Stream.new("hello")
	local copy = stream:asBuffer()

	buffer.writestring(copy, 0, "j")

	test.expect(readBufferString(copy)):toBe("jello")
	test.expect(stream:asString()):toBe("hello")
end)

suite:test("close: updates flags and blocks read, write, and seek", function()
	local stream = Stream.new("hello")

	stream:close()

	test.expect(stream.closed):toBeTrue()
	test.expect(stream.readable):toBeFalse()
	test.expect(stream.writable):toBeFalse()
	test.expect(function()
		stream:read(1)
	end):toError("Stream is closed")
	test.expect(function()
		stream:write("x")
	end):toError("Stream is closed")
	test.expect(function()
		stream:seek(0, "set")
	end):toError("Stream is closed")
end)

suite:test("closeSync: delegates to close and leaves snapshots accessible", function()
	local stream = Stream.new("hello")

	stream:closeSync()

	test.expect(stream.closed):toBeTrue()
	test.expect(stream:asString()):toBe("hello")
	test.expect(readBufferString(stream:asBuffer())):toBe("hello")
end)

return suite
