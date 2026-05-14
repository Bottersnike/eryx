--[=[
We have to use `self: any` across this whole file because otherwise
implementations of Streams will end up incompatible.

I hate that as much as you, but hopefully classes might fix this
]=]

export type StreamThatCanClose = {
	--- Closes this stream, setting closed to true
	--- @yields
	read close: (self: any) -> (),
	--- Non-yielding version of [[close]]
	read closeSync: (self: any) -> (),
	--- A boolean indicating if this stream is already closed
	read closed: boolean?,
}
export type StringStreamThatCanRead = {
	--- Marks that this stream is readable
	read readable: true,
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
	read read: (self: any, size: number?) -> string,
	--- Non-yielding version of [[read]]
	read readSync: (self: any, size: number?) -> string,
}
export type BufferStreamThatCanRead = {
	--- Marks that this stream is readable
	read readable: true,
	--[=[
	Read data from the stream, returning the data as a `buffer`. See [[read]].
	@yields
	]=]
	read readBuffer: (self: any, size: number?) -> buffer,
	--- Non-yielding version of [[readBuffer]]
	read readBufferSync: (self: any, size: number?) -> buffer,
}
export type StreamThatCanRead = StringStreamThatCanRead & BufferStreamThatCanRead

export type StringStreamThatCanWrite = {
	--- Marks that this stream is writable
	read writable: true,
	--[=[
	Writes data to the stream

	@param data The data to write
	@return The number of bytes of `data` that was written
	@yields
	]=]
	read write: (self: any, data: string) -> number,
	--- Non-yielding version of [[write]]
	read writeSync: (self: any, data: string) -> number,
}
export type BufferStreamThatCanWrite = {
	-- Note: We cannot safely type `self` here due to `StreamThatCanWrite`

	--- Marks that this stream is writable
	read writable: true,
	--[=[
	Writes data to the stream

	@param data The data to write
	@return The number of bytes of `data` that was written
	@yields
	]=]
	read write: (self: any, data: buffer) -> number,
	--- Non-yielding version of [[write]]
	read writeSync: (self: any, data: buffer) -> number,
}
export type StreamThatCanWrite = StringStreamThatCanWrite & BufferStreamThatCanWrite

export type Whence = "set" | "cur" | "end"
export type StreamThatCanSeek = {
	--- Moves the file cursor.
	--- @param whence Seek origin: `set` (default), `cur`, or `end`.
	--- @return The new file offset.
	read seek: (self: any, offset: number, whence: Whence?) -> number,
	--- Returns the current file cursor position.
	read tell: (self: any) -> number,
}
export type StreamThatCanFlush = {
	--- Flushes buffered data
	--- @yields
	read flush: (self: any) -> (),
	--- Flushes buffered data
	read flushSync: (self: any) -> (),
}

--[=[
	Read-only stream contract.

	`read` and `readSync` are intentionally generic and may return either
	`string` or `buffer` depending on the concrete stream source.
	Use `readBuffer` variants when you specifically need `buffer`.
]=]
export type ReadOnlyStream = StreamThatCanClose & StreamThatCanRead & {
	--- Indicates that this stream is read-only
	read writable: false,
}

--[=[
	Write-only stream contract.

	`write` and `writeSync` accept `string | buffer` to support both text and
	binary producer code with one surface.
]=]
export type WriteOnlyStream = StreamThatCanClose & StreamThatCanWrite & {
	--- Indicates that this stream is write-only
	read readable: false,
}

--[=[
	Duplex stream contract.

	This is effectively `ReadOnlyStream & WriteOnlyStream` with explicit tags.
]=]
export type ReadWriteStream = StreamThatCanClose & StreamThatCanRead & StreamThatCanWrite

return table.freeze({})
