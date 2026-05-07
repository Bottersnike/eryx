local json = require("@eryx/data/json")
local modulesApi = require("@self/content/modules")
local buildWarnings = require("@self/warnings")

type ModuleInfo = modulesApi.ModuleInfo

export type ModuleJsonOptions = {
	pretty: boolean?,
}

local funcDocs

local function array<T>(values: { T }?): { T }
	if values and next(values) ~= nil then
		return values
	end
	return json.tableAsArray({})
end

local function copyArray<T>(values: { T }?): { T }
	if not values then
		return json.tableAsArray({})
	end

	local out: { T } = {}
	for _, value in values do
		table.insert(out, value)
	end
	return array(out)
end

local function location(loc: any): any
	if type(loc) ~= "table" then
		return nil
	end

	return {
		begin = {
			line = loc.beginline,
			column = loc.begincolumn,
		},
		["end"] = {
			line = loc.endline,
			column = loc.endcolumn,
		},
	}
end

local function signatureParts(parts: { any }?): { any }
	if not parts then
		return json.tableAsArray({})
	end

	local out = {}
	for _, part in parts do
		table.insert(out, {
			text = part.text,
			typeRef = part.typeRef,
			hoverText = part.hoverText,
			kind = part.kind,
		})
	end
	return array(out)
end

local function paramMeta(params: { any }?): { any }
	if not params then
		return json.tableAsArray({})
	end

	local out = {}
	for _, param in params do
		table.insert(out, {
			name = param.name,
			type = param.type,
			typeParts = signatureParts(param.typeParts),
			description = param.description,
		})
	end
	return array(out)
end

local function returnMeta(returns: { any }?): { any }
	if not returns then
		return json.tableAsArray({})
	end

	local out = {}
	for _, ret in returns do
		table.insert(out, {
			type = ret.type,
			typeParts = signatureParts(ret.typeParts),
			description = ret.description,
		})
	end
	return array(out)
end

local function signatureMeta(meta: any): any
	if type(meta) ~= "table" then
		return nil
	end

	return {
		name = meta.name,
		owner = meta.owner,
		isMethod = meta.isMethod,
		generics = copyArray(meta.generics),
		params = paramMeta(meta.params),
		returns = returnMeta(meta.returns),
	}
end

local function parsedDoc(doc: any): any
	if type(doc) ~= "table" then
		return nil
	end

	local params = {}
	for _, param in doc.params or {} do
		table.insert(params, {
			name = param.name,
			description = param.description,
			type = param.typeOverride,
		})
	end

	local returns = {}
	for _, ret in doc.returns or {} do
		table.insert(returns, {
			description = ret.description,
			type = ret.type,
		})
	end

	local errors = {}
	for _, err in doc.errors or {} do
		table.insert(errors, {
			description = err.description,
			type = err.type,
		})
	end

	return {
		body = doc.body,
		params = array(params),
		returns = array(returns),
		errors = array(errors),
		yields = doc.yields,
		unreleased = doc.unreleased,
		since = doc.since,
		deprecated = doc.deprecated and {
			version = doc.deprecated.version,
			description = doc.deprecated.description,
		} or nil,
		private = doc.private,
		ignore = doc.ignore,
		reexportOnly = doc.reexportOnly,
		tags = copyArray(doc.tags),
	}
end

local function funcDoc(func: any): any
	return {
		name = func.name,
		owner = func.owner,
		kind = if func.params then (if func.isMethod then "method" else "function") else "property",
		doc = func.doc,
		location = location(func.location),
		params = copyArray(func.params),
		returnStr = func.returnStr,
		parsedDoc = parsedDoc(func.parsedDoc),
		yields = func.yields,
		isMethod = func.isMethod,
		selfType = func.selfType,
		generics = copyArray(func.generics),
		signature = func.signature,
		signatureFull = func.signatureFull,
		signatureParts = signatureParts(func.signatureParts),
		signatureMeta = signatureMeta(func.signatureMeta),
		overloads = funcDocs(func.overloads),
	}
end

funcDocs = function(funcs: { any }?): { any }
	if not funcs then
		return json.tableAsArray({})
	end

	local out = {}
	for _, func in funcs do
		table.insert(out, funcDoc(func))
	end
	return array(out)
end

local function typeDoc(typeInfo: any): any
	if type(typeInfo) ~= "table" then
		return nil
	end

	return {
		name = typeInfo.name,
		exported = typeInfo.exported,
		kind = typeInfo.kind,
		doc = typeInfo.doc,
		extendsTypes = copyArray(typeInfo.extendsTypes),
		signatureFull = typeInfo.signatureFull,
		signatureParts = signatureParts(typeInfo.signatureParts),
		location = location(typeInfo.location),
		members = funcDocs(typeInfo.members),
		generics = copyArray(typeInfo.generics),
		parsedDoc = parsedDoc(typeInfo.parsedDoc),
		classImplTable = typeInfo.classImplTable,
		classFieldsType = typeInfo.classFieldsType,
		isPrimaryExport = typeInfo.isPrimaryExport,
		metamethods = funcDocs(typeInfo.metamethods),
	}
end

local function typeDocs(types: { any }?): { any }
	if not types then
		return json.tableAsArray({})
	end

	local out = {}
	for _, typeInfo in types do
		table.insert(out, typeDoc(typeInfo))
	end
	return array(out)
end

local function constDocs(constants: { any }?): { any }
	if not constants then
		return json.tableAsArray({})
	end

	local out = {}
	for _, constant in constants do
		table.insert(out, {
			name = constant.name,
			owner = constant.owner,
			value = constant.value,
			doc = constant.doc,
			groupTitle = constant.groupTitle,
		})
	end
	return array(out)
end

local function moduleInfo(mod: ModuleInfo): any
	return {
		name = mod.name,
		qualifiedName = mod.qualifiedName,
		filename = mod.filename,
		description = mod.description,
		moduleRoot = mod.moduleRoot,
		primaryExport = typeDoc(mod.primaryExport),
		classes = typeDocs(mod.classes),
		functions = funcDocs(mod.functions),
		types = typeDocs(mod.types),
		constants = constDocs(mod.constants),
	}
end

local function moduleInfos(modules: { ModuleInfo }): { any }
	local out = {}
	for _, mod in modules do
		table.insert(out, moduleInfo(mod))
	end
	return array(out)
end

local function exportModules(modulesDir: string, prefix: string): any
	buildWarnings.clear()
	local modules = modulesApi.collectModules(modulesDir, prefix, "")

	return {
		schemaVersion = 1,
		generator = {
			name = "eryxdoc",
			format = "modules-json",
		},
		config = {
			modules = modulesDir,
			prefix = prefix,
		},
		moduleCount = #modules,
		modules = moduleInfos(modules),
		warnings = copyArray(buildWarnings.summary()),
	}
end

local function encodeModules(modulesDir: string, prefix: string, options: ModuleJsonOptions?): string
	return json.encode(exportModules(modulesDir, prefix), {
		pretty = options and options.pretty,
		sortKeys = true,
	})
end

return {
	exportModules = exportModules,
	encodeModules = encodeModules,
}
