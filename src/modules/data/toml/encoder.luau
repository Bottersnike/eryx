local shared = require("@self/shared")
local cst = require("@self/cst")

local encoder = {}

export type EncodeOptions = {
	sortKeys: boolean?,
}

type EncodeContext = {
	styleByPath: { [string]: string }?,
	commentByPathAndWhere: { [string]: string }?,
	dottedLines: { string },
}

local encodeValue: (value: any, sort: boolean) -> string

local function pathKey(path: { string }): string
	return table.concat(path, "\0")
end

local function pathWhereKey(path: { string }, where: string): string
	return pathKey(path) .. "\0" .. where
end

local function emitCommentedLine(out: { string }, line: string, path: { string }, ctx: EncodeContext)
	local comments = ctx.commentByPathAndWhere
	if comments ~= nil then
		local before = comments[pathWhereKey(path, "before")]
		if before ~= nil and before ~= "" then
			for part in string.gmatch(before, "[^\n]+") do
				table.insert(out, "# " .. part)
			end
		end

		local inline = comments[pathWhereKey(path, "inline")]
		if inline ~= nil and inline ~= "" then
			line ..= " # " .. inline
		end
	end

	table.insert(out, line)

	if comments ~= nil then
		local after = comments[pathWhereKey(path, "after")]
		if after ~= nil and after ~= "" then
			for part in string.gmatch(after, "[^\n]+") do
				table.insert(out, "# " .. part)
			end
		end
	end
end

local function spliceReplace(source: string, startPos: number, endExclusive: number, replacement: string): string
	return string.sub(source, 1, startPos - 1) .. replacement .. string.sub(source, endExclusive)
end

local function splitPathKey(key: string): { string }
	local out: { string } = {}
	local startPos = 1
	while true do
		local i = string.find(key, "\0", startPos, true)
		if i == nil then
			table.insert(out, string.sub(key, startPos))
			break
		end
		table.insert(out, string.sub(key, startPos, i - 1))
		startPos = i + 1
	end
	return out
end

local function joinPath(path: { string }, upto: number): { string }
	local out: { string } = {}
	for i = 1, upto do
		table.insert(out, path[i])
	end
	return out
end

local function canPatchAssignmentValue(value: any): boolean
	local t = type(value)
	return t == "string" or t == "number" or t == "boolean" or t == "table"
end

local function decoratedLine(
	base: string,
	path: { string },
	newline: string,
	commentByPathAndWhere: { [string]: string },
	fallbackSuffix: string?
): string
	local out = ""

	local before = commentByPathAndWhere[pathWhereKey(path, "before")]
	if before ~= nil and before ~= "" then
		for part in string.gmatch(before, "[^\n]+") do
			out ..= "# " .. part .. newline
		end
	end

	local inline = commentByPathAndWhere[pathWhereKey(path, "inline")]
	local line = base
	if inline ~= nil and inline ~= "" then
		line ..= " # " .. inline
	elseif fallbackSuffix ~= nil then
		line ..= fallbackSuffix
	end
	out ..= line .. newline

	local after = commentByPathAndWhere[pathWhereKey(path, "after")]
	if after ~= nil and after ~= "" then
		for part in string.gmatch(after, "[^\n]+") do
			out ..= "# " .. part .. newline
		end
	end

	return out
end

local function cleanupAfterDeletion(source: string): string
	local out = source
	out = out:gsub("\r\n\r\n\r\n+", "\r\n\r\n")
	out = out:gsub("\n\n\n+", "\n\n")
	return out
end

local function tryPatchCSTScalarAssignments(cstValue: any, sort: boolean): string?
	local source = cst.getOriginalSource(cstValue)
	if source == nil then
		return nil
	end

	local assignmentByPath = cst.getAssignmentMap(cstValue)
	local headerByPath = cst.getHeaderMap(cstValue)
	local changedByPath = cst.getChangedPathMap(cstValue)
	local styleByPath = cst.getStyleMap(cstValue)
	local commentByPathAndWhere = cst.getCommentMap(cstValue)

	if next(styleByPath) ~= nil then
		return nil
	end
	if next(changedByPath) == nil then
		return cst.getSourceIfUnchanged(cstValue)
	end

	type Patch = { startPos: number, endExclusive: number, replacement: string }
	local patches: { Patch } = {}
	local hadDeletion = false
	type PendingInsert = { seq: number, path: { string }, value: any }
	local pendingTopLevelInserts: { PendingInsert } = {}
	local pendingNestedInserts: { PendingInsert } = {}
	for k, seq in changedByPath do
		local path = splitPathKey(k)
		local rec = assignmentByPath[k]
		local value = cst.getValueAtPath(cstValue, path)

		if rec ~= nil then
			if value == nil then
				hadDeletion = true
				table.insert(patches, {
					startPos = rec.lineStart,
					endExclusive = rec.lineEndExclusive,
					replacement = "",
				})
				continue
			end

			if not canPatchAssignmentValue(value) then
				return nil
			end

			local encodedValue = encodeValue(value, sort)
			local base = rec.keySegment .. "=" .. rec.postEqWhitespace .. encodedValue
			local newline = rec.newline
			local replacement = decoratedLine(base, path, newline, commentByPathAndWhere, rec.lineSuffix)

			table.insert(patches, {
				startPos = rec.lineStart,
				endExclusive = rec.lineEndExclusive,
				replacement = replacement,
			})
		else
			if value == nil then
				continue
			end
			if not canPatchAssignmentValue(value) then
				return nil
			end
			if #path == 1 then
				table.insert(pendingTopLevelInserts, { seq = seq, path = path, value = value })
			else
				table.insert(pendingNestedInserts, { seq = seq, path = path, value = value })
			end
		end
	end

	if #pendingNestedInserts > 0 then
		local groupsByParent: { [string]: any } = {}

		table.sort(pendingNestedInserts, function(a: PendingInsert, b: PendingInsert)
			return a.seq < b.seq
		end)

		for _, ins in pendingNestedInserts do
			local parent = joinPath(ins.path, #ins.path - 1)
			local parentKey = pathKey(parent)
			local leaf = ins.path[#ins.path]

			local group: any = groupsByParent[parentKey]
			if group == nil then
				local header = headerByPath[parentKey]
				local newline = "\n"
				local insertPos = #source + 1
				local groupSeq = ins.seq

				if header ~= nil then
					newline = if header.newline ~= nil and header.newline ~= "" then header.newline else "\n"
					insertPos = header.lineEndExclusive
					for _, rec in assignmentByPath do
						if rec.sectionPathKey == parentKey and rec.lineEndExclusive > insertPos then
							insertPos = rec.lineEndExclusive
						end
					end
				else
					local sampleHeader = next(headerByPath)
					if sampleHeader ~= nil then
						local hdr = headerByPath[sampleHeader]
						newline = if hdr.newline ~= nil and hdr.newline ~= "" then hdr.newline else "\n"
					elseif string.sub(source, -2) == "\r\n" then
						newline = "\r\n"
					end
				end

				group = {
					seq = groupSeq,
					parent = parent,
					insertPos = insertPos,
					newline = tostring(newline),
					lines = {},
				}
				groupsByParent[parentKey] = group

				if header == nil then
					table.insert(group.lines, "[" .. shared.joinDottedPath(parent) .. "]")
				end
			end

			local base = `{shared.encodeKeyPart(leaf)} = {encodeValue(ins.value, sort)}`
			local line = decoratedLine(base, ins.path, group.newline, commentByPathAndWhere, nil)
			if #group.newline > 0 and string.sub(line, -#group.newline) == group.newline then
				line = string.sub(line, 1, -#group.newline - 1)
			end
			table.insert(group.lines, line)
		end

		for _, group in groupsByParent do
			table.insert(patches, {
				startPos = group.insertPos,
				endExclusive = group.insertPos,
				replacement = table.concat(group.lines, group.newline) .. group.newline,
			})
		end
	end

	table.sort(patches, function(a: Patch, b: Patch)
		return a.startPos > b.startPos
	end)

	local out = source
	for _, patch in patches do
		out = spliceReplace(out, patch.startPos, patch.endExclusive, patch.replacement)
	end

	if #pendingTopLevelInserts > 0 then
		table.sort(pendingTopLevelInserts, function(a: PendingInsert, b: PendingInsert)
			return a.seq < b.seq
		end)
		local appendLines: { string } = {}
		for _, ins in pendingTopLevelInserts do
			table.insert(appendLines, `{shared.encodeKeyPart(ins.path[1])} = {encodeValue(ins.value, sort)}`)
		end
		local newline = if string.sub(source, -2) == "\r\n" then "\r\n" else "\n"
		if #out > 0 and string.sub(out, -1) ~= "\n" then
			out ..= newline
		end
		out ..= table.concat(appendLines, newline)
	end

	if hadDeletion then
		out = cleanupAfterDeletion(out)
	end

	return out
end

local function encodeInlineKeyValuePairs(
	value: { [string]: any },
	sort: boolean,
	encodeValue: (value: any, sort: boolean) -> string
): string
	local keys: { string } = {}
	for key in value do
		if type(key) ~= "string" then
			error("TOML tables can only have string keys")
		end
		table.insert(keys, key)
	end
	if sort then
		shared.sortKeys(keys)
	end

	local parts = table.create(#keys)
	for i, key in keys do
		parts[i] = `{shared.encodeKeyPart(key)} = {encodeValue((value :: any)[key], sort)}`
	end
	return table.concat(parts, ", ")
end

encodeValue = function(value: any, sort: boolean): string
	local t = type(value)
	if t == "string" then
		return shared.encodeString(value)
	elseif t == "number" then
		if math.isnan(value) then
			return "nan"
		elseif math.isinf(value) and value > 0 then
			return "inf"
		elseif math.isinf(value) and value < 0 then
			return "-inf"
		elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	elseif t == "boolean" then
		return if value then "true" else "false"
	elseif t == "table" then
		if shared.tableIsArray(value) then
			local parts = table.create(#value)
			for i = 1, #value do
				parts[i] = encodeValue(value[i], sort)
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		return "{" .. encodeInlineKeyValuePairs(value, sort, encodeValue) .. "}"
	end

	error("Cannot encode type '" .. t .. "' as TOML")
end

local function emitTable(
	out: { string },
	value: { [string]: any },
	path: { string },
	sort: boolean,
	isRoot: boolean,
	hadPriorSection: boolean,
	ctx: EncodeContext
): boolean
	local scalarKeys: { string } = {}
	local childTableKeys: { string } = {}
	local childArrayTableKeys: { string } = {}

	for key, child in value do
		if type(key) ~= "string" then
			error("TOML tables can only have string keys")
		end

		if type(child) == "table" and shared.isArrayOfTables(child) and getmetatable(child) ~= shared.TOML_ARRAY_MT then
			table.insert(childArrayTableKeys, key)
		elseif type(child) == "table" and not shared.tableIsArray(child) then
			table.insert(childTableKeys, key)
		else
			table.insert(scalarKeys, key)
		end
	end

	if sort then
		shared.sortKeys(scalarKeys)
		shared.sortKeys(childTableKeys)
		shared.sortKeys(childArrayTableKeys)
	end

	local dottedCandidateKeys: { string } = {}
	local normalScalarKeys: { string } = {}
	local styles = ctx.styleByPath
	if styles ~= nil then
		for _, key in scalarKeys do
			local fullPath = table.clone(path)
			table.insert(fullPath, key)
			if #fullPath > 1 and styles[pathKey(fullPath)] == "dotted" then
				table.insert(dottedCandidateKeys, key)
			else
				table.insert(normalScalarKeys, key)
			end
		end
	else
		normalScalarKeys = scalarKeys
	end

	local allowDottedForTable = #dottedCandidateKeys > 0
		and #normalScalarKeys == 0
		and #childTableKeys == 0
		and #childArrayTableKeys == 0

	if allowDottedForTable then
		for _, key in dottedCandidateKeys do
			local fullPath = table.clone(path)
			table.insert(fullPath, key)
			local encodedValue = encodeValue((value :: any)[key], sort)
			emitCommentedLine(ctx.dottedLines, `{shared.joinDottedPath(fullPath)} = {encodedValue}`, fullPath, ctx)
		end
	else
		for _, key in dottedCandidateKeys do
			table.insert(normalScalarKeys, key)
		end
		if sort then
			shared.sortKeys(normalScalarKeys)
		end
	end

	local wroteSection = hadPriorSection
	local shouldEmitHeader = not isRoot
		and (#normalScalarKeys > 0 or #childTableKeys > 0 or #childArrayTableKeys > 0 or not allowDottedForTable)
	if shouldEmitHeader then
		if #out > 0 then
			table.insert(out, "")
		end
		emitCommentedLine(out, "[" .. shared.joinDottedPath(path) .. "]", path, ctx)
		wroteSection = true
	end

	for _, key in normalScalarKeys do
		local fullPath = table.clone(path)
		table.insert(fullPath, key)
		local encodedValue = encodeValue((value :: any)[key], sort)
		emitCommentedLine(out, `{shared.encodeKeyPart(key)} = {encodedValue}`, fullPath, ctx)
	end

	for _, key in childTableKeys do
		local childPath = table.clone(path)
		table.insert(childPath, key)
		wroteSection = emitTable(out, (value :: any)[key], childPath, sort, false, wroteSection, ctx)
	end

	for _, key in childArrayTableKeys do
		local childPath = table.clone(path)
		table.insert(childPath, key)
		local arrayOfTables = (value :: any)[key] :: { [number]: { [string]: any } }
		for i = 1, #arrayOfTables do
			local entry = arrayOfTables[i]
			if type(entry) ~= "table" then
				error("TOML array-of-tables values must be tables")
			end
			if #out > 0 then
				table.insert(out, "")
			end
			emitCommentedLine(out, "[[" .. shared.joinDottedPath(childPath) .. "]]", childPath, ctx)
			wroteSection = emitTable(out, entry :: any, childPath, sort, true, true, ctx)
		end
	end

	return wroteSection
end

function encoder.encode(value: any, options: EncodeOptions?): string
	if type(value) ~= "table" then
		error("toml.encode expects a table")
	end

	if cst.isCSTObject(value) then
		local source = cst.getSourceIfUnchanged(value)
		if source ~= nil then
			return source
		end

		local opts: EncodeOptions = (options or {}) :: any
		local sort: boolean = if opts.sortKeys == nil then true else opts.sortKeys :: boolean
		local patched = tryPatchCSTScalarAssignments(value, sort)
		if patched ~= nil then
			return patched
		end

		local styleByPath = cst.getStyleMap(value)
		local commentByPathAndWhere = cst.getCommentMap(value)
		local ctx: EncodeContext = {
			styleByPath = styleByPath,
			commentByPathAndWhere = commentByPathAndWhere,
			dottedLines = {},
		}
		value = cst.getSemanticRoot(value)
		local out: { string } = {}
		emitTable(out, value :: any, {}, sort, true, false, ctx)
		if #ctx.dottedLines > 0 then
			if #out > 0 then
				return table.concat(ctx.dottedLines, "\n") .. "\n" .. table.concat(out, "\n")
			end
			return table.concat(ctx.dottedLines, "\n")
		end
		return table.concat(out, "\n")
	end

	local opts: EncodeOptions = (options or {}) :: any
	local sort: boolean = if opts.sortKeys == nil then true else opts.sortKeys :: boolean

	local out: { string } = {}
	local ctx: EncodeContext = {
		styleByPath = nil,
		commentByPathAndWhere = nil,
		dottedLines = {},
	}
	emitTable(out, value :: any, {}, sort, true, false, ctx)
	return table.concat(out, "\n")
end

return encoder
