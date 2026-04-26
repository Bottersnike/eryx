--[=[
	Temporary files and directories.

	`open()` returns a file-like object with an explicit `:close()` method.
	`openDir()` returns a directory handle with `path` and `:close()`.

	:::warning
	Temporary resources are explicit-lifecycle. You must call `:close()`
	on returned handles to ensure cleanup.
	Unlike some runtimes, this module does not rely on GC finalizers.
]=]

--[=[
	Represents an opened temporary file.

	The object forwards file operations (e.g. `readSync`, `writeSync`, `seek`)
	to the underlying `fs.File` handle and adds lifecycle helpers that remove
	the file from disk.
]=]
local fs = require("@eryx/fs")
local os = require("@eryx/os")

local tempfile = {}

local CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local nonce = 0

export type TempFile = {
	--- Absolute path to the temp file.
	read path: string,
	--- Closes the file handle (if open) and deletes the file path.
	close: (self: TempFile) -> (),

	--- The underlying open file
	read file: fs.File,
}
type TempFileInternal = { __state: TempState }

--[=[
	Represents a temporary directory handle.

	Use `path` for filesystem operations and call `:close()` to
	remove it recursively.
]=]
export type TempDir = {
	--- Absolute path to the temp directory.
	read path: string,
	--- Removes the directory recursively.
	close: (self: TempDir) -> (),
}

type TempState = {
	path: string,
	closed: boolean,
	file: fs.File?,
}

local function randomChar(): string
	local i = math.random(1, #CHARS)
	return string.sub(CHARS, i, i)
end

local function randomSuffix(length: number): string
	local out = table.create(length)
	for i = 1, length do
		out[i] = randomChar()
	end
	return table.concat(out)
end

local function sanitizeName(name: string): string
	local trimmed = string.match(name, "^%s*(.-)%s*$") or ""
	local sanitized = string.gsub(trimmed, "[\\/:]", "_")
	sanitized = string.gsub(sanitized, "%c", "_")
	return sanitized
end

local function makeStem(name: string?, defaultStem: string): string
	if name == nil or name == "" then
		return defaultStem .. "-XXXXXX"
	end

	local stem = sanitizeName(name)
	if stem == "" then
		return defaultStem .. "-XXXXXX"
	end

	if string.find(stem, "X", 1, true) then
		return stem
	end

	return stem .. "-XXXXXX"
end

local function fillTemplate(stem: string): string
	if string.find(stem, "X", 1, true) then
		return (string.gsub(stem, "X", function()
			return randomChar()
		end))
	end

	return stem .. "-" .. randomSuffix(6)
end

local function makeCandidatePath(stem: string): string
	nonce += 1
	local rendered = fillTemplate(stem)
	local suffix = string.format("%x%x%x", os.pid(), math.floor(os.clock() * 1e9), nonce)
	return fs.path.join(os.tmpdir(), rendered .. "-" .. suffix)
end

local function cleanup(state: TempState)
	if state.closed then
		return
	end
	state.closed = true

	if state.file ~= nil and state.file.isOpen then
		pcall(function()
			state.file:closeSync()
		end)
	end

	if fs.exists(state.path) then
		local ok = fs.remove(state.path)
		if not ok or fs.exists(state.path) then
			error(`tempfile: failed to remove temporary path: {state.path}`)
		end
	end
end

local TempFile = {}
TempFile.__index = function(self: TempFile, key): any
	local self_ = (self :: any) :: TempFileInternal

	if key == "path" then
		return self_.__state.path
	end
	if key == "file" then
		return self_.__state.file
	end

	local own = TempFile[key]
	if own ~= nil then
		return own
	end

	local file = self_.__state.file
	if file == nil then
		return nil
	end

	local value = (file :: any)[key]
	if type(value) == "function" then
		return function(_, ...: any)
			return (value :: any)(file, ...)
		end
	end
	return value
end

function TempFile.close(self: TempFile)
	cleanup(((self :: any) :: TempFileInternal).__state)
end

local TempDir = {}
TempDir.__index = TempDir

function TempDir.close(self: TempDir)
	cleanup(((self :: any) :: TempFileInternal).__state)
end

local function createTempFile(name: string?, mode: string?): TempFile
	local stem = makeStem(name, "tmp")
	local openMode = mode or "w+"

	for _ = 1, 512 do
		local path = makeCandidatePath(stem)
		if fs.exists(path) then
			continue
		end

		local file = fs.openSync(path, openMode)
		local state: TempState = {
			path = path,
			file = file,
			closed = false,
		}
		return setmetatable({
			__state = state,
		}, TempFile) :: any
	end

	error("tempfile.open: failed to allocate a unique temp file name after 512 attempts")
end

local function createTempDir(name: string?): TempDir
	local stem = makeStem(name, "tmpdir")

	for _ = 1, 512 do
		local path = makeCandidatePath(stem)
		if fs.exists(path) then
			continue
		end

		if fs.mkdir(path) then
			local state: TempState = {
				path = path,
				file = nil,
				closed = false,
			}
			return setmetatable({
				path = path,
				__state = state,
			}, TempDir) :: any
		end
	end

	error("tempfile.openDir: failed to allocate a unique temp directory name after 512 attempts")
end

--[=[
	Returns the process temporary directory.

	@return string Absolute path to the OS temp directory.
]=]
function tempfile.tempdir(): string
	return os.tmpdir()
end

--[=[
	Creates a unique temp file, then immediately closes and deletes it.

	This is useful when you only need a collision-resistant path string.

	@param name string? Optional name/template prefix. If it includes `X`
	               characters, each `X` is replaced with random alphanumeric
	               characters.
	@return string A unique temp file path that does not exist on return.
]=]
function tempfile.mktemp(name: string?): string
	local temp = createTempFile(name, "w+")
	local path = temp.path
	temp:close()
	return path
end

--[=[
	Creates and opens a unique temp file.

	The returned handle behaves like `fs.File` and also supports `:close()`
	to close and delete the file path.

	@param name string? Optional name/template prefix. If it includes `X`
	               characters, each `X` is replaced with random alphanumeric
	               characters.
	@param mode string? File mode (`"r"`, `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`).
	                   Defaults to `"w+"`.
	@return TempFile Open temp file handle with explicit cleanup methods.
]=]
function tempfile.open(name: string?, mode: string?): TempFile
	return createTempFile(name, mode)
end

--[=[
	Creates a unique temporary directory.

	@param name string? Optional name/template prefix. If it includes `X`
	               characters, each `X` is replaced with random alphanumeric
	               characters.
	@return TempDir Directory handle with `path` and explicit cleanup methods.
]=]
function tempfile.openDir(name: string?): TempDir
	return createTempDir(name)
end

--[=[
	Creates a temp file, calls `fn(file)`, and always cleans it up.

	`file:close()` is guaranteed after callback completion, including error
	paths. Any callback error is rethrown.

	@param fn (file: TempFile) -> T Callback that uses the temp file handle.
	@param options { name: string?, mode: string? }? Optional creation options.
	@return T The callback return value.
]=]
function tempfile.withTempFile<T>(fn: (file: TempFile) -> ...T, options: { name: string?, mode: string? }?): ...T
	local opts = options or ({} :: { name: string?, mode: string? })
	local file = createTempFile(opts.name, opts.mode)
	local result = table.pack(pcall(fn, file))
	file:close()
	if not result[1] then
		error(result[2], 2)
	end
	return table.unpack(result, 2, result.n)
end

--[=[
	Creates a temp directory, calls `fn(path)`, and always removes it.

	Directory cleanup is guaranteed after callback completion, including error
	paths. Any callback error is rethrown.

	@param fn (path: string) -> T Callback that receives the temp directory path.
	@param name string? Optional name/template prefix.
	@return T The callback return value.
]=]
function tempfile.withTempDir<T>(fn: (path: string) -> ...T, name: string?): ...T
	local dir = createTempDir(name)
	local result = table.pack(pcall(fn, dir.path))
	dir:close()
	if not result[1] then
		error(result[2], 2)
	end
	return table.unpack(result, 2, result.n)
end

return table.freeze(tempfile)
