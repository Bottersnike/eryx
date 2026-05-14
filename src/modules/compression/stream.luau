local streamTypes = require("@eryx/stream")

local compressionStream = {}

local DecompressionReadStream = {}
DecompressionReadStream.__index = DecompressionReadStream
local CompressionWriteStream = {}
CompressionWriteStream.__index = CompressionWriteStream

export type Decompressor = {
	write: (self: any, data: buffer) -> (buffer, boolean),
	close: (self: any) -> (),
}
export type Compressor = {
	write: (self: any, data: buffer, flush: number?) -> buffer,
	finish: (self: any) -> buffer,
	close: (self: any) -> (),
	flush: ((self: any) -> buffer)?,
}

export type WrapOptions = {
	chunkSize: number?,
	closeSource: boolean?,
}
export type WrapWriterOptions = {
	closeSink: boolean?,
}

type DecompressionReadStreamState = {
	source: streamTypes.StreamThatCanRead,
	decompressor: Decompressor,
	chunkSize: number,
	closeSource: boolean,
	buffered: string,
	finished: boolean,
	closed: boolean,
	readable: true,
	writable: false,
}
type CompressionWriteStreamState = {
	sink: streamTypes.StreamThatCanWrite,
	compressor: Compressor,
	closeSink: boolean,
	closed: boolean,
	readable: false,
	writable: true,
}

export type ReadStream = streamTypes.ReadOnlyStream
export type WriteStream = streamTypes.WriteOnlyStream & streamTypes.StreamThatCanFlush

local DEFAULT_CHUNK_SIZE = 8192

local function appendDecoded(self: DecompressionReadStreamState, chunk: buffer)
	if buffer.len(chunk) == 0 then
		return
	end

	self.buffered ..= buffer.tostring(chunk)
end

local function takeBuffered(self: DecompressionReadStreamState, size: number?): string
	local available = #self.buffered
	if size == nil or size >= available then
		local out = self.buffered
		self.buffered = ""
		return out
	end

	local out = string.sub(self.buffered, 1, size)
	self.buffered = string.sub(self.buffered, size + 1)
	return out
end

local function pullCompressedChunk(self: DecompressionReadStreamState, sync: boolean): buffer
	if sync then
		return self.source:readBufferSync(self.chunkSize)
	end
	return self.source:readBuffer(self.chunkSize)
end

local function fillBuffer(self: DecompressionReadStreamState, targetSize: number?, sync: boolean)
	while not self.finished and (targetSize == nil or #self.buffered < targetSize) do
		local compressed = pullCompressedChunk(self, sync)
		if buffer.len(compressed) == 0 then
			self.finished = true
			error("Compressed stream ended before decompressor finished")
		end

		local decoded, done = self.decompressor:write(compressed)
		appendDecoded(self, decoded)
		if done then
			self.finished = true
			break
		end
	end
end

local function readImpl(self: DecompressionReadStreamState, size: number?, sync: boolean): string
	if self.closed then
		error("Stream is closed")
	end
	if size ~= nil and size < 0 then
		error("size must be non-negative")
	end
	if size == 0 then
		return ""
	end

	if size == nil then
		fillBuffer(self, nil, sync)
		return takeBuffered(self, nil)
	end

	if #self.buffered < size and not self.finished then
		fillBuffer(self, size, sync)
	end

	return takeBuffered(self, size)
end

local function closeSourceIfNeeded(self: DecompressionReadStreamState, sync: boolean)
	if not self.closeSource then
		return
	end

	local sourceAny = self.source :: any
	if sync then
		local closeSync = sourceAny.closeSync
		if closeSync ~= nil then
			(closeSync :: any)(sourceAny)
			return
		end
	end

	local close = sourceAny.close
	if close ~= nil then
		(close :: any)(sourceAny)
	end
end

local function closeSinkIfNeeded(self: CompressionWriteStreamState, sync: boolean)
	if not self.closeSink then
		return
	end

	local sinkAny = self.sink :: any
	if sync then
		local closeSync = sinkAny.closeSync
		if closeSync ~= nil then
			(closeSync :: any)(sinkAny)
			return
		end
	end

	local close = sinkAny.close
	if close ~= nil then
		(close :: any)(sinkAny)
	end
end

local function writeCompressedOutput(self: CompressionWriteStreamState, chunk: buffer, sync: boolean)
	if buffer.len(chunk) == 0 then
		return
	end

	if sync then
		self.sink:writeSync(chunk)
	else
		self.sink:write(chunk)
	end
end

function DecompressionReadStream.read(self: any, size: number?): string
	return readImpl(self, size, false)
end

function DecompressionReadStream.readSync(self: any, size: number?): string
	return readImpl(self, size, true)
end

function DecompressionReadStream.readBuffer(self: any, size: number?): buffer
	return buffer.fromstring(self:read(size))
end

function DecompressionReadStream.readBufferSync(self: any, size: number?): buffer
	return buffer.fromstring(self:readSync(size))
end

function DecompressionReadStream.close(self: any)
	if self.closed then
		return
	end

	self.decompressor:close()
	closeSourceIfNeeded(self, false)
	self.closed = true
end

function DecompressionReadStream.closeSync(self: any)
	if self.closed then
		return
	end

	self.decompressor:close()
	closeSourceIfNeeded(self, true)
	self.closed = true
end

local function writeImpl(self: CompressionWriteStreamState, data: string | buffer, sync: boolean): number
	if self.closed then
		error("Stream is closed")
	end

	local input = if type(data) == "string" then buffer.fromstring(data) else data
	local compressed = self.compressor:write(input)
	writeCompressedOutput(self, compressed, sync)
	return buffer.len(input)
end

local function flushImpl(self: CompressionWriteStreamState, sync: boolean)
	if self.closed then
		error("Stream is closed")
	end

	local flush = self.compressor.flush
	if flush == nil then
		return
	end

	local compressed = (flush :: any)(self.compressor)
	writeCompressedOutput(self, compressed, sync)
end

local function finishImpl(self: CompressionWriteStreamState, sync: boolean)
	if self.closed then
		return
	end

	local compressed = self.compressor:finish()
	writeCompressedOutput(self, compressed, sync)
	self.compressor:close()
	closeSinkIfNeeded(self, sync)
	self.closed = true
end

function CompressionWriteStream.write(self: any, data: string | buffer): number
	return writeImpl(self, data, false)
end

function CompressionWriteStream.writeSync(self: any, data: string | buffer): number
	return writeImpl(self, data, true)
end

function CompressionWriteStream.flush(self: any)
	flushImpl(self, false)
end

function CompressionWriteStream.flushSync(self: any)
	flushImpl(self, true)
end

function CompressionWriteStream.close(self: any)
	finishImpl(self, false)
end

function CompressionWriteStream.closeSync(self: any)
	finishImpl(self, true)
end

function compressionStream.wrap(
	source: streamTypes.StreamThatCanRead,
	decompressor: Decompressor,
	options: WrapOptions?
): ReadStream
	local chunkSize = if options and options.chunkSize ~= nil then options.chunkSize else DEFAULT_CHUNK_SIZE
	if chunkSize <= 0 then
		error("chunkSize must be positive")
	end

	local self: DecompressionReadStreamState = {
		source = source,
		decompressor = decompressor,
		chunkSize = chunkSize,
		closeSource = if options and options.closeSource ~= nil then options.closeSource else true,
		buffered = "",
		finished = false,
		closed = false,
		readable = true,
		writable = false,
	}

	return setmetatable(self, DecompressionReadStream) :: any
end

function compressionStream.wrapWriter(
	sink: streamTypes.StreamThatCanWrite,
	compressor: Compressor,
	options: WrapWriterOptions?
): WriteStream
	local self: CompressionWriteStreamState = {
		sink = sink,
		compressor = compressor,
		closeSink = if options and options.closeSink ~= nil then options.closeSink else true,
		closed = false,
		readable = false,
		writable = true,
	}

	return setmetatable(self, CompressionWriteStream) :: any
end

return table.freeze(compressionStream)
