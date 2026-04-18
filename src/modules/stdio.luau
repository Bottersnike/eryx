--[=[
	Standard I/O module -- read/write access to stdin, stdout, and stderr.

	Provides both synchronous (blocking) and asynchronous (yielding) APIs
	for interacting with the process's standard streams.

	## Quick start
	```luau
	local stdio = require("@eryx/stdio")

	-- Prompt the user
	stdio.write("Enter your name: ")
	stdio.flush()
	local name = stdio.readline()
	stdio.write("Hello, " .. (name or "stranger") .. "!\n")

	-- Check if running in a terminal
	local tty = stdio.isatty()
	if tty.stdin then
		print("stdin is a terminal")
	end
	```
]=]

local stdio = {}
local stream = require("@eryx/stream")

--- Result of `isatty()` -- indicates which streams are connected to a terminal.
export type TtyInfo = {
	stdin: boolean,
	stdout: boolean,
	stderr: boolean,
}

export type ReadLineOptions = {
	--- Line terminator sequence to stop at. Defaults to `"\n"`.
	terminator: string?,
	--- Whether to keep the matched terminator in the returned value.
	--- Defaults to `false`.
	keepTerminator: boolean?,
}

-- Reading

--[=[
	Yields the current coroutine until data is available on stdin,
	then returns up to `bytes` bytes (default 4096).
	Returns `""` on EOF. Passing `0` also returns `""`.
	Only one `read` may be pending at a time.
]=]
function stdio.read(bytes: number?): string
	return nil :: any
end

--[=[
	Reads up to `bytes` bytes from stdin (default 4096).
	Returns `""` on EOF. Passing `0` also returns `""`.
]=]
function stdio.readSync(bytes: number?): string
	return nil :: any
end

--- Yields and reads from stdin as a `buffer`.
--- Returns an empty buffer on EOF.
function stdio.readBuffer(bytes: number?): buffer
	return nil :: any
end

--- Reads from stdin synchronously as a `buffer`.
--- Returns an empty buffer on EOF.
function stdio.readBufferSync(bytes: number?): buffer
	return nil :: any
end

--[=[
	Reads stdin in chunks until EOF and returns all data as one string.
]=]
function stdio.readall(chunkSize: number?): string
	return nil :: any
end

--[=[
	Reads one line from stdin.

	By default this reads until `"\n"` and strips the terminator.
	Use `options.terminator` to change the delimiter and
	`options.keepTerminator=true` to keep it.

	Returns `""` on EOF.
]=]
function stdio.readline(options: ReadLineOptions?): string
	return nil :: any
end

--- Yields, writes a string to stdout, and returns bytes written.
function stdio.write(data: string | buffer): number
	return 0 :: any
end

--- Yields, writes a string to stderr, and returns bytes written.
function stdio.writeerr(data: string | buffer): number
	return 0 :: any
end

--- Yields and flushes the stdout buffer.
function stdio.flush() end

--- Yields and flushes the stderr buffer.
function stdio.flusherr() end

--- Writes a string to stdout synchronously.
--- Returns the number of bytes written.
function stdio.writeSync(data: string | buffer): number
	return 0 :: any
end

--- Writes a string to stderr synchronously.
--- Returns the number of bytes written.
function stdio.writeerrSync(data: string | buffer): number
	return 0 :: any
end

--- Flushes the stdout buffer synchronously.
function stdio.flushSync() end

--- Flushes the stderr buffer synchronously.
function stdio.flusherrSync() end

-- Utilities

--[=[
	Returns a table indicating whether each standard stream is connected
	to a terminal (TTY).
]=]
function stdio.isatty(): TtyInfo
	return nil :: any
end

--[=[
	Enables or disables terminal raw mode for stdin.

	Raw mode is only available when stdin is a TTY.
	Returns the active raw-mode state after applying the change.
]=]
function stdio.setRawMode(enabled: boolean): boolean
	return false :: any
end

--- Returns whether stdin raw mode is currently enabled.
function stdio.isRawMode(): boolean
	return false :: any
end

-- Stream handles
--[=[
	Process stdin exposed as a stream object.
	Use `stdio.stdin:read(...)` style calls.
]=]
local stdinStream: stream.ReadableStream = nil :: any
stdio.stdin = stdinStream

--[=[
	Process stdout exposed as a stream object.
	Use `stdio.stdout:write(...)` style calls.
]=]
local stdoutStream: stream.WritableStream = nil :: any
stdio.stdout = stdoutStream

--[=[
	Process stderr exposed as a stream object.
	Use `stdio.stderr:write(...)` style calls.
]=]
local stderrStream: stream.WritableStream = nil :: any
stdio.stderr = stderrStream

return table.freeze(stdio)
