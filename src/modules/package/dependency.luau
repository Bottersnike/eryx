-- @ignore

local project = require("@eryx/project")

local types = require("./types")

local dependency = {}

function dependency.collect(
	root: string,
	path: string,
	manifest: project.Manifest,
	requirements: { types.Requirement },
	visiting: types.Visiting,
	allowLocal: boolean
)
	local sources = require("./sources") :: { types.Source }

	for key, data in manifest.dependencies or {} do
		local collected = false
		for _, source in sources do
			if source.checkDependency(data) then
				source.collect(root, path, manifest, key, data, requirements, visiting, allowLocal, dependency.collect)
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
