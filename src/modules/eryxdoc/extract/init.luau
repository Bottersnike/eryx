--- Public API for extracting structured documentation from a Luau parse result.
---
--- Usage:
---
--- ```luau
--- local extract = require("eryxdoc/extract")
--- local luau = require("@eryx/luau")
---
--- local source = fs.openSync("mymodule.luau"):readSync()
--- local result = luau.parse(source, { captureComments = true })
--- local docs = extract.extract(result, string.split(source, "\n"))
--- -- docs.functions, docs.types, docs.constants, docs.moduleDescription
--- ```

local luau = require("@eryx/luau")
local doctags = require("@self/../parse/doctags")
local types = require("@self/types")
local comments = require("@self/comments")
local td = require("@self/typeDescriber")
local sig = require("@self/signatures")
local classDetection = require("@self/classDetection")
local members = require("@self/members")

type ParsedDoc = doctags.ParsedDoc
export type SignaturePart = types.SignaturePart
export type ParamMeta = types.ParamMeta
export type ReturnMeta = types.ReturnMeta
export type SignatureMeta = types.SignatureMeta
export type FuncDoc = types.FuncDoc
export type TypeDoc = types.TypeDoc
export type ConstDoc = types.ConstDoc
export type ExtractedDocs = types.ExtractedDocs
type CommentBlock = types.CommentBlock

local parseDocTags = doctags.parseDocTags
local tp = td.tp
local tpExtend = td.tpExtend

local extract = {}

local function genericName(g: any): string
	if type(g) == "table" then
		return tostring(g.name or "?")
	end
	return tostring(g)
end

local function renderGenerics(generics: { string }?): string
	if not generics or #generics == 0 then
		return ""
	end
	return "<" .. table.concat(generics, ", ") .. ">"
end

local function unwrapTypeOrPack(value: any): luau.AstType?
	if type(value) ~= "table" then
		return nil
	end
	if value.type then
		return value :: luau.AstType
	end
	if value.kind and value.value and type(value.value) == "table" and value.value.type then
		local inner = value.value
		if value.kind == "Type" then
			return inner :: luau.AstType
		end
		return nil
	end
	return nil
end

local function normalizeTypeList(typeList: any): ({ any }, any)
	if type(typeList) ~= "table" then
		return {}, nil
	end
	if type(typeList.types) == "table" then
		return typeList.types, typeList.tail
	end
	return typeList, nil
end

local function stripInlineComments(signature: string?): string?
	if not signature then
		return nil
	end

	local cleaned: { string } = {}
	for _, line in string.split(signature, "\n") do
		local withoutComment = line:match("^(.-)%s*%-%-") or line
		local trimmed = (withoutComment:gsub("%s+$", ""))
		table.insert(cleaned, trimmed)
	end

	return table.concat(cleaned, "\n")
end

local function formatTypeHoverSignature(typeDoc: TypeDoc): string?
	if not typeDoc.signatureFull then
		return nil
	end

	local signature = stripInlineComments(typeDoc.signatureFull)
	if not signature then
		return nil
	end

	if typeDoc.exported then
		return signature:gsub("^type%s+", "export type ", 1)
	end

	return signature
end

local MAX_HOVER_LINES = 200
local MAX_HOVER_CHARS = 10000

local function clampHoverText(signature: string?): string?
	if not signature or signature == "" then
		return signature
	end

	local lines = string.split(signature, "\n")
	local truncated = false

	if #lines > MAX_HOVER_LINES then
		local trimmed: { string } = {}
		for i = 1, MAX_HOVER_LINES do
			table.insert(trimmed, lines[i])
		end
		lines = trimmed
		truncated = true
	end

	local joined = table.concat(lines, "\n")
	if #joined > MAX_HOVER_CHARS then
		joined = joined:sub(1, MAX_HOVER_CHARS)
		truncated = true
	end

	if truncated then
		joined ..= "\n\n... hover truncated for large type"
	end

	return joined
end

function extract.extract(result: luau.ParseResult, sourceLines: { string }): ExtractedDocs
	local commentBlocks, inlineComments = comments.collectComments(result, sourceLines)

	-- ── Module description detection ─────────────────────────────────────
	local moduleDescription: string? = nil
	local moduleBlockIdx: number? = nil
	if
		#commentBlocks > 0
		and result.comments
		and #result.comments > 0
		and result.comments[1].location.beginline == 1
	then
		local first = commentBlocks[1]
		local firstStat = if result.root.body and #result.root.body > 0 then result.root.body[1] else nil
		local firstStatLine = if firstStat then firstStat.location.beginline else nil

		if firstStatLine == nil or firstStatLine > first.endLine + 1 then
			moduleDescription = first.text
			moduleBlockIdx = 1
		elseif firstStatLine == first.endLine + 1 then
			local statType = if firstStat then firstStat.type else nil
			local isDocumentable = statType == "StatFunction"
				or statType == "StatLocalFunction"
				or statType == "StatTypeAlias"

			if not isDocumentable and statType == "StatLocal" then
				local localStat = firstStat :: luau.StatLocal
				if localStat.values then
					for _, val in localStat.values do
						if val.type == "ExprTable" then
							isDocumentable = true
							break
						end
					end
				end
			end

			if not isDocumentable then
				moduleDescription = first.text
				moduleBlockIdx = 1
			end
		end
	end

	local function findDocComment(nodeLine: number): string?
		for i, block in commentBlocks do
			if i == moduleBlockIdx then
				continue
			end
			if block.endLine == nodeLine - 1 then
				return block.text
			end
		end
		return nil
	end

	local function mergeDocText(primary: string?, secondary: string?): string?
		if primary and secondary then
			if primary == secondary then
				return primary
			end
			if primary == "" then
				return secondary
			end
			if secondary == "" then
				return primary
			end
			return primary .. "\n\n" .. secondary
		end
		return primary or secondary
	end

	local function exprToPath(expr: luau.AstExpr): string?
		if expr.type == "ExprGlobal" then
			return (expr :: luau.ExprGlobal).name
		elseif expr.type == "ExprLocal" then
			local loc = expr :: luau.ExprLocal
			return loc["local"] and loc["local"].name
		elseif expr.type == "ExprIndexName" then
			local idx = expr :: luau.ExprIndexName
			local parent = exprToPath(idx.expr)
			if parent then
				return parent .. "." .. idx.index
			end
		end
		return nil
	end

	local function typeRootName(annotation: luau.AstType?): string?
		if not annotation then
			return nil
		end
		if annotation.type == "TypeTypeof" then
			return exprToPath((annotation :: luau.TypeTypeof).expr)
		end
		return nil
	end

	local function returnedRootName(expr: luau.AstExpr): string?
		if expr.type == "ExprGlobal" then
			return (expr :: luau.ExprGlobal).name
		elseif expr.type == "ExprLocal" then
			local loc = expr :: luau.ExprLocal
			return loc["local"] and loc["local"].name
		elseif expr.type == "ExprTypeAssertion" then
			local assertion = expr :: luau.ExprTypeAssertion
			local annotatedRoot = typeRootName(assertion.annotation)
			if annotatedRoot then
				return annotatedRoot
			end
			local inner = assertion.expr
			if inner then
				return returnedRootName(inner)
			end
		elseif expr.type == "ExprCall" then
			local call = expr :: luau.ExprCall
			if call.func and call.func.type == "ExprIndexName" then
				local idx = call.func :: luau.ExprIndexName
				if
					idx.index == "freeze"
					and idx.expr.type == "ExprGlobal"
					and (idx.expr :: luau.ExprGlobal).name == "table"
					and call.args
					and #call.args >= 1
				then
					return returnedRootName(call.args[1])
				end
			end
		end
		return nil
	end

	-- ── Collect returned names for export detection ──────────────────────
	local returnedRoots: { [string]: boolean } = {}
	for _, stat in result.root.body do
		if stat.type == "StatReturn" then
			local retStat = stat :: luau.StatReturn
			local list = retStat.list
			if list then
				for _, expr in list do
					local name = returnedRootName(expr)
					if name then
						returnedRoots[name] = true
					end
				end
			end
		end
	end

	-- ── AST helpers ─────────────────────────────────────────────────────
	local function exprRootIsExported(expr: luau.AstExpr): boolean
		if expr.type == "ExprGlobal" then
			return true
		end
		if expr.type == "ExprLocal" then
			local loc = expr :: luau.ExprLocal
			local name = loc["local"] and loc["local"].name
			return name ~= nil and returnedRoots[name] == true
		end
		if expr.type == "ExprIndexName" then
			return exprRootIsExported((expr :: luau.ExprIndexName).expr)
		end
		return false
	end

	-- ── Result accumulators ──────────────────────────────────────────────
	local typeDocs: { TypeDoc } = {}
	local functions: { FuncDoc } = {}
	local constants: { ConstDoc } = {}

	local classImplToType: { [string]: string } = {}
	local suppressedTypes: { [string]: boolean } = {}
	local typeMemberMixins: { [string]: { string } } = {}

	-- ── Process a function statement/expression ─────────────────────────
	local function processFunction(
		name: string,
		owner: string?,
		funcNode: luau.ExprFunction,
		location: luau.Location,
		doc: string?
	)
		local funcSig = sig.extractFuncSig(funcNode)

		-- Build known param names set for doc tag parsing
		local knownParams: { [string]: boolean } = {}
		for _, n in funcSig.paramNames do
			if n and n ~= "self" then
				knownParams[n :: string] = true
			end
		end
		knownParams["..."] = true

		local parsed = if doc then parseDocTags(doc, knownParams) else nil

		-- @ignore: totally exclude from documentation
		if parsed and parsed.ignore then
			return
		end

		local func: FuncDoc = {
			name = name,
			doc = if parsed then parsed.body else doc,
			location = location,
			params = funcSig.params,
			returnStr = funcSig.retStr,
			parsedDoc = parsed,
			yields = if parsed then parsed.yields else false,
			isMethod = funcSig.isMethod,
			selfType = funcSig.selfType,
			owner = owner,
			generics = funcSig.generics,
			signature = "",
			signatureFull = "",
		}
		sig.applySignature(func, funcSig)
		table.insert(functions, func)
	end

	-- ── Extract a literal value string from an expression ────────────────
	local function extractLiteralValue(val: luau.AstExpr): string?
		if val.type == "ExprTable" then
			local chunks: { string } = {}
			for _, i in val.items do
				local v = extractLiteralValue(i.value)
				if not v then
					continue
				end
				if not i.key then
					table.insert(chunks, v)
					continue
				end
				local k = extractLiteralValue(i.key)
				if not k then
					continue
				end
				table.insert(chunks, `[{k}] = {v}`)
			end
			if #chunks == 0 then
				return nil
			end
			return "{" .. table.concat(chunks, " ") .. "}"

			-- return tostring((val :: luau.ExprConstantNumber).value)
		elseif val.type == "ExprConstantNumber" then
			return tostring((val :: luau.ExprConstantNumber).value)
		elseif val.type == "ExprConstantString" then
			return '"' .. (val :: luau.ExprConstantString).value .. '"'
		elseif val.type == "ExprConstantBool" then
			return tostring((val :: luau.ExprConstantBool).value)
		elseif val.type == "ExprTypeAssertion" then
			local inner = (val :: luau.ExprTypeAssertion).expr
			if inner then
				return extractLiteralValue(inner)
			end
		end
		return nil
	end

	-- ── Process a type alias ─────────────────────────────────────────────
	local function extractFunctionExpr(val: luau.AstExpr?): luau.ExprFunction?
		if not val then
			return nil
		end
		if val.type == "ExprFunction" then
			return val :: luau.ExprFunction
		end
		if val.type == "ExprTypeAssertion" then
			local inner = (val :: luau.ExprTypeAssertion).expr
			if inner then
				return extractFunctionExpr(inner)
			end
		end
		return nil
	end

	local function extractTableExpr(val: luau.AstExpr): luau.ExprTable?
		if val.type == "ExprTable" then
			return val :: luau.ExprTable
		end
		if val.type == "ExprCall" then
			local call = val :: luau.ExprCall
			if call.func and call.func.type == "ExprIndexName" then
				local idx = call.func :: luau.ExprIndexName
				if
					idx.index == "freeze"
					and idx.expr.type == "ExprGlobal"
					and (idx.expr :: luau.ExprGlobal).name == "table"
				then
					if call.args and #call.args >= 1 and call.args[1].type == "ExprTable" then
						return call.args[1] :: luau.ExprTable
					end
				end
			end
		end
		return nil
	end

	local function buildTypeMembersFromTable(
		tbl: luau.TypeTable,
		findMemberDoc: (number) -> string?,
		ownerName: string
	): { FuncDoc }?
		if not tbl.props then
			return nil
		end

		local typeMembers: { FuncDoc } = {}
		for _, prop in tbl.props do
			local member = members.buildMember(prop, findMemberDoc, ownerName)
			if member then
				table.insert(typeMembers, member)
			end
		end
		return typeMembers
	end

	local function appendMemberList(into: { FuncDoc }?, extra: { FuncDoc }?): { FuncDoc }?
		if not extra or #extra == 0 then
			return into
		end
		if not into then
			into = {}
		end
		for _, member in extra do
			table.insert(into, member)
		end
		return into
	end

	local function appendUniqueStrings(into: { string }?, extra: { string }?): { string }?
		if not extra or #extra == 0 then
			return into
		end
		if not into then
			into = {}
		end

		local seen: { [string]: boolean } = {}
		for _, value in into do
			seen[value] = true
		end
		for _, value in extra do
			if not seen[value] then
				seen[value] = true
				table.insert(into, value)
			end
		end
		return into
	end

	local function collectExpandedTypeMembers(
		typeNode: luau.AstType?,
		findMemberDoc: (number) -> string?,
		ownerName: string
	): ({ FuncDoc }?, { string }?)
		local collectedMembers: { FuncDoc }? = nil
		local referencedTypes: { string }? = nil

		local function visit(node: luau.AstType?)
			if not node then
				return
			end

			if node.type == "TypeTable" then
				collectedMembers = appendMemberList(
					collectedMembers,
					buildTypeMembersFromTable(node :: luau.TypeTable, findMemberDoc, ownerName)
				)
			elseif node.type == "TypeIntersection" then
				for _, part in (node :: luau.TypeIntersection).types do
					visit(part)
				end
			elseif node.type == "TypeGroup" then
				visit((node :: luau.TypeGroup).inner)
			elseif node.type == "TypeReference" then
				local ref = node :: luau.TypeReference
				if ref.name == "setmetatable" and ref.parameters and #ref.parameters >= 1 then
					visit(unwrapTypeOrPack(ref.parameters[1]))
				elseif ref.name ~= "typeof" then
					local refName = if ref.prefix then ref.prefix .. "." .. ref.name else ref.name
					referencedTypes = appendUniqueStrings(referencedTypes, { refName })
				end
			end
		end

		visit(typeNode)
		return collectedMembers, referencedTypes
	end

	local function rebuildTypeSignature(typeDoc: TypeDoc)
		if not typeDoc.members or #typeDoc.members == 0 then
			return
		end

		local function memberSignatureForType(member: FuncDoc): string?
			if not member.signature then
				return nil
			end
			if member.owner and member.signature:sub(1, #member.owner + 1) == member.owner .. "." then
				return member.signature:sub(#member.owner + 1)
			end
			if member.owner and member.signature:sub(1, #member.owner + 1) == member.owner .. ":" then
				return member.signature:sub(#member.owner + 1)
			end
			return member.signature
		end

		local function memberSignaturePartsForType(member: FuncDoc): { SignaturePart }?
			if not member.signatureParts then
				return nil
			end

			local parts = member.signatureParts :: { SignaturePart }
			if
				member.owner
				and #parts >= 3
				and parts[1].text == member.owner
				and parts[2].kind == "punct"
				and (parts[2].text == "." or parts[2].text == ":")
				and parts[3].kind == "name"
			then
				local stripped: { SignaturePart } = {}
				for i = 2, #parts do
					table.insert(stripped, parts[i])
				end
				return stripped
			end
			return parts
		end

		local tableParts: { SignaturePart } = { tp("type ", false, "keyword") }
		table.insert(tableParts, tp(typeDoc.name, true, "type"))
		if typeDoc.generics and #typeDoc.generics > 0 then
			table.insert(tableParts, tp(renderGenerics(typeDoc.generics), false, "punct"))
		end
		table.insert(tableParts, tp(" = {\n", false, "punct"))
		for _, member in typeDoc.members do
			local memberParts = memberSignaturePartsForType(member)
			if memberParts then
				table.insert(tableParts, tp("    ", false, "plain"))
				tpExtend(tableParts, memberParts)
				table.insert(tableParts, tp(",\n", false, "punct"))
			end
		end
		table.insert(tableParts, tp("}", false, "punct"))

		local memberLines: { string } = {}
		for _, member in typeDoc.members do
			local memberSignature = memberSignatureForType(member)
			if memberSignature then
				table.insert(memberLines, "    " .. memberSignature .. ",")
			end
		end

		typeDoc.signatureParts = tableParts
		typeDoc.signatureFull = "type "
			.. typeDoc.name
			.. renderGenerics(typeDoc.generics)
			.. " = "
			.. "{\n"
			.. table.concat(memberLines, "\n")
			.. "\n}"
	end

	local function mergeMembersUnique(into: { FuncDoc }, extra: { FuncDoc })
		local seen: { [string]: boolean } = {}
		for _, member in into do
			seen[member.name .. "|" .. tostring(member.params ~= nil)] = true
		end
		for _, member in extra do
			local key = member.name .. "|" .. tostring(member.params ~= nil)
			if not seen[key] then
				seen[key] = true
				table.insert(into, member)
			end
		end
	end

	local function normalizeMemberOrder(typeDoc: TypeDoc)
		if not typeDoc.members or #typeDoc.members == 0 then
			return
		end

		local callableMembers: { FuncDoc } = {}
		local fieldMembers: { FuncDoc } = {}

		for _, member in typeDoc.members do
			if member.params then
				table.insert(callableMembers, member)
			else
				table.insert(fieldMembers, member)
			end
		end

		local reordered: { FuncDoc } = {}
		for _, member in callableMembers do
			table.insert(reordered, member)
		end
		for _, member in fieldMembers do
			table.insert(reordered, member)
		end

		typeDoc.members = reordered
	end

	local classImplDocs: { [string]: string } = {}
	for _, stat in result.root.body do
		if stat.type ~= "StatLocal" then
			continue
		end

		local doc = findDocComment(stat.location.beginline)
		if not doc then
			continue
		end

		local localStat = stat :: luau.StatLocal
		if not localStat.vars or not localStat.values then
			continue
		end

		for i, varNode in localStat.vars do
			if i ~= 1 then
				continue
			end

			local val: luau.AstExpr? = localStat.values[i]
			if not val or not varNode.name then
				continue
			end

			if extractTableExpr(val) then
				classImplDocs[varNode.name] = mergeDocText(classImplDocs[varNode.name], doc) :: string
			end
		end
	end

	local function processTypeAlias(stat: luau.StatTypeAlias, doc: string?)
		local line = stat.location.beginline
		local typeMembers: { FuncDoc }? = nil
		local metamethods: { FuncDoc }? = nil
		local aliasedType = stat.aliasedType
		local mixinTypes: { string }? = nil

		local function findMemberDoc(nodeLine: number): string?
			if nodeLine == line then
				return nil
			end
			return findDocComment(nodeLine)
		end

		typeMembers, mixinTypes = collectExpandedTypeMembers(aliasedType, findMemberDoc, stat.name)

		local generics: { string }? = nil
		local statAny = stat :: any
		local hasGenerics = stat.generics and #stat.generics > 0
		local hasGenericPacks = statAny.genericPacks and #statAny.genericPacks > 0
		if hasGenerics or hasGenericPacks then
			generics = {}
			if hasGenerics then
				for _, g in stat.generics do
					table.insert(generics :: { string }, genericName(g))
				end
			end
			if hasGenericPacks then
				for _, gp in statAny.genericPacks do
					table.insert(generics :: { string }, genericName(gp) .. "...")
				end
			end
		end

		local implTable, fieldsType, isInlineClass = classDetection.detectClassPattern(aliasedType)
		if implTable then
			doc = mergeDocText(doc, classImplDocs[implTable])
		end

		-- Pattern 3: inline setmetatable<{fields}, {meta}>
		if isInlineClass then
			local ref = aliasedType :: luau.TypeReference
			local params = ref.parameters
			if (not typeMembers) and params and #params >= 1 then
				local p1 = unwrapTypeOrPack(params[1])
				if p1 and p1.type == "TypeTable" then
					local tbl = p1 :: luau.TypeTable
					if tbl.props then
						typeMembers = {}
						for _, prop in tbl.props do
							local member = members.buildMember(prop, findMemberDoc, stat.name)
							if member then
								table.insert(typeMembers :: { FuncDoc }, member)
							end
						end
					end
				end
			end
			if params and #params >= 2 then
				local p2 = unwrapTypeOrPack(params[2])
				if p2 and p2.type == "TypeTable" then
					local tbl = p2 :: luau.TypeTable
					if tbl.props then
						metamethods = {}
						for _, prop in tbl.props do
							local member = members.buildMember(prop, findMemberDoc, stat.name)
							if member then
								table.insert(metamethods :: { FuncDoc }, member)
							end
						end
					end
				end
			end
		end

		if mixinTypes and #mixinTypes > 0 then
			typeMemberMixins[stat.name] = mixinTypes
		end

		local parsed = if doc then parseDocTags(doc) else nil

		-- @ignore: totally exclude from documentation
		if parsed and parsed.ignore then
			return
		end

		local typePrefix = "type " .. stat.name .. renderGenerics(generics) .. " = "

		-- Build signatureParts
		local typeSignatureParts: { SignaturePart }? = nil
		if not implTable and not isInlineClass and aliasedType then
			local aliasParts: { SignaturePart } = { tp("type ", false, "keyword") }
			table.insert(aliasParts, tp(stat.name, true, "type"))
			if generics and #generics > 0 then
				table.insert(aliasParts, tp(renderGenerics(generics), false, "punct"))
			end
			table.insert(aliasParts, tp(" = ", false, "punct"))
			tpExtend(aliasParts, td.describeTypeParts(aliasedType))
			typeSignatureParts = aliasParts
		elseif typeMembers and #typeMembers > 0 then
			local tableParts: { SignaturePart } = { tp("type ", false, "keyword") }
			table.insert(tableParts, tp(stat.name, true, "type"))
			if generics and #generics > 0 then
				table.insert(tableParts, tp(renderGenerics(generics), false, "punct"))
			end
			table.insert(tableParts, tp(" = {\n", false, "punct"))
			for _, m in typeMembers :: { FuncDoc } do
				if m.signatureParts then
					table.insert(tableParts, tp("    ", false, "plain"))
					tpExtend(tableParts, m.signatureParts :: { SignaturePart })
					table.insert(tableParts, tp(",\n", false, "punct"))
				end
			end
			table.insert(tableParts, tp("}", false, "punct"))
			typeSignatureParts = tableParts
		end

		local kind: "class" | "table" | "alias" = if implTable or isInlineClass
			then "class"
			elseif typeMembers then "table"
			else "alias"

		local typeDoc: TypeDoc = {
			name = stat.name,
			exported = stat.exported,
			kind = kind,
			doc = if parsed then parsed.body else doc,
			extendsTypes = if mixinTypes and #mixinTypes > 0 then mixinTypes else nil,
			signatureFull = if not implTable
					and not isInlineClass
					and aliasedType
				then typePrefix .. td.describeTypeFull(aliasedType)
				elseif typeMembers and #typeMembers > 0 then typePrefix .. members.buildTableSignatureFull(
					typeMembers :: { FuncDoc }
				)
				else nil,
			signatureParts = typeSignatureParts,
			location = stat.location,
			members = typeMembers or (if implTable or isInlineClass then {} else nil),
			generics = generics,
			parsedDoc = parsed,
			classImplTable = implTable,
			classFieldsType = fieldsType,
			metamethods = metamethods,
			aliasedTypeNode = aliasedType,
		}
		table.insert(typeDocs, typeDoc)

		if implTable then
			classImplToType[implTable] = stat.name
		end
		if fieldsType then
			suppressedTypes[fieldsType] = true
		end
	end

	-- ── Walk top-level statements ────────────────────────────────────────
	for _, stat in result.root.body do
		local line = stat.location.beginline
		local doc = findDocComment(line)

		if stat.type == "StatTypeAlias" then
			processTypeAlias(stat :: luau.StatTypeAlias, doc)
		elseif stat.type == "StatFunction" then
			local funcStat = stat :: luau.StatFunction
			local fname: string? = nil
			local owner: string? = nil
			if funcStat.name then
				if funcStat.name.type == "ExprIndexName" then
					local idx = funcStat.name :: luau.ExprIndexName
					fname = idx.index
					owner = exprToPath(idx.expr)
				elseif funcStat.name.type == "ExprGlobal" then
					fname = (funcStat.name :: luau.ExprGlobal).name
				end
			end
			processFunction(fname or "<anonymous>", owner, funcStat.func, stat.location, doc)
		elseif stat.type == "StatLocalFunction" then
			local localFunc = stat :: luau.StatLocalFunction
			local fname = localFunc.name and localFunc.name.name or "<anonymous>"
			if returnedRoots[fname] then
				processFunction(fname, nil, localFunc.func, stat.location, doc)
			end
		elseif stat.type == "StatLocal" then
			local localStat = stat :: luau.StatLocal
			if localStat.vars and localStat.values then
				for i, varNode in localStat.vars do
					local varName = varNode.name
					local val: luau.AstExpr? = localStat.values[i]
					if not val then
						continue
					end

					local fnExpr = extractFunctionExpr(val)
					if fnExpr and varName and returnedRoots[varName] then
						processFunction(varName, nil, fnExpr, stat.location, if i == 1 then doc else nil)
						continue
					end

					if varName and returnedRoots[varName] then
						local valStr = extractLiteralValue(val :: luau.AstExpr)
						if valStr then
							table.insert(constants, {
								name = varName,
								value = valStr,
								groupTitle = if i == 1 then doc else nil,
								doc = inlineComments[line],
								owner = nil,
							})
						end
					end
				end
			end
		elseif stat.type == "StatAssign" then
			local assignStat = stat :: luau.StatAssign
			if assignStat.vars and assignStat.values then
				for i, var in assignStat.vars do
					local cname: string? = nil
					local cowner: string? = nil
					local isExported = false
					if var.type == "ExprIndexName" then
						local idx = var :: luau.ExprIndexName
						cname = idx.index
						cowner = exprToPath(idx.expr)
						isExported = exprRootIsExported(idx.expr)
					elseif var.type == "ExprGlobal" then
						cname = (var :: luau.ExprGlobal).name
						isExported = true
					end
					if not isExported or not cname then
						continue
					end
					local name: string = cname :: string
					if name:match("^__") then
						continue
					end
					local val: luau.AstExpr? = assignStat.values[i]

					local fnExpr = extractFunctionExpr(val)
					if fnExpr then
						local ownerPath = if var.type == "ExprIndexName"
							then exprToPath((var :: luau.ExprIndexName).expr)
							else nil
						processFunction(name, ownerPath, fnExpr, stat.location, if i == 1 then doc else nil)
						continue
					end

					-- Table constructor: foo.bar = { ... } or foo.bar = table.freeze({ ... })
					if val then
						local tableExpr = extractTableExpr(val)
						if tableExpr then
							local ownerPath = exprToPath(var)
							for _, item in tableExpr.items do
								if item.kind ~= "Record" or not item.key then
									continue
								end
								local keyName: string? = nil
								if item.key.type == "ExprConstantString" then
									keyName = (item.key :: luau.ExprConstantString).value
								end
								if not keyName then
									continue
								end

								local itemDoc = findDocComment(item.value.location.beginline)

								local itemFnExpr = extractFunctionExpr(item.value)
								if itemFnExpr then
									processFunction(
										keyName :: string,
										ownerPath,
										itemFnExpr,
										item.value.location,
										itemDoc
									)
								else
									local litVal = extractLiteralValue(item.value)
									if litVal then
										table.insert(
											constants,
											{
												name = keyName :: string,
												value = litVal,
												groupTitle = nil,
												doc = inlineComments[item.value.location.beginline],
												owner = ownerPath,
											} :: ConstDoc
										)
									end
								end
							end
							continue
						end
					end

					if val then
						local valStr = extractLiteralValue(val :: luau.AstExpr)
						if valStr then
							table.insert(
								constants,
								{
									name = name,
									value = valStr,
									groupTitle = if i == 1 then doc else nil,
									doc = inlineComments[line],
									owner = cowner,
								} :: ConstDoc
							)
						end
					end
				end
			end
		end
	end

	-- ── Post-processing: move functions into their owner class ───────────
	local classTypeByName: { [string]: TypeDoc } = {}
	for _, t in typeDocs do
		if t.classImplTable then
			classTypeByName[t.classImplTable] = t
		end
	end

	local remainingFunctions: { FuncDoc } = {}
	for _, f in functions do
		local ownerType = if f.owner then classTypeByName[f.owner] else nil
		if ownerType and ownerType.members then
			table.insert(ownerType.members :: { FuncDoc }, f)
		else
			table.insert(remainingFunctions, f)
		end
	end
	functions = remainingFunctions

	-- Merge fields from a separate `Fields` type into the class TypeDoc when
	-- `classFieldsType` references a named type that holds the instance fields.
	local typeByName: { [string]: TypeDoc } = {}
	for _, t in typeDocs do
		typeByName[t.name] = t
	end
	for _, t in typeDocs do
		if t.classFieldsType then
			local fieldsType = typeByName[t.classFieldsType]
			if fieldsType and fieldsType.members and #fieldsType.members > 0 then
				-- Ensure the target has a members table to receive merged fields
				if not t.members then
					t.members = {}
				end
				mergeMembersUnique(t.members, fieldsType.members)
			end
		end

		local mixins = typeMemberMixins[t.name]
		if t.kind == "class" and mixins and #mixins > 0 then
			if not t.members then
				t.members = {}
			end
			for _, mixinName in mixins do
				local mixinType = typeByName[mixinName]
				if mixinType and mixinType.members and #mixinType.members > 0 then
					mergeMembersUnique(t.members, mixinType.members)
				end
			end
		end

		normalizeMemberOrder(t)
		if t.kind == "class" then
			rebuildTypeSignature(t)
		end
	end

	local function collectReferencedTypeDocs(
		node: luau.AstType | luau.AstTypePack?,
		seenRefs: { [string]: boolean },
		out: { TypeDoc }
	)
		if not node then
			return
		end

		if node.type == "TypeReference" then
			local ref = node :: luau.TypeReference
			if ref.name == "setmetatable" or ref.name == "typeof" then
				if ref.parameters then
					for _, parameter in ref.parameters do
						collectReferencedTypeDocs(unwrapTypeOrPack(parameter), seenRefs, out)
					end
				end
				return
			end

			local refName = if ref.prefix then ref.prefix .. "." .. ref.name else ref.name
			local refType = typeByName[refName]
			if refType and not seenRefs[refName] then
				seenRefs[refName] = true
				table.insert(out, refType)
			end

			if ref.parameters then
				for _, parameter in ref.parameters do
					collectReferencedTypeDocs(unwrapTypeOrPack(parameter), seenRefs, out)
				end
			end
		elseif node.type == "TypeTable" then
			local tbl = node :: luau.TypeTable
			if tbl.props then
				for _, prop in tbl.props do
					collectReferencedTypeDocs(prop.type, seenRefs, out)
				end
			end
			if tbl.indexer then
				collectReferencedTypeDocs(tbl.indexer.indexType, seenRefs, out)
				collectReferencedTypeDocs(tbl.indexer.resultType, seenRefs, out)
			end
		elseif node.type == "TypeFunction" then
			local fn = node :: luau.TypeFunction
			local argTypes, argTail = normalizeTypeList(fn.argTypes)
			for _, argType in argTypes do
				collectReferencedTypeDocs(argType, seenRefs, out)
			end
			collectReferencedTypeDocs(argTail, seenRefs, out)
			collectReferencedTypeDocs(fn.returnTypes, seenRefs, out)
		elseif node.type == "TypeUnion" then
			for _, part in (node :: luau.TypeUnion).types do
				collectReferencedTypeDocs(part, seenRefs, out)
			end
		elseif node.type == "TypeIntersection" then
			for _, part in (node :: luau.TypeIntersection).types do
				collectReferencedTypeDocs(part, seenRefs, out)
			end
		elseif node.type == "TypeGroup" then
			collectReferencedTypeDocs((node :: luau.TypeGroup).inner, seenRefs, out)
		elseif node.type == "TypePackExplicit" then
			local pack = node :: luau.TypePackExplicit
			if pack.types then
				for _, part in pack.types do
					collectReferencedTypeDocs(part, seenRefs, out)
				end
			end
			collectReferencedTypeDocs(pack.tail, seenRefs, out)
		elseif node.type == "TypePackVariadic" then
			collectReferencedTypeDocs((node :: luau.TypePackVariadic).variadicType, seenRefs, out)
		elseif node.type == "TypeError" then
			for _, part in (node :: luau.TypeError).types do
				collectReferencedTypeDocs(part, seenRefs, out)
			end
		end
	end

	local hoverTextCache: { [string]: string? } = {}
	local function collectDirectTypeDependencies(typeDoc: TypeDoc): { TypeDoc }
		local dependencies: { TypeDoc } = {}
		if not typeDoc.aliasedTypeNode then
			return dependencies
		end

		collectReferencedTypeDocs(typeDoc.aliasedTypeNode, { [typeDoc.name] = true }, dependencies)
		return dependencies
	end

	local function buildTypeHoverText(typeDoc: TypeDoc): string?
		local cached = hoverTextCache[typeDoc.name]
		if cached ~= nil then
			return cached
		end

		local sections: { string } = {}
		local includedTypes: { [string]: boolean } = {}

		local function addTypeSection(target: TypeDoc?)
			if not target or includedTypes[target.name] then
				return
			end

			local text = clampHoverText(formatTypeHoverSignature(target))
			if not text or text == "" then
				return
			end

			includedTypes[target.name] = true
			table.insert(sections, text)
		end

		addTypeSection(typeDoc)

		local queue = if typeDoc.kind == "class" then collectDirectTypeDependencies(typeDoc) else {}
		local index = 1
		while index <= #queue do
			local dependency = queue[index]
			index += 1

			if dependency and not includedTypes[dependency.name] then
				addTypeSection(dependency)
				for _, nested in collectDirectTypeDependencies(dependency) do
					if not includedTypes[nested.name] then
						table.insert(queue, nested)
					end
				end
			end
		end

		local hoverText = if #sections > 0 then clampHoverText(table.concat(sections, "\n\n")) else nil
		hoverTextCache[typeDoc.name] = hoverText
		return hoverText
	end

	local function annotateSignatureParts(parts: { SignaturePart }?)
		if not parts then
			return
		end
		for _, part in parts do
			if part.typeRef then
				local refType = typeByName[part.text]
				if refType then
					part.hoverText = buildTypeHoverText(refType)
				end
			end
		end
	end

	local function annotateSignatureMeta(meta: SignatureMeta?)
		if not meta then
			return
		end
		if meta.params then
			for _, param in meta.params do
				annotateSignatureParts(param.typeParts)
			end
		end
		if meta.returns then
			for _, ret in meta.returns do
				annotateSignatureParts(ret.typeParts)
			end
		end
	end

	for _, t in typeDocs do
		annotateSignatureParts(t.signatureParts)
		if t.members then
			for _, member in t.members do
				annotateSignatureParts(member.signatureParts)
				annotateSignatureMeta(member.signatureMeta)
			end
		end
		if t.metamethods then
			for _, member in t.metamethods do
				annotateSignatureParts(member.signatureParts)
				annotateSignatureMeta(member.signatureMeta)
			end
		end
	end
	for _, f in functions do
		annotateSignatureParts(f.signatureParts)
		annotateSignatureMeta(f.signatureMeta)
	end

	-- ── Detect primary export ────────────────────────────────────────────
	local returnedNamesList: { string } = {}
	for name in returnedRoots do
		table.insert(returnedNamesList, name)
	end
	if #returnedNamesList == 1 then
		local implName = returnedNamesList[1]
		for _, t in typeDocs do
			if t.classImplTable == implName then
				t.exported = true
				t.isPrimaryExport = true
				break
			end
		end
	end

	-- ── Suppress internal fields types ───────────────────────────────────
	local remainingTypes: { TypeDoc } = {}
	for _, t in typeDocs do
		if not suppressedTypes[t.name] then
			table.insert(remainingTypes, t)
		end
	end
	typeDocs = remainingTypes

	-- ── Determine module root name ──────────────────────────────────────
	local moduleRoot: string? = nil
	for name in returnedRoots do
		moduleRoot = name
		break
	end

	return {
		types = typeDocs,
		functions = functions,
		constants = constants,
		moduleDescription = moduleDescription,
		moduleRoot = moduleRoot,
	}
end

extract.describeType = td.describeType
extract.describeTypeParts = td.describeTypeParts
extract.describeTypeFull = td.describeTypeFull

return extract
