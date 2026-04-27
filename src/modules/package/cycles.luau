local types = require("./types")

local function dependencyKey(kind: types.RequirementKind, path: string): string
	return kind .. "\0" .. path
end

local function requirementKey(requirement: types.Requirement): string
	return dependencyKey(requirement.type, requirement.path)
end

local cycles = {}

function cycles.pushVisiting(requirement: types.Requirement, visiting: types.Visiting, name: string)
	local key = requirementKey(requirement)
	local at = visiting.set[key]

	if at then
		local chain: { string } = {}

		for i = at, #visiting.order do
			table.insert(chain, visiting.order[i].name)
		end

		table.insert(chain, name)

		error(`Cyclic dependency detected ({name})\n{table.concat(chain, " -> ")}`)
	end

	table.insert(visiting.order, {
		key = key,
		name = name,
	})

	visiting.set[key] = #visiting.order

	return key
end

function cycles.popVisiting(key: string, visiting: types.Visiting)
	local last = table.remove(visiting.order)
	visiting.set[key] = nil

	assert(last and last.key == key, "Visiting stack corruption")
end

return table.freeze(cycles)
