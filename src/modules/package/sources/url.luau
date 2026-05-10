--!nolint LocalShadow
-- @ignore

local zip = require("@eryx/compression/zip")
local hash = require("@eryx/crypto/hazmat/hash")
local hex = require("@eryx/encoding/hex")
local fs = require("@eryx/fs")
local http = require("@eryx/http")
local project = require("@eryx/project")
local cycles = require("../cycles")
local types = require("../types")

local function digest(algorithm: string, data: buffer): buffer
	local ctx = hash.new(algorithm)
	ctx:update(data)
	return ctx:final()
end

local function fetchArchive(url: string, sha256: string?): buffer
	local res = http.get(url)
	if res.status ~= 200 then
		error(`Failed to download URL dependency {url}`)
	end

	local archive = buffer.fromstring(res.body)

	if sha256 then
		local actual = hex.encode(digest("sha256", archive))
		if actual ~= string.lower(sha256) then
			error(`Downloaded file for {url} did not match expected sha256`)
		end
	end

	if not zip.isZip(archive) then
		error(`URL dependency {url} is not a valid zip archive`)
	end

	return archive
end

local function archiveRoot(entries: { zip.EntryInfo }): string?
	local root: string? = nil

	for _, entry in entries do
		local name = entry.name
		if name == "" then
			continue
		end

		local slash = name:find("/", 1, true)
		if not slash then
			return nil
		end

		local segment = name:sub(1, slash)
		if root == nil then
			root = segment
		elseif root ~= segment then
			return nil
		end
	end

	return root
end

local function manifestFromArchive(archive: buffer): project.Manifest?
	local entries = zip.list(archive)
	local root = archiveRoot(entries)

	local manifestPath = if root then root .. "eryx.toml" else "eryx.toml"
	local manifestData = zip.read(archive, manifestPath)
	if not manifestData then
		return nil
	end

	return project.parse(buffer.tostring(manifestData)).manifest
end

local function getManifestFromUrl(url: string, sha256: string?): project.Manifest?
	local archive = fetchArchive(url, sha256)
	return manifestFromArchive(archive)
end

local function ensureDirRecursive(path: string)
	if path == "" or fs.exists(path) then
		return
	end

	local parent = fs.path.dirname(path)
	if parent and parent ~= path and parent ~= "" then
		ensureDirRecursive(parent)
	end

	if not fs.exists(path) then
		fs.mkdir(path)
	end
end

local function extractArchiveTo(archive: buffer, dest: string)
	local entries = zip.list(archive)
	local root = archiveRoot(entries)

	for path, data in zip.unpack(archive) do
		local relative = path
		if root and relative:sub(1, #root) == root then
			relative = relative:sub(#root + 1)
		end

		if relative == "" then
			continue
		end

		local fullyQualified = fs.path.join(dest, relative)
		local parent = fs.path.dirname(fullyQualified)
		if parent then
			ensureDirRecursive(parent)
		end

		local f = fs.open(fullyQualified, "w")
		f:write(data)
		f:close()
	end
end

local urlSource: types.Source = {
	type = "file",

	checkDependency = function(dep)
		if (dep :: any)["url"] then
			return true
		end
		return false
	end,

	collect = function(
		root: string,
		path: string,
		manifest: project.Manifest,
		name: string,
		dep: project.Dependency,
		requirements: { types.Requirement },
		visiting: types.Visiting,
		allowLocal: boolean,
		recurse: types.CollectRecursion,
		workspace: project.Workspace?
	)
		local dep = dep :: project.UrlDependency

		local url = dep.url
		local sha256 = (dep :: any).sha256

		local r: types.Requirement = {
			type = "file",
			name = name,
			path = url,
			sha256 = sha256,
			sourceRoot = nil,
			tree = {},
		}

		local childManifest = getManifestFromUrl(url, sha256)
		if childManifest and childManifest.dependencies then
			r.sourceRoot = childManifest.project.sourceRoot
			local visitingKey = cycles.pushVisiting(r, visiting, name)
			recurse(root, path, childManifest, r.tree, visiting, false, workspace)
			cycles.popVisiting(visitingKey, visiting)
		elseif childManifest then
			r.sourceRoot = childManifest.project.sourceRoot
		end

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		if requirement.type ~= "file" then
			error("Internal error: expected file requirement")
		end

		local archive = fetchArchive(requirement.path, requirement.sha256)
		extractArchiveTo(archive, dest)
	end,

	identity = function(requirement: types.Requirement): string
		assert(requirement.type == "file")
		return "file:" .. requirement.path .. "#" .. (requirement.sha256 or "unverified")
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		assert(requirement.type == "file")
		return {
			url = requirement.path,
			sha256 = requirement.sha256,
			sourceRoot = requirement.sourceRoot,
		}
	end,

	readLock = function(_root: string, package: types.LockPackage): types.Requirement
		return {
			type = "file",
			name = "",
			path = package.data.url,
			sha256 = package.data.sha256,
			sourceRoot = package.data.sourceRoot,
			tree = {},
		}
	end,
}

return table.freeze(urlSource)
