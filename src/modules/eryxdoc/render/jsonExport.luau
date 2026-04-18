-- Converts module documentation data into Moonwave-compatible JSON format.
-- Pure data transformation with no renderer state dependency.

local json = require("@eryx/encoding/json")
local modules = require("../content/modules")

-- Converts a FuncDoc into a Moonwave-compatible function entry.
local function funcToMoonwave(f: any): { [string]: any }
	local params: { { [string]: any } } = {}
	local returns: { { [string]: any } } = {}

	-- Use signatureMeta for typed param/return info, fall back to parsedDoc
	if f.signatureMeta and f.signatureMeta.params then
		for _, p in f.signatureMeta.params do
			table.insert(params, {
				name = p.name or "",
				desc = p.description or "",
				lua_type = p.type or "",
			})
		end
	elseif f.params then
		for _, p in f.params :: { string } do
			local name, typ = p:match("^(.-):%s*(.+)$")
			if name then
				table.insert(params, { name = name, desc = "", lua_type = typ })
			else
				table.insert(params, { name = p, desc = "", lua_type = "" })
			end
		end
	end

	if f.signatureMeta and f.signatureMeta.returns then
		for _, r in f.signatureMeta.returns do
			table.insert(returns, {
				desc = r.description or "",
				lua_type = r.type or "any",
			})
		end
	elseif f.returnStr and f.returnStr ~= "" then
		table.insert(returns, { desc = "", lua_type = f.returnStr })
	end

	-- Fill in param descriptions from parsedDoc if available
	if f.parsedDoc then
		for _, pd in f.parsedDoc.params do
			for _, param in params do
				if param.name == pd.name and (param.desc == nil or param.desc == "") then
					param.desc = pd.description
				end
			end
		end
		for i, rd in f.parsedDoc.returns do
			if returns[i] and (returns[i].desc == nil or returns[i].desc == "") then
				returns[i].desc = rd.description
			end
		end
	end

	local tags: { string } = {}
	if f.parsedDoc then
		if f.parsedDoc.yields then
			table.insert(tags, "Yields")
		end
		if f.parsedDoc.unreleased then
			table.insert(tags, "Unreleased")
		end
		if f.parsedDoc.private then
			table.insert(tags, "Private")
		end
		for _, t in f.parsedDoc.tags do
			table.insert(tags, t)
		end
	end

	-- Errors from doc tags
	local docErrors: { { [string]: any } }? = nil
	if f.parsedDoc and #f.parsedDoc.errors > 0 then
		docErrors = {}
		for _, e in f.parsedDoc.errors do
			table.insert(docErrors :: { { [string]: any } }, {
				type = e.type,
				desc = e.description or "",
			})
		end
	end

	local functionType = if f.isMethod then "Method" else "Function"

	return {
		name = f.name,
		owner = f.owner,
		is_method = f.isMethod or false,
		desc = f.doc or "",
		signature = f.signatureFull or f.signature or "",
		params = params,
		returns = returns,
		return_str = f.returnStr or "",
		errors = docErrors,
		function_type = functionType,
		tags = tags,
		since = if f.parsedDoc then f.parsedDoc.since else nil,
		deprecated = if f.parsedDoc and f.parsedDoc.deprecated
			then {
				version = f.parsedDoc.deprecated.version,
				description = f.parsedDoc.deprecated.description,
			}
			else nil,
		source = {
			line = if f.location then f.location.beginline else 0,
			path = "",
		},
	}
end

-- Converts a TypeDoc member (property, not callable) into a Moonwave property entry.
local function propToMoonwave(m: any): { [string]: any }
	return {
		name = m.name,
		desc = m.doc or "",
		lua_type = m.signatureFull or m.signature or "any",
		tags = {},
	}
end

-- Converts a TypeDoc into a Moonwave type entry.
local function typeToMoonwave(t: any): { [string]: any }
	local fields: { { [string]: any } } = {}
	if t.members then
		for _, m in t.members do
			table.insert(fields, {
				name = m.name,
				desc = m.doc or "",
				lua_type = m.signatureFull or m.signature or "any",
			})
		end
	end

	return {
		name = t.name,
		desc = t.doc or "",
		lua_type = t.signatureFull or "",
		generics = t.generics,
		fields = fields,
		tags = {},
		source = {
			line = if t.location then t.location.beginline else 0,
			path = "",
		},
	}
end

-- Converts a full ModuleInfo into the Moonwave-compatible JSON string.
local function moduleToJSON(mod: modules.ModuleInfo): string
	local classes: { { [string]: any } } = {}

	local function classToEntry(c: any, isPrimary: boolean?): { [string]: any }
		local functions: { { [string]: any } } = {}
		local properties: { { [string]: any } } = {}

		if c.members then
			for _, m in c.members do
				if m.params then
					table.insert(functions, funcToMoonwave(m))
				else
					table.insert(properties, propToMoonwave(m))
				end
			end
		end

		local metamethods: { { [string]: any } } = {}
		if c.metamethods then
			for _, m in c.metamethods do
				table.insert(metamethods, {
					name = m.name,
					desc = m.doc or "",
					signature = m.signatureFull or "",
				})
			end
		end

		return {
			name = c.name,
			desc = c.doc or "",
			is_primary_export = isPrimary or false,
			tags = {},
			source = {
				line = if c.location then c.location.beginline else 0,
				path = "",
			},
			functions = functions,
			properties = properties,
			metamethods = metamethods,
			types = {},
		}
	end

	if mod.primaryExport then
		table.insert(classes, classToEntry(mod.primaryExport, true))
	end

	for _, c in mod.classes do
		table.insert(classes, classToEntry(c, false))
	end

	local moduleFunctions: { { [string]: any } } = {}
	for _, f in mod.functions do
		table.insert(moduleFunctions, funcToMoonwave(f))
	end

	local moduleTypes: { { [string]: any } } = {}
	for _, t in mod.types do
		table.insert(moduleTypes, typeToMoonwave(t))
	end

	local moduleConstants: { { [string]: any } } = {}
	for _, c in mod.constants do
		table.insert(moduleConstants, {
			name = c.name,
			owner = c.owner,
			value = c.value,
			desc = c.doc or "",
			group_title = c.groupTitle,
		})
	end

	-- Always insert the module entry (carries name, description, and any content)
	table.insert(classes, 1, {
		name = mod.qualifiedName,
		desc = mod.description or "",
		tags = {},
		source = { line = 0, path = "" },
		functions = moduleFunctions,
		properties = {},
		types = moduleTypes,
		constants = moduleConstants,
	})

	return json.encode({ classes = classes }, { pretty = true })
end

return {
	funcToMoonwave = funcToMoonwave,
	propToMoonwave = propToMoonwave,
	typeToMoonwave = typeToMoonwave,
	moduleToJSON = moduleToJSON,
}
