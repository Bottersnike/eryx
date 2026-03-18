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
	local name = stdio.readln()
	stdio.write("Hello, " .. (name or "stranger") .. "!\n")

	-- Write to stderr
	stdio.writeerr("warning: something happened\n")

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

-- Synchronous I/O

--[=[
	Reads up to `bytes` bytes from stdin (default 4096).
	Returns `nil` on EOF.
]=]
function stdio.read(bytes: number?): string?
	return nil :: any
end

--[=[
	Reads one line from stdin, stripping the trailing newline.
	Returns `nil` on EOF.
]=]
function stdio.readln(): string?
	return nil :: any
end

--- Writes a string to stdout.
function stdio.write(data: string) end

--- Writes a string to stderr.
function stdio.writeerr(data: string) end

--- Flushes the stdout buffer.
function stdio.flush() end

--- Flushes the stderr buffer.
function stdio.flusherr() end

-- Asynchronous I/O

--[=[
	Yields the current coroutine until data is available on stdin,
	then returns up to `bytes` bytes (default 4096).
	Returns `nil` on EOF.  Only one `readasync` may be pending at a time.
]=]
function stdio.readasync(bytes: number?): string?
	return nil :: any
end

-- Utilities

--[=[
	Returns a table indicating whether each standard stream is connected
	to a terminal (TTY).
]=]
function stdio.isatty(): TtyInfo
	return nil :: any
end

return stdio
