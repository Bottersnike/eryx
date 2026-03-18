local fs = {}

--- Reads the entire contents of a file as a binary string.
function fs.readFile(path: string): string
	return nil :: any
end
--- Writes a string to a file, replacing any existing content.
function fs.writeFile(path: string, content: string): ()
	return nil :: any
end
--- Appends a string to the end of a file.
function fs.appendFile(path: string, content: string): ()
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
--- Returns an array of filenames in the given directory.
function fs.listDir(path: string): { string }
	return nil :: any
end
--- Returns the parent directory of the path (`"a/b/c.txt"` → `"a/b"`).
function fs.dirname(path: string): string
	return nil :: any
end
--- Returns the filename component of the path (`"a/b/c.txt"` → `"c.txt"`).
function fs.basename(path: string): string
	return nil :: any
end
--- Returns the filename without its extension (`"a/b/c.txt"` → `"c"`).
function fs.stem(path: string): string
	return nil :: any
end
--- Returns the file extension including the dot (`"a/b/c.txt"` → `".txt"`).
function fs.extension(path: string): string
	return nil :: any
end
--- Resolves a path to an absolute, canonical form. Errors if the path doesn't exist.
function fs.canonicalize(path: string): string
	return nil :: any
end
--- Joins path segments with the platform separator.
function fs.join(path: string, ...: string): string
	return nil :: any
end
--- Returns file metadata (size, mtime, isFile, isDirectory) as a table.
function fs.stat(path: string): { size: number?, mtime: number?, isFile: boolean?, isDirectory: boolean? }
	return nil :: any
end

return fs
