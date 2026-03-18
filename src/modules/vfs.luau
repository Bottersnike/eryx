local vfs = {}

export type BuildOptions = {
	--- Path to the output executable.
	outputExe: string,
	--- Project root directory. All file paths in the bundle are relative to this.
	root: string,
	--- Entrypoint script path (relative to root).
	entrypoint: string,
	--- Array of file or directory paths to include in the bundle.
	--- Directories are expanded recursively.
	files: { string },
	--- Source executable to clone. Defaults to the currently running executable.
	sourceExe: string?,
}

--- Returns `true` if a VFS bundle is currently loaded.
function vfs.isOpen(): boolean
	return nil :: any
end
--- Returns the entrypoint path of the loaded bundle, or `nil` if no bundle is open.
function vfs.entrypoint(): string?
	return nil :: any
end
--- Reads the entire contents of a VFS file as a string.
--- Errors if no bundle is open or the file doesn't exist.
function vfs.readFile(path: string): string
	return nil :: any
end
--- Returns `true` if the given path exists in the VFS bundle.
--- Returns `false` if no bundle is open.
function vfs.exists(path: string): boolean
	return nil :: any
end
--- Returns an array of direct children (files and directories) in the given VFS directory.
--- Returns an empty table if no bundle is open.
function vfs.listDir(dir: string): { string }
	return nil :: any
end
--- Returns `true` if the given path is a file in the VFS bundle.
--- Returns `false` if no bundle is open or the path is a directory / doesn't exist.
function vfs.isFile(path: string): boolean
	return nil :: any
end
--- Returns `true` if the given path is a directory in the VFS bundle.
--- A path is a directory if any file exists under it.
--- Returns `false` if no bundle is open.
function vfs.isDir(path: string): boolean
	return nil :: any
end
--- Returns the modification time of a VFS file (as stored at bundle time).
--- Errors if no bundle is open or the file doesn't exist.
function vfs.mtime(path: string): number
	return nil :: any
end
--- Builds a new VFS bundle by cloning an executable and appending a file archive.
function vfs.build(options: BuildOptions): boolean
	return nil :: any
end
--- Returns `true` if VFS isolation is enabled (the default).
--- When isolated, VFS scripts cannot fall through to the real filesystem
--- for requires or config resolution.
function vfs.isIsolated(): boolean
	return nil :: any
end
--- Sets VFS isolation mode. When disabled, VFS scripts can fall through
--- to the real filesystem (relative to the exe directory) for requires
--- and config resolution.
function vfs.setIsolated(isolated: boolean)
end

return vfs
