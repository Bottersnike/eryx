--[=[
	Project manifest and lockfile helpers.

	This module intentionally parses `eryx.toml` and `eryx.lock` through the
	TOML CST API. The typed `manifest` / `lockfile` views are for validation and
	convenient reads; the original CST document remains available for edits so
	comments, whitespace, unknown Eryx fields, and third-party `[tool.*]` tables
	can be preserved when the file is written back.
]=]

local fs = require("@eryx/fs")
local os = require("@eryx/os")
local path = require("@eryx/path")
local toml = require("@eryx/data/toml")
local semver = require("@eryx/semver")

export type Author = {
	name: string,
	email: string?,
	url: string?,
}

export type ProjectMetadata = {
	name: string,
	version: string,
	private: boolean?,
	description: string?,
	authors: { Author }?,
	license: string?,
	licenseFile: string?,
	keywords: { string }?,
	sourceRoot: string?,
}

export type Links = {
	homepage: string?,
	documentation: string?,
	source: string?,
	bugs: string?,
	[string]: string?,
}

-- Represents a dependency that is available on git
--
-- Exactly one of rev, tag or branch must be specified
export type GitDependency =
	{
		git: string,
		rev: string,
	}
	| {
		git: string,
		tag: string,
	}
	| {
		git: string,
		branch: string,
	}

-- Represents a dependency that is on the local filesystem
--
-- This dependency will not be copied, and is only referenced as an
-- alias.
-- A child eryx.toml is ignored.
export type PathDependency = {
	path: string,
}

-- Represents a dependency that is on the local filesystem
--
-- The contents of this dependency will be copied to the local project,
-- and any root eryx.toml will be used for child dependency resolution
export type LocalDependency = {
	["local"]: string,
}

-- Represents a dependency that is a downloadable archive
--
-- The archive may optionally include an eryx.toml,
-- which will be used for child depdendency resolution
export type UrlDependency = {
	url: string,
	sha256: string?,
}

-- Represents a package available on a repository
export type RepositoryDependency = {
	repo: string,
	version: semver.Range?,
	package: string?,
}

export type Dependency = string | GitDependency | PathDependency | LocalDependency | UrlDependency | RepositoryDependency
export type Dependencies = { [string]: Dependency }

export type BuildTarget = {
	output: string,
	entrypoint: string,
	include: { string }?,
	exclude: { string }?,
	sourceExe: string?,
}

export type TestConfig = {
	include: { string }?,
	exclude: { string }?,
}

export type Manifest = {
	manifestVersion: number,
	project: ProjectMetadata,
	links: Links?,
	scripts: { [string]: string }?,
	repositories: { [string]: string }?,
	dependencies: Dependencies?,
	devDependencies: Dependencies?,
	build: { [string]: BuildTarget }?,
	test: TestConfig?,
	raw: { [any]: any },
}

export type ManifestDocument = {
	path: string?,
	root: string?,
	cst: any,
	manifest: Manifest,
}

export type LockedDependency = {
	name: string,
	version: string?,
	source: string?,
}

export type LockedPackage = {
	name: string,
	version: string?,
	source: string?,
	checksum: string?,
	rev: string?,
	dependencies: { LockedDependency }?,
	raw: { [any]: any },
}

export type Lockfile = {
	version: number,
	eryxVersion: string?,
	generatedAt: string?,
	packages: { LockedPackage },
	raw: { [any]: any },
}

export type LockDocument = {
	path: string?,
	root: string?,
	cst: any,
	lockfile: Lockfile,
}

local project = {}
local lock = {}

local MANIFEST_FILENAME = "eryx.toml"
local LOCK_FILENAME = "eryx.lock"

local function fail(message: string): never
	error(message, 2)
end

local function at(context: string, key: string): string
	if context == "" then
		return key
	end
	return context .. "." .. key
end

local function expectTable(value: any, context: string): { [any]: any }
	if type(value) ~= "table" then
		fail(`expected {context} to be a table`)
	end
	return value :: { [any]: any }
end

local function expectString(value: any, context: string): string
	if type(value) ~= "string" then
		fail(`expected {context} to be a string`)
	end
	return value
end

local function expectOptionalString(value: any, context: string): string?
	if value == nil then
		return nil
	end
	return expectString(value, context)
end

local function expectBoolean(value: any, context: string): boolean
	if type(value) ~= "boolean" then
		fail(`expected {context} to be a boolean`)
	end
	return value
end

local function expectOptionalBoolean(value: any, context: string): boolean?
	if value == nil then
		return nil
	end
	return expectBoolean(value, context)
end

local function expectNumber(value: any, context: string): number
	if type(value) ~= "number" then
		fail(`expected {context} to be a number`)
	end
	if value ~= math.floor(value) then
		fail(`expected {context} to be an integer`)
	end
	return value
end

local function expectStringArray(value: any, context: string): { string }
	if type(value) ~= "table" then
		fail(`expected {context} to be an array of strings`)
	end
	local out = {}
	for i = 1, #value do
		out[i] = expectString((value :: any)[i], `{context}[{i}]`)
	end
	for key in value do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #value then
			fail(`expected {context} to be an array of strings`)
		end
	end
	return out
end

local function expectOptionalStringArray(value: any, context: string): { string }?
	if value == nil then
		return nil
	end
	return expectStringArray(value, context)
end

local function parseAuthors(value: any): { Author }?
	if value == nil then
		return nil
	end
	if type(value) ~= "table" then
		fail("expected eryx.project.authors to be an array of tables")
	end
	local authors = {}
	for i = 1, #value do
		local rawAuthor = expectTable((value :: any)[i], `eryx.project.authors[{i}]`)
		authors[i] = {
			name = expectString(rawAuthor.name, `eryx.project.authors[{i}].name`),
			email = expectOptionalString(rawAuthor.email, `eryx.project.authors[{i}].email`),
			url = expectOptionalString(rawAuthor.url, `eryx.project.authors[{i}].url`),
		}
	end
	for key in value do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #value then
			fail("expected eryx.project.authors to be an array of tables")
		end
	end
	return authors
end

local function parseProjectMetadata(value: any): ProjectMetadata
	local rawProject = expectTable(value, "eryx.project")
	return {
		name = expectString(rawProject.name, "eryx.project.name"),
		version = expectString(rawProject.version, "eryx.project.version"),
		private = expectOptionalBoolean(rawProject.private, "eryx.project.private"),
		description = expectOptionalString(rawProject.description, "eryx.project.description"),
		authors = parseAuthors(rawProject.authors),
		license = expectOptionalString(rawProject.license, "eryx.project.license"),
		licenseFile = expectOptionalString(rawProject["license-file"], "eryx.project.license-file"),
		keywords = expectOptionalStringArray(rawProject.keywords, "eryx.project.keywords"),
		sourceRoot = expectOptionalString(rawProject["source-root"], "eryx.project.source-root"),
	}
end

local function parseStringMap(value: any, context: string): { [string]: string }?
	if value == nil then
		return nil
	end
	local raw = expectTable(value, context)
	local out: { [string]: string } = {}
	for key, child in raw do
		if type(key) ~= "string" then
			fail(`expected {context} keys to be strings`)
		end
		out[key] = expectString(child, at(context, key))
	end
	return out
end

local function parseLinks(value: any): Links?
	local parsed = parseStringMap(value, "eryx.links")
	return parsed :: Links?
end

local function parseDependency(value: any, context: string): Dependency
	if type(value) == "string" then
		return value
	end
	local raw = expectTable(value, context)
	if raw.alias ~= nil then
		fail(`{context}.alias is not supported; the dependency table key is the alias`)
	end
	if raw.git then
		if raw.rev then
			return {
				git = expectString(raw.git, at(context, "git")),
				rev = expectString(raw.rev, at(context, "rev")),
			}
		end
		if raw.tag then
			return {
				git = expectString(raw.git, at(context, "git")),
				tag = expectString(raw.tag, at(context, "tag")),
			}
		end
		if raw.branch then
			return {
				git = expectString(raw.git, at(context, "git")),
				branch = expectString(raw.branch, at(context, "branch")),
			}
		end
		return fail(`git dependency {context} must specify exactly one of rev/tag/branch.`)
	elseif raw["local"] then
		return {
			["local"] = expectString(raw["local"], at(context, "local")),
		}
	elseif raw.path then
		return {
			path = expectString(raw.path, at(context, "path")),
		}
	elseif raw.url then
		return {
			url = expectString(raw.url, at(context, "url")),
			sha256 = expectOptionalString(raw.sha256, at(context, "sha256")),
		}
	elseif raw.repo then
		if raw.packageName ~= nil then
			fail(`{context}.packageName is not supported; use {context}.package instead`)
		end
		local ver: semver.Range? = nil
		local verStr = expectOptionalString(raw.version, at(context, "version"))
		if verStr then
			ver = semver.parseRange(verStr)
		end
		return {
			repo = expectString(raw.repo, at(context, "repo")),
			version = ver,
			package = expectOptionalString(raw.package, at(context, "package")),
		}
	end
	return fail(`expected {context} to be a version string or dependency source table`)
end

local function parseDependencies(value: any, context: string): Dependencies?
	if value == nil then
		return nil
	end
	local raw = expectTable(value, context)
	local out: Dependencies = {}
	for key, child in raw do
		if type(key) ~= "string" then
			fail(`expected {context} keys to be strings`)
		end
		out[key] = parseDependency(child, at(context, key))
	end
	return out
end

local function parseBuildTarget(value: any, context: string): BuildTarget
	local raw = expectTable(value, context)
	return {
		output = expectString(raw.output, at(context, "output")),
		entrypoint = expectString(raw.entrypoint, at(context, "entrypoint")),
		include = expectOptionalStringArray(raw.include, at(context, "include")),
		exclude = expectOptionalStringArray(raw.exclude, at(context, "exclude")),
		sourceExe = expectOptionalString(raw["source-exe"], at(context, "source-exe")),
	}
end

local function parseBuildTargets(value: any): { [string]: BuildTarget }?
	if value == nil then
		return nil
	end
	local raw = expectTable(value, "eryx.build")
	local out: { [string]: BuildTarget } = {}
	for key, child in raw do
		if type(key) ~= "string" then
			fail("expected eryx.build target names to be strings")
		end
		out[key] = parseBuildTarget(child, `eryx.build.{key}`)
	end
	return out
end

local function parseTestConfig(value: any): TestConfig?
	if value == nil then
		return nil
	end
	local raw = expectTable(value, "eryx.test")
	return {
		include = expectOptionalStringArray(raw.include, "eryx.test.include"),
		exclude = expectOptionalStringArray(raw.exclude, "eryx.test.exclude"),
	}
end

local function parseManifestTable(raw: { [any]: any }): Manifest
	local eryx = expectTable(raw.eryx, "eryx")
	return {
		manifestVersion = expectNumber(eryx["manifest-version"], "eryx.manifest-version"),
		project = parseProjectMetadata(eryx.project),
		links = parseLinks(eryx.links),
		scripts = parseStringMap(eryx.scripts, "eryx.scripts"),
		repositories = parseStringMap(eryx.repositories, "eryx.repositories"),
		dependencies = parseDependencies(eryx.dependencies, "eryx.dependencies"),
		devDependencies = parseDependencies(eryx["dev-dependencies"], "eryx.dev-dependencies"),
		build = parseBuildTargets(eryx.build),
		test = parseTestConfig(eryx.test),
		raw = raw,
	}
end

local function parseLockedDependencies(value: any, context: string): { LockedDependency }?
	if value == nil then
		return nil
	end
	if type(value) ~= "table" then
		fail(`expected {context} to be an array of dependency tables`)
	end
	local out = {}
	for i = 1, #value do
		local raw = expectTable((value :: any)[i], `{context}[{i}]`)
		out[i] = {
			name = expectString(raw.name, `{context}[{i}].name`),
			version = expectOptionalString(raw.version, `{context}[{i}].version`),
			source = expectOptionalString(raw.source, `{context}[{i}].source`),
		}
	end
	for key in value do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #value then
			fail(`expected {context} to be an array of dependency tables`)
		end
	end
	return out
end

local function parseLockedPackage(value: any, context: string): LockedPackage
	local raw = expectTable(value, context)
	return {
		name = expectString(raw.name, at(context, "name")),
		version = expectOptionalString(raw.version, at(context, "version")),
		source = expectOptionalString(raw.source, at(context, "source")),
		checksum = expectOptionalString(raw.checksum, at(context, "checksum")),
		rev = expectOptionalString(raw.rev, at(context, "rev")),
		dependencies = parseLockedDependencies(raw.dependencies, at(context, "dependencies")),
		raw = raw,
	}
end

local function parseLockTable(raw: { [any]: any }): Lockfile
	local lock = expectTable(raw.lock, "lock")
	local packagesValue = raw.package
	local packages = {}
	if packagesValue then
		if type(packagesValue) ~= "table" then
			fail("expected package to be an array of tables")
		end
		for i = 1, #packagesValue do
			packages[i] = parseLockedPackage((packagesValue :: any)[i], `package[{i}]`)
		end
	end
	return {
		version = expectNumber(lock.version, "lock.version"),
		eryxVersion = expectOptionalString(lock["eryx-version"], "lock.eryx-version"),
		generatedAt = expectOptionalString(lock["generated-at"], "lock.generated-at"),
		packages = packages,
		raw = raw,
	}
end

local function readFile(filePath: string): string
	return fs.openSync(filePath):readSync()
end

local function writeFile(filePath: string, source: string)
	fs.openSync(filePath, "w"):writeSync(source)
end

local function parentDir(filePath: string): string?
	local parent = path.dirname(filePath)
	if parent == nil then
		return nil
	end
	return tostring(parent)
end

local function joinPath(base: string, child: string): string
	return tostring(path.join(base, child))
end

local function parseDocument(source: string, filePath: string?): ManifestDocument
	local cst = toml.decodeCST(source)
	local raw = toml.cstToTable(cst)
	return {
		path = filePath,
		root = if filePath then parentDir(filePath) else nil,
		cst = cst,
		manifest = parseManifestTable(raw),
	}
end

local function parseLockDocument(source: string, filePath: string?): LockDocument
	local cst = toml.decodeCST(source)
	local raw = toml.cstToTable(cst)
	return {
		path = filePath,
		root = if filePath then parentDir(filePath) else nil,
		cst = cst,
		lockfile = parseLockTable(raw),
	}
end

--[=[
	Parse an `eryx.toml` source string.
]=]
function project.parse(source: string): ManifestDocument
	return parseDocument(source, nil)
end

--[=[
	Load an `eryx.toml` file. Defaults to `./eryx.toml`.
]=]
function project.load(filePath: string?): ManifestDocument
	local resolved = filePath or MANIFEST_FILENAME
	return parseDocument(readFile(resolved), resolved)
end

--[=[
	Find the nearest `eryx.toml`, searching upward from `start` or the current
	working directory. Returns nil when no project manifest is found.
]=]
function project.find(start: string?): string?
	local current = tostring(path.new(start or tostring(os.cwd())))
	while true do
		local candidate = joinPath(current, MANIFEST_FILENAME)
		if fs.isFile(candidate) then
			return candidate
		end
		local parent = path.dirname(current)
		if parent == nil then
			return nil
		end
		local parentString = tostring(parent)
		if parentString == current then
			return nil
		end
		current = parentString
	end
end

--[=[
	Load the nearest project manifest, searching upward from `start` or the
	current working directory.
]=]
function project.loadNearest(start: string?): ManifestDocument?
	local manifestPath = project.find(start)
	if manifestPath == nil then
		return nil
	end
	return project.load(manifestPath)
end

--[=[
	Return a third-party `[tool.<name>]` table from a parsed manifest document.
	The returned value is read from the CST-backed document so callers can inspect
	the exact currently loaded config without Eryx validating that tool's schema.
]=]
function project.getTool(document: ManifestDocument, name: string): any
	local tool = document.cst.tool
	if type(tool) ~= "table" then
		return nil
	end
	return (tool :: any)[name]
end

--[=[
	Encode a manifest document. Unchanged CST documents round-trip exactly;
	changed CST documents preserve as much source formatting as the TOML CST
	encoder can patch.
]=]
function project.encode(document: ManifestDocument): string
	return toml.encode(document.cst)
end

--[=[
	Write a manifest document to disk. Defaults to the path it was loaded from,
	or `./eryx.toml` for documents created from a string.
]=]
function project.save(document: ManifestDocument, filePath: string?)
	writeFile(filePath or document.path or MANIFEST_FILENAME, project.encode(document))
end

--[=[
	Parse an `eryx.lock` source string.
]=]
function lock.parse(source: string): LockDocument
	return parseLockDocument(source, nil)
end

--[=[
	Load an `eryx.lock` file. If `rootOrPath` is a directory, `eryx.lock` inside
	that directory is loaded. If it is a file path, that file is loaded.
]=]
function lock.load(rootOrPath: string?): LockDocument
	local resolved = rootOrPath or LOCK_FILENAME
	if fs.isDirectory(resolved) then
		resolved = joinPath(resolved, LOCK_FILENAME)
	end
	return parseLockDocument(readFile(resolved), resolved)
end

--[=[
	Return whether a lockfile exists for a project root.
]=]
function lock.exists(root: string?): boolean
	local lockPath = if root then joinPath(root, LOCK_FILENAME) else LOCK_FILENAME
	return fs.isFile(lockPath)
end

--[=[
	Encode a lockfile document.
]=]
function lock.encode(document: LockDocument): string
	return toml.encode(document.cst)
end

--[=[
	Write a lockfile document to disk. Defaults to the path it was loaded from,
	or `./eryx.lock` for documents created from a string.
]=]
function lock.save(document: LockDocument, filePath: string?)
	writeFile(filePath or document.path or LOCK_FILENAME, lock.encode(document))
end

project.lock = table.freeze(lock)

return table.freeze(project)
