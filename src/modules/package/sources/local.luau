--!nolint LocalShadow
-- @ignore

local cycles = require("../cycles")
local fs = require("@eryx/fs")
local os = require("@eryx/os")
local project = require("@eryx/project")

local types = require("../types")

local repo: types.Source = {
	type = "local",

	checkDependency = function(dep)
		if (dep :: any)["local"] then
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
		local dep = dep :: project.LocalDependency

		if not allowLocal then
			error(`Dependency "{name}" is local, but local dependencies are not allowed here`)
		end

		if not fs.exists(dep["local"]) then
			error(`{name} references {dep["local"]} which does not exist`)
		end

		local r: types.Requirement = {
			type = "local",
			name = name,
			path = dep["local"],
			tree = {},
		}

		local visitingKey = cycles.pushVisiting(r, visiting, name)

		local childPrj = project.loadNearest(dep["local"])
		if childPrj then
			recurse(root, dep["local"], childPrj.manifest, r.tree, visiting, allowLocal)
		end

		cycles.popVisiting(visitingKey, visiting)

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		local from = requirement.path

		-- TODO: Replace with a proper built-in copy (fs.copy)
		if os.platform() == "windows" then
			local res = os.exec("robocopy", { from, dest, "/E" })
			if res.code > 7 then
				error(`Failed to copy {from} to {dest}\n{res.stderr}`)
			end
		else
			local res = os.exec("cp", { "-a", from .. "/.", dest })
			if res.code ~= 0 then
				error(`Failed to copy {from} to {dest}\n{res.stderr}`)
			end
		end
	end,

	identity = function(requirement: types.Requirement): string
		return "local:" .. requirement.path
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		return {
			path = requirement.path,
		}
	end,
}

return table.freeze(repo)
