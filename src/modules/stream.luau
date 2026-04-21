--[=[
	Functions that return a stream will return a [[ReadOnlyStream]],
	a [[WriteOnlyStream]], or a [[ReadWriteStream]].

	[[Stream]] represent a generic stream of unknown writability, but
	`readable` and `writable` allow this to be narrowed down. For
	example:

	```luau
	if s.readable then
		s:read()
	end
	if s.writable then
		s:write()
	end
	```

	When writing a function that expects a generic stream as an
	argument, the `StreamThatCanX` types should be used instead. If a
	function is defined as taking a [[ReadOnlyStream]], the type system
	will not allow a [[ReadWriteStream]] to be passed. On the other
	hand, that same function can be defined to take a
	`StreamThatCanRead & StreamThatCanClose` and a read-write stream can
	be passed.

	```luau
	local function foo(x: ReadOnlyStream)
		print(x:read())
		x:close()
	end
	foo(y :: ReadWriteStream)  -- Type error
	```

	```luau
	local function foo(x: StreamThatCanRead & StreamThatCanClose)
		print(x:read())
		x:close()
	end
	foo(y :: ReadWriteStream)  -- Ok!
	```

	This way, a function's argument describes the expected capabilities
	required of the passed stream.
]=]

local stream = {}

export type StreamThatCanClose = {
	--- Closes this stream, setting closed to true
	--- @yields
	close: (self: StreamThatCanClose) -> (),
	--- Non-yielding version of [[close]]
	closeSync: (self: StreamThatCanClose) -> (),
	--- A boolean indicating if this stream is already closed
	closed: boolean?,
}
export type StreamThatCanRead = {
	--- Marks that this stream is readable
	readable: true,
	--[=[
	Read data from the stream.

	The formal [[Stream]] contract defines this as always returning a
	`string`.

	Some implementations of streams may augment this function to return
	`string?` in non-blocking contexts.

	@param size The number of bytes to read. If omitted, reads all available data
	@return The data read, which may be shorter than `size` (including `""`), but never larger.
	@yields
	]=]
	read: (self: StreamThatCanRead, size: number?) -> string,
	--- Non-yielding version of [[read]]
	readSync: (self: StreamThatCanRead, size: number?) -> string,
	--[=[
	Read data from the stream, returning the data as a `buffer`. See [[read]].
	@yields
	]=]
	readBuffer: (self: StreamThatCanRead, size: number?) -> buffer,
	--- Non-yielding version of [[readBuffer]]
	readBufferSync: (self: StreamThatCanRead, size: number?) -> buffer,
}
export type StreamThatCanWrite = {
	--- Marks that this stream is writable
	writable: true,
	--[=[
	Writes data to the stream

	@param data The data to write
	@return The number of bytes of `data` that was written
	@yields
	]=]
	write: (self: StreamThatCanWrite, data: string | buffer) -> number,
	--- Non-yielding version of [[write]]
	writeSync: (self: StreamThatCanWrite, data: string | buffer) -> number,
}

--[=[
	Read-only stream contract.

	`read` and `readSync` are intentionally generic and may return either
	`string` or `buffer` depending on the concrete stream source.
	Use `readBuffer` variants when you specifically need `buffer`.
]=]
export type ReadOnlyStream = StreamThatCanClose & StreamThatCanRead & {
	--- Indicates that this stream is read-only
	writable: false,
}

--[=[
	Write-only stream contract.

	`write` and `writeSync` accept `string | buffer` to support both text and
	binary producer code with one surface.
]=]
export type WriteOnlyStream = StreamThatCanClose & StreamThatCanWrite & {
	--- Indicates that this stream is write-only
	readable: false,
}

--[=[
	Duplex stream contract.

	This is effectively `ReadOnlyStream & WriteOnlyStream` with explicit tags.
]=]
export type ReadWriteStream = StreamThatCanClose & StreamThatCanRead & StreamThatCanWrite

--- Union of all stream capability variants.
export type Stream = ReadOnlyStream | WriteOnlyStream | ReadWriteStream

return table.freeze(stream)
