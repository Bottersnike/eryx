local fs = require("@eryx/fs")
local os = require("@eryx/os")
local path = require("@eryx/path")
local lockfile = require("@eryx/package/lockfile")
local project = require("@eryx/project")
local stdio = require("@eryx/stdio")

local FORWARDED_RUNTIME_ARGS_ENV = "ERYX_FORWARD_RUNTIME_ARGS"
local RUNTIME_USAGE = "[-O0|-O1|-O2] [--native|--no-native|--native-only-specified]"

type RuntimeCliOptions = {
	optimizationLevel: number?,
	nativeMode: "all" | "disabled" | "only-specified"?,
}

type ParsedRuntimeCli = {
	options: RuntimeCliOptions,
	nextIndex: number,
}

type ParsedRunCli = {
	help: boolean,
	helpScripts: boolean,
	nextIndex: number,
}

type ScriptMatch = {
	owner: string,
	manifestPath: string,
	packageRoot: string,
	scriptPath: string,
}

type ResolvedScript = {
	path: string,
	cwd: string?,
}

local args = os.cliargs()
local SCRIPT_ARGS_START_INDEX = 2

local function writeln(text: string)
	stdio.writeSync(text .. "\n")
end

local function fail(message: string): never
	stdio.writeerrSync(message .. "\n")
	os.exit(1)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function parseRuntimeCli(arguments: { string }, startIndex: number): ParsedRuntimeCli
	local options: RuntimeCliOptions = {}
	local i = startIndex

	while i <= #arguments do
		local arg = arguments[i]
		if arg == "--" then
			i += 1
			break
		end

		if arg == "-O0" or arg == "-O1" or arg == "-O2" then
			options.optimizationLevel = tonumber(arg:sub(3)) :: number
			i += 1
			continue
		end

		if arg == "--native" then
			options.nativeMode = "all"
			i += 1
			continue
		end

		if arg == "--no-native" then
			options.nativeMode = "disabled"
			i += 1
			continue
		end

		if arg == "--native-only-specified" then
			options.nativeMode = "only-specified"
			i += 1
			continue
		end

		if arg:sub(1, 2) == "-O" then
			fail(`Unsupported optimization level '{arg}' (expected -O0, -O1, or -O2)`)
		end

		break
	end

	return {
		options = options,
		nextIndex = i,
	}
end

local function parseRunCli(arguments: { string }, startIndex: number): ParsedRunCli
	local parsed: ParsedRunCli = {
		help = false,
		helpScripts = false,
		nextIndex = startIndex,
	}

	while parsed.nextIndex <= #arguments do
		local arg = arguments[parsed.nextIndex]
		if arg == "--" then
			parsed.nextIndex += 1
			break
		end

		if arg == "-h" or arg == "--help" then
			parsed.help = true
			parsed.nextIndex += 1
			return parsed
		end

		if arg == "--help-scripts" then
			parsed.helpScripts = true
			parsed.nextIndex += 1
			return parsed
		end

		break
	end

	return parsed
end

local function splitForwardedRuntimeArgs(value: string?): { string }
	local out = {}
	if not value or value == "" then
		return out
	end

	for line in value:gmatch("[^\n]+") do
		table.insert(out, line)
	end

	return out
end

local function mergeRuntimeCliOptions(base: RuntimeCliOptions, override: RuntimeCliOptions): RuntimeCliOptions
	return {
		optimizationLevel = if override.optimizationLevel ~= nil
			then override.optimizationLevel
			else base.optimizationLevel,
		nativeMode = if override.nativeMode ~= nil then override.nativeMode else base.nativeMode,
	}
end

local function renderRuntimeCliArgs(options: RuntimeCliOptions): { string }
	local out = {}
	if options.optimizationLevel ~= nil then
		table.insert(out, `-O{options.optimizationLevel}`)
	end

	if options.nativeMode == "disabled" then
		table.insert(out, "--no-native")
	elseif options.nativeMode == "only-specified" then
		table.insert(out, "--native-only-specified")
	elseif options.nativeMode == "all" then
		table.insert(out, "--native")
	end

	return out
end

local function tailArgs(startIndex: number): { string }
	local out = {}
	for i = startIndex, #args do
		table.insert(out, args[i])
	end
	return out
end

local function hasPathSyntax(value: string): boolean
	return value:find("/", 1, true) ~= nil or value:find("\\", 1, true) ~= nil or value:find(".", 1, true) ~= nil
end

local function join(root: string, child: string): string
	return tostring(path.join(root, child))
end

local function projectRoot(doc: project.ManifestDocument): string
	return doc.root or tostring(os.cwd())
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

local function dependencyWorkspaceName(alias: string, dep: project.Dependency): string
	if type(dep) == "table" and (dep :: any).repo then
		return ((dep :: any).package or alias) :: string
	end

	return alias
end

local function packageRootForDirectDependency(root: string, lock: any, alias: string): string?
	if not lock then
		return nil
	end

	for _, edges in { lock.roots, lock.devRoots or {} } do
		for _, edge in edges do
			if edge.alias ~= alias then
				continue
			end

			local pkg = lock.packages[edge.target]
			if not pkg then
				return nil
			end

			if pkg.type == "workspace" then
				return pkg.data.path
			end
			if pkg.installName then
				return join(join(root, "eryx_packages"), pkg.installName)
			end

			return nil
		end
	end

	return nil
end

local function collectDependencyScriptMatches(doc: project.ManifestDocument): { [string]: { ScriptMatch } }
	local root = projectRoot(doc)
	local lock = lockfile.load(root)
	local matchesByName: { [string]: { ScriptMatch } } = {}

	local function addMatch(name: string, match: ScriptMatch)
		local matches = matchesByName[name]
		if not matches then
			matches = {}
			matchesByName[name] = matches
		end
		table.insert(matches, match)
	end

	local function scan(deps: project.Dependencies?)
		for alias, dep in deps or {} do
			local workspaceName = dependencyWorkspaceName(alias, dep)
			local workspacePath = doc.manifest.workspace and doc.manifest.workspace[workspaceName]
			local packageRoot = if workspacePath
				then resolveWorkspacePath(root, workspacePath)
				else packageRootForDirectDependency(root, lock, alias)
			if packageRoot == nil then
				continue
			end

			local manifestPath = join(packageRoot, "eryx.toml")
			if not fs.isFile(manifestPath) then
				continue
			end

			local depDoc = project.load(manifestPath)
			local scripts = depDoc.manifest.scripts
			if not scripts then
				continue
			end

			for scriptName, scriptRel in scripts do
				addMatch(scriptName, {
					owner = alias,
					manifestPath = manifestPath,
					packageRoot = packageRoot,
					scriptPath = join(packageRoot, scriptRel),
				})
			end
		end
	end

	scan(doc.manifest.dependencies)
	scan(doc.manifest.devDependencies)

	return matchesByName
end

local function resolveDependencyScript(doc: project.ManifestDocument, scriptName: string): ScriptMatch?
	local matches = collectDependencyScriptMatches(doc)[scriptName]
	if not matches or #matches == 0 then
		return nil
	end

	if #matches > 1 then
		local owners = {}
		for _, match in matches do
			table.insert(owners, match.owner)
		end
		table.sort(owners)
		fail(`Script '{scriptName}' is defined by multiple direct dependencies: {table.concat(owners, ", ")}`)
	end

	return matches[1]
end

local function printRunHelp()
	local lines = {
		`Usage: eryx run {RUNTIME_USAGE} [--help|--help-scripts] <script> [args...]`,
		"",
		"Resolves and runs a script by file path, project script name, or direct dependency script name.",
		"",
		"Options:",
		"  -h, --help                   Show this help text",
		"  --help-scripts               List project and direct dependency scripts",
		"  -O0, -O1, -O2                Set Luau optimization level",
		"  --native                     Enable native codegen for all eligible chunks",
		"  --no-native                  Disable native codegen",
		"  --native-only-specified      Only native-compile chunks marked with --!native",
		"",
		"Use -- before the script name if it begins with -.",
	}

	for _, line in lines do
		writeln(line)
	end
end

local function printAvailableScripts(doc: project.ManifestDocument)
	local root = projectRoot(doc)
	writeln(`Scripts available for {doc.path or join(root, "eryx.toml")}:`)

	local projectScripts = doc.manifest.scripts or {}
	local projectKeys = sortedKeys(projectScripts)
	writeln("")
	writeln("Project scripts:")
	if #projectKeys == 0 then
		writeln("  (none)")
	else
		for _, scriptName in projectKeys do
			writeln(`  {scriptName} -> {projectScripts[scriptName]}`)
		end
	end

	local dependencyScripts = collectDependencyScriptMatches(doc)
	local dependencyKeys = sortedKeys(dependencyScripts)
	writeln("")
	writeln("Direct dependency scripts:")
	if #dependencyKeys == 0 then
		writeln("  (none)")
	else
		for _, scriptName in dependencyKeys do
			local owners = {}
			for _, match in dependencyScripts[scriptName] do
				table.insert(owners, match.owner)
			end
			table.sort(owners)
			writeln(`  {scriptName} ({table.concat(owners, ", ")})`)
		end
	end
end

local function launchResolvedScript(resolved: ResolvedScript, scriptArgs: { string }, runtimeArgs: { string })
	local exe = os.getenv("ERYX_EXE_PATH") or "eryx"
	local childArgs = {}

	for _, arg in runtimeArgs do
		table.insert(childArgs, arg)
	end
	table.insert(childArgs, resolved.path)
	for _, arg in scriptArgs do
		table.insert(childArgs, arg)
	end

	local result = os.exec(exe, childArgs, {
		cwd = resolved.cwd,
		inheritStdio = true,
	})
	os.exit(result.code)
end

local function resolveScript(name: string, doc: project.ManifestDocument?): ResolvedScript?
	if hasPathSyntax(name) or fs.isFile(name) then
		return {
			path = name,
			cwd = nil,
		}
	end

	if not doc then
		return nil
	end

	local root = projectRoot(doc)
	local projectScripts = doc.manifest.scripts
	if projectScripts and projectScripts[name] then
		local scriptPath = join(root, projectScripts[name])
		if not fs.isFile(scriptPath) then
			fail(`Project script '{name}' points to missing file: {scriptPath}`)
		end
		return {
			path = scriptPath,
			cwd = root,
		}
	end

	local dependencyScript = resolveDependencyScript(doc, name)
	if dependencyScript then
		if not fs.isFile(dependencyScript.scriptPath) then
			fail(
				`Dependency script '{name}' from '{dependencyScript.owner}' points to missing file: {dependencyScript.scriptPath}`
			)
		end
		return {
			path = dependencyScript.scriptPath,
			cwd = root,
		}
	end

	return nil
end

local inheritedRuntimeOptions =
	parseRuntimeCli(splitForwardedRuntimeArgs(os.getenv(FORWARDED_RUNTIME_ARGS_ENV)), 1).options
local parsedRuntimeCli = parseRuntimeCli(args, SCRIPT_ARGS_START_INDEX)
local parsedRunCli = parseRunCli(args, parsedRuntimeCli.nextIndex)
local effectiveRuntimeOptions = mergeRuntimeCliOptions(inheritedRuntimeOptions, parsedRuntimeCli.options)
local runtimeArgs = renderRuntimeCliArgs(effectiveRuntimeOptions)
local nameIndex = parsedRunCli.nextIndex
local name = args[nameIndex]
local scriptArgs = tailArgs(nameIndex + 1)

if parsedRunCli.help then
	printRunHelp()
	os.exit(0)
end

local doc = project.loadNearest()
if parsedRunCli.helpScripts then
	if not doc then
		fail("No project found and there are no scripts to list")
	end
	printAvailableScripts(doc)
	os.exit(0)
end

if not name then
	printRunHelp()
	os.exit(1)
end

local resolved = resolveScript(name, doc)
if resolved then
	launchResolvedScript(resolved, scriptArgs, runtimeArgs)
end

if doc then
	fail(`No project script named '{name}' in {doc.path or "eryx.toml"}`)
else
	fail(`No project found and script file does not exist: {name}`)
end
