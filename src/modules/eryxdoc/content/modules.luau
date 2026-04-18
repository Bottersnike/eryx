local fs = require("@eryx/fs")
local logging = require("@eryx/logging")
local luau = require("@eryx/luau")
local extract = require("../extract")

local log = logging.getLogger("eryxdoc.content.modules")

export type ModuleClass = {}
export type ModuleFunction = {}
export type ModuleType = {}
export type ModuleConstant = {}

export type ModuleInfo = {
	name: string, -- e.g. "_socket"
	qualifiedName: string, -- e.g. "@eryx/_socket"
	filename: string, -- e.g. "_socket.luau"
	description: string?,
	moduleRoot: string?, -- e.g. "fs" - the returned table name, for stripping owner prefixes

	primaryExport: extract.TypeDoc?,
	classes: { extract.TypeDoc },
	functions: { extract.FuncDoc },
	types: { extract.TypeDoc },
	constants: { extract.ConstDoc },
}

type ReExportBinding = {
	exportedName: string,
	exportedOwner: string?,
	sourceModule: string,
	sourcePath: string,
	line: number,
}

type ParsedModule = {
	module: ModuleInfo,
	ignoreModule: boolean,
	reexports: { ReExportBinding },
}

local function splitPath(path: string): { string }
	local parts = {}
	for part in path:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

local function joinPath(parts: { string }): string
	return table.concat(parts, "/")
end

local function moduleDirFromQualified(qualifiedName: string): string
	local idx = qualifiedName:match("^.*()/")
	if idx then
		return qualifiedName:sub(1, idx - 1)
	end
	return qualifiedName
end

local function resolveRequireSpecifier(moduleDir: string, specifier: string): string?
	if specifier == "@self" then
		return moduleDir
	end
	if specifier:sub(1, 6) == "@self/" then
		return moduleDir .. "/" .. specifier:sub(7)
	end
	if specifier:sub(1, 1) == "@" then
		return specifier
	end
	if specifier:sub(1, 1) ~= "." then
		return nil
	end

	local baseParts = splitPath(moduleDir)
	for token in specifier:gmatch("[^/]+") do
		if token == "." then
			continue
		end
		if token == ".." then
			if #baseParts > 0 then
				table.remove(baseParts)
			end
			continue
		end
		table.insert(baseParts, token)
	end

	return joinPath(baseParts)
end

local function exprToPath(expr: luau.AstExpr): string?
	if expr.type == "ExprGlobal" then
		return (expr :: luau.ExprGlobal).name
	end
	if expr.type == "ExprLocal" then
		local loc = expr :: luau.ExprLocal
		return if loc["local"] then loc["local"].name else nil
	end
	if expr.type == "ExprIndexName" then
		local idx = expr :: luau.ExprIndexName
		local parent = exprToPath(idx.expr)
		if parent then
			return parent .. "." .. idx.index
		end
	end
	return nil
end

local function parseRequireCall(expr: luau.AstExpr): string?
	if expr.type ~= "ExprCall" then
		return nil
	end

	local call = expr :: luau.ExprCall
	if not call.func or call.func.type ~= "ExprGlobal" then
		return nil
	end
	local callee = call.func :: luau.ExprGlobal
	if callee.name ~= "require" then
		return nil
	end

	if not call.args or #call.args < 1 then
		return nil
	end
	local first = call.args[1]
	if first.type ~= "ExprConstantString" then
		return nil
	end

	return (first :: luau.ExprConstantString).value
end

local function hasMethods(typeDoc: extract.TypeDoc): boolean
	if not typeDoc.members then
		return false
	end
	for _, member in typeDoc.members do
		if member.params then
			return true
		end
	end
	return false
end

local function deepCopy(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end

	local memo = seen or {}
	local existing = memo[value]
	if existing ~= nil then
		return existing
	end

	local out = {}
	memo[value] = out
	for k, v in value do
		out[deepCopy(k, memo)] = deepCopy(v, memo)
	end
	return out
end

local function rewriteFunctionIdentity(func: extract.FuncDoc, newName: string, newOwner: string?)
	local oldName = func.name
	local oldOwner = func.owner

	func.name = newName
	func.owner = newOwner

	local oldPrefix = (if oldOwner then oldOwner .. (if func.isMethod then ":" else ".") else "") .. oldName
	local newPrefix = (if newOwner then newOwner .. (if func.isMethod then ":" else ".") else "") .. newName

	if func.signature and func.signature:sub(1, #oldPrefix) == oldPrefix then
		func.signature = newPrefix .. func.signature:sub(#oldPrefix + 1)
	end
	if func.signatureFull and func.signatureFull:sub(1, #oldPrefix) == oldPrefix then
		func.signatureFull = newPrefix .. func.signatureFull:sub(#oldPrefix + 1)
	end

	if func.signatureParts then
		local parts = func.signatureParts
		if oldOwner then
			if #parts >= 3 then
				if newOwner then
					parts[1].text = newOwner
				end
				parts[3].text = newName
			end
		elseif #parts >= 1 then
			parts[1].text = newName
		end
	end

	if func.signatureMeta then
		func.signatureMeta.name = newName
		func.signatureMeta.owner = newOwner
	end
end

local function functionKey(owner: string?, name: string): string
	return (owner or "") .. "::" .. name
end

local function typeKey(name: string): string
	return name
end

local function constantKey(owner: string?, name: string): string
	return (owner or "") .. "::" .. name
end

local function findFunctionBySourcePath(mod: ModuleInfo, sourcePath: string): extract.FuncDoc?
	local segments = string.split(sourcePath, ".")
	if #segments == 0 then
		return nil
	end
	local wantedName = segments[#segments]
	local wantedOwner = if #segments > 1 then table.concat(segments, ".", 1, #segments - 1) else nil

	local best: extract.FuncDoc? = nil
	local bestScore = -1
	for _, f in mod.functions do
		if f.name ~= wantedName then
			continue
		end

		local score = 10
		if wantedOwner then
			if f.owner == wantedOwner then
				score += 20
			elseif mod.moduleRoot and f.owner == mod.moduleRoot .. "." .. wantedOwner then
				score += 18
			elseif mod.moduleRoot and wantedOwner == mod.moduleRoot and f.owner == mod.moduleRoot then
				score += 20
			else
				continue
			end
		else
			if f.owner == nil then
				score += 5
			elseif mod.moduleRoot and f.owner == mod.moduleRoot then
				score += 4
			end
		end

		if score > bestScore then
			best = f
			bestScore = score
		end
	end

	return best
end

local function findConstantBySourcePath(mod: ModuleInfo, sourcePath: string): extract.ConstDoc?
	local segments = string.split(sourcePath, ".")
	if #segments == 0 then
		return nil
	end
	local wantedName = segments[#segments]
	local wantedOwner = if #segments > 1 then table.concat(segments, ".", 1, #segments - 1) else nil

	local best: extract.ConstDoc? = nil
	local bestScore = -1
	for _, c in mod.constants do
		if c.name ~= wantedName then
			continue
		end

		local score = 10
		if wantedOwner then
			if c.owner == wantedOwner then
				score += 20
			elseif mod.moduleRoot and c.owner == mod.moduleRoot .. "." .. wantedOwner then
				score += 18
			elseif mod.moduleRoot and wantedOwner == mod.moduleRoot and c.owner == mod.moduleRoot then
				score += 20
			else
				continue
			end
		else
			if c.owner == nil then
				score += 5
			elseif mod.moduleRoot and c.owner == mod.moduleRoot then
				score += 4
			end
		end

		if score > bestScore then
			best = c
			bestScore = score
		end
	end

	return best
end

local function findTypeBySourcePath(mod: ModuleInfo, sourcePath: string): extract.TypeDoc?
	if sourcePath:find(".", 1, true) then
		return nil
	end

	if mod.primaryExport and mod.primaryExport.name == sourcePath then
		return mod.primaryExport
	end
	for _, cls in mod.classes do
		if cls.name == sourcePath then
			return cls
		end
	end
	for _, t in mod.types do
		if t.name == sourcePath then
			return t
		end
	end

	return nil
end

local function hasFunction(module: ModuleInfo, owner: string?, name: string): boolean
	for _, f in module.functions do
		if f.name == name and f.owner == owner then
			return true
		end
	end
	return false
end

local function hasConstant(module: ModuleInfo, owner: string?, name: string): boolean
	for _, c in module.constants do
		if c.name == name and c.owner == owner then
			return true
		end
	end
	return false
end

local function hasType(module: ModuleInfo, name: string): boolean
	if module.primaryExport and module.primaryExport.name == name then
		return true
	end
	for _, cls in module.classes do
		if cls.name == name then
			return true
		end
	end
	for _, t in module.types do
		if t.name == name then
			return true
		end
	end
	return false
end

local function parseModuleDetailed(path: string, prefix: string, relPath: string): ParsedModule
	local baseName = fs.path.stem(path)

	local qualifiedName: string
	local importName: string
	local htmlFilename: string

	if baseName == "init" then
		qualifiedName = prefix
		importName = if relPath ~= "" then relPath:gsub("/", ".") else baseName
		htmlFilename = if relPath ~= "" then relPath:gsub("/", "_") .. ".html" else "init.html"
	else
		qualifiedName = prefix .. "/" .. baseName
		local fullRel = if relPath ~= "" then relPath .. "/" .. baseName else baseName
		importName = fullRel:gsub("/", ".")
		htmlFilename = fullRel:gsub("/", "_") .. ".html"
	end

	log:info(string.format("Processing %s ...", qualifiedName))

	local source = fs.openSync(path):readSync()
	local result = luau.parse(source, { captureComments = true })

	if #result.errors > 0 then
		log:error(string.format("  %s: %d parse errors", path, #result.errors))
		for _, err in result.errors do
			log:error(string.format("    [%d:%d] %s", err.location.beginline, err.location.begincolumn, err.message))
		end
		error("")
	end

	local sourceLines: { string } = string.split(source, "\n")
	local data = extract.extract(result, sourceLines)

	local types = {}
	local classes = {}
	local primaryExport: extract.TypeDoc? = nil

	for _, typeDoc in data.types do
		if typeDoc.isPrimaryExport then
			primaryExport = typeDoc
			continue
		end
		if not typeDoc.exported then
			continue
		end

		if hasMethods(typeDoc) then
			table.insert(classes, typeDoc)
		else
			table.insert(types, typeDoc)
		end
	end

	local moduleInfo: ModuleInfo = {
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

	local ignoreModule = false
	if moduleInfo.description then
		for _, line in moduleInfo.description:split("\n") do
			if line:sub(1, 7) == "@ignore" then
				ignoreModule = true
			end
		end
	end

	local localRequires: { [string]: string } = {}
	local selfRequireBase = if baseName == "init" then qualifiedName else moduleDirFromQualified(qualifiedName)
	for _, stat in result.root.body do
		if stat.type ~= "StatLocal" then
			continue
		end
		local localStat = stat :: luau.StatLocal
		if not localStat.vars or not localStat.values then
			continue
		end
		for i, varNode in localStat.vars do
			local value = localStat.values[i]
			if not value or not varNode.name then
				continue
			end
			local specifier = parseRequireCall(value)
			if not specifier then
				continue
			end
			local resolved = resolveRequireSpecifier(selfRequireBase, specifier)
			if resolved then
				localRequires[varNode.name] = resolved
			end
		end
	end

	local reexports: { ReExportBinding } = {}
	local moduleRoot = moduleInfo.moduleRoot
	if moduleRoot then
		for _, stat in result.root.body do
			if stat.type ~= "StatAssign" then
				continue
			end
			local assignStat = stat :: luau.StatAssign
			if not assignStat.vars or not assignStat.values then
				continue
			end

			for i, var in assignStat.vars do
				if var.type ~= "ExprIndexName" then
					continue
				end

				local idx = var :: luau.ExprIndexName
				local exportedOwner = exprToPath(idx.expr)
				if not exportedOwner then
					continue
				end
				if exportedOwner ~= moduleRoot and exportedOwner:sub(1, #moduleRoot + 1) ~= moduleRoot .. "." then
					continue
				end

				local value = assignStat.values[i]
				if not value then
					continue
				end

				local rhsPath = exprToPath(value)
				if not rhsPath then
					continue
				end

				local rootName, rest = rhsPath:match("^([^.]+)%.(.+)$")
				if not rootName or not rest then
					continue
				end

				local sourceModule = localRequires[rootName]
				if not sourceModule then
					continue
				end

				table.insert(reexports, {
					exportedName = idx.index,
					exportedOwner = exportedOwner,
					sourceModule = sourceModule,
					sourcePath = rest,
					line = stat.location.beginline,
				})
			end
		end
	end

	return {
		module = moduleInfo,
		ignoreModule = ignoreModule,
		reexports = reexports,
	}
end

local function parseModule(path: string, prefix: string, relPath: string): ModuleInfo
	return parseModuleDetailed(path, prefix, relPath).module
end

local function applyReExports(parsedModules: { ParsedModule })
	local modulesByName: { [string]: ModuleInfo } = {}
	for _, parsed in parsedModules do
		modulesByName[parsed.module.qualifiedName] = parsed.module
	end

	local reexportedFuncs: { [string]: { [string]: boolean } } = {}
	local reexportedTypes: { [string]: { [string]: boolean } } = {}

	local function markFunc(moduleName: string, owner: string?, name: string)
		if not reexportedFuncs[moduleName] then
			reexportedFuncs[moduleName] = {}
		end
		reexportedFuncs[moduleName][functionKey(owner, name)] = true
	end

	local function markType(moduleName: string, name: string)
		if not reexportedTypes[moduleName] then
			reexportedTypes[moduleName] = {}
		end
		reexportedTypes[moduleName][typeKey(name)] = true
	end

	for _, parsed in parsedModules do
		local targetModule = parsed.module
		for _, binding in parsed.reexports do
			local sourceModule = modulesByName[binding.sourceModule]
			if not sourceModule then
				continue
			end

			local sourceFunc = findFunctionBySourcePath(sourceModule, binding.sourcePath)
			if sourceFunc then
				if not hasFunction(targetModule, binding.exportedOwner, binding.exportedName) then
					local cloned = deepCopy(sourceFunc) :: extract.FuncDoc
					rewriteFunctionIdentity(cloned, binding.exportedName, binding.exportedOwner)
					table.insert(targetModule.functions, cloned)
				end
				if sourceFunc.parsedDoc and sourceFunc.parsedDoc.reexportOnly then
					markFunc(sourceModule.qualifiedName, sourceFunc.owner, sourceFunc.name)
				end
				continue
			end

			local sourceType = findTypeBySourcePath(sourceModule, binding.sourcePath)
			if sourceType then
				if not hasType(targetModule, binding.exportedName) then
					local clonedType = deepCopy(sourceType) :: extract.TypeDoc
					clonedType.name = binding.exportedName
					clonedType.isPrimaryExport = nil
					if clonedType.kind == "class" or hasMethods(clonedType) then
						table.insert(targetModule.classes, clonedType)
					else
						table.insert(targetModule.types, clonedType)
					end
				end
				if sourceType.parsedDoc and sourceType.parsedDoc.reexportOnly then
					markType(sourceModule.qualifiedName, sourceType.name)
				end
				continue
			end

			local sourceConst = findConstantBySourcePath(sourceModule, binding.sourcePath)
			if sourceConst then
				if not hasConstant(targetModule, binding.exportedOwner, binding.exportedName) then
					local clonedConst = deepCopy(sourceConst) :: extract.ConstDoc
					clonedConst.name = binding.exportedName
					clonedConst.owner = binding.exportedOwner
					table.insert(targetModule.constants, clonedConst)
				end
			end
		end
	end

	for _, parsed in parsedModules do
		local module = parsed.module
		local funcMarks = reexportedFuncs[module.qualifiedName]
		if funcMarks then
			local keptFunctions: { extract.FuncDoc } = {}
			for _, f in module.functions do
				local shouldHide = f.parsedDoc
					and f.parsedDoc.reexportOnly
					and funcMarks[functionKey(f.owner, f.name)] == true
				if not shouldHide then
					table.insert(keptFunctions, f)
				end
			end
			module.functions = keptFunctions
		end

		local typeMarks = reexportedTypes[module.qualifiedName]
		if typeMarks then
			if
				module.primaryExport
				and module.primaryExport.parsedDoc
				and module.primaryExport.parsedDoc.reexportOnly
			then
				if typeMarks[typeKey(module.primaryExport.name)] then
					module.primaryExport = nil
				end
			end

			local keptClasses: { extract.TypeDoc } = {}
			for _, cls in module.classes do
				local shouldHide = cls.parsedDoc and cls.parsedDoc.reexportOnly and typeMarks[typeKey(cls.name)] == true
				if not shouldHide then
					table.insert(keptClasses, cls)
				end
			end
			module.classes = keptClasses

			local keptTypes: { extract.TypeDoc } = {}
			for _, t in module.types do
				local shouldHide = t.parsedDoc and t.parsedDoc.reexportOnly and typeMarks[typeKey(t.name)] == true
				if not shouldHide then
					table.insert(keptTypes, t)
				end
			end
			module.types = keptTypes
		end
	end
end

-- Recursively collect .luau modules from a directory.
-- @param dir       Absolute filesystem path to scan
-- @param prefix    Qualified name prefix (e.g. "@eryx" or "@eryx/encoding")
-- @param relPath   Relative path fragment for flat filenames (e.g. "" or "encoding")
local function collectModules(dir: string, prefix: string, relPath: string): { ModuleInfo }
	local parsedModules: { ParsedModule } = {}

	local function walk(currentDir: string, currentPrefix: string, currentRelPath: string)
		local entries = fs.listDir(currentDir)
		table.sort(entries)

		local initEntry: string? = nil
		local luauFiles: { string } = {}
		local dirs: { string } = {}

		for _, entry in entries do
			local fullPath = currentDir .. "/" .. entry
			if fs.isDirectory(fullPath) then
				table.insert(dirs, entry)
			elseif entry == "init.luau" then
				initEntry = entry
			elseif entry:match("%.luau$") and not entry:match("%.test%.luau$") then
				table.insert(luauFiles, entry)
			end
		end

		local ordered: { string } = {}
		if initEntry then
			table.insert(ordered, initEntry)
		end
		for _, f in luauFiles do
			table.insert(ordered, f)
		end

		for _, entry in ordered do
			local fullPath = currentDir .. "/" .. entry
			table.insert(parsedModules, parseModuleDetailed(fullPath, currentPrefix, currentRelPath))
		end

		for _, entry in dirs do
			local fullPath = currentDir .. "/" .. entry
			local subRel = if currentRelPath ~= "" then currentRelPath .. "/" .. entry else entry
			walk(fullPath, currentPrefix .. "/" .. entry, subRel)
		end
	end

	walk(dir, prefix, relPath)
	applyReExports(parsedModules)

	local modules: { ModuleInfo } = {}
	for _, parsed in parsedModules do
		local module = parsed.module
		if parsed.ignoreModule then
			continue
		end
		if
			module.description
			or module.primaryExport
			or #module.classes > 0
			or #module.functions > 0
			or #module.types > 0
			or #module.constants > 0
		then
			table.insert(modules, module)
		end
	end

	return modules
end

return {
	collectModules = collectModules,
	parseModule = parseModule,
}
