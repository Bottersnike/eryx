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
	--- @param whence Seek origin: `set` (default), `cur`, or `end`.
	--- @return The new file offset.
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

--[=[
	Union of all file-handle variants returned by `fs.open`/`fs.openSync`.
]=]
export type File = ReadableFile | WritableFile | ReadWriteFile

--[=[
	Permission token used by [[hasPermission]] and ACL entry `rights`.
]=]
export type PermissionToken = "read" | "write" | "execute" | "delete" | "readAcl" | "writeAcl" | "writeOwner"

--[=[
	ACL inheritance scope.
]=]
export type AclAppliesTo = "this" | "children" | "this_and_children"

--[=[
	Single ACL entry.
	Windows-focused in this release.
]=]
export type AclEntry = {
	--- Entry type.
	type: "allow" | "deny",
	--- Principal identifier (SID on Windows).
	principal: string,
	--- Rights granted/denied by this entry.
	rights: { PermissionToken },
	--- Whether this rule participates in inheritance.
	inherits: boolean?,
	--- Whether this entry was inherited from a parent ACL.
	inherited: boolean?,
	--- Scope this entry applies to.
	appliesTo: AclAppliesTo?,
}

--[=[
	Optional overrides for [[hasPermission]] checks.
]=]
export type PermissionCheckOptions = {
	--- Principal id override (uid/gid on POSIX, SID on Windows when supported).
	principal: number | string?,
	--- Supplemental group ids/identifiers for permission evaluation.
	groups: { number | string }?,
	--- Whether symlinks should be followed while evaluating access.
	followSymlinks: boolean?,
}

--[=[
	Metadata returned by [[stat]].
]=]
export type FileStat = {
	--- File size in bytes when available.
	size: number?,
	--- Last modification time as Unix timestamp seconds.
	mtime: number?,
	--- `true` when the path is a regular file.
	isFile: boolean?,
	--- `true` when the path is a directory.
	isDirectory: boolean?,
	--- `true` when the path itself is a symlink.
	isSymlink: boolean?,
	--- `true` when readonly is enabled/effective.
	readonly: boolean?,
}

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

--[=[
	Pure path manipulation helpers (no I/O).
]=]
fs.path = table.freeze({
	--- Returns the parent directory of the path (`"a/b/c.txt"` -> `"a/b"`).
	--- @param path Input path.
	--- @return Parent directory path.
	dirname = function(path: string): string
		return nil :: any
	end,
	--- Returns the filename component of the path (`"a/b/c.txt"` -> `"c.txt"`).
	--- @param path Input path.
	--- @return Basename component.
	basename = function(path: string): string
		return nil :: any
	end,
	--- Returns the filename without its extension (`"a/b/c.txt"` -> `"c"`).
	--- @param path Input path.
	--- @return Stem component.
	stem = function(path: string): string
		return nil :: any
	end,
	--- Returns the file extension including the dot (`"a/b/c.txt"` -> `".txt"`).
	--- @param path Input path.
	--- @return Extension including leading dot, or empty string.
	extension = function(path: string): string
		return nil :: any
	end,
	--- Resolves a path to an absolute, canonical form.
	--- @param path Input path.
	--- @return Canonical absolute path.
	canonicalize = function(path: string): string
		return nil :: any
	end,
	--- Joins path segments with the platform separator.
	--- @param path First path segment.
	--- @param ... Additional path segments.
	--- @return Joined path.
	join = function(path: string, ...: string): string
		return nil :: any
	end,
})

--[=[
	Opens a file and returns a `File` handle.
	Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.

	@param path File path to open.
	@param mode File mode string.
	@return Open file handle.
	@yields
]=]
fs.open = function(path: string, mode: string?): File
	return nil :: any
end :: Open

--[=[
	Opens a file synchronously and returns a `File` handle.
	Mode: `"r"` (default), `"w"`, `"a"`, `"r+"`, `"w+"`, `"a+"`.

	@param path File path to open.
	@param mode File mode string.
	@return Open file handle.
]=]
fs.openSync = function(path: string, mode: string?): File
	return nil :: any
end :: OpenSync

--- @param path Path to check.
--- @return `true` when the path exists.
function fs.exists(path: string): boolean
	return nil :: any
end
--- @param path Path to check.
--- @return `true` when the path is a regular file.
function fs.isFile(path: string): boolean
	return nil :: any
end
--- @param path Path to check.
--- @return `true` when the path is a directory.
function fs.isDirectory(path: string): boolean
	return nil :: any
end
--- @param path Directory path to create.
--- @return `true` when directory creation succeeds.
function fs.mkdir(path: string): boolean
	return nil :: any
end
--- @param path File or directory path to remove recursively.
--- @return `true` when removal succeeds.
function fs.remove(path: string): boolean
	return nil :: any
end
--- @param oldPath Existing path.
--- @param newPath Destination path.
--- @return Nothing.
function fs.rename(oldPath: string, newPath: string): ()
	return nil :: any
end
--- @param src Source path.
--- @param dst Destination path.
--- @return Nothing.
function fs.copy(src: string, dst: string): ()
	return nil :: any
end
--- @param path Directory path.
--- @return Entry names from the directory.
function fs.listDir(path: string): { string }
	return nil :: any
end
--[=[
	Creates a symlink at `link` pointing to `target`.
	`type`: `"file"` (default) or `"directory"`. Auto-detected from target if omitted.
	On Windows, creating symlinks requires Developer Mode or administrator privileges.

	@param target Symlink target path.
	@param link Symlink path to create.
	@param type Optional symlink type hint.
	@return Nothing.
]=]
function fs.symlink(target: string, link: string, type: ("file" | "directory")?): ()
	return nil :: any
end
--- @param path Symlink path.
--- @return Symlink target path.
function fs.readlink(path: string): string
	return nil :: any
end
--- @param path Path to inspect.
--- @return `true` when the path itself is a symbolic link.
function fs.isSymlink(path: string): boolean
	return nil :: any
end
--[=[
	Returns file metadata.
	Set `followSymlinks` to `false` to inspect the link itself.
	The result always includes `isSymlink` regardless of `followSymlinks`.

	@param path Path to inspect.
	@param followSymlinks Whether symlinks should be followed. Defaults to `true`.
	@return Metadata for the path, or an empty-like table when missing.
]=]
function fs.stat(path: string, followSymlinks: boolean?): FileStat
	return nil :: any
end

--[=[
	Checks whether a principal has a specific permission on a path.
	If `options` is omitted, checks the current effective principal.

	@param path Target path.
	@param permission Permission to test.
	@param options Optional principal/group override.
	@return `true` when permission is granted.
]=]
function fs.hasPermission(path: string, permission: PermissionToken, options: PermissionCheckOptions?): boolean
	return nil :: any
end

--[=[
	Changes POSIX mode bits.

	:::warning
	POSIX only. On Windows, use [[setReadonly]] and [[setAcl]].
	:::

	@param path Target path.
	@param mode POSIX mode bits (for example `0o644`).
	@return Nothing.
]=]
function fs.chmod(path: string, mode: number): ()
	return nil :: any
end

--[=[
	Changes owner (`uid` on POSIX, SID string on Windows).
	@param path Target path.
	@param owner Owner uid (POSIX) or SID string (Windows).
	@return Nothing.
]=]
function fs.chown(path: string, owner: number | string): ()
	return nil :: any
end

--[=[
	Changes group (`gid` on POSIX).

	:::warning
	POSIX only.
	:::

	@param path Target path.
	@param group Group id.
	@return Nothing.
]=]
function fs.chgrp(path: string, group: number): ()
	return nil :: any
end

--[=[
	Gets whether the path has the readonly attribute/effective readonly state.
	@param path Target path.
	@return `true` when readonly is enabled.
]=]
function fs.getReadonly(path: string): boolean
	return nil :: any
end

--[=[
	Sets whether the path is readonly.
	@param path Target path.
	@param value Desired readonly state.
	@return Nothing.
]=]
function fs.setReadonly(path: string, value: boolean): ()
	return nil :: any
end

--[=[
	Gets whether the path has the hidden attribute.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@return `true` when hidden is enabled.
]=]
function fs.getHidden(path: string): boolean
	return nil :: any
end

--[=[
	Sets whether the path has the hidden attribute.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@param value Desired hidden state.
	@return Nothing.
]=]
function fs.setHidden(path: string, value: boolean): ()
	return nil :: any
end

--[=[
	Gets whether the path has the system attribute.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@return `true` when the system attribute is enabled.
]=]
function fs.getSystem(path: string): boolean
	return nil :: any
end

--[=[
	Sets whether the path has the system attribute.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@param value Desired system-attribute state.
	@return Nothing.
]=]
function fs.setSystem(path: string, value: boolean): ()
	return nil :: any
end

--[=[
	Reads ACL entries for a path.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@return Ordered ACL entries.
]=]
function fs.getAcl(path: string): { AclEntry }
	return nil :: any
end

--[=[
	Writes ACL entries for a path.

	:::warning
	This API is only available in Windows environments.
	:::

	@param path Target path.
	@param entries ACL entries applied in order.
	@return Nothing.
]=]
function fs.setAcl(path: string, entries: { AclEntry }): ()
	return nil :: any
end

return table.freeze(fs)
