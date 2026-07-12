--!native

local BufferBuilder = {}
BufferBuilder.__index = BufferBuilder

export type BufferBuilder = setmetatable<{
	buf: buffer,
	offset: number,
}, typeof(BufferBuilder)>

function BufferBuilder.new(initial: number?): BufferBuilder
	local self = {
		buf = buffer.create(initial or 512),
		offset = 0,
	}

	return setmetatable(self, BufferBuilder)
end

function BufferBuilder.tell(self: BufferBuilder): number
	return self.offset
end

function BufferBuilder.seek(self: BufferBuilder, offset: number): ()
	self.offset = offset
end

function BufferBuilder.ensure(self: BufferBuilder, extra: number)
	local needed = self.offset + extra
	if needed <= buffer.len(self.buf) then
		return
	end

	local newSize = buffer.len(self.buf)
	if newSize == 0 then
		newSize = 1
	end

	while newSize < needed do
		newSize *= 2
	end

	local newBuf = buffer.create(newSize)
	buffer.copy(newBuf, 0, self.buf, 0, self.offset)
	self.buf = newBuf
end

function BufferBuilder.finish(self: BufferBuilder): buffer
	local out = buffer.create(self.offset)
	buffer.copy(out, 0, self.buf, 0, self.offset)
	return out
end

function BufferBuilder.writeI8(self: BufferBuilder, value: number)
	self:ensure(1)
	buffer.writei8(self.buf, self.offset, bit32.band(value, 0xff))
	self.offset += 1
end

function BufferBuilder.writeU8(self: BufferBuilder, value: number)
	self:ensure(1)
	buffer.writeu8(self.buf, self.offset, bit32.band(value, 0xff))
	self.offset += 1
end

function BufferBuilder.writeI16le(self: BufferBuilder, value: number)
	self:ensure(2)
	buffer.writei16(self.buf, self.offset, value)
	self.offset += 2
end

function BufferBuilder.writeU16le(self: BufferBuilder, value: number)
	self:ensure(2)
	buffer.writeu16(self.buf, self.offset, value)
	self.offset += 2
end

function BufferBuilder.writeI16be(self: BufferBuilder, value: number)
	self:ensure(2)
	buffer.writeu8(self.buf, self.offset, bit32.band(bit32.rshift(value, 8), 0xff))
	buffer.writeu8(self.buf, self.offset + 1, bit32.band(value, 0xff))
	self.offset += 2
end

function BufferBuilder.writeU16be(self: BufferBuilder, value: number)
	self:ensure(2)
	buffer.writeu8(self.buf, self.offset, bit32.band(bit32.rshift(value, 8), 0xff))
	buffer.writeu8(self.buf, self.offset + 1, bit32.band(value, 0xff))
	self.offset += 2
end

function BufferBuilder.writeI32le(self: BufferBuilder, value: number)
	self:ensure(4)
	buffer.writei32(self.buf, self.offset, value)
	self.offset += 4
end

function BufferBuilder.writeU32le(self: BufferBuilder, value: number)
	self:ensure(4)
	buffer.writeu32(self.buf, self.offset, value)
	self.offset += 4
end

function BufferBuilder.writeI32be(self: BufferBuilder, value: number)
	self:ensure(4)
	buffer.writeu8(self.buf, self.offset, bit32.band(bit32.rshift(value, 24), 0xff))
	buffer.writeu8(self.buf, self.offset + 1, bit32.band(bit32.rshift(value, 16), 0xff))
	buffer.writeu8(self.buf, self.offset + 2, bit32.band(bit32.rshift(value, 8), 0xff))
	buffer.writeu8(self.buf, self.offset + 3, bit32.band(value, 0xff))
	self.offset += 4
end

function BufferBuilder.writeU32be(self: BufferBuilder, value: number)
	self:ensure(4)
	buffer.writeu8(self.buf, self.offset, bit32.band(bit32.rshift(value, 24), 0xff))
	buffer.writeu8(self.buf, self.offset + 1, bit32.band(bit32.rshift(value, 16), 0xff))
	buffer.writeu8(self.buf, self.offset + 2, bit32.band(bit32.rshift(value, 8), 0xff))
	buffer.writeu8(self.buf, self.offset + 3, bit32.band(value, 0xff))
	self.offset += 4
end

function BufferBuilder.writeString(self: BufferBuilder, value: string)
	self:ensure(#value)
	buffer.writestring(self.buf, self.offset, value)
	self.offset += #value
end

function BufferBuilder.writeBuffer(self: BufferBuilder, src: buffer)
	local len = buffer.len(src)
	self:ensure(len)
	buffer.copy(self.buf, self.offset, src, 0, len)
	self.offset += len
end

local function foo(options: { bar: number? })
	if options.bar == nil then
		options.bar = 1
	end

	options.bar += 1
end

return table.freeze(BufferBuilder)
