local tabUtil = require("../tabUtil")
local types = require("../types")

-- ======================== HTML Block helpers (§4.6) ========================

local function isAsciiLetter(b: number): boolean
	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

local function isDigit(b: number): boolean
	return b >= 48 and b <= 57
end

local function isWS(b: number): boolean
	return b == 32 or b == 9
end

--- Case-insensitive prefix check. `str` MUST be lowercase.
local function startsWithCI(line: string, pos: number, str: string): boolean
	if pos + #str - 1 > #line then
		return false
	end
	for i = 1, #str do
		local lb = string.byte(line, pos + i - 1)
		if lb >= 65 and lb <= 90 then
			lb += 32
		end
		if lb ~= string.byte(str, i) then
			return false
		end
	end
	return true
end

--- Case-insensitive substring search.
local function containsCI(line: string, str: string): boolean
	for i = 1, #line - #str + 1 do
		if startsWithCI(line, i, str) then
			return true
		end
	end
	return false
end

--- Exact substring search.
local function containsExact(line: string, str: string): boolean
	for i = 1, #line - #str + 1 do
		if line:sub(i, i + #str - 1) == str then
			return true
		end
	end
	return false
end

local TYPE1_TAGS = { "pre", "script", "style", "textarea" }

local BLOCK_TAGS: { [string]: boolean } = {}
do
	local tags = {
		"address",
		"article",
		"aside",
		"base",
		"basefont",
		"blockquote",
		"body",
		"caption",
		"center",
		"col",
		"colgroup",
		"dd",
		"details",
		"dialog",
		"dir",
		"div",
		"dl",
		"dt",
		"fieldset",
		"figcaption",
		"figure",
		"footer",
		"form",
		"frame",
		"frameset",
		"h1",
		"h2",
		"h3",
		"h4",
		"h5",
		"h6",
		"head",
		"header",
		"hr",
		"html",
		"iframe",
		"legend",
		"li",
		"link",
		"main",
		"menu",
		"menuitem",
		"nav",
		"noframes",
		"ol",
		"optgroup",
		"option",
		"p",
		"param",
		"search",
		"section",
		"summary",
		"table",
		"tbody",
		"td",
		"tfoot",
		"th",
		"thead",
		"title",
		"tr",
		"track",
		"ul",
	}
	for _, t in tags do
		BLOCK_TAGS[t] = true
	end
end

--- Try to parse a complete HTML open tag at `pos`. Returns position after `>`, or nil.
--- Excludes pre/script/style/textarea (those are type 1, not type 7).
local function tryParseOpenTag(line: string, pos: number): number?
	if string.byte(line, pos) ~= 60 then
		return nil
	end -- <
	pos += 1

	-- Tag name: ASCII letter followed by letters/digits/hyphens
	if pos > #line or not isAsciiLetter(string.byte(line, pos)) then
		return nil
	end
	local tagStart = pos
	pos += 1
	while pos <= #line do
		local b = string.byte(line, pos)
		if isAsciiLetter(b) or isDigit(b) or b == 45 then
			pos += 1
		else
			break
		end
	end

	-- Reject type-1 tag names
	local tagName = string.lower(line:sub(tagStart, pos - 1))
	if tagName == "pre" or tagName == "script" or tagName == "style" or tagName == "textarea" then
		return nil
	end

	-- Parse attributes
	while pos <= #line do
		-- Need at least one whitespace before an attribute
		local wsStart = pos
		while pos <= #line and isWS(string.byte(line, pos)) do
			pos += 1
		end
		if pos == wsStart then
			break
		end

		-- Attribute name start: letter, _, or :
		local ab = string.byte(line, pos)
		if not ab or not (isAsciiLetter(ab) or ab == 95 or ab == 58) then
			break
		end
		pos += 1

		-- Rest of attribute name: letter, digit, _, ., :, -
		while pos <= #line do
			local b = string.byte(line, pos)
			if isAsciiLetter(b) or isDigit(b) or b == 95 or b == 46 or b == 58 or b == 45 then
				pos += 1
			else
				break
			end
		end

		-- Optional attribute value specification
		local saved = pos
		while pos <= #line and isWS(string.byte(line, pos)) do
			pos += 1
		end
		if pos <= #line and string.byte(line, pos) == 61 then -- =
			pos += 1
			while pos <= #line and isWS(string.byte(line, pos)) do
				pos += 1
			end
			if pos > #line then
				return nil
			end
			local vb = string.byte(line, pos)
			if vb == 39 then -- single-quoted
				pos += 1
				while pos <= #line and string.byte(line, pos) ~= 39 do
					pos += 1
				end
				if pos > #line then
					return nil
				end
				pos += 1
			elseif vb == 34 then -- double-quoted
				pos += 1
				while pos <= #line and string.byte(line, pos) ~= 34 do
					pos += 1
				end
				if pos > #line then
					return nil
				end
				pos += 1
			else
				-- Unquoted: non-empty, no space/tab/"/'/=/</>/ `
				if isWS(vb) or vb == 34 or vb == 39 or vb == 61 or vb == 60 or vb == 62 or vb == 96 then
					return nil
				end
				pos += 1
				while pos <= #line do
					local b = string.byte(line, pos)
					if isWS(b) or b == 34 or b == 39 or b == 61 or b == 60 or b == 62 or b == 96 then
						break
					end
					pos += 1
				end
			end
		else
			pos = saved -- no value spec
		end
	end

	-- Optional trailing whitespace
	while pos <= #line and isWS(string.byte(line, pos)) do
		pos += 1
	end
	-- Optional self-closing /
	if pos <= #line and string.byte(line, pos) == 47 then
		pos += 1
	end
	-- Must end with >
	if pos > #line or string.byte(line, pos) ~= 62 then
		return nil
	end
	return pos + 1
end

--- Try to parse a complete HTML closing tag at `pos`. Returns position after `>`, or nil.
local function tryParseClosingTag(line: string, pos: number): number?
	-- </
	if string.byte(line, pos) ~= 60 or pos + 1 > #line or string.byte(line, pos + 1) ~= 47 then
		return nil
	end
	pos += 2
	-- Tag name
	if pos > #line or not isAsciiLetter(string.byte(line, pos)) then
		return nil
	end
	pos += 1
	while pos <= #line do
		local b = string.byte(line, pos)
		if isAsciiLetter(b) or isDigit(b) or b == 45 then
			pos += 1
		else
			break
		end
	end
	-- Optional whitespace
	while pos <= #line and isWS(string.byte(line, pos)) do
		pos += 1
	end
	-- >
	if pos > #line or string.byte(line, pos) ~= 62 then
		return nil
	end
	return pos + 1
end

--- Detect which HTML block type (1-7) starts at `pos`, or nil.
local function matchHtmlBlockType(line: string, pos: number): number?
	if string.byte(line, pos) ~= 60 then
		return nil
	end -- must start with <

	-- Type 2: <!--
	if line:sub(pos, pos + 3) == "<!--" then
		return 2
	end
	-- Type 3: <?
	if pos + 1 <= #line and string.byte(line, pos + 1) == 63 then
		return 3
	end
	-- Type 5: <![CDATA[
	if startsWithCI(line, pos, "<![cdata[") then
		return 5
	end
	-- Type 4: <! followed by ASCII letter
	if pos + 1 <= #line and string.byte(line, pos + 1) == 33 then
		if pos + 2 <= #line and isAsciiLetter(string.byte(line, pos + 2)) then
			return 4
		end
	end

	-- Type 1: <pre, <script, <style, <textarea followed by space/tab/>/EOL
	for _, tag in TYPE1_TAGS do
		if startsWithCI(line, pos + 1, tag) then
			local afterPos = pos + 1 + #tag
			if afterPos > #line then
				return 1
			end
			local after = string.byte(line, afterPos)
			if isWS(after) or after == 62 then
				return 1
			end -- space/tab or >
		end
	end

	-- Type 6: < or </ followed by block-level tag name, then space/tab/EOL/>//>
	do
		local tStart = pos + 1
		if tStart <= #line and string.byte(line, tStart) == 47 then
			tStart += 1
		end
		local tEnd = tStart
		while tEnd <= #line do
			local b = string.byte(line, tEnd)
			if isAsciiLetter(b) or isDigit(b) or b == 45 then
				tEnd += 1
			else
				break
			end
		end
		if tEnd > tStart then
			local tagName = string.lower(line:sub(tStart, tEnd - 1))
			if BLOCK_TAGS[tagName] then
				if tEnd > #line then
					return 6
				end
				local after = string.byte(line, tEnd)
				if isWS(after) or after == 62 then
					return 6
				end
				if after == 47 and tEnd + 1 <= #line and string.byte(line, tEnd + 1) == 62 then
					return 6
				end
			end
		end
	end

	-- Type 7: complete open tag (not pre/script/style/textarea) or closing tag,
	-- followed by optional whitespace, then EOL.
	do
		local endPos = tryParseOpenTag(line, pos) or tryParseClosingTag(line, pos)
		if endPos then
			local allWS = true
			for i = endPos, #line do
				if not isWS(string.byte(line, i)) then
					allWS = false
					break
				end
			end
			if allWS then
				return 7
			end
		end
	end

	return nil
end

--- Check if a line contains the end condition for HTML block types 1-5.
local function checkHtmlBlockEnd(line: string, htmlBlockType: number): boolean
	if htmlBlockType == 1 then
		return containsCI(line, "</pre>")
			or containsCI(line, "</script>")
			or containsCI(line, "</style>")
			or containsCI(line, "</textarea>")
	elseif htmlBlockType == 2 then
		return containsExact(line, "-->")
	elseif htmlBlockType == 3 then
		return containsExact(line, "?>")
	elseif htmlBlockType == 4 then
		return containsExact(line, ">")
	elseif htmlBlockType == 5 then
		return containsExact(line, "]]>")
	end
	return false
end

-- HTML block: continues until end condition, starts with HTML patterns
local HtmlBlockRule: types.BlockRule<
	"html_block",
	{
		htmlBlockType: number, -- 1-7 per CommonMark spec
		open: boolean,
		lines: { string },
	}
> =
	{
		name = "html_block",
		continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			return { matched = true, cursor = cursor }
		end,
		tryStart = function(
			line: string,
			cursor: tabUtil.LineCursor,
			tip: types.AnyBlockNode,
			_openStack: { types.AnyBlockNode }
		): types.StartResult?
			local indent = tabUtil.indentationLevel(line, cursor)
			if indent.column > 3 then
				return nil
			end
			local indented: tabUtil.LineCursor = {
				byte = indent.byte + cursor.byte,
				column = indent.column + cursor.column,
			}

			local htmlType = matchHtmlBlockType(line, indented.byte)
			if not htmlType then
				return nil
			end
			-- Type 7 cannot interrupt a paragraph
			if htmlType == 7 and tip.type == "paragraph" then
				return nil
			end

			local lines = { line:sub(cursor.byte) }
			local isOpen = true
			if htmlType <= 5 and checkHtmlBlockEnd(lines[1], htmlType) then
				isOpen = false
			end

			local htmlBlock = {
				type = "html_block",
				htmlBlockType = htmlType,
				open = isOpen,
				lines = lines,
			}

			return {
				blocks = { htmlBlock },
				cursor = { byte = #line + 1, column = -1 },
				breakAfterOpen = true,
			}
		end,
		incorporateLine = function(block, remains: string): boolean
			table.insert(block.lines, remains)
			-- Check end condition for types 1-5
			if block.htmlBlockType <= 5 and checkHtmlBlockEnd(remains, block.htmlBlockType) then
				block.open = false -- signal to main loop to close
			end
			return true
		end,
		onBlankLine = function(block, _openStack: { types.AnyBlockNode }): boolean
			if block.htmlBlockType == 6 or block.htmlBlockType == 7 then
				return true -- close on blank line
			end
			-- Types 1-5: blank line is content, don't close
			table.insert(block.lines, "")
			return false
		end,
		onClose = function(block)
			while #block.lines > 0 and block.lines[#block.lines] == "" do
				table.remove(block.lines, #block.lines)
			end
		end,
		afterIncorporate = function(block): boolean?
			return not block.open
		end,
		shouldCloseAfterOpen = function(block): boolean?
			return not block.open
		end,

		toHtml = function(block, rules, config): string
			local content: string
			if config.useCrlf then
				content = table.concat(block.lines, "\r\n")
			else
				content = table.concat(block.lines, "\n")
			end

			return content
		end,
	}

return table.freeze(HtmlBlockRule) :: types.AnyBlockRule
