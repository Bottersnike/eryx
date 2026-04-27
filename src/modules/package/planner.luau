local types = require("./types")
local planning = require("./planning")
local sources = require("./sources")

local planner = {}

local resolveRequirementIntoPlan

local function resolveConcreteRequirementChildren(
	ctx: types.ResolveContext,
	node: types.InstallNode,
	children: { types.Requirement }
)
	if ctx.resolving[node.id] then
		error(`Cyclic dependency detected while resolving {node.id}`)
	end

	ctx.resolving[node.id] = true

	for _, child in children do
		resolveRequirementIntoPlan(ctx, node, child)
	end

	ctx.resolving[node.id] = nil
end

function resolveRequirementIntoPlan(ctx: types.ResolveContext, parent: types.InstallNode?, r: types.Requirement)
	for _, source in sources do
		if r.type == source.type and source.resolveInstallPlan then
			source.resolveInstallPlan(ctx, parent, r, resolveConcreteRequirementChildren)
			return
		end
	end

	local node = planning.addRequirementNode(ctx, r)

	if parent then
		planning.addEdge(parent.dependencies, r.name, node.id)
	else
		planning.addEdge(ctx.plan.roots, r.name, node.id)
	end

	resolveConcreteRequirementChildren(ctx, node, r.tree)
end

function planner.produceInstallPlan(tree: { types.Requirement }): types.InstallPlan
	local ctx: types.ResolveContext = {
		plan = {
			nodes = {},
			roots = {},
		},
		repositorySelections = {},
		resolving = {},
	}

	for _, r in tree do
		resolveRequirementIntoPlan(ctx, nil, r)
	end

	return ctx.plan
end

function planner.generateLockFile(plan: types.InstallPlan)
	local packages = {}

	for id, node in plan.nodes do
		local r = node.requirement

		local entry = {
			id = id,
			installName = node.installName,
			type = r.type,
			dependencies = {},
		}

		for _, dep in node.dependencies do
			table.insert(entry.dependencies, {
				alias = dep.alias,
				target = dep.target,
			})
		end

		local generated = false
		for _, source in sources do
			if r.type == source.type then
				local data = source.generateLock(r)
				for k, v in data do
					entry[k] = v
				end
				generated = true
				break
			end
		end
		if not generated then
			error(`Failed to generate lock for {r.type}`)
		end

		packages[id] = entry
	end

	local roots = {}

	for _, edge in plan.roots do
		table.insert(roots, {
			alias = edge.alias,
			target = edge.target,
		})
	end

	return {
		packages = packages,
		roots = roots,
	}
end

return table.freeze(planner)
