--- @ignore

-- Converts AST type nodes into human-readable string and structured token representations.
--
-- `describeTypeParts` is the single source of truth for rendering types.
-- `describeType` derives the string by concatenating part texts.

local luau = require("@eryx/luau")
local types = require("./types")
type SignaturePart = types.SignaturePart

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

function describer.describeTypeParts(node: luau.AstType | luau.AstTypePack): { SignaturePart }
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

-- String form derived from parts.
function describer.describeType(node: luau.AstType | luau.AstTypePack): string
	return partsToString(describer.describeTypeParts(node))
end

-- Multi-line string for large unions/intersections (used in type alias signatures).
function describer.describeTypeFull(node: luau.AstType | luau.AstTypePack): string
	if node.type == "TypeUnion" then
		local u = node :: luau.TypeUnion
		if #u.types == 2 and u.types[2] and u.types[2].type == "TypeOptional" then
			return describer.describeType(u.types[1]) .. "?"
		end
		local pp: { string } = {}
		for _, t in u.types do
			if t.type ~= "TypeOptional" then
				table.insert(pp, describer.describeType(t))
			end
		end
		local suffix = if u.types[#u.types] and u.types[#u.types].type == "TypeOptional" then "?" else ""
		if #pp <= 2 then
			return table.concat(pp, " | ") .. suffix
		end
		local lines: { string } = { pp[1] }
		for i = 2, #pp do
			table.insert(lines, "    | " .. pp[i])
		end
		return table.concat(lines, "\n") .. suffix
	elseif node.type == "TypeIntersection" then
		local inter = node :: luau.TypeIntersection
		local pp: { string } = {}
		for _, t in inter.types do
			table.insert(pp, describer.describeType(t))
		end
		if #pp <= 2 then
			return table.concat(pp, " & ")
		end
		local lines: { string } = { pp[1] }
		for i = 2, #pp do
			table.insert(lines, "    & " .. pp[i])
		end
		return table.concat(lines, "\n")
	end
	return describer.describeType(node)
end

return {
	describeTypeParts = describer.describeTypeParts,
	describeType = describer.describeType,
	describeTypeFull = describer.describeTypeFull,
	tp = tp,
	tpExtend = tpExtend,
	partsToString = partsToString,
}
