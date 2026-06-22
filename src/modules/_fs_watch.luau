local _fs_watch = {}
local path = require("@eryx/path")

type PathLike = path.PathLike

export type WatchEventKind = "create" | "remove" | "modify" | "rename" | "overflow" | "unknown"

export type WatchEvent = {
	kind: WatchEventKind,
	path: string,
	oldPath: string?,
	filename: string?,
	oldFilename: string?,
	relativePath: string?,
	oldRelativePath: string?,
	isDirectory: boolean?,
	rawKind: string?,
}

export type WatchHandle = setmetatable<
	{},
	{
		__index: {
			--- Stops the filesystem watcher and releases its resources.
			stop: (self: WatchHandle) -> (),
			--- Makes this handle keep the event loop alive (it is unref'd by default).
			ref: (self: WatchHandle) -> (),
			--- Allows the event loop to exit even while this handle is active (the default).
			unref: (self: WatchHandle) -> (),
		},
	}
>

--- Creates a low-level filesystem watcher.
--- The callback is invoked with a normalized event table each time the watched
--- path changes. Set `recursive` to `true` to watch subdirectories.
function _fs_watch.create(path: PathLike, recursive: boolean, callback: (event: WatchEvent) -> ()): WatchHandle
	return nil :: any
end

return table.freeze(_fs_watch)
