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

local types = require("@self/types")
local Stream = require("@self/stream")

export type StreamThatCanClose = types.StreamThatCanClose
export type StringStreamThatCanRead = types.StringStreamThatCanRead
export type BufferStreamThatCanRead = types.BufferStreamThatCanRead
export type StreamThatCanRead = types.StreamThatCanRead
export type StringStreamThatCanWrite = types.StringStreamThatCanWrite
export type BufferStreamThatCanWrite = types.BufferStreamThatCanWrite
export type StreamThatCanWrite = types.StreamThatCanWrite
export type StreamThatCanSeek = types.StreamThatCanSeek
export type StreamThatCanFlush = types.StreamThatCanFlush

export type ReadOnlyStream = types.ReadOnlyStream
export type WriteOnlyStream = types.WriteOnlyStream
export type ReadWriteStream = types.ReadWriteStream

export type Stream = Stream.Stream

return Stream
