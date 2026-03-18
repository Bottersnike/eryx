export type SpawnOptions = {
	--- Specify the directory for the child process
	cwd: string?,
	--- Specify additional environment variables for the child process
	env: { [string]: string }?,
	--[=[
		Run this as a shell command
		:::warning
		    This passes the provided command and arguments directly to `cmd.exe /C`
	]=]
	shell: boolean?,
}

export type ExecResult = {
	stdout: string,
	stderr: string,
	code: number,
}

export type ProcessHandle = {
	--- Process ID
	pid: number,
	--- Process return code, if it's exited
	status: number?,
	--- Wait for the process to complete
	Wait: (self: ProcessHandle) -> ExecResult,
	--[=[
		Kill the process
		@param signal Optional signal to raise in process
	]=]
	Kill: (self: ProcessHandle, signal: number?) -> (),
	--[=[
		Write data to the process' stdin
		@param data Data to write
	]=]
	Write: (self: ProcessHandle, data: string) -> (),
	--- Close the connecting to the process' stdin
	CloseStdin: (self: ProcessHandle) -> (),
	--- Read any data available on stdout
	ReadStdout: (self: ProcessHandle) -> string?,
	--- Read any data available on stderr
	ReadStderr: (self: ProcessHandle) -> string?,
}

export type Platform = "windows" | "macos" | "linux" | nil
export type Arch = "x64" | "arm64" | "arm" | "x86" | nil

local os = {}

--[=[
	Get a specific environment variable
	@param key string Environment variable to get
]=]
function os.getenv(key: string): string?
	return nil :: any
end

--[=[
	Set or unset a specific environment variable
	@param key string Environment variable to set
	@param value string? Value to set, or nil to unset
]=]
function os.setenv(key: string, value: string?) end

--- Get all currently defined environment variables
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

--- Get the current system platform
function os.platform(): Platform
	return nil :: any
end

--- Get the current system arch
function os.arch(): Arch
	return nil :: any
end

--- Get the current system hostname
function os.hostname(): string
	return nil :: any
end

--- Get the current user's temporary directory
function os.tmpdir(): string
	return nil :: any
end

--- Get the current user's home directory
function os.homedir(): string
	return nil :: any
end

--- Get the number of CPUs present
function os.cpucount(): number
	return nil :: any
end

--- Get the total system memory in KiB
function os.totalmem(): number
	return nil :: any
end

--- Get the free system memory in KiB
function os.freemem(): number
	return nil :: any
end

--- Get the system uptime in seconds
function os.uptime(): number
	return nil :: any
end

--- Get the current process PID
function os.pid(): number
	return nil :: any
end

--[=[
	Exit the process with a specific status code
	@param code number? Process exit code
]=]
function os.exit(code: number?) end

--- Get the current time of the system clock
function os.clock(): number
	return nil :: any
end

--- Get the current working directory
function os.cwd(): string
	return nil :: any
end

--[=[
	Change the current working directory
	@param path string New directory
]=]
function os.chdir(path: string) end

--[=[
	Get the command line arguments for this script.

	Returns only the user-supplied arguments; the executable name, subcommand,
	and script path are automatically stripped.

	For example, `eryx run foo.luau --verbose bar` returns `{"--verbose", "bar"}`.
]=]
function os.cliargs(): { string }
	return nil :: any
end

--[=[
	Execute a child process and wait for it to complete.

	This function is equivalent to using:
	```luau
	os.spawn(...):Wait()
	```

	@param cmd string The process to spawn. Can be either a complete path, or a name to be resolve on the PATH
	@param args {string} Arguments to pass to the process
	@param args SpawnOptions? Optional addition configuration
]=]
function os.exec(cmd: string, args: { string }, opts: SpawnOptions?): ExecResult
	return nil :: any
end

--[=[
	Spawn a process, returning an interactive handle to it
	@param cmd string The process to spawn. Can be either a complete path, or a name to be resolve on the PATH
	@param args {string} Arguments to pass to the process
	@param args SpawnOptions? Optional addition configuration
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

	@param cmd string  The command to run
	@param opts SpawnOptions? Optional addition configuration
	@return number The process' status code after completion
]=]
function os.shell(cmd: string, opts: SpawnOptions?): number
	return nil :: any
end

return os
