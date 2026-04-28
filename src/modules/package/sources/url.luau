--!nolint LocalShadow
-- @ignore

local project = require("@eryx/project")
local cycles = require("../cycles")
local types = require("../types")

local function getDependenciesFromUrl(url: string, sha256: string?): project.Dependencies?
	error("TODO: fetch URL dependency, verify sha256 if present, and read eryx.toml")
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
		recurse: types.CollectRecursion
	)
		local dep = dep :: project.UrlDependency

		local url = dep.url
		local sha256 = (dep :: any).sha256

		local r: types.Requirement = {
			type = "file",
			name = name,
			path = url,
			sha256 = sha256,
			tree = {},
		}

		-- TODO: This needs to be "get manifest!"
		local deps = getDependenciesFromUrl(url, sha256)
		if deps then
			local visitingKey = cycles.pushVisiting(r, visiting, name)
			recurse(root, path, deps, r.tree, visiting, false)
			cycles.popVisiting(visitingKey, visiting)
		end

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		if requirement.type ~= "file" then
			error("Internal error: expected file requirement")
		end

		error(`TODO: download/extract file dependency {requirement.path} into {dest}`)
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
		}
	end,
}

return table.freeze(urlSource)
