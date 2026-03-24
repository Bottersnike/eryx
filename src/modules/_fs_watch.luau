local _fs_watch = {}

export type WatchHandle = {
	--- Stops the filesystem watcher and releases its resources.
	stop: (self: WatchHandle) -> (),
	--- Makes this handle keep the event loop alive (it is unref'd by default).
	ref: (self: WatchHandle) -> (),
	--- Allows the event loop to exit even while this handle is active (the default).
	unref: (self: WatchHandle) -> (),
}

--- Creates a low-level filesystem watcher.
--- The callback is invoked with (eventType, filename?) each time the watched
--- path changes.  `eventType` is `"change"` or `"rename"`.
--- `filename` is the name of the changed file (may be nil on some platforms).
--- Set `recursive` to `true` to watch subdirectories (supported on Windows
--- and macOS; on Linux each subdirectory needs its own watcher).
function _fs_watch.create(
	path: string,
	recursive: boolean,
	callback: (eventType: string, filename: string?) -> ()
): WatchHandle
	return nil :: any
end

return table.freeze(_fs_watch)
