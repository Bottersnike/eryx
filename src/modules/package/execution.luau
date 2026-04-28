-- @ignore

local json = require("@eryx/data/json")
local fs = require("@eryx/fs")

local util = require("./util")
local types = require("./types")
local sources = require("./sources")
local execution = {}

local function aliasPathForEdge(
	plan: types.InstallPlan,
	edge: types.InstallEdge,
	installNames: { [string]: string },
	root: boolean
): string
	local node = plan.nodes[edge.target]
	if not node then
		error(`Internal error: missing install node for {edge.target}`)
	end

	local r = node.requirement

	if r.type == "path" then
		return r.path
	end

	local targetName = installNames[edge.target]
	if not targetName then
		error(`Internal error: missing install name for {edge.target}`)
	end

	if root then
		return util.PACKAGES_DIR .. "/" .. targetName
	else
		return "../" .. targetName
	end
end

local function computeAliases(
	plan: types.InstallPlan,
	edges: { types.InstallEdge },
	installNames: { [string]: string },
	root: boolean
): { [string]: string }
	local aliases: { [string]: string } = {}
	for i, edge in edges do
		local targetPath = aliasPathForEdge(plan, edge, installNames, root)
		aliases[edge.alias] = targetPath
	end

	return aliases
end

local function resolveInstallNames(plan: types.InstallPlan): { [string]: string }
	local used: { [string]: string } = {}
	local names: { [string]: string } = {}

	for id, node in plan.nodes do
		local base = node.installName
		local name = base
		local n = 2

		while used[name] and used[name] ~= id do
			name = base .. "-" .. tostring(n)
			n += 1
		end

		used[name] = id
		names[id] = name
	end

	return names
end

local function ensureEmptyDir(path: string)
	if fs.exists(path) then
		fs.remove(path)
	end

	fs.mkdir(path)
end

local function installAliases(path: string, aliases: { [string]: string }): ()
	if fs.exists(fs.path.join(path, ".config.luau")) then
		error(".config.luau is not supported")
	end

	local rcPath = fs.path.join(path, ".luaurc")

	local config = {}
	if fs.exists(rcPath) then
		local f = fs.open(rcPath)
		-- TODO: Luaurc is technically a bit jank, not JSON
		config = json.decode(f:read())
		f:close()
	end

	-- TODO: Use a lock file to identify which aliases we own
	-- For now, we own all of them
	config.aliases = aliases

	local f = fs.open(rcPath, "w")
	f:write(json.encode(config, { pretty = true }))
	f:close()
end

local function materializeNode(
	plan: types.InstallPlan,
	root: string,
	node: types.InstallNode,
	installNames: { [string]: string }
)
	local r = node.requirement
	local installName = installNames[node.id]
	local packagesDir = util.ensurePackagesDir(root)
	local dest = fs.path.join(packagesDir, installName)

	if r.type == "path" then
		-- Path deps are not copied. They point at an existing folder.
		-- Do not mutate them by writing .luaurc.
		return
	end

	ensureEmptyDir(dest)

	local materialised = false
	for _, source in sources do
		if source.type == r.type then
			source.materialise(root, r, dest)
			materialised = true
			break
		end
	end
	if not materialised then
		error(`Cannot materialize dependency type {r.type}`)
	end

	local aliases = computeAliases(plan, node.dependencies, installNames, false)
	installAliases(dest, aliases)
end

function execution.execute(root: string, plan: types.InstallPlan)
	util.ensurePackagesDir(root)
	local installNames = resolveInstallNames(plan)

	for _, node in plan.nodes do
		materializeNode(plan, root, node, installNames)
	end

	local aliases = computeAliases(plan, plan.roots, installNames, true)
	installAliases(root, aliases)
end

return table.freeze(execution)
