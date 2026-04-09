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

--- Result of `isatty()` -- indicates which streams are connected to a terminal.
export type TtyInfo = {
	stdin: boolean,
	stdout: boolean,
	stderr: boolean,
}

-- Reading

--[=[
	Yields the current coroutine until data is available on stdin,
	then returns up to `bytes` bytes (default 4096).
	Returns `nil` on EOF. Passing `0` returns `""`.
	Only one `read` may be pending at a time.
]=]
function stdio.read(bytes: number?): string?
	return nil :: any
end

--[=[
	Reads up to `bytes` bytes from stdin (default 4096).
	Returns `nil` on EOF. Passing `0` returns `""`.
]=]
function stdio.readSync(bytes: number?): string?
	return nil :: any
end

--[=[
	Reads stdin in chunks until EOF and returns all data as one string.
]=]
function stdio.readall(chunkSize: number?): string
	return nil :: any
end

--[=[
	Reads one line from stdin, stripping the trailing newline.
	Returns `nil` on EOF.
]=]
function stdio.readline(): string?
	return nil :: any
end

--- Yields, writes a string to stdout, and returns bytes written.
function stdio.write(data: string): number
	return 0 :: any
end

--- Yields, writes a string to stderr, and returns bytes written.
function stdio.writeerr(data: string): number
	return 0 :: any
end

--- Yields and flushes the stdout buffer.
function stdio.flush() end

--- Yields and flushes the stderr buffer.
function stdio.flusherr() end

--- Writes a string to stdout synchronously.
--- Returns the number of bytes written.
function stdio.writeSync(data: string): number
	return 0 :: any
end

--- Writes a string to stderr synchronously.
--- Returns the number of bytes written.
function stdio.writeerrSync(data: string): number
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

return table.freeze(stdio)
