--[=[
	File system operations and file handle I/O.

	Use `open()` / `openSync()` to get a `File` handle with read, write, seek,
	truncate, and other operations. Most `File` methods yield by default; use
	the `Sync` suffix for non-yielding variants (e.g. `readSync`, `writeSync`).

	Pure path manipulation lives under `fs.path.*`.
]=]

export type File = {
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

	--- Reads up to `size` bytes as a string. Pass `nil` to read remaining.
	--- @yields
	read: (self: File, size: number?) -> string,
	--- Reads up to `size` bytes as a string. Pass `nil` to read remaining.
	readSync: (self: File, size: number?) -> string,
	--- Reads up to `size` bytes as a buffer. Pass `nil` to read remaining.
	--- @yields
	readBuffer: (self: File, size: number?) -> buffer,
	--- Reads up to `size` bytes as a buffer. Pass `nil` to read remaining.
	readBufferSync: (self: File, size: number?) -> buffer,

	--- Writes a string to the file, returns bytes written.
	--- @yields
	write: (self: File, data: string) -> number,
	--- Writes a string to the file, returns bytes written.
	writeSync: (self: File, data: string) -> number,
	--- Writes a buffer to the file, returns bytes written.
	--- @yields
	writeBuffer: (self: File, data: buffer) -> number,
	--- Writes a buffer to the file, returns bytes written.
	writeBufferSync: (self: File, data: buffer) -> number,

	--- Moves the file cursor.
	--- @param whence string: `set` is default if unspecified, and treats `offset` as an absolute position. `cur` treats `offset` as relative from the current position. `end` seeks relative to the end of the file.
	--- @return number: The new file offset
	seek: (self: File, offset: number, whence: ("set" | "cur" | "end")?) -> number,
	--- Returns the current file cursor position.
	tell: (self: File) -> number,
	--- Truncates the file to `size` bytes, or at the current position if `nil`.
	truncate: (self: File, size: number?) -> (),
	--- Returns the file size in bytes.
	size: (self: File) -> number,

	--- Flushes buffered writes to disk.
	--- @yields
	flush: (self: File) -> (),
	--- Flushes buffered writes to disk.
	flushSync: (self: File) -> (),
	--- Closes the file. Yield is due to the implicit file flush.
	--- @yields
	close: (self: File) -> (),
	--- Closes the file.
	closeSync: (self: File) -> (),
}

local fs = {}

--- Pure path manipulation (no I/O)
fs.path = table.freeze({
	--- Returns the parent directory of the path (`"a/b/c.txt"` -> `"a/b"`).
	dirname = function(path: string): string return nil :: any end,
	--- Returns the filename component of the path (`"a/b/c.txt"` -> `"c.txt"`).
	basename = function(path: string): string return nil :: any end,
	--- Returns the filename without its extension (`"a/b/c.txt"` -> `"c"`).
	stem = function(path: string): string return nil :: any end,
	--- Returns the file extension including the dot (`"a/b/c.txt"` -> `".txt"`).
	extension = function(path: string): string return nil :: any end,
	--- Resolves a path to an absolute, canonical form.
	canonicalize = function(path: string): string return nil :: any end,
	--- Joins path segments with the platform separator.
	join = function(path: string, ...: string): string return nil :: any end,
})

--- Opens a file and returns a `File` handle.
--- Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.
--- @yields
function fs.open(path: string, mode: string?): File
	return nil :: any
end
--- Opens a file and returns a `File` handle.
--- Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.
function fs.openSync(path: string, mode: string?): File
	return nil :: any
end

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
function fs.stat(path: string, followSymlinks: boolean?): { size: number?, mtime: number?, isFile: boolean?, isDirectory: boolean?, isSymlink: boolean? }
	return nil :: any
end

return table.freeze(fs)
