-- @ignore

local project = require("@eryx/project")

local types = require("./types")

local dependency = {}

local function dependencyWorkspaceName(alias: string, dep: project.Dependency): string
	if type(dep) == "table" and (dep :: any).repo then
		return ((dep :: any).package or alias) :: string
	end

	return alias
end

function dependency.collect(
	root: string,
	path: string,
	manifest: project.Manifest,
	requirements: { types.Requirement },
	visiting: types.Visiting,
	allowLocal: boolean,
	workspace: project.Workspace?
)
	local sources = require("./sources") :: { types.Source }
	local workspaceSource = require("./sources/workspace") :: types.Source

	for key, data in manifest.dependencies or {} do
		local workspaceName = dependencyWorkspaceName(key, data)
		if workspace and workspace[workspaceName] then
			workspaceSource.collect(
				root,
				path,
				manifest,
				key,
				data,
				requirements,
				visiting,
				allowLocal,
				dependency.collect,
				workspace
			)
			continue
		end

		local collected = false
		for _, source in sources do
			if source.checkDependency(data) then
				source.collect(
					root,
					path,
					manifest,
					key,
					data,
					requirements,
					visiting,
					allowLocal,
					dependency.collect,
					workspace
				)
				collected = true
				break
			end
		end
		if collected then
			continue
		end

		error(`Unknown dep type {key}`)
	end
end

return table.freeze(dependency)
