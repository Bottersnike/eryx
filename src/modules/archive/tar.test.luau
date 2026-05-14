local test = require("@eryx/test")
local tar = require("@eryx/archive/tar")

local suite = test.Suite.new("tar")

type StubSeekableStream = {
	readable: true,
	closed: boolean,
	read: (self: StubSeekableStream, size: number?) -> string,
	readSync: (self: StubSeekableStream, size: number?) -> string,
	readBuffer: (self: StubSeekableStream, size: number?) -> buffer,
	readBufferSync: (self: StubSeekableStream, size: number?) -> buffer,
	seek: (self: StubSeekableStream, offset: number, whence: ("set" | "cur" | "end")?) -> number,
	tell: (self: StubSeekableStream) -> number,
	close: (self: StubSeekableStream) -> (),
	closeSync: (self: StubSeekableStream) -> (),
	closeCalls: number,
	closeSyncCalls: number,
	position: number,
}

local function makeSeekableStream(): StubSeekableStream
	local stream_: StubSeekableStream
	stream_ = {
		readable = true,
		closed = false,
		closeCalls = 0,
		closeSyncCalls = 0,
		position = 0,
		read = function(self, _size)
			if self.closed then
				error("stream is closed")
			end
			return ""
		end,
		readSync = function(self, size)
			return self:read(size)
		end,
		readBuffer = function(self, size)
			return buffer.fromstring(self:read(size))
		end,
		readBufferSync = function(self, size)
			return buffer.fromstring(self:readSync(size))
		end,
		seek = function(self, offset, whence)
			if self.closed then
				error("stream is closed")
			end

			if whence == nil or whence == "set" then
				self.position = offset
			elseif whence == "cur" then
				self.position += offset
			elseif whence == "end" then
				self.position = offset
			end

			return self.position
		end,
		tell = function(self)
			if self.closed then
				error("stream is closed")
			end
			return self.position
		end,
		close = function(self)
			self.closeCalls += 1
			self.closed = true
		end,
		closeSync = function(self)
			self.closeSyncCalls += 1
			self.closed = true
		end,
	}

	return stream_
end

suite:test("openSeekable: close releases underlying stream and is idempotent", function()
	local stream_ = makeSeekableStream()
	local reader = tar.openSeekable(stream_ :: any)

	reader:close()
	reader:close()

	test.expect(stream_.closeCalls):toBe(1)
	test.expect(stream_.closeSyncCalls):toBe(0)
	test.expect(stream_.closed):toBeTrue()
	test.expect(function()
		reader:nextMember()
	end):toError("TAR reader is closed")
end)

suite:test("openSeekable: closeSync prefers closeSync and blocks later seeking", function()
	local stream_ = makeSeekableStream()
	local reader = tar.openSeekable(stream_ :: any)

	reader:closeSync()

	test.expect(stream_.closeSyncCalls):toBe(1)
	test.expect(stream_.closeCalls):toBe(0)
	test.expect(function()
		reader:rewind()
	end):toError("TAR reader is closed")
end)

return suite
