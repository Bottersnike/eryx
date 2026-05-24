local path = require("@eryx/path")
local stream = require("@eryx/stream")

type Path = path.Path
type PathLike = path.PathLike

--[=[
	Options controlling how a child process is spawned.
]=]
export type SpawnOptions = {
	--- Specify the directory for the child process
	cwd: PathLike?,
	--- Specify additional environment variables for the child process
	env: { [string]: string }?,
	--- Inherit the parent process stdin/stdout/stderr instead of creating pipes.
	--- Supported by `os.exec`; `os.spawn` requires piped stdio.
	inheritStdio: boolean?,
	--[=[
		Run this as a shell command
		:::warning
		This passes the provided command and arguments directly to `cmd.exe /C`
		:::
	]=]
	shell: boolean?,
}

--[=[
	Result of `os.exec(...)`.
]=]
export type ExecResult = {
	--- Captured stdout output.
	stdout: string,
	--- Captured stderr output.
	stderr: string,
	--- Process exit status code.
	code: number,
}

--[=[
	Handle to a running child process returned by [[os.spawn]].
]=]
export type ProcessHandle = {
	--- Process ID
	pid: number,
	--- Process return code, if it's exited
	status: number?,
	--- Writable stream connected to the child process stdin.
	stdin: stream.WriteOnlyStream,
	--- Readable stream connected to the child process stdout.
	stdout: stream.ReadOnlyStream,
	--- Readable stream connected to the child process stderr.
	stderr: stream.ReadOnlyStream,
	--- Wait for the process to complete
	--- @yields
	wait: (self: ProcessHandle) -> ExecResult,
	--[=[
		Kill the process
		@param signal Optional signal to raise in process
	]=]
	kill: (self: ProcessHandle, signal: number | string?) -> (),
}

--[=[
	Cross-platform principal identifier.
	On POSIX this is typically numeric (`uid`/`gid`), and on Windows this is typically a SID string.
]=]
export type PrincipalId = number | string

--[=[
	Resolved user/group metadata.
	Fields may vary by platform.
]=]
export type PrincipalInfo = {
	--- Canonical identifier for the principal.
	id: PrincipalId,
	--- Friendly account/group name when available.
	name: string?,
	--- Principal category.
	kind: "user" | "group",
	--- Platform that produced this identity record.
	platform: Platform,
	--- POSIX uid when available.
	uid: number?,
	--- POSIX gid when available.
	gid: number?,
	--- Windows SID when available.
	sid: string?,
	--- Home/profile directory when available.
	home: string?,
	--- Login shell when available (POSIX).
	shell: string?,
	--- Windows account domain when available.
	domain: string?,
	--- Windows account name when available.
	accountName: string?,
}

--[=[
	Supported host platforms.
]=]
export type Platform = "windows" | "macos" | "linux" | nil

--[=[
	Supported CPU architecture identifiers.
]=]
export type Arch = "x64" | "arm64" | "arm" | "x86" | nil

local os = {}

--- Common process signal constants (`TERM`, `SIGTERM`, `INT`, etc).
os.signals = nil :: any

--[=[
	Get a specific environment variable
	@param key Environment variable name.
	@return Environment variable value, or nil when undefined.
]=]
function os.getenv(key: string): string?
	return nil :: any
end

--[=[
	Set or unset a specific environment variable
	@param key Environment variable name.
	@param value Value to set, or nil to unset.
]=]
function os.setenv(key: string, value: string?) end

--[=[
	Get all currently defined environment variables.
	@return A table of environment variables keyed by name.
]=]
function os.environ(): { [string]: string }
	return nil :: any
end

--[=[
	Get the git hash of Luau

	There are no official "proper" version numbers for Luau, so the values here are derived from git.

	The hash is the most reliable value, and indicates the exact version of Luau compiled against

	The release is based on most recent tag, and typically follows the format `0.xxx`, but can include
	additional information if the tagged commit is not the most recent
]=]
function os.luauVersion(): { release: string, hash: string }
	return nil :: any
end

--[=[
	Get the current system platform.
	@return Current platform identifier.
]=]
function os.platform(): Platform
	return nil :: any
end

--[=[
	Get the current system architecture.
	@return Current CPU architecture identifier.
]=]
function os.arch(): Arch
	return nil :: any
end

--[=[
	Get the current system hostname.
	@return Hostname reported by the operating system.
]=]
function os.hostname(): string
	return nil :: any
end

--[=[
	Get the current user's temporary directory.
	@return Absolute path to the temp directory.
]=]
function os.tmpdir(): string
	return nil :: any
end

--[=[
	Get the current user's home directory.
	@return Absolute path to the home/profile directory.
]=]
function os.homedir(): string
	return nil :: any
end

--[=[
	Get the number of CPUs present.
	@return Number of logical CPUs.
]=]
function os.cpucount(): number
	return nil :: any
end

--[=[
	Get the total system memory in KiB.
	@return Total memory in kibibytes.
]=]
function os.totalmem(): number
	return nil :: any
end

--[=[
	Get the free system memory in KiB.
	@return Free memory in kibibytes.
]=]
function os.freemem(): number
	return nil :: any
end

--[=[
	Get the system uptime in seconds.
	@return Seconds since system boot.
]=]
function os.uptime(): number
	return nil :: any
end

--[=[
	Get the current process PID.
	@return Current process identifier.
]=]
function os.pid(): number
	return nil :: any
end

--[=[
	Current process user identifier (`uid` on POSIX, SID string on Windows).
	@return Current user identifier.
]=]
function os.uid(): PrincipalId
	return nil :: any
end

--[=[
	Current process group identifier (`gid` on POSIX, SID string on Windows).
	@return Current group identifier.
]=]
function os.gid(): PrincipalId
	return nil :: any
end

--[=[
	Effective user identifier (`euid` on POSIX, SID string on Windows).
	@return Effective user identifier.
]=]
function os.euid(): PrincipalId
	return nil :: any
end

--[=[
	Effective group identifier (`egid` on POSIX, SID string on Windows).
	@return Effective group identifier.
]=]
function os.egid(): PrincipalId
	return nil :: any
end

--[=[
	Resolve user details for current user or an explicit subject.
	@param subject Optional uid/SID or user name. Defaults to current user.
	@return Resolved user details, or nil when not found.
]=]
function os.userInfo(subject: PrincipalId?): PrincipalInfo?
	return nil :: any
end

--[=[
	Resolve group details for current group or an explicit subject.
	@param subject Optional gid/SID or group name. Defaults to current group.
	@return Resolved group details, or nil when not found.
]=]
function os.groupInfo(subject: PrincipalId?): PrincipalInfo?
	return nil :: any
end

--[=[
	Exit the process with a specific status code
	@param code Process exit code. Defaults to `0`.
]=]
function os.exit(code: number?) end

--[=[
	Get the current monotonic system clock time in seconds.
	@return Monotonic clock value in seconds.
]=]
function os.clock(): number
	return nil :: any
end

--[=[
	Get the current working directory.
	@return Absolute path to the current working directory.
]=]
function os.cwd(): Path
	return nil :: any
end

--[=[
	Change the current working directory
	@param path New working directory path.
]=]
function os.chdir(path: PathLike) end

--[=[
	Get the command line arguments for this script.

	Returns the synthetic script-facing argv for the current runtime: the
	invoked script name/path first, followed by that script's arguments.

	For example, `eryx -O2 foo.luau --verbose bar` returns
	`{"foo.luau", "--verbose", "bar"}`.
	@return Ordered script argv for the current runtime.
]=]
function os.cliargs(): { string }
	return nil :: any
end

--[=[
	Execute a child process and wait for it to complete.

	This function is equivalent to using:
	```luau
	os.spawn(...):wait()
	```

	When `opts.inheritStdio` is true, stdout and stderr are forwarded live to the
	parent process and the returned `stdout`/`stderr` fields are empty strings.

	@param cmd Executable path or name to resolve on PATH.
	@param args Ordered argument list passed to the process.
	@param opts Optional spawn configuration.
	@return Process result containing captured output and exit code.
	@yields
]=]
function os.exec(cmd: string, args: { string }, opts: SpawnOptions?): ExecResult
	return nil :: any
end

--[=[
	Spawn a process, returning an interactive handle to it

	Use stream handles for child process stdio:
	```luau
	local p = os.spawn("cat")
	p.stdin:write("hello\n")
	p.stdin:close()
	local chunk = p.stdout:read(4096)
	```

	@param cmd Executable path or name to resolve on PATH.
	@param args Ordered argument list passed to the process.
	@param opts Optional spawn configuration.
	@return Handle for interacting with the running child process.
]=]
function os.spawn(cmd: string, args: { string }, opts: SpawnOptions?): ProcessHandle
	return nil :: any
end

--[=[
	Run a command as if it was run on the shell.
	This is similar to setting `shell=true` in [[SpawnOptions]], but does not
	attempt to capture input or output from the process.

	`SpawnOptions.shell` is ignored when calling this function.

	:::warning
	This function passes the provided argument directly to `cmd.exe /C`
	:::

	@param cmd Command string to execute through the shell.
	@param opts Optional spawn configuration.
	@return Process exit status code.
	@yields
]=]
function os.shell(cmd: string, opts: SpawnOptions?): number
	return nil :: any
end

return table.freeze(os)
