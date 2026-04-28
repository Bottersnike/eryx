--!nolint LocalShadow
-- @ignore

local project = require("@eryx/project")

local types = require("../types")

local repo: types.Source = {
	type = "path",

	checkDependency = function(dep)
		if (dep :: any)["path"] then
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
		local dep = dep :: project.PathDependency

		local r: types.Requirement = {
			type = "path",
			name = name,
			path = dep["path"],
			tree = {},
		}

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		error("Attempted to materialise path alias")
	end,

	identity = function(requirement: types.Requirement): string
		return "path:" .. requirement.path
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		return {
			path = requirement.path,
		}
	end,

	readLock = function(_root: string, package: types.LockPackage): types.Requirement
		return {
			type = "path",
			name = "",
			path = package.data.path,
			tree = {},
		}
	end,
}

return table.freeze(repo)
