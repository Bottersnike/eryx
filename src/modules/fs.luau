--[=[
	File system operations and file handle I/O.

	Use `open()` / `openSync()` to get a `File` handle with read, write, seek,
	truncate, and other operations. Most `File` methods yield by default; use
	the `Sync` suffix for non-yielding variants (e.g. `readSync`, `writeSync`).

	Pure path manipulation lives under `fs.path.*`.
]=]

local stream = require("@eryx/stream")

export type BaseFile = {
	--- The file path passed to `open`.
	read path: string,
	--- The underlying file descriptor number.
	read fd: number,
	--- `true` if the file has not been closed.
	read isOpen: boolean,
	--- `true` if the file was opened for reading.
	read readable: boolean,
	--- `true` if the file was opened for writing.
	read writable: boolean,

	--- Moves the file cursor.
	--- @param whence string: `set` is default if unspecified, and treats `offset` as an absolute position. `cur` treats `offset` as relative from the current position. `end` seeks relative to the end of the file.
	--- @return number: The new file offset
	seek: (self: BaseFile, offset: number, whence: ("set" | "cur" | "end")?) -> number,
	--- Returns the current file cursor position.
	tell: (self: BaseFile) -> number,
	--- Truncates the file to `size` bytes, or at the current position if `nil`.
	truncate: (self: BaseFile, size: number?) -> (),
	--- Returns the file size in bytes.
	size: (self: BaseFile) -> number,

	--- Flushes buffered writes to disk.
	--- @yields
	flush: (self: BaseFile) -> (),
	--- Flushes buffered writes to disk.
	flushSync: (self: BaseFile) -> (),
	--- Closes the file. Yield is due to the implicit file flush.
	--- @yields
	close: (self: BaseFile) -> (),
	--- Closes the file.
	closeSync: (self: BaseFile) -> (),
}

export type ReadableFile = BaseFile & stream.ReadableStream
export type WritableFile = BaseFile & stream.WritableStream
export type ReadWriteFile = BaseFile & stream.ReadWriteStream

export type File = ReadableFile | WritableFile | ReadWriteFile

type Open =
	((path: string, mode: "r") -> ReadableFile)
	& ((path: string, mode: "w") -> WritableFile)
	& ((path: string, mode: "a") -> WritableFile)
	& ((path: string, mode: "r+") -> ReadWriteFile)
	& ((path: string, mode: "w+") -> ReadWriteFile)
	& ((path: string, mode: "a+") -> ReadWriteFile)
	& ((path: string, mode: string?) -> File)

type OpenSync =
	((path: string, mode: "r") -> ReadableFile)
	& ((path: string, mode: "w") -> WritableFile)
	& ((path: string, mode: "a") -> WritableFile)
	& ((path: string, mode: "r+") -> ReadWriteFile)
	& ((path: string, mode: "w+") -> ReadWriteFile)
	& ((path: string, mode: "a+") -> ReadWriteFile)
	& ((path: string, mode: string?) -> File)

local fs = {}

--- Pure path manipulation (no I/O)
fs.path = table.freeze({
	--- Returns the parent directory of the path (`"a/b/c.txt"` -> `"a/b"`).
	dirname = function(path: string): string
		return nil :: any
	end,
	--- Returns the filename component of the path (`"a/b/c.txt"` -> `"c.txt"`).
	basename = function(path: string): string
		return nil :: any
	end,
	--- Returns the filename without its extension (`"a/b/c.txt"` -> `"c"`).
	stem = function(path: string): string
		return nil :: any
	end,
	--- Returns the file extension including the dot (`"a/b/c.txt"` -> `".txt"`).
	extension = function(path: string): string
		return nil :: any
	end,
	--- Resolves a path to an absolute, canonical form.
	canonicalize = function(path: string): string
		return nil :: any
	end,
	--- Joins path segments with the platform separator.
	join = function(path: string, ...: string): string
		return nil :: any
	end,
})

--- Opens a file and returns a `File` handle.
--- Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.
--- @yields
fs.open = function(path: string, mode: string?): File
	return nil :: any
end :: Open

--- Opens a file and returns a `File` handle.
--- Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.
fs.openSync = function(path: string, mode: string?): File
	return nil :: any
end :: OpenSync

--- Returns `true` if the path exists on disk.
function fs.exists(path: string): boolean
	return nil :: any
end
--- Returns `true` if the path is a regular file.
function fs.isFile(path: string): boolean
	return nil :: any
end
--- Returns `true` if the path is a directory.
function fs.isDirectory(path: string): boolean
	return nil :: any
end
--- Creates a directory (and any missing parents). Returns `true` on success.
function fs.mkdir(path: string): boolean
	return nil :: any
end
--- Recursively removes a file or directory. Returns `true` on success.
function fs.remove(path: string): boolean
	return nil :: any
end
--- Atomically renames (moves) a file or directory.
function fs.rename(oldPath: string, newPath: string): ()
	return nil :: any
end
--- Copies a file or directory (recursively). Overwrites existing destinations.
function fs.copy(src: string, dst: string): ()
	return nil :: any
end
--- Returns an array of filenames in the given directory.
function fs.listDir(path: string): { string }
	return nil :: any
end
--- Creates a symlink at `link` pointing to `target`.
--- `type`: `"file"` (default) or `"directory"`. Auto-detected from target if omitted.
--- On Windows, creating symlinks requires Developer Mode or administrator privileges.
function fs.symlink(target: string, link: string, type: ("file" | "directory")?): ()
	return nil :: any
end
--- Reads the target of a symlink.
function fs.readlink(path: string): string
	return nil :: any
end
--- Returns `true` if the path is a symbolic link (does not follow the link).
function fs.isSymlink(path: string): boolean
	return nil :: any
end
--- Returns file metadata. Set `followSymlinks` to `false` to inspect the link itself.
--- The result always includes `isSymlink` regardless of `followSymlinks`.
function fs.stat(
	path: string,
	followSymlinks: boolean?
): { size: number?, mtime: number?, isFile: boolean?, isDirectory: boolean?, isSymlink: boolean? }
	return nil :: any
end

return table.freeze(fs)
