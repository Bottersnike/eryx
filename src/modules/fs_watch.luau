--[=[
	Filesystem watcher with Signal-based event delivery.

	Watch a single file:
	```luau
	local fsWatch = require("@eryx/fs_watch")

	local watcher = fsWatch.watchFile("config.json")
	watcher.changed:connect(function(eventType)
		print("config.json:", eventType) -- "change" or "rename"
	end)

	-- later:
	watcher:stop()
	```

	Watch a directory (with debounce to coalesce rapid OS events):
	```luau
	local watcher = fsWatch.watchDir("src/", { recursive = true, debounce = 0.1 })
	watcher.changed:connect(function(filename, eventType)
		print(filename, eventType)
	end)

	watcher:stop()
	```
]=]
local Signal = require("@eryx/signal")
local task = require("@eryx/task")
local _fs_watch = require("@eryx/_fs_watch")

type Signal<T...> = Signal.Signal<T...>

local fs_watch = {}

export type WatchOptions = {
	--- Watch subdirectories recursively (supported on Windows and macOS;
	--- on Linux you may need individual watchers per subdirectory).
	recursive: boolean?,
	--- Debounce interval in seconds. When set, rapid-fire OS events for the
	--- same file are coalesced - only the last event fires after the interval
	--- elapses with no new events. Set to `0` or `nil` to disable.
	debounce: number?,
}

export type FileWatcher = {
	--- Fires when the watched file changes.
	--- Receives `(eventType)` where eventType is `"change"` or `"rename"`.
	changed: Signal<string>,
	--- Stops the watcher and disconnects all signal handlers.
	stop: (self: FileWatcher) -> (),
	--- Makes this watcher keep the event loop alive (watchers are unref'd by default).
	ref: (self: FileWatcher) -> (),
	--- Allows the event loop to exit while this watcher is active (the default).
	unref: (self: FileWatcher) -> (),
}

export type DirWatcher = {
	--- Fires when any file in the watched directory changes.
	--- Receives `(filename, eventType)`.  `filename` is the path of the
	--- changed file relative to the watched directory.
	changed: Signal<string, string>,
	--- Stops the watcher and disconnects all signal handlers.
	stop: (self: DirWatcher) -> (),
	--- Makes this watcher keep the event loop alive (watchers are unref'd by default).
	ref: (self: DirWatcher) -> (),
	--- Allows the event loop to exit while this watcher is active (the default).
	unref: (self: DirWatcher) -> (),
}

--- Watches a single file for changes.
--- Returns a `FileWatcher` whose `changed` signal fires with `(eventType)`.
function fs_watch.watchFile(path: string, options: WatchOptions?): FileWatcher
	local changed: Signal<string> = Signal.new()
	local debounce = if options then options.debounce else nil
	local pendingTimer: thread? = nil
	local pendingEvent: string? = nil

	local handle = _fs_watch.create(path, false, function(eventType: string, _filename: string?)
		if debounce and debounce > 0 then
			pendingEvent = eventType
			if pendingTimer then
				task.cancel(pendingTimer)
			end
			pendingTimer = task.delay(debounce, function()
				pendingTimer = nil
				if pendingEvent then
					changed:fire(pendingEvent)
					pendingEvent = nil
				end
			end)
		else
			changed:fire(eventType)
		end
	end)

	local watcher: FileWatcher = {
		changed = changed,
		stop = function(self: FileWatcher)
			if pendingTimer then
				task.cancel(pendingTimer)
				pendingTimer = nil
			end
			handle:stop()
			changed:disconnectAll()
		end,
		ref = function(self: FileWatcher)
			handle:ref()
		end,
		unref = function(self: FileWatcher)
			handle:unref()
		end,
	}
	return watcher
end

--- Watches a directory for changes.
--- Returns a `DirWatcher` whose `changed` signal fires with `(filename, eventType)`.
function fs_watch.watchDir(path: string, options: WatchOptions?): DirWatcher
	local changed: Signal<string, string> = Signal.new()
	local recursive = if options then options.recursive else false
	local debounce = if options then options.debounce else nil

	-- Per-file debounce timers: filename → pending thread
	local pendingTimers: { [string]: thread } = {}
	-- Per-file last event type
	local pendingEvents: { [string]: string } = {}

	local handle = _fs_watch.create(path, recursive or false, function(eventType: string, filename: string?)
		if not filename then
			return
		end

		if debounce and debounce > 0 then
			pendingEvents[filename] = eventType
			local existing = pendingTimers[filename]
			if existing then
				task.cancel(existing)
			end
			pendingTimers[filename] = task.delay(debounce, function()
				pendingTimers[filename] = nil
				local evt = pendingEvents[filename]
				pendingEvents[filename] = nil
				if evt then
					changed:fire(filename, evt)
				end
			end)
		else
			changed:fire(filename, eventType)
		end
	end)

	local watcher: DirWatcher = {
		changed = changed,
		stop = function(self: DirWatcher)
			for _, timer in pendingTimers do
				task.cancel(timer)
			end
			table.clear(pendingTimers)
			table.clear(pendingEvents)
			handle:stop()
			changed:disconnectAll()
		end,
		ref = function(self: DirWatcher)
			handle:ref()
		end,
		unref = function(self: DirWatcher)
			handle:unref()
		end,
	}
	return watcher
end

return table.freeze(fs_watch)
