--[=[
	Shared stream contracts for Eryx.

	This module provides:

	1. Structural stream types (`ReadableStream`, `WritableStream`,
	   `ReadWriteStream`, and `Stream`) for static typing.

	## Design intent

	- Native objects should "just be streams" by shape, not inheritance.
	  `fs.File`, `_socket.Socket`, and `_ssl.SslSocket` can satisfy these
	  contracts directly via structural typing.
	- Capabilities are represented in types with tags:
	  `readable: true/false` and `writable: true/false`.
	- Runtime compatibility is preserved: some concrete objects may still
	  expose methods that can error when capability is invalid.

	## Return conventions

	- EOF is returned as `""` for string reads and an empty `buffer` for
	  buffer reads.
	- `nil` is reserved for non-blocking "would block" style results on
	  stream-like APIs that support them.

	## Quick examples

	Use `@eryx/stdio` for process-owned stream handles:
	- `stdio.stdin`
	- `stdio.stdout`
	- `stdio.stderr`
]=]

local stream = {}

--[=[
	Read-only stream contract.

	`read` and `readSync` are intentionally generic and may return either
	`string` or `buffer` depending on the concrete stream source.
	Use `readBuffer` variants when you specifically need `buffer`.
]=]
export type ReadableStream = {
	readable: true,
	writable: false,
	closed: boolean?,
	read: (self: ReadableStream, size: number?) -> string,
	readSync: (self: ReadableStream, size: number?) -> string,
	readBuffer: (self: ReadableStream, size: number?) -> buffer,
	readBufferSync: (self: ReadableStream, size: number?) -> buffer,
	close: (self: ReadableStream) -> (),
	closeSync: (self: ReadableStream) -> (),
}

--[=[
	Write-only stream contract.

	`write` and `writeSync` accept `string | buffer` to support both text and
	binary producer code with one surface.
]=]
export type WritableStream = {
	readable: false,
	writable: true,
	closed: boolean?,
	write: (self: WritableStream, data: string | buffer) -> number,
	writeSync: (self: WritableStream, data: string | buffer) -> number,
	close: (self: WritableStream) -> (),
	closeSync: (self: WritableStream) -> (),
}

--[=[
	Duplex stream contract.

	This is effectively `ReadableStream & WritableStream` with explicit tags.
]=]
export type ReadWriteStream = {
	readable: true,
	writable: true,
	closed: boolean?,
	read: (self: ReadWriteStream, size: number?) -> string,
	readSync: (self: ReadWriteStream, size: number?) -> string,
	readBuffer: (self: ReadWriteStream, size: number?) -> buffer,
	readBufferSync: (self: ReadWriteStream, size: number?) -> buffer,
	write: (self: ReadWriteStream, data: string | buffer) -> number,
	writeSync: (self: ReadWriteStream, data: string | buffer) -> number,
	close: (self: ReadWriteStream) -> (),
	closeSync: (self: ReadWriteStream) -> (),
}

--- Union of all stream capability variants.
export type Stream = ReadableStream | WritableStream | ReadWriteStream

return table.freeze(stream)
