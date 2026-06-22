local _fs_watch = require("@eryx/_fs_watch")
local fsWatch = require("@eryx/fs_watch")
local fs = require("@eryx/fs")
local task = require("@eryx/task")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("fs_watch")

local TIMEOUT = 3

local function writeFile(path: string, contents: string)
	local handle = fs.openSync(path, "w")
	handle:writeSync(contents)
	handle:closeSync()
end

local function waitUntil(predicate: () -> boolean, timeout: number?): boolean
	local elapsed = 0
	local limit = timeout or TIMEOUT
	while elapsed < limit do
		if predicate() then
			return true
		end
		elapsed += task.wait(0.025)
	end
	return predicate()
end

local function contains(list: { string }, value: string): boolean
	for _, item in list do
		if item == value then
			return true
		end
	end
	return false
end

local function eventKindSeen(events: { _fs_watch.WatchEvent }, kind: _fs_watch.WatchEventKind): boolean
	for _, event in events do
		if event.kind == kind then
			return true
		end
	end
	return false
end

suite:test("low-level watcher emits normalized event tables", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "config.txt")
		writeFile(filePath, "before")

		local events: { _fs_watch.WatchEvent } = {}
		local handle = _fs_watch.create(filePath, false, function(event)
			table.insert(events, event)
		end)

		task.wait(0.1)
		writeFile(filePath, "after")

		local seen = waitUntil(function()
			return #events > 0
		end)
		handle:stop()

		test.expect(seen):toBeTrue()
		local event = events[1]
		test.expect(type(event)):toBe("table")
		test.expect(type(event.kind)):toBe("string")
		test.expect(type(event.path)):toBe("string")
	end)
end)

suite:test("low-level directory events include relative path and directory flag", function()
	tempfile.withTempDir(function(dir)
		local events: { _fs_watch.WatchEvent } = {}
		local handle = _fs_watch.create(dir, false, function(event)
			table.insert(events, event)
		end)

		task.wait(0.1)
		fs.mkdir(fs.path.join(dir, "child"))

		local seen = waitUntil(function()
			for _, event in events do
				if event.relativePath == "child" and event.isDirectory == true then
					return true
				end
			end
			return false
		end)
		handle:stop()

		test.expect(seen):toBeTrue()
	end)
end)

suite:test("low-level rename events include old path fields when reported", function()
	tempfile.withTempDir(function(dir)
		local before = fs.path.join(dir, "before.txt")
		local after = fs.path.join(dir, "after.txt")
		writeFile(before, "hello")

		local events: { _fs_watch.WatchEvent } = {}
		local handle = _fs_watch.create(dir, false, function(event)
			table.insert(events, event)
		end)

		task.wait(0.1)
		fs.rename(before, after)

		local sawAnyRenameRelatedEvent = waitUntil(function()
			return eventKindSeen(events, "rename") or eventKindSeen(events, "create") or eventKindSeen(events, "remove")
		end)
		handle:stop()

		test.expect(sawAnyRenameRelatedEvent):toBeTrue()

		local renameEvent: _fs_watch.WatchEvent? = nil
		for _, event in events do
			if event.kind == "rename" then
				renameEvent = event
				break
			end
		end

		if not renameEvent then
			test.skip("backend reported rename as create/remove")
		end
		local rename = renameEvent :: _fs_watch.WatchEvent

		test.expect(rename.oldPath):toNotBeNil()
		test.expect(rename.oldFilename):toBe("before.txt")
		test.expect(rename.oldRelativePath):toBe("before.txt")
		test.expect(rename.relativePath):toBe("after.txt")
	end)
end)

suite:test("watchFile fires when a watched file is modified", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "watched.txt")
		writeFile(filePath, "before")

		local kinds: { string } = {}
		local watcher = fsWatch.watchFile(filePath)
		watcher.changed:connect(function(kind)
			table.insert(kinds, kind)
		end)

		task.wait(0.1)
		writeFile(filePath, "after")

		local seen = waitUntil(function()
			return contains(kinds, "modify")
		end)
		watcher:stop()

		test.expect(seen):toBeTrue()
	end)
end)

suite:test("watchFile can watch a file before it exists", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "future.txt")

		local kinds: { string } = {}
		local watcher = fsWatch.watchFile(filePath)
		watcher.changed:connect(function(kind)
			table.insert(kinds, kind)
		end)

		task.wait(0.1)
		writeFile(filePath, "created")

		local seen = waitUntil(function()
			return #kinds > 0
		end)
		watcher:stop()

		test.expect(seen):toBeTrue()
	end)
end)

suite:test("watchFile reports removal of the watched file", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "removed.txt")
		writeFile(filePath, "before")

		local kinds: { string } = {}
		local watcher = fsWatch.watchFile(filePath)
		watcher.changed:connect(function(kind)
			table.insert(kinds, kind)
		end)

		task.wait(0.1)
		fs.remove(filePath)

		local seen = waitUntil(function()
			return contains(kinds, "remove")
		end)
		watcher:stop()

		test.expect(seen):toBeTrue()
	end)
end)

suite:test("watchDir reports created files by relative name", function()
	tempfile.withTempDir(function(dir)
		local seen: { [string]: string } = {}
		local watcher = fsWatch.watchDir(dir)
		watcher.changed:connect(function(filename, kind)
			seen[filename] = kind
		end)

		task.wait(0.1)
		writeFile(fs.path.join(dir, "created.txt"), "hello")

		local created = waitUntil(function()
			return seen["created.txt"] ~= nil
		end)
		watcher:stop()

		test.expect(created):toBeTrue()
		test.expect(type(seen["created.txt"])):toBe("string")
	end)
end)

suite:test("watchDir reports removed files", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "removed.txt")
		writeFile(filePath, "before")

		local seen: { [string]: string } = {}
		local watcher = fsWatch.watchDir(dir)
		watcher.changed:connect(function(filename, kind)
			seen[filename] = kind
		end)

		task.wait(0.1)
		fs.remove(filePath)

		local removed = waitUntil(function()
			return seen["removed.txt"] == "remove"
		end)
		watcher:stop()

		test.expect(removed):toBeTrue()
	end)
end)

suite:test("watchDir reports rename or equivalent move events", function()
	tempfile.withTempDir(function(dir)
		local before = fs.path.join(dir, "before.txt")
		local after = fs.path.join(dir, "after.txt")
		writeFile(before, "hello")

		local seen: { [string]: string } = {}
		local watcher = fsWatch.watchDir(dir)
		watcher.changed:connect(function(filename, kind)
			seen[filename] = kind
		end)

		task.wait(0.1)
		fs.rename(before, after)

		local moved = waitUntil(function()
			return seen["after.txt"] == "rename" or seen["after.txt"] == "create" or seen["before.txt"] == "remove"
		end)
		watcher:stop()

		test.expect(moved):toBeTrue()
	end)
end)

suite:test("watchDir recursive reports nested file paths", function()
	tempfile.withTempDir(function(dir)
		local childDir = fs.path.join(dir, "child")
		fs.mkdir(childDir)

		local seen: { [string]: string } = {}
		local watcher = fsWatch.watchDir(dir, { recursive = true })
		watcher.changed:connect(function(filename, kind)
			seen[filename] = kind
		end)

		task.wait(0.1)
		writeFile(fs.path.join(childDir, "nested.txt"), "hello")

		local nested = waitUntil(function()
			return seen["child/nested.txt"] ~= nil or seen["child\\nested.txt"] ~= nil
		end)
		watcher:stop()

		test.expect(nested):toBeTrue()
	end)
end)

suite:test("watchDir recursive detects newly-created subdirectories", function()
	tempfile.withTempDir(function(dir)
		local childDir = fs.path.join(dir, "child")

		local seen: { [string]: string } = {}
		local watcher = fsWatch.watchDir(dir, { recursive = true })
		watcher.changed:connect(function(filename, kind)
			seen[filename] = kind
		end)

		task.wait(0.1)
		fs.mkdir(childDir)
		task.wait(0.1)
		writeFile(fs.path.join(childDir, "new.txt"), "hello")

		local nested = waitUntil(function()
			return seen["child/new.txt"] ~= nil or seen["child\\new.txt"] ~= nil
		end)
		watcher:stop()

		test.expect(nested):toBeTrue()
	end)
end)

suite:test("debounce coalesces rapid file events", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "debounced.txt")
		writeFile(filePath, "before")

		local count = 0
		local watcher = fsWatch.watchFile(filePath, { debounce = 0.25 })
		watcher.changed:connect(function()
			count += 1
		end)

		task.wait(0.1)
		writeFile(filePath, "one")
		writeFile(filePath, "two")

		local fired = waitUntil(function()
			return count > 0
		end, 1)
		task.wait(0.35)
		watcher:stop()

		test.expect(fired):toBeTrue()
		test.expect(count):toBe(1)
	end)
end)

suite:test("debounce coalesces directory events per filename", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "debounced.txt")

		local seen: { [string]: number } = {}
		local watcher = fsWatch.watchDir(dir, { debounce = 0.25 })
		watcher.changed:connect(function(filename)
			seen[filename] = (seen[filename] or 0) + 1
		end)

		task.wait(0.1)
		writeFile(filePath, "one")
		writeFile(filePath, "two")

		local fired = waitUntil(function()
			return (seen["debounced.txt"] or 0) > 0
		end, 1)
		task.wait(0.35)
		watcher:stop()

		test.expect(fired):toBeTrue()
		test.expect(seen["debounced.txt"]):toBe(1)
	end)
end)

suite:test("ref and unref are callable on active watchers", function()
	tempfile.withTempDir(function(dir)
		local watcher = fsWatch.watchDir(dir)

		test.expect(function()
			watcher:ref()
			watcher:unref()
			watcher:ref()
			watcher:stop()
		end):toNotError()
	end)
end)

suite:test("low-level create rejects paths with missing parent directories", function()
	tempfile.withTempDir(function(dir)
		local missing = fs.path.join(dir, "missing", "file.txt")

		test.expect(function()
			_fs_watch.create(missing, false, function() end)
		end):toError("Failed to watch")
	end)
end)

suite:test("low-level create failure is repeatable after caught errors", function()
	tempfile.withTempDir(function(dir)
		local missing = fs.path.join(dir, "missing", "file.txt")

		for _ = 1, 20 do
			local ok = pcall(function()
				_fs_watch.create(missing, false, function() end)
			end)
			test.expect(ok):toBeFalse()
		end
	end)
end)

suite:test("stop disconnects public watcher callbacks", function()
	tempfile.withTempDir(function(dir)
		local filePath = fs.path.join(dir, "stop.txt")
		writeFile(filePath, "before")

		local count = 0
		local watcher = fsWatch.watchFile(filePath)
		watcher.changed:connect(function()
			count += 1
		end)

		task.wait(0.1)
		watcher:stop()
		writeFile(filePath, "after")
		task.wait(0.2)

		test.expect(count):toBe(0)
	end)
end)

return suite
