--!nolint LocalShadow
-- @ignore

local zip = require("@eryx/compression/zip")
local planning = require("../planning")
local dependency = require("../dependency")
local json = require("@eryx/data/json")
local fs = require("@eryx/fs")
local http = require("@eryx/http")
local semver = require("@eryx/semver")
local project = require("@eryx/project")

local types = require("../types")

local function repositoryBaseId(repository: string, key: string): string
	return repository .. "\0" .. key
end

local function listRepositoryVersions(repository: string, key: string): { semver.Version }
	local res = http.get(`{repository}/packages/{key}`)
	-- if res.status ~= 200 or res.headers["content-type"] ~= "application/json" then
	if res.status ~= 200 then
		error("Repository lookup failed")
	end
	local rawVersions = json.decode(res.body) :: { string }

	local versions = {}
	for _, i in rawVersions do
		table.insert(versions, semver.parse(i))
	end
	return versions
end

local function getManifestFromRepository(repository: string, key: string, version: semver.Version): project.Manifest?
	local res = http.get(`{repository}/packages/{key}/{semver.format(version)}`)
	-- if res.status ~= 200 or res.headers["content-type"] ~= "application/json" then
	if res.status ~= 200 then
		error("Repository lookup failed")
	end
	local rawMetadata = json.decode(res.body)

	local dependencies: project.Dependencies = {}

	for key, i in rawMetadata.dependencies do
		if i.repo then
			i.version = semver.parseRange(i.version)
		end
		dependencies[key] = i
	end

	return {
		manifestVersion = 1,
		project = {
			name = key,
			version = semver.format(version),
		},
		dependencies = dependencies,
		raw = {},
	}
end

local function chooseRepositoryVersion(
	ctx: types.ResolveContext,
	repository: string,
	key: string,
	range: semver.Range?
): semver.Version
	local baseId = repositoryBaseId(repository, key)
	local existing = ctx.repositorySelections[baseId]

	if existing then
		table.sort(existing, function(a: types.InstallNode, b: types.InstallNode)
			local av = (a.requirement :: any).version :: semver.Version
			local bv = (b.requirement :: any).version :: semver.Version

			return semver.greaterThan(av, bv)
		end)

		for _, node in existing do
			local version = (node.requirement :: any).version :: semver.Version
			if not range or semver.satisfies(version, range) then
				return version
			end
		end
	end

	local versions = listRepositoryVersions(repository, key)

	table.sort(versions, function(a, b)
		return semver.greaterThan(a, b)
	end)

	for _, version in versions do
		if not range or semver.satisfies(version, range) then
			return version
		end
	end

	error(`No version of {repository}:{key} satisfies {range}`)
end

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

local repo: types.Source = {
	type = "repository",

	checkDependency = function(dep)
		if (dep :: any)["repo"] then
			return true
		end
		return false
	end,

	collect = function(
		root: string,
		path: string,
		manifest: project.Manifest,
		name: string,
		dep: project.Dependency,
		requirements: { types.Requirement },
		visiting: types.Visiting,
		allowLocal: boolean
	)
		local dep = dep :: project.RepositoryDependency

		local repository: string
		if dep.repo:find("://") then
			repository = dep.repo
		else
			if not manifest.repositories then
				error("eryx.toml does not specify repositories")
			end
			if not manifest.repositories[dep.repo] then
				error(`Attempted to use unspecified repository: {dep.repo}`)
			end
			repository = manifest.repositories[dep.repo]
		end

		local r: types.Requirement = {
			type = "repository",
			repository = repository,
			name = name,
			key = dep.package or name,
			path = repository .. "\0" .. (dep.package or name),
			range = dep.version,
			version = nil,
			tree = {},
		}

		-- Child dependency resolution is going to happen later, during planning

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		if requirement.type ~= "repository" then
			error("Internal error: expected repository requirement")
		end

		if not requirement.version then
			error(`No version was selected for {requirement.key}`)
		end

		local repository = requirement.repository
		local key = requirement.key
		local version = requirement.version

		local res = http.get(`{repository}/packages/{key}/{semver.format(version)}/download`)
		if res.status ~= 200 then
			error("Repository download failed")
		end
		local pkzip = buffer.fromstring(res.body)

		print(`Installing {key}@{semver.format(version)} to {dest}...`)
		-- TODO: We're vulnerable to `../` in zip filenames
		for path, data in zip.unpack(pkzip) do
			local fullyQualified = fs.path.join(dest, path)

			fs.mkdir(fs.path.basename(fullyQualified))
			local f = fs.open(fullyQualified, "w")
			f:write(data)
			f:close()
		end
	end,

	identity = function(requirement: types.Requirement): string
		assert(requirement.type == "repository")
		assert(requirement.version, "Repository requirement has not been resolved")
		return "repository:"
			.. requirement.repository
			.. ":"
			.. requirement.key
			.. "@"
			.. semver.format(requirement.version)
	end,

	resolveInstallPlan = function(
		ctx: types.ResolveContext,
		parent: types.InstallNode?,
		requirement: types.Requirement,
		resolve: types.ResolveRecursion
	): types.InstallNode
		assert(requirement.type == "repository")

		local version = requirement.version
		if not version then
			version = chooseRepositoryVersion(ctx, requirement.repository, requirement.key, requirement.range)
		end

		local resolved: types.Requirement = {
			type = "repository",
			repository = requirement.repository,
			name = requirement.name,
			key = requirement.key,
			path = requirement.path,
			range = requirement.range,
			version = version,
			tree = {},
		}

		local node = planning.addRequirementNode(ctx, resolved)

		local baseId = repositoryBaseId(requirement.repository, requirement.key)
		ctx.repositorySelections[baseId] = ctx.repositorySelections[baseId] or {}

		local alreadyTracked = false
		for _, existing in ctx.repositorySelections[baseId] do
			if existing.id == node.id then
				alreadyTracked = true
				break
			end
		end

		if not alreadyTracked then
			table.insert(ctx.repositorySelections[baseId], node)
		end

		addPlanEdge(ctx, parent, requirement.name, node.id)

		if #node.dependencies == 0 and not ctx.resolving[node.id] then
			local manifest = getManifestFromRepository(requirement.repository, requirement.key, version)
			if manifest and manifest.dependencies then
				local childRequirements: { types.Requirement } = {}
				local visiting: types.Visiting = { order = {}, set = {} }

				dependency.collect("", "", manifest, childRequirements, visiting, false)
				resolve(ctx, node, childRequirements)
			end
		end

		return node
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		assert(requirement.type == "repository")
		assert(requirement.version, "Cannot generate lock file from unresolved repository requirement")
		return {
			repository = requirement.repository,
			key = requirement.key,
			version = semver.format(requirement.version),
		}
	end,

	readLock = function(_root: string, package: types.LockPackage): types.Requirement
		return {
			type = "repository",
			name = "",
			key = package.data.key,
			repository = package.data.repository,
			path = package.data.repository .. "\0" .. package.data.key,
			range = nil,
			version = semver.parse(package.data.version),
			tree = {},
		}
	end,
}

return table.freeze(repo)
