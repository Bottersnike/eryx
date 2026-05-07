local fs = require("@eryx/fs")
local os = require("@eryx/os")
local path = require("@eryx/path")
local lockfile = require("@eryx/package/lockfile")
local project = require("@eryx/project")
local stdio = require("@eryx/stdio")

local args = os.cliargs()
local name = args[1]

if not name then
	stdio.writeerr("Usage: eryx run <script> [args...]\n")
	os.exit(1)
end

local function hasPathSyntax(value: string): boolean
	return value:find("/", 1, true) ~= nil or value:find("\\", 1, true) ~= nil or value:find(".", 1, true) ~= nil
end

local function tailArgs(startIndex: number): { string }
	local out = {}
	for i = startIndex, #args do
		table.insert(out, args[i])
	end
	return out
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

local function quotePosix(value: string): string
	return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function quoteWindows(value: string): string
	if value == "" then
		return '""'
	end

	local needsQuotes = value:find('[%s"]') ~= nil
	if not needsQuotes then
		return (value:gsub("([%%%^&|<>()])", "^%1"))
	end

	local out = { '"' }
	local backslashes = 0
	for i = 1, #value do
		local ch = value:sub(i, i)
		if ch == "\\" then
			backslashes += 1
		elseif ch == '"' then
			table.insert(out, string.rep("\\", backslashes * 2 + 1))
			table.insert(out, '"')
			backslashes = 0
		else
			if backslashes > 0 then
				table.insert(out, string.rep("\\", backslashes))
				backslashes = 0
			end
			table.insert(out, ch)
		end
	end
	if backslashes > 0 then
		table.insert(out, string.rep("\\", backslashes * 2))
	end
	table.insert(out, '"')

	return (table.concat(out):gsub("([%%%^&|<>()])", "^%1"))
end

local function quoteArg(value: string): string
	if os.platform() == "windows" then
		return quoteWindows(value)
	end
	return quotePosix(value)
end

local function runFile(scriptPath: string, scriptArgs: { string }, cwd: string?)
	local exe = os.getenv("ERYX_EXE_PATH") or "eryx"
	local childArgs = { exe, "__run-file", scriptPath }
	for _, arg in scriptArgs do
		table.insert(childArgs, arg)
	end

	local parts = {}
	for _, arg in childArgs do
		table.insert(parts, quoteArg(arg))
	end

	os.exit(os.shell(table.concat(parts, " "), { cwd = cwd }))
end

type ScriptMatch = {
	owner: string,
	manifestPath: string,
	packageRoot: string,
	scriptPath: string,
}

local function dependencyWorkspaceName(alias: string, dep: project.Dependency): string
	if type(dep) == "table" and (dep :: any).repo then
		return ((dep :: any).package or alias) :: string
	end

	return alias
end

local function packageRootForDirectDependency(root: string, lock: any, alias: string): string?
	if lock then
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
	end

	return nil
end

local function findDependencyScript(doc: project.ManifestDocument, scriptName: string): ScriptMatch?
	local root = projectRoot(doc)
	local lock = lockfile.load(root)

	local matches: { ScriptMatch } = {}
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
			local scriptRel = depDoc.manifest.scripts and depDoc.manifest.scripts[scriptName]
			if not scriptRel then
				continue
			end

			table.insert(matches, {
				owner = alias,
				manifestPath = manifestPath,
				packageRoot = packageRoot,
				scriptPath = join(packageRoot, scriptRel),
			})
		end
	end

	scan(doc.manifest.dependencies)
	scan(doc.manifest.devDependencies)

	if #matches == 0 then
		return nil
	end

	if #matches > 1 then
		local owners = {}
		for _, match in matches do
			table.insert(owners, match.owner)
		end

		stdio.writeerr(
			`Script '{scriptName}' is defined by multiple direct dependencies: {table.concat(owners, ", ")}\n`
		)
		os.exit(1)
	end

	return matches[1]
end

if hasPathSyntax(name) or fs.isFile(name) then
	runFile(name, tailArgs(2), nil)
end

local doc = project.loadNearest()
if doc and doc.manifest.scripts and doc.manifest.scripts[name] then
	local root = projectRoot(doc)
	local scriptPath = join(root, doc.manifest.scripts[name])
	if not fs.isFile(scriptPath) then
		stdio.writeerr(`Project script '{name}' points to missing file: {scriptPath}\n`)
		os.exit(1)
	end

	runFile(scriptPath, tailArgs(2), root)
end

if doc then
	local dependencyScript = findDependencyScript(doc, name)
	if dependencyScript then
		if not fs.isFile(dependencyScript.scriptPath) then
			stdio.writeerr(
				`Dependency script '{name}' from '{dependencyScript.owner}' points to missing file: {dependencyScript.scriptPath}\n`
			)
			os.exit(1)
		end

		runFile(dependencyScript.scriptPath, tailArgs(2), projectRoot(doc))
	end
end

if fs.isFile(name) then
	runFile(name, tailArgs(2), nil)
end

if doc then
	stdio.writeerr(`No project script named '{name}' in {doc.path or "eryx.toml"}\n`)
else
	stdio.writeerr(`No project found and script file does not exist: {name}\n`)
end
os.exit(1)
