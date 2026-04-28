-- @ignore

local fs = require("@eryx/fs")
local regex = require("@eryx/regex")
local semver = require("@eryx/semver")

local types = require("./types")

local util = {}

util.PACKAGES_DIR = "eryx_packages"

function util.ensureDir(dir: string): (string, boolean)
	if not fs.exists(dir) then
		fs.mkdir(dir)
		return dir, true
	end

	if fs.isDirectory(dir) then
		return dir, false
	end

	error(`{dir} already exists, but is not a directory`)
end

function util.ensurePackagesDir(root: string): (string, boolean)
	return util.ensureDir(fs.path.join(root, util.PACKAGES_DIR))
end

function util.ensurePackagesSubDir(root: string, subDir: string): (string, boolean)
	local parent, created1 = util.ensurePackagesDir(root)
	local path, created2 = util.ensureDir(fs.path.join(parent, subDir))

	return path, created1 or created2
end

function util.identityToDirName(identity: string): string
	identity = regex.replace([[[\s<>:"/\\|?*\x00-\x1F]+|-+]], identity, "-")
	identity = regex.replace([[\.+]], identity, ".")
	identity = regex.replace([[^[\s._-]+|[\s._-]+$]], identity, "")

	if identity == "" then
		identity = "repo"
	end

	local upper = string.upper(identity)
	local reserved = {
		CON = true,
		PRN = true,
		AUX = true,
		NUL = true,
		COM1 = true,
		COM2 = true,
		COM3 = true,
		COM4 = true,
		COM5 = true,
		COM6 = true,
		COM7 = true,
		COM8 = true,
		COM9 = true,
		LPT1 = true,
		LPT2 = true,
		LPT3 = true,
		LPT4 = true,
		LPT5 = true,
		LPT6 = true,
		LPT7 = true,
		LPT8 = true,
		LPT9 = true,
	}

	if reserved[upper] then
		identity = "_" .. identity
	end

	return identity
end

local function requirementDisplayName(r: types.Requirement): string
	if r.type == "local" or r.type == "path" then
		return r.path
	elseif r.type == "git" then
		return util.identityToDirName(r.path)
	elseif r.type == "file" then
		return util.identityToDirName(r.path)
	elseif r.type == "repository" then
		assert(r.version, "Repository requirement has not been resolved")
		return r.key .. "-" .. semver.format(r.version)
	else
		error("Unknown requirement type")
	end
end

local function stableShortHash(s: string): string
	local hash = 2166136261

	for i = 1, #s do
		hash = bit32.bxor(hash, string.byte(s, i))
		hash = (hash * 16777619) % 4294967296
	end

	return string.format("%08x", hash)
end

function util.installNameFor(r: types.Requirement, id: string): string
	local base = util.identityToDirName(requirementDisplayName(r))
	local hash = stableShortHash(id):sub(1, 8)

	return base .. "-" .. hash
end

return table.freeze(util)
