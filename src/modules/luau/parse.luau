--[=[
	Luau source code parser and comment utilities.

	Wraps the native Luau parser to produce a fully typed AST. Also
	provides helpers for extracting comment text from surrounding-text
	annotations and for round-trip pretty-printing.

	```luau
	local parse = require("@eryx/luau/parse")

	local result = parse.parse(source, { captureComments = true })
	print("Lines:", result.lines)
	for _, stat in result.root.body do
	    print(stat.type, stat.location.beginline)
	end

	-- Extract attached comments from surrounding text
	local text = result.surroundingText and result.surroundingText[result.root.body[1]]
	if text then
	    local comments = parse.extractComments(text.leading, { stripLineLeadingWhitespace = true })
	    print(comments[1])
	end
	```
]=]
local ast = require("@eryx/luau/ast")
local native = require("@eryx/luau/_parse_native")

export type Position = ast.Position
export type Location = ast.Location
export type ParseErrorInfo = ast.ParseErrorInfo
export type CommentInfo = ast.CommentInfo
export type SurroundingText = ast.SurroundingText
export type ParseOptions = ast.ParseOptions
export type AstNode = ast.AstNode
export type ParseResult = ast.ParseResult

export type ExtractCommentsOptions = {
	--- If true, strip the common leading indentation from block comment content.
	unindentMultiLineContent: boolean?,
	--- If true, strip leading whitespace from line comment content (e.g. `-- hello` → `"hello"`).
	stripLineLeadingWhitespace: boolean?,
	--- Controls merging of adjacent comments. `"none"` (default) keeps each comment separate,
	--- `"same"` merges adjacent same-kind comments, `"all"` merges all adjacent comments.
	merge: ("none" | "same" | "all")?,
}

local parse = {}

local function startsWith(text: string, prefix: string, offset: number): boolean
	return text:sub(offset, offset + #prefix - 1) == prefix
end

local function stripLeadingHorizontalWhitespace(text: string): string
	local index = 1
	while index <= #text do
		local ch = text:sub(index, index)
		if ch ~= " " and ch ~= "\t" then
			break
		end
		index += 1
	end
	return text:sub(index)
end

local function separatorForGap(gap: string): string
	local _, newlineCount = gap:gsub("\n", "\n")
	if newlineCount >= 2 then
		return "\n\n"
	end
	if newlineCount == 1 then
		return "\n"
	end
	return " "
end

local function isWhitespaceOnly(gap: string): boolean
	for i = 1, #gap do
		local ch = gap:sub(i, i)
		if ch ~= " " and ch ~= "\t" and ch ~= "\n" and ch ~= "\r" and ch ~= "\v" and ch ~= "\f" then
			return false
		end
	end
	return true
end

local function splitLines(text: string): { string }
	local lines = {}
	local start = 1
	while start <= #text do
		local newline = text:find("\n", start, true)
		if newline == nil then
			table.insert(lines, text:sub(start))
			return lines
		end
		table.insert(lines, text:sub(start, newline - 1))
		start = newline + 1
	end
	if #text == 0 then
		table.insert(lines, "")
	end
	return lines
end

local function unindentMultiLineCommentContent(content: string): string
	if content == "" then
		return content
	end

	if content:sub(1, 2) == "\r\n" then
		content = content:sub(3)
	elseif content:sub(1, 1) == "\n" then
		content = content:sub(2)
	end

	local lines = splitLines(content)
	while #lines > 0 and lines[#lines]:match("^[%s\r]*$") do
		table.remove(lines, #lines)
	end

	local minIndent: number? = nil
	for _, line in lines do
		if not line:match("^[%s\r]*$") then
			local _, indent = line:find("^[ \t]*")
			local width = indent or 0
			if minIndent == nil or width < minIndent then
				minIndent = width
			end
		end
	end

	if minIndent == nil or minIndent == 0 then
		return table.concat(lines, "\n")
	end

	local out = table.create(#lines)
	for i, line in lines do
		local trim = 0
		while trim < minIndent and trim < #line do
			local ch = line:sub(trim + 1, trim + 1)
			if ch ~= " " and ch ~= "\t" then
				break
			end
			trim += 1
		end
		out[i] = line:sub(trim + 1)
	end

	return table.concat(out, "\n")
end

local function tryExtractComment(
	text: string,
	offset: number,
	options: ExtractCommentsOptions?
): { content: string, isBlock: boolean, nextOffset: number }?
	if not startsWith(text, "--", offset) then
		return nil
	end

	if startsWith(text, "--[", offset) then
		local eqLen = 0
		while text:sub(offset + 3 + eqLen, offset + 3 + eqLen) == "=" do
			eqLen += 1
		end
		if text:sub(offset + 3 + eqLen, offset + 3 + eqLen) == "[" then
			local close = "]" .. string.rep("=", eqLen) .. "]"
			local contentStart = offset + 4 + eqLen
			local cursor = contentStart
			while text:sub(cursor, cursor + #close - 1) ~= close do
				if #text - cursor + 1 < #close then
					local content = text:sub(contentStart)
					if options and options.unindentMultiLineContent then
						content = unindentMultiLineCommentContent(content)
					end
					return { content = content, isBlock = true, nextOffset = #text + 1 }
				end
				cursor += 1
			end

			local content = text:sub(contentStart, cursor - 1)
			if options and options.unindentMultiLineContent then
				content = unindentMultiLineCommentContent(content)
			end
			return {
				content = content,
				isBlock = true,
				nextOffset = cursor + #close,
			}
		end
	end

	local cursor = offset + 2
	while cursor <= #text do
		local ch = text:sub(cursor, cursor)
		if ch == "\n" or ch == "\r" then
			break
		end
		cursor += 1
	end

	local content = text:sub(offset + 2, cursor - 1)
	if options and options.stripLineLeadingWhitespace then
		content = stripLeadingHorizontalWhitespace(content)
	end
	return {
		content = content,
		isBlock = false,
		nextOffset = cursor,
	}
end

--[=[
	Parses Luau source code and returns a structured AST.

	The returned `root` is a [[Block]] node whose `body` contains an array
	of statement nodes. Every node carries a `type` string discriminator
	and a `location` with 1-based line/column positions.

	Pass `{ captureComments = true }` to include a `comments` array in
	the result. Pass `{ collectSurroundingText = true }` to include a
	sparse `surroundingText` side table keyed by AST node.

	```luau
	local result = parse.parse(source, { captureComments = true })
	print("Lines:", result.lines)
	print("Errors:", #result.errors)
	print("Top-level statements:", #result.root.body)
	```

	@param source The Luau source code string to parse.
	@param options Parse options (e.g. comment capture).
	@return ParseResult -- The parse result containing the AST root, errors, and optional comments.
]=]
function parse.parse(source: string, options: ParseOptions?): ParseResult
	return native.parse(source, options)
end

--[=[
	Pretty-prints Luau source code by round-tripping through the parser.

	@param source The Luau source code to format.
	@return string -- The reformatted source code.
]=]
function parse.prettyPrint(source: string): string
	return native.prettyPrint(source)
end

--[=[
	Extracts comment content from raw surrounding text.

	This is intended for use with strings from
	`result.surroundingText[node].leading` and `.trailing`. The parse
	result keeps those strings lossless; this helper turns them into
	comment payloads on demand.

	When `stripLineLeadingWhitespace` is true, line comments like
	`-- hello` are returned as `"hello"` instead of `" hello"`.

	@param text Raw surrounding text.
	@param options Comment extraction options.
	@return { string } -- Extracted comment strings.
]=]
function parse.extractComments(text: string, options: ExtractCommentsOptions?): { string }
	local merge = if options and options.merge ~= nil then options.merge else "none"
	local comments = {}

	local current: { content: string, isBlock: boolean }? = nil
	local lastCommentEnd = 1
	local cursor = 1

	local function flush()
		if current ~= nil then
			table.insert(comments, current.content)
			current = nil
		end
	end

	while cursor <= #text do
		local commentStart = text:find("%-%-", cursor)
		if commentStart == nil then
			break
		end

		local extracted = tryExtractComment(text, commentStart, options)
		if extracted == nil then
			cursor = commentStart + 1
			continue
		end

		if current == nil then
			current = { content = extracted.content, isBlock = extracted.isBlock }
		else
			local gap = text:sub(lastCommentEnd, commentStart - 1)
			local mergeable = merge ~= "none"
				and isWhitespaceOnly(gap)
				and (merge == "all" or (merge == "same" and current.isBlock == extracted.isBlock))

			if mergeable then
				current.content ..= separatorForGap(gap) .. extracted.content
			else
				flush()
				current = { content = extracted.content, isBlock = extracted.isBlock }
			end
		end

		lastCommentEnd = extracted.nextOffset
		cursor = extracted.nextOffset
	end

	flush()
	return comments
end

return table.freeze(parse)
