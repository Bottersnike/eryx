-- Function signature extraction and rendering in multiple formats:
-- compact one-liner, multi-line with doc comments, structured token array, and metadata.

local luau = require("@eryx/luau")
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

-- Extract raw signature data from an ExprFunction AST node.
local function extractFuncSig(funcNode: luau.ExprFunction): RawFuncSig
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
		if not isMethod and #funcNode.args > 0 and funcNode.args[1].name == "self" then
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
		if va and va.type == "TypePackVariadic" then
			local vaTyped = va :: luau.TypePackVariadic
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
	if funcAny.generics and #funcAny.generics > 0 then
		generics = {}
		for _, g in funcAny.generics :: { string } do
			table.insert(generics :: { string }, g)
		end
		if funcAny.genericPacks then
			for _, gp in funcAny.genericPacks :: { string } do
				table.insert(generics :: { string }, gp .. "...")
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
local function formatGenerics(generics: { string }?): string
	if not generics or #(generics :: { string }) == 0 then
		return ""
	end
	return "<" .. table.concat(generics :: { string }, ", ") .. ">"
end

-- Build signatureParts (structured token array) for a function.
local function buildParts(
	name: string,
	paramNames: { string? },
	paramTypeParts: { { SignaturePart }? },
	retParts: { SignaturePart }?,
	owner: string?,
	isMethod: boolean?,
	generics: { string }?
): { SignaturePart }
	local parts: { SignaturePart } = {}
	if owner then
		table.insert(parts, tp(owner, false, "name"))
		table.insert(parts, tp(if isMethod then ":" else ".", false, "punct"))
	end
	table.insert(parts, tp(name, false, "name"))
	if generics and #(generics :: { string }) > 0 then
		table.insert(parts, tp("<", false, "punct"))
		for i, g in generics :: { string } do
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
	generics: { string }?,
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
		if retNode.type == "TypePackExplicit" and (retNode :: luau.TypePackExplicit).types then
			local pack = retNode :: luau.TypePackExplicit
			for idx, t in pack.types do
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
		generics = generics,
		params = paramsMeta,
		returns = returnsMeta,
	}
end

-- Build signatureFull (multi-line string with inline doc comments).
local function buildFull(
	name: string,
	params: { string },
	retStr: string?,
	parsedDoc: ParsedDoc?,
	owner: string?,
	isMethod: boolean?,
	generics: { string }?
): string
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
		local retSuffix = if retStr and retStr ~= "()" then " \xe2\x86\x92 " .. retStr else " \xe2\x86\x92 ()"
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
	-- Compact one-liner
	local lineParts: { string } = {}
	if func.owner then
		table.insert(lineParts, func.owner)
		table.insert(lineParts, if func.isMethod then ":" else ".")
	end
	table.insert(lineParts, func.name)
	table.insert(lineParts, formatGenerics(func.generics))
	table.insert(lineParts, "(" .. table.concat(func.params :: { string }, ", ") .. ")")
	if func.returnStr and func.returnStr ~= "()" then
		table.insert(lineParts, " \xe2\x86\x92 " .. func.returnStr)
	else
		table.insert(lineParts, " \xe2\x86\x92 ()")
	end
	func.signature = table.concat(lineParts)

	-- Full multi-line
	func.signatureFull = buildFull(
		func.name,
		func.params :: { string },
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
}
