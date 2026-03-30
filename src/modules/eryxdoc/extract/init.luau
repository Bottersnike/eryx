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

function extract.extract(result: luau.ParseResult, sourceLines: { string }): ExtractedDocs
	local commentBlocks, inlineComments = comments.collectComments(result, sourceLines)

	-- ── Module description detection ─────────────────────────────────────
	local moduleDescription: string? = nil
	local moduleBlockIdx: number? = nil
	if
		#commentBlocks > 0
		and result.comments
		and #result.comments > 0
		and result.comments[1].location.start.line == 1
	then
		local first = commentBlocks[1]
		local firstStat = if result.root.body and #result.root.body > 0 then result.root.body[1] else nil
		local firstStatLine = if firstStat then firstStat.location.start.line else nil

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

	-- ── Collect returned names for export detection ──────────────────────
	local returnedRoots: { [string]: boolean } = {}
	for _, stat in result.root.body do
		if stat.type == "StatReturn" then
			local retStat = stat :: luau.StatReturn
			local list = retStat.list
			if list then
				for _, expr in list do
					if expr.type == "ExprGlobal" then
						returnedRoots[(expr :: luau.ExprGlobal).name] = true
					elseif expr.type == "ExprLocal" then
						local loc = expr :: luau.ExprLocal
						local name = loc["local"] and loc["local"].name
						if name then
							returnedRoots[name] = true
						end
					end
				end
			end
		end
	end

	-- ── AST helpers ─────────────────────────────────────────────────────
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
	local function processTypeAlias(stat: luau.StatTypeAlias, doc: string?)
		local line = stat.location.start.line
		local typeMembers: { FuncDoc }? = nil
		local metamethods: { FuncDoc }? = nil
		local aliasedType = stat.aliasedType

		if aliasedType and aliasedType.type == "TypeTable" then
			local tbl = aliasedType :: luau.TypeTable
			if tbl.props then
				typeMembers = {}
				for _, prop in tbl.props do
					local function findMemberDoc(nodeLine: number): string?
						if nodeLine == line then
							return nil
						end
						return findDocComment(nodeLine)
					end
					table.insert(typeMembers :: { FuncDoc }, members.buildMember(prop, findMemberDoc, stat.name))
				end
			end
		end

		local generics: { string }? = nil
		if stat.generics and #stat.generics > 0 then
			generics = {}
			for _, g in stat.generics do
				table.insert(generics :: { string }, g)
			end
		end

		local implTable, fieldsType, isInlineClass = classDetection.detectClassPattern(aliasedType)

		-- Pattern 3: inline setmetatable<{fields}, {meta}>
		if isInlineClass and not typeMembers then
			local ref = aliasedType :: luau.TypeReference
			local params = ref.parameters
			local function findMemberDoc(nodeLine: number): string?
				if nodeLine == line then
					return nil
				end
				return findDocComment(nodeLine)
			end
			if params and #params >= 1 then
				local p1 = params[1]
				if p1 and p1.type == "TypeTable" then
					local tbl = p1 :: luau.TypeTable
					if tbl.props then
						typeMembers = {}
						for _, prop in tbl.props do
							table.insert(
								typeMembers :: { FuncDoc },
								members.buildMember(prop, findMemberDoc, stat.name)
							)
						end
					end
				end
			end
			if params and #params >= 2 then
				local p2 = params[2]
				if p2 and p2.type == "TypeTable" then
					local tbl = p2 :: luau.TypeTable
					if tbl.props then
						metamethods = {}
						for _, prop in tbl.props do
							table.insert(
								metamethods :: { FuncDoc },
								members.buildMember(prop, findMemberDoc, stat.name)
							)
						end
					end
				end
			end
		end

		local parsed = if doc then parseDocTags(doc) else nil

		-- @ignore: totally exclude from documentation
		if parsed and parsed.ignore then
			return
		end

		local typePrefix = "type "
			.. stat.name
			.. (if generics and #generics > 0 then "<" .. table.concat(generics :: { string }, ", ") .. ">" else "")
			.. " = "

		-- Build signatureParts
		local typeSignatureParts: { SignaturePart }? = nil
		if not implTable and not isInlineClass and aliasedType and (not typeMembers or #typeMembers == 0) then
			local aliasParts: { SignaturePart } = { tp("type ", false, "keyword") }
			table.insert(aliasParts, tp(stat.name, true, "type"))
			if generics and #generics > 0 then
				table.insert(aliasParts, tp("<" .. table.concat(generics :: { string }, ", ") .. ">", false, "punct"))
			end
			table.insert(aliasParts, tp(" = ", false, "punct"))
			tpExtend(aliasParts, td.describeTypeParts(aliasedType))
			typeSignatureParts = aliasParts
		elseif typeMembers and #typeMembers > 0 then
			local tableParts: { SignaturePart } = { tp("type ", false, "keyword") }
			table.insert(tableParts, tp(stat.name, true, "type"))
			if generics and #generics > 0 then
				table.insert(tableParts, tp("<" .. table.concat(generics :: { string }, ", ") .. ">", false, "punct"))
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
			signatureFull = if typeMembers and #typeMembers > 0
				then typePrefix .. members.buildTableSignatureFull(typeMembers :: { FuncDoc })
				elseif not implTable and not isInlineClass and aliasedType then typePrefix .. td.describeTypeFull(
					aliasedType
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
		local line = stat.location.start.line
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

					if val.type == "ExprFunction" and varName and returnedRoots[varName] then
						processFunction(
							varName,
							nil,
							val :: luau.ExprFunction,
							stat.location,
							if i == 1 then doc else nil
						)
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

					if val and val.type == "ExprFunction" then
						local ownerPath = if var.type == "ExprIndexName"
							then exprToPath((var :: luau.ExprIndexName).expr)
							else nil
						processFunction(
							name,
							ownerPath,
							val :: luau.ExprFunction,
							stat.location,
							if i == 1 then doc else nil
						)
						continue
					end

					-- Table constructor: foo.bar = { ... } or foo.bar = table.freeze({ ... })
					if val then
						local tableExpr: luau.ExprTable? = nil
						if val.type == "ExprTable" then
							tableExpr = val :: luau.ExprTable
						elseif val.type == "ExprCall" then
							local call = val :: luau.ExprCall
							if call.func and call.func.type == "ExprIndexName" then
								local idx = call.func :: luau.ExprIndexName
								if
									idx.index == "freeze"
									and idx.expr.type == "ExprGlobal"
									and (idx.expr :: luau.ExprGlobal).name == "table"
								then
									if call.args and #call.args >= 1 and call.args[1].type == "ExprTable" then
										tableExpr = call.args[1] :: luau.ExprTable
									end
								end
							end
						end

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

								local itemDoc = findDocComment(item.value.location.start.line)

								if item.value.type == "ExprFunction" then
									processFunction(
										keyName :: string,
										ownerPath,
										item.value :: luau.ExprFunction,
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
												doc = inlineComments[item.value.location.start.line],
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
				for _, m in fieldsType.members do
					table.insert(t.members, m)
				end
			end
		end
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
