local fs = require("@eryx/fs")
local path = require("@eryx/path")
local project = require("@eryx/project")
local semver = require("@eryx/semver")

local lockfile = require("@self/lockfile")
local planner = require("@self/planner")
local types = require("@self/types")
local dependency = require("@self/dependency")
local execution = require("@self/execution")

local pkg = {}

type TopLevelGroups = {
	regular: project.Dependencies,
	dev: project.Dependencies,
}

local function isHexString(s: string): boolean
	return s:match("^[0-9a-fA-F]+$") ~= nil
end

local function normalizeGitSubdir(subdir: string?): string?
	if subdir == nil then
		return nil
	end

	local normalized = subdir:gsub("\\", "/")

	while normalized:sub(1, 2) == "./" do
		normalized = normalized:sub(3)
	end

	normalized = normalized:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
	if normalized == "" or normalized == "." then
		return nil
	end

	return normalized
end

local function resolveWorkspacePath(root: string, configuredPath: string): string
	local resolved = configuredPath
	if not path.new(resolved):isAbsolute() then
		resolved = fs.path.join(root, resolved)
	end

	if fs.exists(resolved) then
		return fs.path.canonicalize(resolved)
	end

	return resolved
end

local function effectiveWorkspace(manifest: project.Manifest, workspaceOverride: project.Workspace?): project.Workspace?
	if workspaceOverride ~= nil then
		return workspaceOverride
	end

	return manifest.workspace
end

local function resolveRepositoryName(manifest: project.Manifest, dep: project.RepositoryDependency): string
	if dep.repo:find("://") then
		return dep.repo
	end

	if not manifest.repositories then
		error("eryx.toml does not specify repositories")
	end
	local repository = manifest.repositories[dep.repo]
	if not repository then
		error(`Attempted to use unspecified repository: {dep.repo}`)
	end
	return repository
end

local function dependencyMatchesLock(
	root: string,
	alias: string,
	dep: project.Dependency,
	locked: types.LockPackage,
	manifest: project.Manifest,
	workspaceOverride: project.Workspace?
): boolean
	if type(dep) == "string" then
		return false
	end

	local workspace = effectiveWorkspace(manifest, workspaceOverride)
	local workspaceName = if (dep :: any).repo then ((dep :: any).package or alias) :: string else alias
	local workspacePath = workspace and workspace[workspaceName]
	if workspacePath then
		return locked.type == "workspace" and locked.data.path == resolveWorkspacePath(root, workspacePath)
	end

	if (dep :: any)["local"] then
		return locked.type == "local" and locked.data.path == (dep :: any)["local"]
	end

	if (dep :: any).path then
		return locked.type == "path" and locked.data.path == (dep :: any).path
	end

	if (dep :: any).url then
		return locked.type == "file"
			and locked.data.url == (dep :: any).url
			and locked.data.sha256 == (dep :: any).sha256
	end

	if (dep :: any).git then
		if locked.type ~= "git" or locked.data.url ~= (dep :: any).git then
			return false
		end
		if locked.data.subdir ~= normalizeGitSubdir((dep :: any).subdir) then
			return false
		end

		local requestedRef = locked.data.requestedRef or locked.data.ref
		if (dep :: any).rev then
			local requestedRev = (dep :: any).rev
			if locked.data.ref.type ~= "commit" or not isHexString(requestedRev) then
				return false
			end

			local lockedCommit = string.lower(locked.data.ref.value)
			local requestedCommit = string.lower(requestedRev)
			return lockedCommit:sub(1, #requestedCommit) == requestedCommit
		elseif (dep :: any).tag then
			return requestedRef.type == "tag" and requestedRef.value == (dep :: any).tag
		elseif (dep :: any).branch then
			return requestedRef.type == "branch" and requestedRef.value == (dep :: any).branch
		end
		return false
	end

	if (dep :: any).repo then
		if locked.type ~= "repository" then
			return false
		end

		local repoDep = dep :: project.RepositoryDependency
		if locked.data.repository ~= resolveRepositoryName(manifest, repoDep) then
			return false
		end

		if locked.data.key ~= (repoDep.package or alias) then
			return false
		end

		if repoDep.version then
			local lockedVersion = semver.parse(locked.data.version)
			return semver.satisfies(lockedVersion, repoDep.version)
		end

		return true
	end

	return false
end

local function getTopLevelGroups(prj: project.ManifestDocument, includeDev: boolean): TopLevelGroups
	local regular = (prj.manifest.dependencies or {}) :: project.Dependencies
	local dev = if includeDev then (prj.manifest.devDependencies or {}) :: project.Dependencies else {}

	for alias in regular do
		if dev[alias] ~= nil then
			error(`Dependency "{alias}" is defined in both dependencies and dev-dependencies`)
		end
	end

	return {
		regular = regular,
		dev = dev,
	}
end

local function countDependencies(deps: project.Dependencies): number
	local count = 0
	for _ in deps do
		count += 1
	end
	return count
end

local function collectRequirementsFromDependencies(
	root: string,
	manifest: project.Manifest,
	deps: project.Dependencies,
	requirements: { types.Requirement },
	visiting: types.Visiting,
	workspaceOverride: project.Workspace?
)
	if next(deps) == nil then
		return
	end

	local partialManifest = table.clone(manifest)
	partialManifest.dependencies = deps
	dependency.collect(
		root,
		root,
		partialManifest,
		requirements,
		visiting,
		true,
		effectiveWorkspace(manifest, workspaceOverride)
	)
end

local function splitPlanRoots(plan: types.InstallPlan, devDeps: project.Dependencies)
	local roots = {}
	local devRoots = {}

	for _, edge in plan.roots do
		if devDeps[edge.alias] ~= nil then
			table.insert(devRoots, edge)
		else
			table.insert(roots, edge)
		end
	end

	plan.roots = roots
	plan.devRoots = devRoots
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

local function collectReachablePlanTargets(
	nodes: { [string]: types.InstallNode },
	edges: { types.InstallEdge },
	reachable: { [string]: boolean }
)
	for _, edge in edges do
		if reachable[edge.target] then
			continue
		end

		local node = nodes[edge.target]
		if not node then
			error(`Lock file references missing package {edge.target}`)
		end

		reachable[edge.target] = true
		collectReachablePlanTargets(nodes, node.dependencies, reachable)
	end
end

local function preservePreviousDevState(
	plan: types.InstallPlan,
	root: string,
	previousLock: types.LockFile?,
	includeDev: boolean
)
	if includeDev or previousLock == nil or previousLock.devRoots == nil or #previousLock.devRoots == 0 then
		return
	end

	local previousPlan = planner.produceInstallPlanFromLock(root, previousLock, true)
	local reachable: { [string]: boolean } = {}
	collectReachablePlanTargets(previousPlan.nodes, previousPlan.devRoots, reachable)

	plan.devRoots = copyEdges(previousPlan.devRoots)

	for id in reachable do
		if plan.nodes[id] == nil then
			local node = previousPlan.nodes[id]
			if not node then
				error(`Lock file references missing package {id}`)
			end

			plan.nodes[id] = {
				id = node.id,
				installName = node.installName,
				requirement = table.clone(node.requirement),
				dependencies = copyEdges(node.dependencies),
			}
		end
	end
end

local function manifestMatchesLock(
	prj: project.ManifestDocument,
	lock: types.LockFile,
	includeDev: boolean,
	workspaceOverride: project.Workspace?
): boolean
	local groups = getTopLevelGroups(prj, includeDev)
	local manifestDeps = groups.regular
	local manifestDevDeps = groups.dev

	if countDependencies(manifestDeps) ~= #lock.roots then
		return false
	end

	local lockDevRoots = lock.devRoots or {}
	if includeDev and countDependencies(manifestDevDeps) ~= #lockDevRoots then
		return false
	end

	for alias, dep in manifestDeps do
		local lockedTarget: string? = nil
		for _, edge in lock.roots do
			if edge.alias == alias then
				lockedTarget = edge.target
				break
			end
		end

		if not lockedTarget then
			return false
		end

		local lockedPackage = lock.packages[lockedTarget]
		if not lockedPackage then
			return false
		end

		if not dependencyMatchesLock(prj.root, alias, dep, lockedPackage, prj.manifest, workspaceOverride) then
			return false
		end
	end

	for alias, dep in manifestDevDeps do
		local lockedTarget: string? = nil
		for _, edge in lockDevRoots do
			if edge.alias == alias then
				lockedTarget = edge.target
				break
			end
		end

		if not lockedTarget then
			return false
		end

		local lockedPackage = lock.packages[lockedTarget]
		if not lockedPackage then
			return false
		end

		if not dependencyMatchesLock(prj.root, alias, dep, lockedPackage, prj.manifest, workspaceOverride) then
			return false
		end
	end

	return true
end

local function lockedTargetForAlias(lock: types.LockFile, alias: string): string?
	for _, edge in lock.roots do
		if edge.alias == alias then
			return edge.target
		end
	end

	return nil
end

local function planNodeForRootAlias(plan: types.InstallPlan, alias: string): types.InstallNode?
	for _, edge in plan.roots do
		if edge.alias == alias then
			return plan.nodes[edge.target]
		end
	end

	for _, edge in plan.devRoots do
		if edge.alias == alias then
			return plan.nodes[edge.target]
		end
	end

	return nil
end

local function computeInstallPlanFromManifest(
	prj: project.ManifestDocument,
	includeDev: boolean,
	workspaceOverride: project.Workspace?
): types.InstallPlan?
	local groups = getTopLevelGroups(prj, includeDev)
	if next(groups.regular) == nil and next(groups.dev) == nil then
		return {
			nodes = {},
			roots = {},
			devRoots = {},
		}
	end

	if not prj.root then
		print("Failed to identify project root")
		return nil
	end

	local requirements: { types.Requirement } = {}
	local visiting: types.Visiting = { order = {}, set = {} }

	collectRequirementsFromDependencies(
		prj.root,
		prj.manifest,
		groups.regular,
		requirements,
		visiting,
		workspaceOverride
	)
	collectRequirementsFromDependencies(prj.root, prj.manifest, groups.dev, requirements, visiting, workspaceOverride)

	local plan = planner.produceInstallPlan(requirements)
	splitPlanRoots(plan, groups.dev)
	return plan
end

local function computeInstallPlanForUpdate(
	prj: project.ManifestDocument,
	aliases: { string },
	includeDev: boolean
): types.InstallPlan?
	if not prj.root then
		print("Failed to identify project root")
		return nil
	end

	local groups = getTopLevelGroups(prj, includeDev)
	local selected: { [string]: boolean } = {}
	for _, alias in aliases do
		selected[alias] = true
	end

	for alias in selected do
		if groups.regular[alias] == nil and groups.dev[alias] == nil then
			error(`Package {alias} not installed`)
		end
	end

	local previousLock = lockfile.load(prj.root)
	if not previousLock then
		error("Cannot update specific dependencies without an existing eryx.lock")
	end

	local requirements: { types.Requirement } = {}
	local visiting: types.Visiting = { order = {}, set = {} }

	for alias, dep in groups.regular do
		if selected[alias] then
			collectRequirementsFromDependencies(
				prj.root,
				prj.manifest,
				{ [alias] = dep },
				requirements,
				visiting,
				prj.manifest.workspace
			)
		else
			local lockedTarget = lockedTargetForAlias(previousLock, alias)
			if not lockedTarget then
				error(`Dependency "{alias}" is not present in eryx.lock; run pkg update without arguments`)
			end

			table.insert(
				requirements,
				planner.buildRequirementTreeFromLock(prj.root, previousLock, lockedTarget, alias)
			)
		end
	end

	for alias, dep in groups.dev do
		if selected[alias] then
			collectRequirementsFromDependencies(
				prj.root,
				prj.manifest,
				{ [alias] = dep },
				requirements,
				visiting,
				prj.manifest.workspace
			)
		else
			local lockedTarget: string? = nil
			local devRoots = previousLock.devRoots or {}
			for _, edge in devRoots do
				if edge.alias == alias then
					lockedTarget = edge.target
					break
				end
			end
			if not lockedTarget then
				error(`Dependency "{alias}" is not present in eryx.lock; run pkg update --dev without arguments`)
			end

			table.insert(
				requirements,
				planner.buildRequirementTreeFromLock(prj.root, previousLock, lockedTarget, alias)
			)
		end
	end

	local plan = planner.produceInstallPlan(requirements)
	splitPlanRoots(plan, groups.dev)
	return plan
end

function pkg.computeInstallPlan(includeDev: boolean?): types.InstallPlan?
	local prj = project.loadNearest()
	if not prj then
		print("No project")
		return nil
	end

	return computeInstallPlanFromManifest(prj, includeDev == true, prj.manifest.workspace)
end

local function installWithMode(
	forceRefresh: boolean,
	updateAliases: { string }?,
	includeDev: boolean
): (project.ManifestDocument?, types.InstallPlan?)
	local prj = project.loadNearest()
	if not prj then
		print("No project")
		return nil, nil
	end

	if not prj.root then
		print("Failed to identify project root")
		return nil, nil
	end

	local previousLock = lockfile.load(prj.root)
	local plan: types.InstallPlan?

	if updateAliases and #updateAliases > 0 then
		print(`Updating selected dependencies: {table.concat(updateAliases, ", ")}`)
		plan = computeInstallPlanForUpdate(prj, updateAliases, includeDev)
	elseif
		not forceRefresh
		and previousLock
		and manifestMatchesLock(prj, previousLock, includeDev, prj.manifest.workspace)
	then
		print("Using lock file")
		plan = planner.produceInstallPlanFromLock(prj.root, previousLock, true)
	else
		if forceRefresh then
			print("Refreshing dependency lock")
		end
		plan = computeInstallPlanFromManifest(prj, includeDev, prj.manifest.workspace)
	end

	if not plan then
		return prj, nil
	end

	preservePreviousDevState(plan, prj.root, previousLock, includeDev)

	execution.execute(prj.root, plan, previousLock)

	local lock = planner.generateLockFile(plan)
	lockfile.save(prj.root, lock)

	return prj, plan
end

local function initialiseWorkspaceProjects(prj: project.ManifestDocument, includeDev: boolean)
	local workspace = prj.manifest.workspace
	if workspace == nil or prj.root == nil then
		return
	end

	local names = {}
	for name in workspace do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		local packageRoot = resolveWorkspacePath(prj.root, workspace[name])
		local manifestPath = fs.path.join(packageRoot, "eryx.toml")
		if not fs.isFile(manifestPath) then
			error(`Workspace package "{name}" does not contain eryx.toml at {workspace[name]}`)
		end

		local workspaceProject = project.load(manifestPath)
		if workspaceProject.manifest.project.name ~= name then
			error(
				`Workspace package "{name}" expected project name "{name}", found "{workspaceProject.manifest.project.name}"`
			)
		end

		local previousLock = lockfile.load(packageRoot)
		local plan: types.InstallPlan?
		if previousLock and manifestMatchesLock(workspaceProject, previousLock, includeDev, workspace) then
			plan = planner.produceInstallPlanFromLock(packageRoot, previousLock, includeDev)
		else
			plan = computeInstallPlanFromManifest(workspaceProject, includeDev, workspace)
		end

		if plan then
			preservePreviousDevState(plan, packageRoot, previousLock, includeDev)
			execution.execute(packageRoot, plan, previousLock)
		end
	end
end

function pkg.doInstall(includeDev: boolean?)
	local prj = installWithMode(false, nil, includeDev == true)
	if prj then
		initialiseWorkspaceProjects(prj, includeDev == true)
	end
end

function pkg.doUpdate(updateAliases: { string }?, includeDev: boolean?)
	local prj = installWithMode(true, updateAliases, includeDev == true)
	if prj then
		initialiseWorkspaceProjects(prj, includeDev == true)
	end
end

function pkg.doUpgrade(updateAliases: { string }?, includeDev: boolean?)
	local prj, plan = installWithMode(true, updateAliases, includeDev == true)
	if not prj or not plan then
		return
	end

	local groups = getTopLevelGroups(prj, includeDev == true)
	local aliasesToUpgrade: { string } = {}

	if updateAliases and #updateAliases > 0 then
		for _, alias in updateAliases do
			table.insert(aliasesToUpgrade, alias)
		end
	else
		for alias, dep in groups.regular do
			if type(dep) ~= "string" and (dep :: any).repo then
				table.insert(aliasesToUpgrade, alias)
			end
		end
		for alias, dep in groups.dev do
			if type(dep) ~= "string" and (dep :: any).repo then
				table.insert(aliasesToUpgrade, alias)
			end
		end
	end

	table.sort(aliasesToUpgrade)

	local changed = false
	for _, alias in aliasesToUpgrade do
		local dep = groups.regular[alias]
		local depTableParent = prj.cst.eryx.dependencies
		if dep == nil then
			dep = groups.dev[alias]
			depTableParent = prj.cst.eryx["dev-dependencies"]
		end

		if type(dep) == "string" or not (dep :: any).repo then
			print(`Skipping upgrade for {alias}: only repository dependencies rewrite manifest versions`)
			continue
		end

		local node = planNodeForRootAlias(plan, alias)
		if not node or node.requirement.type ~= "repository" or not node.requirement.version then
			error(`Failed to resolve repository version for {alias}`)
		end

		local depTable = depTableParent[alias]
		if type(depTable) ~= "table" then
			error(`Cannot rewrite manifest entry for {alias}`)
		end

		local versionText = semver.format(node.requirement.version)
		if depTable.version ~= versionText then
			local replacement = {
				repo = depTable.repo,
				version = versionText,
			}

			if depTable.package ~= nil then
				replacement.package = depTable.package
			end

			depTableParent[alias] = replacement
			changed = true
		end
	end

	if changed then
		project.save(prj)
	end

	initialiseWorkspaceProjects(prj, includeDev == true)
end

return table.freeze(pkg)
