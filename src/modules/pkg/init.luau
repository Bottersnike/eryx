--[=[
	Local-only package manager implementation.

	This is intentionally small for the first pass: it resolves `local` and
	`local-copy` dependencies from `eryx.toml`, writes an `eryx.lock`, installs
	copied packages under `eryx_packages/<alias>`, and updates project-root
	`.luaurc` aliases.
]=]

local fs = require("@eryx/fs")
local json = require("@eryx/data/json")
local os = require("@eryx/os")
local path = require("@eryx/path")
local project = require("@eryx/project")
local toml = require("@eryx/data/toml")

export type LocalMode = "local" | "local-copy"

export type Requirement = {
	alias: string,
	package: string,
	mode: LocalMode,
	sourcePath: string,
	dev: boolean,
	requestedBy: string?,
}

export type ResolvedPackage = {
	alias: string,
	aliasKey: string,
	name: string,
	version: string?,
	mode: LocalMode,
	sourcePath: string,
	installedPath: string?,
	packageRoot: string,
	aliasTarget: string,
	dev: boolean,
	direct: boolean,
	dependencies: { Requirement },
}

export type AliasRecord = {
	key: string,
	alias: string,
	target: string,
	package: string,
	reason: string,
}

export type InstallResult = {
	root: string,
	packages: { ResolvedPackage },
	aliases: { AliasRecord },
	lockPath: string,
}

local pkg = {}

local PACKAGE_DIR = "eryx_packages"

local function fail(message: string): never
	error(message, 2)
end

local function join(base: string, child: string): string
	return tostring(path.join(base, child))
end

local function readFile(filePath: string): string
	return fs.openSync(filePath):readSync()
end

local function writeFile(filePath: string, source: string)
	local parent = path.dirname(filePath)
	if parent ~= nil then
		fs.mkdir(parent)
	end
	fs.openSync(filePath, "w"):writeSync(source)
end

local function isAbsolute(value: string): boolean
	return path.new(value):isAbsolute()
end

local function absoluteFrom(root: string, value: string): string
	if isAbsolute(value) then
		return tostring(path.canonicalize(value))
	end
	return tostring(path.canonicalize(path.join(root, value)))
end

local function stripLeadingAt(value: string): string
	if string.sub(value, 1, 1) == "@" then
		return string.sub(value, 2)
	end
	return value
end

local function aliasKey(alias: string): string
	return stripLeadingAt(alias)
end

local function packageRootFor(root: string): string
	local src = join(root, "src")
	if fs.isDirectory(src) then
		return src
	end
	return root
end

local function materializedPackageRoot(sourceRoot: string, materializedRoot: string): string
	if fs.isDirectory(join(sourceRoot, "src")) then
		return join(materializedRoot, "src")
	end
	return materializedRoot
end

local function displayPathFrom(root: string, target: string): string
	local okRoot, canonicalRoot = pcall(path.canonicalize, root)
	local okTarget, canonicalTarget = pcall(path.canonicalize, target)
	if okRoot and okTarget then
		local relative = canonicalTarget:relativeTo(canonicalRoot)
		if relative ~= nil then
			local rendered = tostring(relative):gsub("\\", "/")
			if rendered == "" then
				return "."
			end
			if string.sub(rendered, 1, 1) == "." then
				return rendered
			end
			return "./" .. rendered
		end
	end
	return target
end

local function dependencySource(dep: project.Dependency, context: string): (LocalMode, string, string?)
	if type(dep) ~= "table" then
		fail(`{context} is not a local dependency`)
	end

	local raw = dep :: any
	if raw["local"] ~= nil then
		return "local", raw["local"], raw.package
	end
	if raw["local-copy"] ~= nil then
		return "local-copy", raw["local-copy"], raw.package
	end
	if raw.path ~= nil then
		return "local", raw.path, raw.package
	end

	fail(`{context} is not supported yet; only local and local-copy dependencies can be installed`)
end

local function loadManifestIfPresent(root: string): project.ManifestDocument?
	local manifestPath = join(root, "eryx.toml")
	if not fs.isFile(manifestPath) then
		return nil
	end
	return project.load(manifestPath)
end

local function collectRequirementsFrom(
	dependencies: project.Dependencies?,
	root: string,
	dev: boolean,
	requestedBy: string?
): { Requirement }
	local requirements = {}
	if dependencies == nil then
		return requirements
	end

	for alias, dep in dependencies do
		local mode, source, explicitPackage = dependencySource(dep, `dependency {alias}`)
		local sourcePath = absoluteFrom(root, source)
		if not fs.isDirectory(sourcePath) then
			fail(`dependency {alias} points to missing directory: {sourcePath}`)
		end

		local childDoc = loadManifestIfPresent(sourcePath)
		table.insert(requirements, {
			alias = alias,
			package = explicitPackage or if childDoc then childDoc.manifest.project.name else alias,
			mode = mode,
			sourcePath = sourcePath,
			dev = dev,
			requestedBy = requestedBy,
		})
	end

	return requirements
end

local function installPathFor(root: string, alias: string): string
	local current = join(root, PACKAGE_DIR)
	for part in string.gmatch(aliasKey(alias), "[^/\\]+") do
		current = join(current, part)
	end
	return current
end

local function resolveGraph(rootDoc: project.ManifestDocument): { ResolvedPackage }
	local root = rootDoc.root or tostring(os.cwd())
	local resolved: { ResolvedPackage } = {}
	local byAlias: { [string]: ResolvedPackage } = {}
	local visiting: { [string]: boolean } = {}

	local function resolveRequirement(requirement: Requirement, direct: boolean)
		if byAlias[requirement.alias] ~= nil then
			local existing = byAlias[requirement.alias]
			if existing.sourcePath ~= requirement.sourcePath or existing.mode ~= requirement.mode then
				fail(`dependency alias {requirement.alias} is used for multiple local packages`)
			end
			return
		end

		if visiting[requirement.alias] then
			fail(`cyclic dependency through alias {requirement.alias}`)
		end
		visiting[requirement.alias] = true

		local depDoc = loadManifestIfPresent(requirement.sourcePath)
		local installPath = if requirement.mode == "local-copy" then installPathFor(root, requirement.alias) else nil
		local materializedRoot = installPath or requirement.sourcePath
		local packageRoot = if installPath
			then materializedPackageRoot(requirement.sourcePath, materializedRoot)
			else packageRootFor(materializedRoot)
		local aliasTarget = displayPathFrom(root, packageRoot)

		local childRequirements = {}
		if depDoc ~= nil then
			childRequirements =
				collectRequirementsFrom(depDoc.manifest.dependencies, requirement.sourcePath, false, requirement.alias)
			for _, child in
				collectRequirementsFrom(
					depDoc.manifest.devDependencies,
					requirement.sourcePath,
					true,
					requirement.alias
				)
			do
				table.insert(childRequirements, child)
			end
		end

		local resolvedPackage = {
			alias = requirement.alias,
			aliasKey = aliasKey(requirement.alias),
			name = requirement.package,
			version = if depDoc then depDoc.manifest.project.version else nil,
			mode = requirement.mode,
			sourcePath = requirement.sourcePath,
			installedPath = installPath,
			packageRoot = packageRoot,
			aliasTarget = aliasTarget,
			dev = requirement.dev,
			direct = direct,
			dependencies = childRequirements,
		}

		byAlias[requirement.alias] = resolvedPackage
		table.insert(resolved, resolvedPackage)

		for _, child in childRequirements do
			resolveRequirement(child, false)
		end

		visiting[requirement.alias] = false
	end

	for _, requirement in collectRequirementsFrom(rootDoc.manifest.dependencies, root, false, nil) do
		resolveRequirement(requirement, true)
	end
	for _, requirement in collectRequirementsFrom(rootDoc.manifest.devDependencies, root, true, nil) do
		resolveRequirement(requirement, true)
	end

	return resolved
end

local function copyLocalPackages(packages: { ResolvedPackage })
	for _, package in packages do
		if package.mode == "local-copy" then
			local target = package.installedPath or fail("local-copy package missing install path")
			if fs.exists(target) then
				fs.remove(target)
			end
			local parent = path.dirname(target)
			if parent ~= nil then
				fs.mkdir(parent)
			end
			fs.copy(package.sourcePath, target)
		end
	end
end

local function aliasRecords(packages: { ResolvedPackage }): { AliasRecord }
	local aliases = {}
	for _, package in packages do
		table.insert(aliases, {
			key = package.aliasKey,
			alias = package.alias,
			target = package.aliasTarget,
			package = package.name,
			reason = if package.direct then "direct" else "transitive",
		})
	end
	return aliases
end

local function encodeLock(packages: { ResolvedPackage }, aliases: { AliasRecord }): string
	local packageEntries = {}
	for _, package in packages do
		local dependencies = {}
		for _, dependency in package.dependencies do
			table.insert(dependencies, {
				alias = dependency.alias,
				package = dependency.package,
				source = dependency.mode,
				path = dependency.sourcePath,
				dev = dependency.dev,
			})
		end
		local entry: { [string]: any } = {
			alias = package.alias,
			name = package.name,
			version = package.version,
			source = package.mode,
			path = package.sourcePath,
			install = package.installedPath,
			root = package.packageRoot,
			dev = package.dev,
		}
		if #dependencies > 0 then
			entry.dependencies = dependencies
		end
		table.insert(packageEntries, entry)
	end

	local aliasEntries = {}
	for _, alias in aliases do
		table.insert(aliasEntries, {
			key = alias.key,
			alias = alias.alias,
			target = alias.target,
			package = alias.package,
			reason = alias.reason,
		})
	end

	local lockData: { [string]: any } = {
		lock = {
			version = 1,
		},
	}
	if #packageEntries > 0 then
		lockData.package = packageEntries
	end
	if #aliasEntries > 0 then
		lockData.alias = aliasEntries
	end

	return toml.encode(lockData, { sortKeys = false }) .. "\n"
end

local function parseOldAliases(root: string): { [string]: string }
	local lockPath = join(root, "eryx.lock")
	if not fs.isFile(lockPath) then
		return {}
	end

	local ok, decoded = pcall(toml.decode, readFile(lockPath))
	if not ok then
		return {}
	end

	local oldAliases: { [string]: string } = {}
	local aliases = (decoded :: any).alias
	if type(aliases) == "table" then
		for i = 1, #aliases do
			local entry = aliases[i]
			if type(entry) == "table" and type(entry.key) == "string" and type(entry.target) == "string" then
				oldAliases[entry.key] = entry.target
			end
		end
	end
	return oldAliases
end

local function loadLuaurc(root: string): { [string]: any }
	local configPath = join(root, ".luaurc")
	if not fs.isFile(configPath) then
		return {
			languageMode = "strict",
			aliases = {},
		}
	end

	local ok, decoded = pcall(json.decode, readFile(configPath))
	if not ok or type(decoded) ~= "table" then
		fail("failed to parse .luaurc as JSON; comment-preserving .luaurc updates are not implemented yet")
	end

	return decoded :: { [string]: any }
end

local function prepareLuaurc(root: string, aliases: { AliasRecord }): string?
	local oldAliases = parseOldAliases(root)
	if #aliases == 0 and next(oldAliases) == nil and not fs.isFile(join(root, ".luaurc")) then
		return nil
	end

	if fs.isFile(join(root, ".config.luau")) then
		fail("package install cannot update .config.luau yet; please use .luaurc for package aliases")
	end

	local config = loadLuaurc(root)
	if type(config.aliases) ~= "table" then
		config.aliases = {}
	end

	local nextAliasKeys: { [string]: boolean } = {}
	for _, alias in aliases do
		nextAliasKeys[alias.key] = true
	end

	for key, target in oldAliases do
		if not nextAliasKeys[key] and (config.aliases :: any)[key] == target then
			(config.aliases :: any)[key] = nil
		end
	end

	for _, alias in aliases do
		local existing = (config.aliases :: any)[alias.key]
		if existing ~= nil and existing ~= alias.target and oldAliases[alias.key] ~= existing then
			fail(`alias {alias.key} already exists in .luaurc and is not owned by eryx.lock`)
		end
		(config.aliases :: any)[alias.key] = alias.target
	end

	return json.encode(config, { pretty = true, sortKeys = true }) .. "\n"
end

local function writeLuaurc(root: string, source: string?)
	if source == nil then
		return
	end
	writeFile(join(root, ".luaurc"), source)
end

function pkg.install(rootOrManifestPath: string?): InstallResult
	local doc = if rootOrManifestPath then project.load(rootOrManifestPath) else project.loadNearest()
	if doc == nil then
		fail("No eryx.toml found")
	end

	local root = doc.root or tostring(os.cwd())
	local packages = resolveGraph(doc)
	local aliases = aliasRecords(packages)
	local lockSource = encodeLock(packages, aliases)
	local luaurcSource = prepareLuaurc(root, aliases)

	local lockPath = join(root, "eryx.lock")
	copyLocalPackages(packages)
	writeLuaurc(root, luaurcSource)
	writeFile(lockPath, lockSource)

	return {
		root = root,
		packages = packages,
		aliases = aliases,
		lockPath = lockPath,
	}
end

return table.freeze(pkg)
