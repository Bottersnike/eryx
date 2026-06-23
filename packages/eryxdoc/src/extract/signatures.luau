--- @ignore

-- Function signature extraction and rendering in multiple formats:
-- compact one-liner, multi-line with doc comments, structured token array, and metadata.

local luau = require("@eryx/luau/ast")
local doctags = require("../parse/doctags")
local types = require("./types")
local td = require("./typeDescriber")

type ParsedDoc = doctags.ParsedDoc
type SignaturePart = types.SignaturePart
type ParamMeta = types.ParamMeta
type ReturnMeta = types.ReturnMeta
type SignatureMeta = types.SignatureMeta
type FuncDoc = types.FuncDoc
type RawFuncSig = types.RawFuncSig

local tp = td.tp
local tpExtend = td.tpExtend
local partsToString = td.partsToString

local function genericName(g: any): string
	if type(g) == "table" then
		return tostring(g.name or "?")
	end
	return tostring(g)
end

local function normalizeGenerics(generics: { any }?): { string }
	local out: { string } = {}
	if not generics then
		return out
	end
	for _, g in generics do
		table.insert(out, genericName(g))
	end
	return out
end

local function normalizeTypeList(listLike: any): ({ any }, any)
	if type(listLike) ~= "table" then
		return {}, nil
	end
	if type(listLike.typeList) == "table" then
		listLike = listLike.typeList
	end
	if type(listLike.types) == "table" then
		return listLike.types, listLike.tail
	end
	return listLike, nil
end

local function unwrapTypeOrPack(value: any): any
	if type(value) == "table" and value.kind and value.value ~= nil then
		return value.value
	end
	return value
end

-- Extract raw signature data from an ExprFunction AST node.
local function extractFuncSig(funcNode: luau.AstExprFunction, keepSelf: boolean?): RawFuncSig
	local params: { string } = {}
	local paramNames: { string? } = {}
	local paramTypeParts: { { SignaturePart }? } = {}
	local paramTypeNodes: { (luau.AstType | luau.AstTypePack)? } = {}
	local isMethod = false
	local selfType: string? = nil

	-- Implicit self (colon syntax)
	if funcNode.self then
		isMethod = true
		if funcNode.self.annotation then
			selfType = td.describeType(funcNode.self.annotation)
		end
	end

	if funcNode.args then
		local startIdx = 1
		-- Explicit self parameter (dot syntax with self)
		if not keepSelf and not isMethod and #funcNode.args > 0 and funcNode.args[1].name == "self" then
			isMethod = true
			if funcNode.args[1].annotation then
				selfType = td.describeType(funcNode.args[1].annotation)
			end
			startIdx = 2
		end
		for i = startIdx, #funcNode.args do
			local arg = funcNode.args[i]
			local name = arg.name or "?"
			if arg.annotation then
				table.insert(params, name .. ": " .. td.describeType(arg.annotation))
				table.insert(paramNames, name)
				table.insert(paramTypeParts, td.describeTypeParts(arg.annotation))
				table.insert(paramTypeNodes, arg.annotation)
			else
				table.insert(params, name)
				table.insert(paramNames, name)
				table.insert(paramTypeParts, nil)
				table.insert(paramTypeNodes, nil)
			end
		end
	end

	if funcNode.vararg then
		local va = funcNode.varargAnnotation
		if va and va.type == "variadic" then
			local vaTyped = va :: luau.AstTypePackVariadic
			table.insert(params, "...: " .. td.describeType(vaTyped.variadicType))
			table.insert(paramNames, "...")
			table.insert(paramTypeParts, td.describeTypeParts(vaTyped.variadicType))
			table.insert(paramTypeNodes, vaTyped.variadicType)
		else
			table.insert(params, "...")
			table.insert(paramNames, "...")
			table.insert(paramTypeParts, nil)
			table.insert(paramTypeNodes, nil)
		end
	end

	local retStr: string? = nil
	local retNode: (luau.AstType | luau.AstTypePack)? = nil
	local retParts: { SignaturePart }? = nil
	if funcNode.returnAnnotation then
		retParts = td.describeTypeParts(funcNode.returnAnnotation)
		retStr = partsToString(retParts :: { SignaturePart })
		retNode = funcNode.returnAnnotation
	end

	-- Generics (generics/genericPacks fields on ExprFunction)
	local generics: { string }? = nil
	local funcAny = funcNode :: any
	local hasGenerics = funcAny.generics and #funcAny.generics > 0
	local hasGenericPacks = funcAny.genericPacks and #funcAny.genericPacks > 0
	if hasGenerics or hasGenericPacks then
		generics = {}
		if hasGenerics then
			for _, g in funcAny.generics do
				table.insert(generics :: { string }, genericName(g))
			end
		end
		if hasGenericPacks then
			for _, gp in funcAny.genericPacks do
				table.insert(generics :: { string }, genericName(gp) .. "...")
			end
		end
	end

	return {
		params = params,
		paramNames = paramNames,
		paramTypeParts = paramTypeParts,
		paramTypeNodes = paramTypeNodes,
		retStr = retStr,
		retNode = retNode,
		retParts = retParts,
		isMethod = isMethod,
		selfType = selfType,
		generics = generics,
	}
end

local function extractTypeFuncSig(funcNode: luau.AstTypeFunction, keepSelf: boolean?): RawFuncSig
	local params: { string } = {}
	local paramNames: { string? } = {}
	local paramTypeParts: { { SignaturePart }? } = {}
	local paramTypeNodes: { (luau.AstType | luau.AstTypePack)? } = {}
	local isMethod = false
	local selfType: string? = nil

	local argTypes, argTail = normalizeTypeList(funcNode.argTypes)
	local argNames = funcNode.argNames or ({} :: { any })
	local startIdx = 1
	if not keepSelf and #argNames > 0 then
		local first = argNames[1]
		local firstName = if type(first) == "table" then first.name else first
		if firstName == "self" then
			isMethod = true
			if argTypes[1] then
				selfType = td.describeType(argTypes[1])
			end
			startIdx = 2
		end
	end

	for i = startIdx, #argTypes do
		local argType = argTypes[i]
		local argName = if argNames[i]
			then (if type(argNames[i]) == "table" then argNames[i].name else argNames[i])
			else nil
		if argName then
			table.insert(params, argName .. ": " .. td.describeType(argType))
			table.insert(paramNames, argName)
		else
			table.insert(params, td.describeType(argType))
			table.insert(paramNames, nil)
		end
		table.insert(paramTypeParts, td.describeTypeParts(argType))
		table.insert(paramTypeNodes, argType)
	end

	if argTail then
		local tailNode = unwrapTypeOrPack(argTail)
		if tailNode and tailNode.type == "variadic" then
			local variadic = tailNode :: luau.AstTypePackVariadic
			table.insert(params, "...: " .. td.describeType(variadic.variadicType))
			table.insert(paramNames, "...")
			table.insert(paramTypeParts, td.describeTypeParts(variadic.variadicType))
			table.insert(paramTypeNodes, variadic.variadicType)
		else
			table.insert(params, "...")
			table.insert(paramNames, "...")
			table.insert(paramTypeParts, if tailNode then td.describeTypeParts(tailNode) else nil)
			table.insert(paramTypeNodes, tailNode)
		end
	end

	local retStr: string? = nil
	local retNode: (luau.AstType | luau.AstTypePack)? = nil
	local retParts: { SignaturePart }? = nil
	if funcNode.returnTypes then
		retParts = td.describeTypeParts(funcNode.returnTypes)
		retStr = partsToString(retParts)
		retNode = funcNode.returnTypes
	end

	local generics: { string }? = nil
	local funcAny = funcNode :: any
	local hasGenerics = funcAny.generics and #funcAny.generics > 0
	local hasGenericPacks = funcAny.genericPacks and #funcAny.genericPacks > 0
	if hasGenerics or hasGenericPacks then
		generics = {}
		if hasGenerics then
			for _, g in funcAny.generics do
				table.insert(generics :: { string }, genericName(g))
			end
		end
		if hasGenericPacks then
			for _, gp in funcAny.genericPacks do
				table.insert(generics :: { string }, genericName(gp) .. "...")
			end
		end
	end

	return {
		params = params,
		paramNames = paramNames,
		paramTypeParts = paramTypeParts,
		paramTypeNodes = paramTypeNodes,
		retStr = retStr,
		retNode = retNode,
		retParts = retParts,
		isMethod = isMethod,
		selfType = selfType,
		generics = generics,
	}
end

-- Format generics as "<T, U, V...>" or "" if none.
local function formatGenerics(generics: { any }?): string
	local normalized = normalizeGenerics(generics)
	if #normalized == 0 then
		return ""
	end
	return "<" .. table.concat(normalized, ", ") .. ">"
end

local METAMETHOD_OPERATORS: { [string]: { kind: string, symbol: string } } = {
	__add = { kind = "binary", symbol = "+" },
	__sub = { kind = "binary", symbol = "-" },
	__mul = { kind = "binary", symbol = "*" },
	__div = { kind = "binary", symbol = "/" },
	__idiv = { kind = "binary", symbol = "//" },
	__mod = { kind = "binary", symbol = "%" },
	__pow = { kind = "binary", symbol = "^" },
	__concat = { kind = "binary", symbol = ".." },
	__eq = { kind = "binary", symbol = "==" },
	__lt = { kind = "binary", symbol = "<" },
	__le = { kind = "binary", symbol = "<=" },
	__band = { kind = "binary", symbol = "&" },
	__bor = { kind = "binary", symbol = "|" },
	__bxor = { kind = "binary", symbol = "~" },
	__shl = { kind = "binary", symbol = "<<" },
	__shr = { kind = "binary", symbol = ">>" },
	__unm = { kind = "unary_prefix", symbol = "-" },
	__bnot = { kind = "unary_prefix", symbol = "~" },
	__len = { kind = "unary_prefix", symbol = "#" },
}

local function metamethodInfo(name: string): { kind: string, symbol: string }?
	return METAMETHOD_OPERATORS[name]
end

local function appendReturnParts(parts: { SignaturePart }, retParts: { SignaturePart }?)
	table.insert(parts, tp(" → ", false, "punct"))
	if retParts and #retParts > 0 then
		tpExtend(parts, retParts)
	else
		table.insert(parts, tp("()", false, "punct"))
	end
end

local function appendOperandParts(parts: { SignaturePart }, name: string?, typeParts: { SignaturePart }?)
	local hasName = name ~= nil and name ~= ""
	local hasType = typeParts ~= nil and #typeParts > 0
	if hasName or hasType then
		table.insert(parts, tp("(", false, "punct"))
	end
	if hasName then
		table.insert(parts, tp(name :: string, false, "param"))
		if hasType then
			table.insert(parts, tp(": ", false, "punct"))
		end
	end
	if hasType then
		tpExtend(parts, typeParts :: { SignaturePart })
	end
	if hasName or hasType then
		table.insert(parts, tp(")", false, "punct"))
	end
end

local function operandText(name: string?, typedText: string?): string
	if name and typedText then
		return "(" .. name .. ": " .. typedText .. ")"
	end
	if name then
		return "(" .. name .. ")"
	end
	if typedText then
		return typedText
	end
	return "()"
end

local function returnSuffix(retStr: string?): string
	if retStr and retStr ~= "()" then
		return " → " .. retStr
	end
	return " → ()"
end

local function buildMetamethodParts(
	name: string,
	paramNames: { string? },
	paramTypeParts: { { SignaturePart }? },
	retParts: { SignaturePart }?
): { SignaturePart }?
	local info = metamethodInfo(name)
	if not info then
		return nil
	end

	if info.kind == "binary" and #paramTypeParts >= 2 then
		local parts: { SignaturePart } = {}
		appendOperandParts(parts, paramNames[1], paramTypeParts[1])
		table.insert(parts, tp(" " .. info.symbol .. " ", false, "punct"))
		appendOperandParts(parts, paramNames[2], paramTypeParts[2])
		appendReturnParts(parts, retParts)
		return parts
	end

	if info.kind == "unary_prefix" and #paramTypeParts >= 1 then
		local parts: { SignaturePart } = {}
		table.insert(parts, tp(info.symbol, false, "punct"))
		appendOperandParts(parts, paramNames[1], paramTypeParts[1])
		appendReturnParts(parts, retParts)
		return parts
	end

	return nil
end

local function buildMetamethodText(
	name: string,
	paramNames: { string? },
	paramTypes: { string? },
	retStr: string?
): string?
	local info = metamethodInfo(name)
	if not info then
		return nil
	end

	if info.kind == "binary" and #paramTypes >= 2 then
		return operandText(paramNames[1], paramTypes[1])
			.. " "
			.. info.symbol
			.. " "
			.. operandText(paramNames[2], paramTypes[2])
			.. returnSuffix(retStr)
	end

	if info.kind == "unary_prefix" and #paramTypes >= 1 then
		return info.symbol .. operandText(paramNames[1], paramTypes[1]) .. returnSuffix(retStr)
	end

	return nil
end

local function paramTypeStrings(paramTypeParts: { { SignaturePart }? }): { string? }
	local out: { string? } = {}
	for _, parts in paramTypeParts do
		table.insert(out, if parts then partsToString(parts :: { SignaturePart }) else nil)
	end
	return out
end

-- Build signatureParts (structured token array) for a function.
local function buildParts(
	name: string,
	paramNames: { string? },
	paramTypeParts: { { SignaturePart }? },
	retParts: { SignaturePart }?,
	owner: string?,
	isMethod: boolean?,
	generics: { any }?
): { SignaturePart }
	local metamethodParts = buildMetamethodParts(name, paramNames, paramTypeParts, retParts)
	if metamethodParts then
		return metamethodParts
	end

	local parts: { SignaturePart } = {}
	local normalizedGenerics = normalizeGenerics(generics)
	if owner then
		table.insert(parts, tp(owner, false, "name"))
		table.insert(parts, tp(if isMethod then ":" else ".", false, "punct"))
	end
	table.insert(parts, tp(name, false, "name"))
	if #normalizedGenerics > 0 then
		table.insert(parts, tp("<", false, "punct"))
		for i, g in normalizedGenerics do
			if i > 1 then
				table.insert(parts, tp(", ", false, "punct"))
			end
			table.insert(parts, tp(g, false, "type"))
		end
		table.insert(parts, tp(">", false, "punct"))
	end
	table.insert(parts, tp("(", false, "punct"))
	for i = 1, #paramNames do
		if i > 1 then
			table.insert(parts, tp(", ", false, "punct"))
		end
		local pName = paramNames[i]
		local pParts = paramTypeParts[i]
		if pName and pParts then
			table.insert(parts, tp(pName :: string, false, "param"))
			table.insert(parts, tp(": ", false, "punct"))
			tpExtend(parts, pParts :: { SignaturePart })
		elseif pName then
			table.insert(parts, tp(pName :: string, false, "param"))
		elseif pParts then
			tpExtend(parts, pParts :: { SignaturePart })
		end
	end
	table.insert(parts, tp(")", false, "punct"))
	table.insert(parts, tp(" \xe2\x86\x92 ", false, "punct"))
	if retParts and #retParts > 0 then
		tpExtend(parts, retParts)
	else
		table.insert(parts, tp("()", false, "punct"))
	end
	return parts
end

-- Build signatureMeta (structured param/return data) for a function.
local function buildMeta(
	name: string,
	paramNames: { string? },
	paramTypeNodes: { (luau.AstType | luau.AstTypePack)? },
	retNode: (luau.AstType | luau.AstTypePack)?,
	owner: string?,
	isMethod: boolean?,
	generics: { any }?,
	parsedDoc: ParsedDoc?
): SignatureMeta
	local paramDescriptions: { [string]: string } = {}
	if parsedDoc then
		for _, p in parsedDoc.params do
			paramDescriptions[p.name] = p.description
		end
	end

	local paramsMeta: { ParamMeta } = {}
	for i = 1, #paramNames do
		local pName = paramNames[i]
		local pNode = paramTypeNodes[i]
		local desc: string? = if pName then paramDescriptions[pName :: string] else nil
		table.insert(paramsMeta, {
			name = pName,
			type = if pNode then td.describeType(pNode :: any) else nil,
			typeParts = if pNode then td.describeTypeParts(pNode :: any) else nil,
			description = if desc and #desc > 0 then desc else nil,
		})
	end

	local returnsMeta: { ReturnMeta }? = nil
	if retNode then
		local rets: { ReturnMeta } = {}
		if retNode.type == "explicit" then
			local pack = retNode :: luau.AstTypePackExplicit
			local packTypes = normalizeTypeList(pack.typeList)
			for idx, t in packTypes do
				local desc: string? = if parsedDoc and parsedDoc.returns[idx]
					then parsedDoc.returns[idx].description
					else nil
				table.insert(rets, {
					type = td.describeType(t),
					typeParts = td.describeTypeParts(t),
					description = if desc and #desc > 0 then desc else nil,
				})
			end
		else
			local desc: string? = if parsedDoc and #parsedDoc.returns > 0 then parsedDoc.returns[1].description else nil
			table.insert(rets, {
				type = td.describeType(retNode),
				typeParts = td.describeTypeParts(retNode),
				description = if desc and #desc > 0 then desc else nil,
			})
		end
		returnsMeta = rets
	end

	return {
		name = name,
		owner = owner,
		isMethod = isMethod,
		generics = normalizeGenerics(generics),
		params = paramsMeta,
		returns = returnsMeta,
	}
end

-- Build signatureFull (multi-line string with inline doc comments).
local function buildFull(
	name: string,
	params: { string },
	paramNames: { string? },
	paramTypes: { string? },
	retStr: string?,
	parsedDoc: ParsedDoc?,
	owner: string?,
	isMethod: boolean?,
	generics: { string }?
): string
	local metamethodText = buildMetamethodText(name, paramNames, paramTypes, retStr)
	if metamethodText then
		return metamethodText
	end

	local paramDocs: { [string]: string } = {}
	if parsedDoc then
		for _, p in parsedDoc.params do
			paramDocs[p.name] = p.description
		end
	end

	-- Check if any inline docs exist
	local hasComments = false
	for _, p in params do
		local pName = p:split(":")[1]
		if paramDocs[pName] and #paramDocs[pName] > 0 then
			hasComments = true
			break
		end
	end
	if not hasComments and parsedDoc then
		for _, r in parsedDoc.returns do
			if #r.description > 0 then
				hasComments = true
				break
			end
		end
	end

	-- Compact form when no inline docs
	if not hasComments then
		local pfx = if owner then owner .. (if isMethod then ":" else ".") else ""
		local retSuffix = returnSuffix(retStr)
		local genStr = formatGenerics(generics)
		return pfx .. name .. genStr .. "(" .. table.concat(params, ", ") .. ")" .. retSuffix
	end

	-- Expanded form with comments
	local buf: { string } = {}
	if owner then
		table.insert(buf, owner)
		table.insert(buf, if isMethod then ":" else ".")
	end
	table.insert(buf, name)
	table.insert(buf, formatGenerics(generics))
	table.insert(buf, "(")
	if #params > 0 then
		table.insert(buf, "\n")
		for i, p in params do
			local pName = p:split(":")[1]
			table.insert(buf, "    " .. p)
			if i ~= #params then
				table.insert(buf, ",")
			end
			if paramDocs[pName] and #paramDocs[pName] > 0 then
				table.insert(buf, "  -- " .. paramDocs[pName] .. "\n")
			else
				table.insert(buf, "\n")
			end
		end
		table.insert(buf, ")")
	else
		table.insert(buf, ")")
	end

	if parsedDoc and #parsedDoc.returns > 0 then
		local hasReturnDocs = false
		for _, r in parsedDoc.returns do
			if #r.description > 0 then
				hasReturnDocs = true
				break
			end
		end
		if not hasReturnDocs then
			if #parsedDoc.returns == 1 and parsedDoc.returns[1].type then
				table.insert(buf, " \xe2\x86\x92 " .. (parsedDoc.returns[1].type :: string))
			else
				local retTypes: { string } = {}
				for _, r in parsedDoc.returns do
					if r.type then
						table.insert(retTypes, r.type :: string)
					end
				end
				if #retTypes > 0 then
					table.insert(buf, " \xe2\x86\x92 (" .. table.concat(retTypes, ", ") .. ")")
				end
			end
		else
			table.insert(buf, " \xe2\x86\x92 (\n")
			for i, r in parsedDoc.returns do
				table.insert(buf, "    " .. (r.type or ""))
				if i ~= #parsedDoc.returns then
					table.insert(buf, ",")
				end
				if #r.description > 0 then
					table.insert(buf, "  -- " .. r.description .. "\n")
				else
					table.insert(buf, "\n")
				end
			end
			table.insert(buf, ")")
		end
	elseif retStr and retStr ~= "()" then
		table.insert(buf, " \xe2\x86\x92 " .. retStr)
	else
		table.insert(buf, " \xe2\x86\x92 ()")
	end

	return table.concat(buf)
end

-- Populate all signature fields on a FuncDoc in one shot.
local function applySignature(func: FuncDoc, sig: RawFuncSig)
	local paramTypes = paramTypeStrings(sig.paramTypeParts)
	local compactMetamethod = buildMetamethodText(func.name, sig.paramNames, paramTypes, func.returnStr)
	if compactMetamethod then
		func.signature = compactMetamethod
	else
		-- Compact one-liner
		local lineParts: { string } = {}
		if func.owner then
			table.insert(lineParts, func.owner)
			table.insert(lineParts, if func.isMethod then ":" else ".")
		end
		table.insert(lineParts, func.name)
		table.insert(lineParts, formatGenerics(func.generics))
		table.insert(lineParts, "(" .. table.concat(func.params :: { string }, ", ") .. ")")
		table.insert(lineParts, returnSuffix(func.returnStr))
		func.signature = table.concat(lineParts)
	end

	-- Full multi-line
	func.signatureFull = buildFull(
		func.name,
		func.params :: { string },
		sig.paramNames,
		paramTypes,
		func.returnStr,
		func.parsedDoc,
		func.owner,
		func.isMethod,
		func.generics
	)

	-- Structured parts and meta
	func.signatureParts = buildParts(
		func.name,
		sig.paramNames,
		sig.paramTypeParts,
		sig.retParts,
		func.owner,
		func.isMethod,
		func.generics
	)
	func.signatureMeta = buildMeta(
		func.name,
		sig.paramNames,
		sig.paramTypeNodes,
		sig.retNode,
		func.owner,
		func.isMethod,
		sig.generics,
		func.parsedDoc
	)
end

return {
	extractFuncSig = extractFuncSig,
	formatGenerics = formatGenerics,
	buildParts = buildParts,
	buildMeta = buildMeta,
	buildFull = buildFull,
	applySignature = applySignature,
	extractTypeFuncSig = extractTypeFuncSig,
}
