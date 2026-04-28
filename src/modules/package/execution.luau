-- @ignore

local json = require("@eryx/data/json")
local fs = require("@eryx/fs")

local layout = require("./layout")
local util = require("./util")
local types = require("./types")
local sources = require("./sources")
local execution = {}

local function combineEdges(a: { types.InstallEdge }, b: { types.InstallEdge }): { types.InstallEdge }
	local out = {}
	for _, edge in a do
		table.insert(out, edge)
	end
	for _, edge in b do
		table.insert(out, edge)
	end
	return out
end

local function combineAliasMaps(a: types.AliasMap?, b: types.AliasMap?): types.AliasMap?
	if a == nil and b == nil then
		return nil
	end

	local out: types.AliasMap = {}
	for alias, target in a or {} do
		out[alias] = target
	end
	for alias, target in b or {} do
		out[alias] = target
	end
	return out
end

local function needsMaterialization(plan: types.InstallPlan): boolean
	for _, node in plan.nodes do
		if node.requirement.type ~= "path" then
			return true
		end
	end

	return false
end

local function ensureEmptyDir(path: string)
	if fs.exists(path) then
		fs.remove(path)
	end

	fs.mkdir(path)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function warnAboutClobbers(path: string, existingAliases: types.AliasMap, aliases: types.AliasMap)
	local clobbers = {}

	for _, alias in sortedKeys(aliases) do
		local existing = existingAliases[alias]
		local nextValue = aliases[alias]
		if existing and existing ~= nextValue then
			table.insert(clobbers, {
				alias = alias,
				before = existing,
				after = nextValue,
			})
		end
	end

	if #clobbers == 0 then
		return
	end

	print("Warning: no eryx.lock found; alias ownership cannot be verified.")
	print(`Eryx will claim the following aliases in {path}:`)
	print("")

	for _, clobber in clobbers do
		print(`  {clobber.alias}: "{clobber.before}" -> "{clobber.after}"`)
	end

	print("")
	print("These aliases will be treated as Eryx-owned after this install.")
end

local function installAliases(
	path: string,
	aliases: types.AliasMap,
	previousOwnedAliases: types.AliasMap?,
	warnIfNoLock: boolean
): ()
	if fs.exists(fs.path.join(path, ".config.luau")) then
		error(".config.luau is not supported")
	end

	local rcPath = fs.path.join(path, ".luaurc")

	local config = {}
	if fs.exists(rcPath) then
		local f = fs.open(rcPath)
		config = json.decode(f:read(), json.JSONC)
		f:close()
	end

	local existingAliases = (config.aliases or {}) :: types.AliasMap
	local finalAliases: types.AliasMap = table.clone(existingAliases)
	local previousOwned = previousOwnedAliases or {}

	if previousOwnedAliases == nil and warnIfNoLock then
		warnAboutClobbers(path, existingAliases, aliases)
	end

	for alias in previousOwned do
		if aliases[alias] == nil then
			finalAliases[alias] = nil
		end
	end

	for alias, target in aliases do
		finalAliases[alias] = target
	end

	config.aliases = finalAliases

	local f = fs.open(rcPath, "w")
	f:write(json.encode(config, { pretty = true }))
	f:close()
end

local function activeGitCacheEntries(plan: types.InstallPlan): { [string]: boolean }
	local active = {}

	for _, node in plan.nodes do
		local r = node.requirement
		if r.type == "git" then
			active[fs.path.basename(r.gitFolder)] = true
		end
	end

	return active
end

local function cleanupGitCache(packagesDir: string, activeCaches: { [string]: boolean }): boolean
	local gitCacheDir = fs.path.join(packagesDir, ".git-cache")
	if not fs.exists(gitCacheDir) then
		return false
	end

	for _, entry in fs.listDir(gitCacheDir) do
		if not activeCaches[entry] then
			fs.remove(fs.path.join(gitCacheDir, entry))
		end
	end

	if #fs.listDir(gitCacheDir) == 0 then
		fs.remove(gitCacheDir)
		return false
	end

	return true
end

local function cleanupPackagesDir(
	root: string,
	activeInstallNames: { [string]: boolean },
	activeCaches: { [string]: boolean }
)
	local packagesDir = fs.path.join(root, util.PACKAGES_DIR)
	if not fs.exists(packagesDir) then
		return
	end

	local hasGitCache = cleanupGitCache(packagesDir, activeCaches)

	for _, entry in fs.listDir(packagesDir) do
		if entry ~= ".git-cache" and not activeInstallNames[entry] then
			fs.remove(fs.path.join(packagesDir, entry))
		end
	end

	if not hasGitCache and #fs.listDir(packagesDir) == 0 then
		fs.remove(packagesDir)
	end
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

	local aliases = layout.computeAliases(plan, node.dependencies, installNames, false)
	installAliases(dest, aliases, nil, false)
end

function execution.execute(root: string, plan: types.InstallPlan, previousLock: types.LockFile?)
	local installNames = layout.resolveInstallNames(plan)
	local installDirs: { [string]: boolean } = {}

	if needsMaterialization(plan) then
		util.ensurePackagesDir(root)
	end

	for _, node in plan.nodes do
		materializeNode(plan, root, node, installNames)
		if node.requirement.type ~= "path" then
			local installName = installNames[node.id]
			if installName then
				installDirs[installName] = true
			end
		end
	end

	local rootEdges = combineEdges(plan.roots, plan.devRoots)
	local aliases = layout.computeAliases(plan, rootEdges, installNames, true)
	local previousRootAliases = if previousLock
		then combineAliasMaps(previousLock.rootAliases, previousLock.devRootAliases)
		else nil
	installAliases(root, aliases, previousRootAliases, previousLock == nil)

	cleanupPackagesDir(root, installDirs, activeGitCacheEntries(plan))
end

return table.freeze(execution)
