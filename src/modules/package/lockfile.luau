local toml = require("@eryx/data/toml")
local fs = require("@eryx/fs")

local types = require("./types")

local lockfile = {}

local LOCK_FILENAME = "eryx.lock"

local function lockPath(root: string): string
	return fs.path.join(root, LOCK_FILENAME)
end

function lockfile.exists(root: string): boolean
	return fs.exists(lockPath(root))
end

function lockfile.load(root: string): types.LockFile?
	local path = lockPath(root)
	if not fs.exists(path) then
		return nil
	end

	local f = fs.open(path)
	local source = f:read()
	f:close()

	return toml.decode(source) :: types.LockFile
end

function lockfile.save(root: string, lock: types.LockFile)
	local path = lockPath(root)
	local f = fs.open(path, "w")
	f:write(toml.encode(lock))
	f:close()
end

return table.freeze(lockfile)
