--- @ignore

-- Converts AST type nodes into human-readable string and structured token representations.
--
-- `describeTypeParts` is the single source of truth for rendering types.
-- `describeType` derives the string by concatenating part texts.

local luau = require("@eryx/luau/ast")
local types = require("./types")
type SignaturePart = types.SignaturePart

local INLINE_WIDTH = 72
local INDENT_UNIT = "    "

local function tp(
	text: string,
	typeRef: boolean?,
	kind: ("type" | "param" | "punct" | "keyword" | "name" | "plain")?
): SignaturePart
	return { text = text, typeRef = typeRef, kind = kind or (if typeRef then "type" else nil) }
end

local function tpExtend(dest: { SignaturePart }, src: { SignaturePart })
	for _, p in src do
		table.insert(dest, p)
	end
end

local function partsToString(parts: { SignaturePart }): string
	local buf: { string } = {}
	for _, p in parts do
		table.insert(buf, p.text)
	end
	return table.concat(buf)
end

local function indent(level: number): string
	return string.rep(INDENT_UNIT, level)
end

local function hasLineBreak(parts: { SignaturePart }): boolean
	for _, part in parts do
		if string.find(part.text, "\n", 1, true) then
			return true
		end
	end
	return false
end

local function fitsInline(parts: { SignaturePart }, level: number): boolean
	if hasLineBreak(parts) then
		return false
	end
	return #partsToString(parts) + #indent(level) <= INLINE_WIDTH
end

local describer = {}

local function normalizeTypeList(typeList: any): ({ any }, any)
	if type(typeList) ~= "table" then
		return {}, nil
	end

	-- New shape: { types = {...}, tail = ... }
	if type(typeList.types) == "table" then
		return typeList.types, typeList.tail
	end

	-- Old shape: direct array
	return typeList, nil
end

local function unwrapTypeOrPack(value: any): any
	-- New shape for generic params in TypeReference / calls:
	-- { kind = "Type"|"TypePack", value = ... }
	if type(value) == "table" and value.kind and value.value ~= nil then
		return value.value
	end
	return value
end

local function describeCompactTypeParts(node: luau.AstType | luau.AstTypePack): { SignaturePart }
	if node == nil then
		return { tp("any", true, "type") }
	end

	if node.type == "TypeReference" then
		local ref = node :: luau.TypeReference
		local parts: { SignaturePart } = {}
		if ref.prefix then
			table.insert(parts, tp(ref.prefix, false, "plain"))
			table.insert(parts, tp(".", false, "punct"))
		end
		table.insert(parts, tp(ref.name, true, "type"))
		if ref.parameters then
			table.insert(parts, tp("<", false, "punct"))
			for i, p in ref.parameters do
				if i > 1 then
					table.insert(parts, tp(", ", false, "punct"))
				end
				local inner = unwrapTypeOrPack(p)
				tpExtend(parts, describer.describeTypeParts(inner))
			end
			table.insert(parts, tp(">", false, "punct"))
		end
		return parts
	elseif node.type == "TypeTable" then
		local tbl = node :: luau.TypeTable
		if tbl.indexer then
			local idx = tbl.indexer
			local resultType = idx.resultType or idx.indexerType or idx.result
			local indexType = idx.indexType or idx.keyType or nil
			if resultType then
				if not indexType or partsToString(describer.describeTypeParts(indexType)) == "number" then
					local parts = { tp("{ ", false, "punct") }
					tpExtend(parts, describer.describeTypeParts(resultType))
					table.insert(parts, tp(" }", false, "punct"))
					return parts
				end
				local parts = { tp("{ [", false, "punct") }
				tpExtend(parts, describer.describeTypeParts(indexType))
				table.insert(parts, tp("]: ", false, "punct"))
				tpExtend(parts, describer.describeTypeParts(resultType))
				table.insert(parts, tp(" }", false, "punct"))
				return parts
			end
		end
		if not tbl.props or #tbl.props == 0 then
			return { tp("{}", false, "punct") }
		end
		local parts = { tp("{ ", false, "punct") }
		for i, prop in tbl.props do
			if i > 1 then
				table.insert(parts, tp(", ", false, "punct"))
			end
			table.insert(parts, tp(prop.name, false, "param"))
			table.insert(parts, tp(": ", false, "punct"))
			tpExtend(parts, describer.describeTypeParts(prop.type))
		end
		table.insert(parts, tp(" }", false, "punct"))
		return parts
	elseif node.type == "TypeFunction" then
		local fn = node :: luau.TypeFunction
		local parts: { SignaturePart } = { tp("(", false, "punct"), tp("(", false, "punct") }
		if fn.argTypes then
			local argTypes = fn.argTypes
			local argTail = nil
			argTypes, argTail = normalizeTypeList(fn.argTypes)

			for i, a in argTypes do
				if i > 1 then
					table.insert(parts, tp(", ", false, "punct"))
				end
				local argName = if fn.argNames and fn.argNames[i] then fn.argNames[i] else nil
				if argName then
					local renderedName = if type(argName) == "table" then argName.name else argName
					table.insert(parts, tp(renderedName :: string, false, "param"))
					table.insert(parts, tp(": ", false, "punct"))
				end
				tpExtend(parts, describer.describeTypeParts(a))
			end

			if argTail then
				if #argTypes > 0 then
					table.insert(parts, tp(", ", false, "punct"))
				end
				tpExtend(parts, describer.describeTypeParts(argTail))
			end
		end
		table.insert(parts, tp(") \xe2\x86\x92 ", false, "punct"))
		if fn.returnTypes then
			tpExtend(parts, describer.describeTypeParts(fn.returnTypes))
		else
			table.insert(parts, tp("()", false, "punct"))
		end
		table.insert(parts, tp(")", false, "punct"))
		return parts
	elseif node.type == "TypeUnion" then
		local u = node :: luau.TypeUnion
		if #u.types == 2 and u.types[2] and u.types[2].type == "TypeOptional" then
			local parts = describer.describeTypeParts(u.types[1])
			table.insert(parts, tp("?", false, "punct"))
			return parts
		end
		local parts: { SignaturePart } = {}
		local first = true
		for _, t in u.types do
			if t.type == "TypeOptional" then
				continue
			end
			if not first then
				table.insert(parts, tp(" | ", false, "punct"))
			end
			tpExtend(parts, describer.describeTypeParts(t))
			first = false
		end
		if u.types[#u.types] and u.types[#u.types].type == "TypeOptional" then
			table.insert(parts, tp("?", false, "punct"))
		end
		return parts
	elseif node.type == "TypeIntersection" then
		local inter = node :: luau.TypeIntersection
		local parts: { SignaturePart } = {}
		for i, t in inter.types do
			if i > 1 then
				table.insert(parts, tp(" & ", false, "punct"))
			end
			tpExtend(parts, describer.describeTypeParts(t))
		end
		return parts
	elseif node.type == "TypeOptional" then
		return { tp("?", false, "punct") }
	elseif node.type == "TypeSingletonBool" then
		return { tp(tostring((node :: luau.TypeSingletonBool).value), false, "keyword") }
	elseif node.type == "TypeSingletonString" then
		return { tp('"' .. tostring((node :: luau.TypeSingletonString).value) .. '"', false, "plain") }
	elseif node.type == "TypeGroup" then
		local parts = { tp("(", false, "punct") }
		tpExtend(parts, describer.describeTypeParts((node :: luau.TypeGroup).inner))
		table.insert(parts, tp(")", false, "punct"))
		return parts
	elseif node.type == "TypePackExplicit" then
		local pack = node :: luau.TypePackExplicit
		if pack.types then
			local inner: { SignaturePart } = {}
			for i, t in pack.types do
				if i > 1 then
					table.insert(inner, tp(", ", false, "punct"))
				end
				tpExtend(inner, describer.describeTypeParts(t))
			end
			if pack.tail then
				table.insert(inner, tp(", ", false, "punct"))
				tpExtend(inner, describer.describeTypeParts(pack.tail))
				local parts = { tp("(", false, "punct") }
				tpExtend(parts, inner)
				table.insert(parts, tp(")", false, "punct"))
				return parts
			end
			if #pack.types == 1 then
				return inner
			end
			local parts = { tp("(", false, "punct") }
			tpExtend(parts, inner)
			table.insert(parts, tp(")", false, "punct"))
			return parts
		end
		return { tp("()", false, "punct") }
	elseif node.type == "TypePackVariadic" then
		local parts = { tp("...", false, "punct") }
		tpExtend(parts, describer.describeTypeParts((node :: luau.TypePackVariadic).variadicType))
		return parts
	elseif node.type == "TypePackGeneric" then
		return { tp((node :: luau.TypePackGeneric).name .. "...", false, "type") }
	end

	return { tp("<" .. tostring(node.type) .. ">", false, "plain") }
end

local function appendIndentedLine(
	parts: { SignaturePart },
	level: number,
	lineParts: { SignaturePart },
	suffix: string?
)
	table.insert(parts, tp(indent(level), false, "plain"))
	tpExtend(parts, lineParts)
	if suffix and suffix ~= "" then
		table.insert(parts, tp(suffix, false, "punct"))
	end
end

local function describePrettyTypeParts(node: luau.AstType | luau.AstTypePack, level: number): { SignaturePart }
	local compact = describeCompactTypeParts(node)
	if fitsInline(compact, level) then
		return compact
	end

	if node.type == "TypeReference" then
		local ref = node :: luau.TypeReference
		if not ref.parameters or #ref.parameters == 0 then
			return compact
		end

		local paramParts: { { SignaturePart } } = {}
		local multiline = false
		for _, parameter in ref.parameters do
			local prettyParam = describePrettyTypeParts(unwrapTypeOrPack(parameter), level + 1)
			if hasLineBreak(prettyParam) then
				multiline = true
			end
			table.insert(paramParts, prettyParam)
		end

		if not multiline then
			local inlineLength = #ref.name + 2
			if ref.prefix then
				inlineLength += #ref.prefix + 1
			end
			for i, parts in paramParts do
				inlineLength += #partsToString(parts)
				if i > 1 then
					inlineLength += 2
				end
			end
			if inlineLength + #indent(level) <= INLINE_WIDTH then
				return compact
			end
		end

		local parts: { SignaturePart } = {}
		if ref.prefix then
			table.insert(parts, tp(ref.prefix, false, "plain"))
			table.insert(parts, tp(".", false, "punct"))
		end
		table.insert(parts, tp(ref.name, true, "type"))
		table.insert(parts, tp("<\n", false, "punct"))
		for i, prettyParam in paramParts do
			appendIndentedLine(parts, level + 1, prettyParam, if i < #paramParts then ",\n" else "\n")
		end
		table.insert(parts, tp(indent(level) .. ">", false, "punct"))
		return parts
	elseif node.type == "TypeTable" then
		local tbl = node :: luau.TypeTable
		if tbl.indexer then
			local idx = tbl.indexer
			local resultType = idx.resultType or idx.indexerType or idx.result
			local indexType = idx.indexType or idx.keyType or nil
			if not resultType then
				return compact
			end

			local resultParts = describePrettyTypeParts(resultType, level + 1)
			if not indexType or partsToString(describeCompactTypeParts(indexType)) == "number" then
				local parts: { SignaturePart } = { tp("{\n", false, "punct") }
				appendIndentedLine(parts, level + 1, resultParts, "\n")
				table.insert(parts, tp(indent(level) .. "}", false, "punct"))
				return parts
			end

			local indexParts = describePrettyTypeParts(indexType, level + 1)
			local parts: { SignaturePart } = { tp("{\n", false, "punct") }
			table.insert(parts, tp(indent(level + 1) .. "[", false, "punct"))
			tpExtend(parts, indexParts)
			table.insert(parts, tp("]: ", false, "punct"))
			tpExtend(parts, resultParts)
			table.insert(parts, tp("\n" .. indent(level) .. "}", false, "punct"))
			return parts
		end

		if not tbl.props or #tbl.props == 0 then
			return compact
		end

		local parts: { SignaturePart } = { tp("{\n", false, "punct") }
		for i, prop in tbl.props do
			table.insert(parts, tp(indent(level + 1), false, "plain"))
			table.insert(parts, tp(prop.name, false, "param"))
			table.insert(parts, tp(": ", false, "punct"))
			tpExtend(parts, describePrettyTypeParts(prop.type, level + 1))
			table.insert(parts, tp(if i < #tbl.props then ",\n" else "\n", false, "punct"))
		end
		table.insert(parts, tp(indent(level) .. "}", false, "punct"))
		return parts
	elseif node.type == "TypeFunction" then
		local fn = node :: luau.TypeFunction
		local argTypes, argTail = normalizeTypeList(fn.argTypes)
		local inlineReturn = if fn.returnTypes then describePrettyTypeParts(fn.returnTypes, level + 1) else nil

		local hasArgs = #argTypes > 0 or argTail ~= nil
		local parts: { SignaturePart } = if hasArgs then { tp("(\n", false, "punct") } else { tp("()", false, "punct") }
		for i, argType in argTypes do
			local argParts = describePrettyTypeParts(argType, level + 1)
			table.insert(parts, tp(indent(level + 1), false, "plain"))
			local argName = if fn.argNames and fn.argNames[i] then fn.argNames[i] else nil
			if argName then
				local renderedName = if type(argName) == "table" then argName.name else argName
				table.insert(parts, tp(renderedName :: string, false, "param"))
				table.insert(parts, tp(": ", false, "punct"))
			end
			tpExtend(parts, argParts)
			local hasMoreArgs = i < #argTypes or argTail ~= nil
			table.insert(parts, tp(if hasMoreArgs then ",\n" else "\n", false, "punct"))
		end
		if argTail then
			table.insert(parts, tp(indent(level + 1), false, "plain"))
			tpExtend(parts, describePrettyTypeParts(argTail, level + 1))
			table.insert(parts, tp("\n", false, "punct"))
		end
		if hasArgs then
			table.insert(parts, tp(indent(level) .. ")", false, "punct"))
		end
		if inlineReturn and fitsInline(inlineReturn, level) then
			table.insert(parts, tp(" → ", false, "punct"))
			tpExtend(parts, inlineReturn)
		else
			table.insert(parts, tp(" →\n", false, "punct"))
			if inlineReturn then
				appendIndentedLine(parts, level + 1, inlineReturn, "")
			else
				table.insert(parts, tp(indent(level + 1) .. "()", false, "punct"))
			end
		end
		return parts
	elseif node.type == "TypeUnion" then
		local union = node :: luau.TypeUnion
		if #union.types == 2 and union.types[2] and union.types[2].type == "TypeOptional" then
			local parts = describePrettyTypeParts(union.types[1], level)
			table.insert(parts, tp("?", false, "punct"))
			return parts
		end

		local visible: { luau.AstType } = {}
		for _, part in union.types do
			if part.type ~= "TypeOptional" then
				table.insert(visible, part)
			end
		end
		if #visible == 0 then
			return compact
		end

		local parts = describePrettyTypeParts(visible[1], level)
		if #visible == 2 and not hasLineBreak(parts) then
			table.insert(parts, tp(" | ", false, "punct"))
			tpExtend(parts, describePrettyTypeParts(visible[2], level))
			if union.types[#union.types] and union.types[#union.types].type == "TypeOptional" then
				table.insert(parts, tp("?", false, "punct"))
			end
			return parts
		end

		for i = 2, #visible do
			table.insert(parts, tp("\n" .. indent(level) .. "| ", false, "punct"))
			tpExtend(parts, describePrettyTypeParts(visible[i], level + 1))
		end
		if union.types[#union.types] and union.types[#union.types].type == "TypeOptional" then
			table.insert(parts, tp("?", false, "punct"))
		end
		return parts
	elseif node.type == "TypeIntersection" then
		local inter = node :: luau.TypeIntersection
		local parts = describePrettyTypeParts(inter.types[1], level)
		if #inter.types == 2 and not hasLineBreak(parts) then
			table.insert(parts, tp(" & ", false, "punct"))
			tpExtend(parts, describePrettyTypeParts(inter.types[2], level))
			return parts
		end

		for i = 2, #inter.types do
			table.insert(parts, tp("\n" .. indent(level) .. "& ", false, "punct"))
			tpExtend(parts, describePrettyTypeParts(inter.types[i], level + 1))
		end
		return parts
	elseif node.type == "TypeGroup" then
		local inner = describePrettyTypeParts((node :: luau.TypeGroup).inner, level + 1)
		if fitsInline(inner, level + 1) then
			local parts = { tp("(", false, "punct") }
			tpExtend(parts, inner)
			table.insert(parts, tp(")", false, "punct"))
			return parts
		end

		local parts = { tp("(\n", false, "punct") }
		appendIndentedLine(parts, level + 1, inner, "\n")
		table.insert(parts, tp(indent(level) .. ")", false, "punct"))
		return parts
	elseif node.type == "TypePackExplicit" then
		local pack = node :: luau.TypePackExplicit
		if not pack.types or #pack.types == 0 then
			return compact
		end

		local parts = { tp("(\n", false, "punct") }
		for i, packType in pack.types do
			local hasMorePackItems = i < #pack.types or pack.tail ~= nil
			appendIndentedLine(
				parts,
				level + 1,
				describePrettyTypeParts(packType, level + 1),
				if hasMorePackItems then ",\n" else "\n"
			)
		end
		if pack.tail then
			appendIndentedLine(parts, level + 1, describePrettyTypeParts(pack.tail, level + 1), "\n")
		end
		table.insert(parts, tp(indent(level) .. ")", false, "punct"))
		return parts
	end

	return compact
end

function describer.describeTypeParts(node: luau.AstType | luau.AstTypePack): { SignaturePart }
	return describeCompactTypeParts(node)
end

-- String form derived from parts.
function describer.describeType(node: luau.AstType | luau.AstTypePack): string
	return partsToString(describer.describeTypeParts(node))
end

-- Multi-line string for large unions/intersections (used in type alias signatures).
function describer.describeTypeFull(node: luau.AstType | luau.AstTypePack): string
	return partsToString(describePrettyTypeParts(node, 0))
end

function describer.describeTypeFullParts(node: luau.AstType | luau.AstTypePack): { SignaturePart }
	return describePrettyTypeParts(node, 0)
end

return {
	describeTypeParts = describer.describeTypeParts,
	describeType = describer.describeType,
	describeTypeFull = describer.describeTypeFull,
	describeTypeFullParts = describer.describeTypeFullParts,
	tp = tp,
	tpExtend = tpExtend,
	partsToString = partsToString,
}
