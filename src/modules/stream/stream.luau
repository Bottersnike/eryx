local types = require("./types")

local INITIAL_BUFFER_SIZE = 64
local SMALL_GROWTH_FACTOR = 2
local LARGE_GROWTH_CONSTANT = 1024 * 1024 -- 1 MiB
local LARGE_THRESHOLD = 1024 * 1024 -- 1 MiB

local function nextCapacity(current: number, required: number): number
	if current == 0 then
		current = INITIAL_BUFFER_SIZE
	end

	while current < required do
		if current < LARGE_THRESHOLD then
			current *= SMALL_GROWTH_FACTOR
		else
			current += LARGE_GROWTH_CONSTANT
		end
	end

	assert(current >= required, "Growth failure")
	return current
end

local function ensureBufferCapacity(buf: buffer, capacity: number, usedLength: number): buffer
	local len = buffer.len(buf)
	if len >= capacity then
		return buf
	end

	local newCapacity = nextCapacity(len, capacity)
	local new = buffer.create(newCapacity)
	buffer.copy(new, 0, buf, 0, usedLength)

	return new
end

local Stream = {}
Stream.__index = Stream

-- Stream satisfies the following, but we cannot annotate this due to `self`:
-- & types.StreamThatCanRead
-- & types.StreamThatCanWrite
-- & types.StreamThatCanSeek
-- & types.StreamThatCanClose

export type Stream = setmetatable<
	types.StreamThatCanRead & types.StreamThatCanWrite & types.StreamThatCanSeek & types.StreamThatCanClose & {
		_data: buffer,
		_length: number,
		_cursor: number,

		readable: boolean,
		writable: boolean,
		closed: boolean?,
	},
	typeof(Stream)
>

function Stream.new(initialValue: (string | buffer)?): Stream
	local buf: buffer
	local length = 0

	if initialValue == nil then
		buf = buffer.create(INITIAL_BUFFER_SIZE)
	elseif typeof(initialValue) == "string" then
		length = #initialValue
		buf = buffer.create(nextCapacity(0, length))
		buffer.writestring(buf, 0, initialValue)
	elseif typeof(initialValue) == "buffer" then
		length = buffer.len(initialValue)
		buf = buffer.create(nextCapacity(0, length))
		buffer.copy(buf, 0, initialValue, 0, length)
	else
		error("Invalid initial stream value")
	end

	local this = {
		_data = buf,
		_length = length,
		_cursor = 0,

		readable = true,
		writable = true,
		closed = false,
	}

	return setmetatable(this, Stream) :: any
end

function Stream.read(self: Stream, size: number?): string
	assert(not self.closed, "Stream is closed")

	local available = self._length - self._cursor
	local readSize = if size == nil then available else math.min(available, size)

	if readSize <= 0 then
		return ""
	end

	local read = buffer.readstring(self._data, self._cursor, readSize)
	self._cursor += #read
	return read
end

function Stream.readSync(self: Stream, size: number?): string
	return Stream.read(self, size)
end

function Stream.readBuffer(self: Stream, size: number?): buffer
	assert(not self.closed, "Stream is closed")

	local available = self._length - self._cursor
	local readSize = if size == nil then available else math.min(available, size)

	if readSize <= 0 then
		return buffer.create(0)
	end

	local ret = buffer.create(readSize)
	buffer.copy(ret, 0, self._data, self._cursor, readSize)
	self._cursor += readSize
	return ret
end

function Stream.readBufferSync(self: Stream, size: number?): buffer
	return Stream.readBuffer(self, size)
end

function Stream.write(self: Stream, data: string | buffer): number
	assert(not self.closed, "Stream is closed")

	local writeSize = if typeof(data) == "string" then #data else buffer.len(data)
	local required = self._cursor + writeSize

	self._data = ensureBufferCapacity(self._data, required, self._length)

	if typeof(data) == "string" then
		buffer.writestring(self._data, self._cursor, data)
	else
		buffer.copy(self._data, self._cursor, data, 0, writeSize)
	end

	self._cursor += writeSize
	self._length = math.max(self._length, self._cursor)

	return writeSize
end

function Stream.writeSync(self: Stream, data: string | buffer): number
	return Stream.write(self, data)
end

function Stream.seek(self: Stream, offset: number, whence: types.Whence?): number
	assert(not self.closed, "Stream is closed")

	local base = if whence == "set" then 0 elseif whence == "end" then self._length else self._cursor

	local newCursor = base + offset

	self._cursor = math.max(0, math.min(self._length, newCursor))
	return self._cursor
end

function Stream.tell(self: Stream): number
	return self._cursor
end

function Stream.close(self: Stream): ()
	self.closed = true
	self.readable = false
	self.writable = false
end

function Stream.closeSync(self: Stream): ()
	Stream.close(self)
end

function Stream.asBuffer(self: Stream): buffer
	local buf = buffer.create(self._length)
	buffer.copy(buf, 0, self._data, 0, self._length)
	return buf
end

function Stream.asString(self: Stream): string
	return buffer.readstring(self._data, 0, self._length)
end

return Stream
