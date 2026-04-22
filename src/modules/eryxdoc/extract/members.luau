--- @ignore

-- Builds FuncDoc records from type table properties (class members and properties).

local luau = require("@eryx/luau/ast")
local doctags = require("../parse/doctags")
local types = require("./types")
local td = require("./typeDescriber")
local signatures = require("./signatures")

type ParsedDoc = doctags.ParsedDoc
type SignaturePart = types.SignaturePart
type ReturnMeta = types.ReturnMeta
type FuncDoc = types.FuncDoc

local parseDocTags = doctags.parseDocTags
local tp = td.tp
local tpExtend = td.tpExtend
local partsToString = td.partsToString

local function normalizeArgTypes(argTypes: luau.AstTypeList | { luau.AstType }?): { luau.AstType }
	if not argTypes then
		return {}
	end
	local anyArgTypes = argTypes :: any
	if anyArgTypes.types then
		return anyArgTypes.types :: { luau.AstType }
	end
	return argTypes :: { luau.AstType }
end

local function argNameValue(value: any): string?
	if not value then
		return nil
	end
	if type(value) == "table" then
		return value.name
	end
	return value
end

-- Build a FuncDoc from a type table property.
-- For function-typed props, builds full signature data.
-- For non-function props, builds a property record (params=nil).
local function buildMember(prop: luau.TypeTableProp, findDocComment: (number) -> string?, ownerName: string?): FuncDoc?
	local rawDoc: string? = if prop.location then findDocComment(prop.location.beginline) else nil
	local parsed: ParsedDoc? = nil
	local memberDoc: string? = rawDoc

	local ty = prop.type
	if ty and ty.type == "TypeFunction" then
		local fn = ty :: luau.TypeFunction
		local isMethod = false
		local argNames = fn.argNames or ({} :: { any })
		local argTypes = normalizeArgTypes(fn.argTypes)

		-- Build known param names set for doc tag parsing
		local knownParams: { [string]: boolean } = {}
		for _, n in argNames do
			local name = argNameValue(n)
			if name and name ~= "self" then
				knownParams[name] = true
			end
		end
		knownParams["..."] = true -- variadic is always valid

		parsed = if rawDoc then parseDocTags(rawDoc, knownParams) else nil
		if parsed and parsed.ignore then
			return nil
		end
		memberDoc = if parsed then parsed.body else rawDoc
		if #argNames > 0 and argNameValue(argNames[1]) == "self" then
			isMethod = true
		end

		local params: { string } = {}
		local pNames: { string? } = {}
		local pTypeParts: { { SignaturePart }? } = {}
		local pTypeNodes: { (luau.AstType | luau.AstTypePack)? } = {}
		local startIdx = if isMethod then 2 else 1
		for i = startIdx, #argTypes do
			local aName = if argNames[i] then argNameValue(argNames[i]) else nil
			local aType = td.describeType(argTypes[i])
			table.insert(params, if aName then aName .. ": " .. aType else aType)
			table.insert(pNames, aName)
			table.insert(pTypeParts, td.describeTypeParts(argTypes[i]))
			table.insert(pTypeNodes, argTypes[i])
		end

		local retParts = if fn.returnTypes then td.describeTypeParts(fn.returnTypes) else nil
		local retStr = if retParts then partsToString(retParts :: { SignaturePart }) else "()"
		local sig = prop.name .. "(" .. table.concat(params, ", ") .. ")"
		if retStr ~= "()" then
			sig ..= " -> " .. retStr
		end

		return {
			name = prop.name,
			isMethod = isMethod,
			yields = if parsed then parsed.yields else false,
			signature = sig,
			signatureFull = signatures.buildFull(prop.name, params, retStr, parsed, ownerName, isMethod),
			signatureParts = signatures.buildParts(prop.name, pNames, pTypeParts, retParts, ownerName, isMethod),
			signatureMeta = signatures.buildMeta(
				prop.name,
				pNames,
				pTypeNodes,
				fn.returnTypes,
				ownerName,
				isMethod,
				nil,
				parsed
			),
			params = params,
			returnStr = retStr,
			doc = memberDoc,
			parsedDoc = parsed,
			location = prop.location,
		}
	else
		parsed = if rawDoc then parseDocTags(rawDoc) else nil
		if parsed and parsed.ignore then
			return nil
		end
		memberDoc = if parsed then parsed.body else rawDoc

		local typeParts = if ty then td.describeTypeParts(ty) else nil
		local typeStr = if typeParts then partsToString(typeParts :: { SignaturePart }) else "any"

		-- Property signature parts: name: Type
		local propParts: { SignaturePart } = { tp(prop.name, false, "param"), tp(": ", false, "punct") }
		if typeParts then
			tpExtend(propParts, typeParts :: { SignaturePart })
		end

		return {
			name = prop.name,
			isMethod = false,
			yields = false,
			signature = prop.name .. ": " .. typeStr,
			signatureFull = prop.name .. ": " .. typeStr,
			signatureParts = propParts,
			signatureMeta = {
				name = prop.name,
				params = nil,
				returns = {
					{
						type = typeStr,
						typeParts = typeParts,
					} :: ReturnMeta,
				},
			},
			params = nil, -- nil signals "this is a property, not a callable"
			doc = memberDoc,
			parsedDoc = parsed,
			location = prop.location,
		}
	end
end

-- Build a table signature string from members (used for type alias display).
local function buildTableSignatureFull(members: { FuncDoc }): string
	local parts: { string } = { "{\n" }
	for _, m in members do
		if m.signature then
			table.insert(parts, "    " .. m.signature .. ",")
			local firstDocLine = if m.doc then m.doc:match("^([^\n]+)") else nil
			if firstDocLine and #firstDocLine > 0 then
				table.insert(parts, "  -- " .. firstDocLine)
			end
			table.insert(parts, "\n")
		end
	end
	table.insert(parts, "}")
	return table.concat(parts)
end

return {
	buildMember = buildMember,
	buildTableSignatureFull = buildTableSignatureFull,
}
