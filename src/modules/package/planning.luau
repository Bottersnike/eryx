local util = require("./util")
local types = require("./types")

local planning = {}

local function requirementIdentity(r: types.Requirement): string
	local sources = require("./sources") :: { types.Source }

	for _, source in sources do
		if source.type == r.type then
			return source.identity(r)
		end
	end
	error("Unknown requirement type")
end

function planning.addRequirementNode(ctx: types.ResolveContext, r: types.Requirement): types.InstallNode
	local id = requirementIdentity(r)
	local existing = ctx.plan.nodes[id]

	if existing then
		return existing
	end

	local copy = table.clone(r)
	copy.tree = {}

	local node: types.InstallNode = {
		id = id,
		installName = util.installNameFor(r, id),
		requirement = copy,
		dependencies = {},
	}

	ctx.plan.nodes[id] = node

	return node
end

function planning.addEdge(edges: { types.InstallEdge }, alias: string, target: string)
	for _, edge in edges do
		if edge.alias == alias then
			if edge.target ~= target then
				error(`Alias "{alias}" points to multiple packages`)
			end

			return
		end
	end

	table.insert(edges, {
		alias = alias,
		target = target,
	})
end

return table.freeze(planning)
