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
type OverloadDoc = types.OverloadDoc

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

local function collectFunctionTypeOverloads(ty: luau.AstType?): { luau.TypeFunction }
	local overloads: { luau.TypeFunction } = {}

	local function visit(node: luau.AstType?)
		if not node then
			return
		end
		if node.type == "TypeFunction" then
			table.insert(overloads, node :: luau.TypeFunction)
		elseif node.type == "TypeIntersection" then
			for _, part in (node :: luau.TypeIntersection).types do
				visit(part)
			end
		elseif node.type == "TypeGroup" then
			visit((node :: luau.TypeGroup).inner)
		end
	end

	visit(ty)
	return overloads
end

local function buildKnownParams(sigData: types.RawFuncSig): { [string]: boolean }
	local known: { [string]: boolean } = { ["..."] = true }
	for _, name in sigData.paramNames do
		if name and name ~= "self" then
			known[name] = true
		end
	end
	return known
end

local function makeOverloadDoc(
	name: string,
	ownerName: string?,
	location: luau.Location,
	parsed: ParsedDoc?,
	rawSig: types.RawFuncSig
): OverloadDoc
	local holder: FuncDoc = {
		name = name,
		isMethod = rawSig.isMethod,
		yields = if parsed then parsed.yields else false,
		signature = "",
		signatureFull = "",
		params = rawSig.params,
		returnStr = rawSig.retStr,
		doc = if parsed then parsed.body else nil,
		parsedDoc = parsed,
		location = location,
		owner = ownerName,
		selfType = rawSig.selfType,
		generics = rawSig.generics,
		overloads = nil,
	}
	signatures.applySignature(holder, rawSig)
	return {
		doc = holder.doc,
		location = holder.location,
		params = holder.params,
		returnStr = holder.returnStr,
		parsedDoc = holder.parsedDoc,
		yields = holder.yields,
		isMethod = holder.isMethod,
		selfType = holder.selfType,
		owner = holder.owner,
		generics = holder.generics,
		signature = holder.signature,
		signatureFull = holder.signatureFull,
		signatureParts = holder.signatureParts,
		signatureMeta = holder.signatureMeta,
	}
end

-- Build a FuncDoc from a type table property.
-- For function-typed props, builds full signature data.
-- For non-function props, builds a property record (params=nil).
local function buildMember(prop: luau.TypeTableProp, findDocComment: (number) -> string?, ownerName: string?): FuncDoc?
	local rawDoc: string? = if prop.location then findDocComment(prop.location.beginline) else nil
	local parsed: ParsedDoc? = nil
	local memberDoc: string? = rawDoc

	local ty = prop.type
	if ty and (#collectFunctionTypeOverloads(ty) > 0) then
		local overloadNodes = collectFunctionTypeOverloads(ty)
		local rawOverloads = {}
		local allKnownParams: { [string]: boolean } = { ["..."] = true }
		for _, overloadNode in overloadNodes do
			local overloadSig = signatures.extractTypeFuncSig(overloadNode)
			table.insert(rawOverloads, { node = overloadNode, sig = overloadSig })
			for name in buildKnownParams(overloadSig) do
				allKnownParams[name] = true
			end
		end

		parsed = if rawDoc then parseDocTags(rawDoc, allKnownParams) else nil
		if parsed and parsed.ignore then
			return nil
		end
		memberDoc = if parsed then parsed.body else rawDoc
		local overloads: { OverloadDoc } = {}
		for _, entry in rawOverloads do
			local overloadNode = entry.node :: luau.TypeFunction
			local overloadSig = entry.sig :: types.RawFuncSig
			local overloadKnownParams = buildKnownParams(overloadSig)
			local overloadDoc = if overloadNode.location then findDocComment(overloadNode.location.beginline) else nil
			local overloadParsed = if overloadDoc then parseDocTags(overloadDoc, overloadKnownParams) else nil
			local mergedParsed = overloadParsed or parsed
			table.insert(
				overloads,
				makeOverloadDoc(prop.name, ownerName, overloadNode.location, mergedParsed, overloadSig)
			)
		end

		local primary = overloads[1]

		return {
			name = prop.name,
			isMethod = primary.isMethod,
			yields = if parsed then parsed.yields else primary.yields,
			signature = primary.signature,
			signatureFull = primary.signatureFull,
			signatureParts = primary.signatureParts,
			signatureMeta = primary.signatureMeta,
			params = primary.params,
			returnStr = primary.returnStr,
			doc = memberDoc,
			parsedDoc = parsed,
			location = prop.location,
			selfType = primary.selfType,
			owner = ownerName,
			generics = primary.generics,
			overloads = if #overloads > 1 then overloads else nil,
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
			selfType = nil,
			owner = ownerName,
			generics = nil,
			overloads = nil,
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
