local fs = require("@eryx/fs")
local luau = require("@eryx/luau")
local extract = require("../extract")

export type ModuleClass = {}
export type ModuleFunction = {}
export type ModuleType = {}
export type ModuleConstant = {}

export type ModuleInfo = {
	name: string, -- e.g. "_socket"
	qualifiedName: string, -- e.g. "@eryx/_socket"
	filename: string, -- e.g. "_socket.luau"
	description: string?,
	moduleRoot: string?, -- e.g. "fs" — the returned table name, for stripping owner prefixes

	primaryExport: extract.TypeDoc?,
	classes: { extract.TypeDoc },
	functions: { extract.FuncDoc },
	types: { extract.TypeDoc },
	constants: { extract.ConstDoc },
}

local function parseModule(path: string, prefix: string, relPath: string): ModuleInfo
	local baseName = fs.path.stem(path)

	-- Build qualified name: init.luau -> parent folder name, others -> parent/name
	local qualifiedName: string
	local importName: string
	local htmlFilename: string

	if baseName == "init" then
		-- init.luau represents the folder module itself
		qualifiedName = prefix
		importName = if relPath ~= "" then relPath:gsub("/", ".") else baseName
		htmlFilename = if relPath ~= "" then relPath:gsub("/", "_") .. ".html" else "init.html"
	else
		qualifiedName = prefix .. "/" .. baseName
		local fullRel = if relPath ~= "" then relPath .. "/" .. baseName else baseName
		importName = fullRel:gsub("/", ".")
		htmlFilename = fullRel:gsub("/", "_") .. ".html"
	end

	print(string.format("Processing %s ...", qualifiedName))

	-- Read & Parse
	local source = fs.openSync(path):readSync()
	local result = luau.parse(source, { captureComments = true })

	if #result.errors > 0 then
		print(string.format("  %s: %d parse errors", path, #result.errors))
		for _, err in result.errors do
			print(string.format("    [%d:%d] %s", err.location.start.line, err.location.start.column, err.message))
		end
		error("")
	end

	-- Extract
	local sourceLines: { string } = string.split(source, "\n")
	local data = extract.extract(result, sourceLines)

	local types = {}
	local classes = {}

	-- Split types into classes as types (exported only)
	local primaryExport: extract.TypeDoc? = nil
	for _, typeDoc in data.types do
		if typeDoc.isPrimaryExport then
			primaryExport = typeDoc
			continue
		end

		if not typeDoc.exported then
			continue
		end
		local hasMethods = false
		if typeDoc.members then
			for _, i in typeDoc.members do
				if i.params then
					hasMethods = true
					break
				end
			end
		end

		if hasMethods then
			table.insert(classes, typeDoc)
		else
			table.insert(types, typeDoc)
		end
	end

	-- Collect info for index
	return {
		name = importName,
		qualifiedName = qualifiedName,
		filename = htmlFilename,
		description = data.moduleDescription,
		moduleRoot = data.moduleRoot,

		primaryExport = primaryExport,
		classes = classes,
		functions = data.functions,
		types = types,
		constants = data.constants,
	}
end

-- Recursively collect .luau modules from a directory.
-- @param dir       Absolute filesystem path to scan
-- @param prefix    Qualified name prefix (e.g. "@eryx" or "@eryx/encoding")
-- @param relPath   Relative path fragment for flat filenames (e.g. "" or "encoding")
local function collectModules(dir: string, prefix: string, relPath: string): { ModuleInfo }
	local modules: { ModuleInfo } = {}

	local entries = fs.listDir(dir)
	table.sort(entries)

	-- Separate into init, other .luau files, and directories for proper ordering
	local initEntry: string? = nil
	local luauFiles: { string } = {}
	local dirs: { string } = {}

	for _, entry in entries do
		local fullPath = dir .. "/" .. entry
		if fs.isDirectory(fullPath) then
			table.insert(dirs, entry)
		elseif entry == "init.luau" then
			initEntry = entry
		elseif entry:match("%.luau$") and not entry:match("%.test%.luau$") then
			table.insert(luauFiles, entry)
		end
	end

	-- Process in order: init first (parent module), then sibling files, then subdirectories
	local ordered: { string } = {}
	if initEntry then
		table.insert(ordered, initEntry)
	end
	for _, f in luauFiles do
		table.insert(ordered, f)
	end

	for _, entry in ordered do
		local fullPath = dir .. "/" .. entry

		local module = parseModule(fullPath, prefix, relPath)
		table.insert(modules, module)
	end

	-- Recurse into subdirectories after processing files at this level
	for _, entry in dirs do
		local fullPath = dir .. "/" .. entry
		local subRel = if relPath ~= "" then relPath .. "/" .. entry else entry
		local subMod = collectModules(fullPath, prefix .. "/" .. entry, subRel)
		for _, i in subMod do
			table.insert(modules, i)
		end
		-- for _, i in subEntries do
		-- 	table.insert(moduleEntries, i)
		-- end
	end

	return modules
end

return {
	collectModules = collectModules,
	parseModule = parseModule,
}
