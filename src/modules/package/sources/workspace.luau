--!nolint LocalShadow
-- @ignore

local cycles = require("../cycles")
local fs = require("@eryx/fs")
local pathmod = require("@eryx/path")
local project = require("@eryx/project")

local types = require("../types")

local workspaceSource: types.Source = {
	type = "workspace",

	checkDependency = function(_dep)
		return false
	end,

	collect = function(
		root: string,
		_path: string,
		manifest: project.Manifest,
		name: string,
		dep: project.Dependency,
		requirements: { types.Requirement },
		visiting: types.Visiting,
		allowLocal: boolean,
		recurse: types.CollectRecursion,
		workspace: project.Workspace?
	)
		if workspace == nil then
			error(`Internal error: missing workspace overrides while resolving {name}`)
		end

		local packageName = if type(dep) == "table" and (dep :: any).repo
			then ((dep :: any).package or name) :: string
			else name
		local configuredPath = workspace[packageName]
		if configuredPath == nil then
			error(`Internal error: missing workspace override for {packageName}`)
		end

		local resolvedPath = configuredPath
		if not pathmod.new(resolvedPath):isAbsolute() then
			resolvedPath = fs.path.join(root, resolvedPath)
		end
		if not fs.isDirectory(resolvedPath) then
			error(`Workspace package "{packageName}" points to missing directory {configuredPath}`)
		end
		resolvedPath = fs.path.canonicalize(resolvedPath)

		local manifestPath = fs.path.join(resolvedPath, "eryx.toml")
		if not fs.isFile(manifestPath) then
			error(`Workspace package "{packageName}" does not contain eryx.toml at {configuredPath}`)
		end

		local childPrj = project.load(manifestPath)
		if childPrj.manifest.project.name ~= packageName then
			error(
				`Workspace package "{packageName}" expected project name "{packageName}", found "{childPrj.manifest.project.name}"`
			)
		end

		local r: types.Requirement = {
			type = "workspace",
			name = name,
			path = resolvedPath,
			sourceRoot = childPrj.manifest.project.sourceRoot,
			tree = {},
		}

		local visitingKey = cycles.pushVisiting(r, visiting, name)
		recurse(root, resolvedPath, childPrj.manifest, r.tree, visiting, false, workspace)
		cycles.popVisiting(visitingKey, visiting)

		table.insert(requirements, r)
	end,

	materialise = function(_root: string, _requirement: types.Requirement, _dest: string)
		error("Attempted to materialise workspace package")
	end,

	identity = function(requirement: types.Requirement): string
		assert(requirement.type == "workspace")
		return "workspace:" .. requirement.path
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		assert(requirement.type == "workspace")
		return {
			path = requirement.path,
			sourceRoot = requirement.sourceRoot,
		}
	end,

	readLock = function(_root: string, package: types.LockPackage): types.Requirement
		return {
			type = "workspace",
			name = "",
			path = package.data.path,
			sourceRoot = package.data.sourceRoot,
			tree = {},
		}
	end,
}

return table.freeze(workspaceSource)
