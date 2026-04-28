-- @ignore

local types = require("./types")
local layout = require("./layout")
local planning = require("./planning")
local sources = require("./sources")
local util = require("./util")

local planner = {}

local resolveRequirementIntoPlan

local function pathReaches(
	plan: types.InstallPlan,
	startId: string,
	targetId: string,
	seen: { [string]: boolean }
): boolean
	if startId == targetId then
		return true
	end

	if seen[startId] then
		return false
	end
	seen[startId] = true

	local node = plan.nodes[startId]
	if not node then
		return false
	end

	for _, edge in node.dependencies do
		if pathReaches(plan, edge.target, targetId, seen) then
			return true
		end
	end

	return false
end

local function addPlanEdge(ctx: types.ResolveContext, parent: types.InstallNode?, alias: string, targetId: string)
	if parent then
		if pathReaches(ctx.plan, targetId, parent.id, {}) then
			error(`Cyclic dependency detected while resolving {alias}`)
		end

		planning.addEdge(parent.dependencies, alias, targetId)
	else
		planning.addEdge(ctx.plan.roots, alias, targetId)
	end
end

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

	addPlanEdge(ctx, parent, r.name, node.id)

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

function planner.generateLockFile(plan: types.InstallPlan): types.LockFile
	local installNames = layout.resolveInstallNames(plan)
	local packages = {}

	for id, node in plan.nodes do
		local r = node.requirement

		local entry: types.LockPackage = {
			id = id,
			installName = if r.type == "path" then nil else installNames[id],
			type = r.type,
			dependencies = {},
			aliases = layout.computeAliases(plan, node.dependencies, installNames, false),
			data = {},
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
					entry.data[k] = v
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
		version = 1,
		packages = packages,
		roots = roots,
		rootAliases = layout.computeAliases(plan, plan.roots, installNames, true),
	}
end

local function copyEdges(edges: { types.InstallEdge }): { types.InstallEdge }
	local out = {}
	for _, edge in edges do
		table.insert(out, {
			alias = edge.alias,
			target = edge.target,
		})
	end
	return out
end

local function requirementFromLock(root: string, pkg: types.LockPackage): types.Requirement
	for _, source in sources do
		if source.type == pkg.type and source.readLock then
			return source.readLock(root, pkg)
		end
	end

	error(`Failed to read locked package of type {pkg.type}`)
end

function planner.readRequirementFromLock(root: string, pkg: types.LockPackage): types.Requirement
	return requirementFromLock(root, pkg)
end

function planner.buildRequirementTreeFromLock(
	root: string,
	lock: types.LockFile,
	target: string,
	alias: string,
	visiting: { [string]: boolean }?
): types.Requirement
	local pkg = lock.packages[target]
	if not pkg then
		error(`Lock file references missing package {target}`)
	end

	local active = visiting or {}
	if active[target] then
		error(`Cyclic dependency detected in lock while rebuilding {target}`)
	end

	active[target] = true

	local requirement = requirementFromLock(root, pkg)
	requirement = table.clone(requirement)
	requirement.name = alias
	requirement.tree = {}

	for _, edge in pkg.dependencies do
		table.insert(
			requirement.tree,
			planner.buildRequirementTreeFromLock(root, lock, edge.target, edge.alias, active)
		)
	end

	active[target] = nil

	return requirement
end

function planner.produceInstallPlanFromLock(root: string, lock: types.LockFile): types.InstallPlan
	if lock.version ~= 1 then
		error(`Unsupported lock file version {lock.version}`)
	end

	local plan: types.InstallPlan = {
		nodes = {},
		roots = copyEdges(lock.roots),
	}

	for id, pkg in lock.packages do
		local requirement = requirementFromLock(root, pkg)
		local installName = pkg.installName or util.installNameFor(requirement, id)

		plan.nodes[id] = {
			id = id,
			installName = installName,
			requirement = requirement,
			dependencies = copyEdges(pkg.dependencies),
		}
	end

	for _, edge in plan.roots do
		if not plan.nodes[edge.target] then
			error(`Lock file references missing package {edge.target}`)
		end
	end

	for _, node in plan.nodes do
		for _, edge in node.dependencies do
			if not plan.nodes[edge.target] then
				error(`Lock file references missing package {edge.target}`)
			end
		end
	end

	return plan
end

return table.freeze(planner)
