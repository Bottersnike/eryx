-- @ignore

local util = require("./util")
local types = require("./types")

local layout = {}

local function applySourceRoot(basePath: string, sourceRoot: string?): string
	if sourceRoot == nil or sourceRoot == "" or sourceRoot == "." then
		return basePath
	end

	local normalizedBase = basePath:gsub("\\", "/"):gsub("/+$", "")
	local normalizedRoot = sourceRoot:gsub("\\", "/")

	while normalizedRoot:sub(1, 2) == "./" do
		normalizedRoot = normalizedRoot:sub(3)
	end

	normalizedRoot = normalizedRoot:gsub("^/+", ""):gsub("/+$", "")
	if normalizedRoot == "" or normalizedRoot == "." then
		return normalizedBase
	end

	return normalizedBase .. "/" .. normalizedRoot
end

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
		return applySourceRoot(r.path, r.sourceRoot)
	end

	local targetName = installNames[edge.target]
	if not targetName then
		error(`Internal error: missing install name for {edge.target}`)
	end

	if root then
		return applySourceRoot(util.PACKAGES_DIR .. "/" .. targetName, r.sourceRoot)
	else
		return applySourceRoot("../" .. targetName, r.sourceRoot)
	end
end

function layout.computeAliases(
	plan: types.InstallPlan,
	edges: { types.InstallEdge },
	installNames: { [string]: string },
	root: boolean
): types.AliasMap
	local aliases: types.AliasMap = {}

	for _, edge in edges do
		local targetPath = aliasPathForEdge(plan, edge, installNames, root)
		aliases[edge.alias] = targetPath
	end

	return aliases
end

function layout.resolveInstallNames(plan: types.InstallPlan): { [string]: string }
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

return table.freeze(layout)
