--- @ignore

local types = require("./types")
local HTML_ENTITIES: { [string]: { number } } = require("./entities") :: any
local util = require("./util")

local parse = {}

-- ================================================================
-- Doubly-linked list with head/tail sentinels
-- ================================================================

local SENTINEL = "__SENTINEL"

local function newLL(): (types.LLNode, types.LLNode)
	local head: types.LLNode = { prev = nil :: any, next = nil :: any, val = SENTINEL }
	local tail: types.LLNode = { prev = nil :: any, next = nil :: any, val = SENTINEL }
	head.prev = head
	head.next = tail
	tail.next = tail
	tail.prev = head
	return head, tail
end

local function llInsertBefore(before: types.LLNode, val: any): types.LLNode
	local node: types.LLNode = { prev = before.prev, next = before, val = val }
	before.prev.next = node
	before.prev = node
	return node
end

local function llRemove(node: types.LLNode)
	node.prev.next = node.next
	node.next.prev = node.prev
end

--- Collect all node values between `from` and `to` (both exclusive),
--- removing them from the list.
local function llSpliceBetween(from: types.LLNode, to: types.LLNode): { any }
	local result = {}
	local cur = from.next
	while cur ~= to do
		local nxt = cur.next
		llRemove(cur)
		table.insert(result, cur.val)
		cur = nxt
	end
	return result
end

-- ================================================================
-- Byte constants
-- ================================================================

local B_TAB = 9
local B_LF = 10
local B_CR = 13
local B_SPACE = 32
local B_BANG = 33
local B_DQUOTE = 34
local B_SQUOTE = 39
local B_LPAREN = 40
local B_RPAREN = 41
local B_STAR = 42
local B_PLUS = 43
local B_DASH = 45
local B_DOT = 46
local B_COLON = 58
local B_LT = 60
local B_GT = 62
local B_AT = 64
local B_LBRACKET = 91
local B_BACKSLASH = 92
local B_RBRACKET = 93
local B_AMP = 38
local B_HASH = 35
local B_SEMICOLON = 59
local B_UNDERSCORE = 95
local B_BACKTICK = 96
local B_TILDE = 126
local B_LOWER_X = 120
local B_UPPER_X = 88

-- ================================================================
-- Character classification
-- ================================================================

local function isAsciiPunctuation(b: number): boolean
	return (b >= 33 and b <= 47) -- !"#$%&'()*+,-./
		or (b >= 58 and b <= 64) -- :;<=>?@
		or (b >= 91 and b <= 96) -- [\]^_`
		or (b >= 123 and b <= 126) -- {|}~
end

local function isWhitespace(b: number): boolean
	return b == B_SPACE or b == B_TAB or b == B_LF or b == B_CR or b == 12
end

--- Convert a Unicode codepoint to a UTF-8 encoded string.
local function utf8Encode(cp: number): string
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 4096), 0x80 + (math.floor(cp / 64) % 64), 0x80 + (cp % 64))
	elseif cp <= 0x10FFFF then
		return string.char(
			0xF0 + math.floor(cp / 262144),
			0x80 + (math.floor(cp / 4096) % 64),
			0x80 + (math.floor(cp / 64) % 64),
			0x80 + (cp % 64)
		)
	end
	return "\xEF\xBF\xBD" -- U+FFFD replacement character
end

-- ================================================================
-- Entity / character reference helper
-- ================================================================

--- Try to parse an HTML entity or numeric character reference at `pos`.
--- `pos` must point to '&'. Returns (resolvedString, newPos) or (nil, pos).
local function tryParseEntity(s: string, pos: number, len: number): (string?, number)
	if pos > len or string.byte(s, pos) ~= B_AMP then
		return nil, pos
	end
	local scanPos = pos + 1
	if scanPos <= len and string.byte(s, scanPos) == B_HASH then
		scanPos += 1
		if scanPos <= len and (string.byte(s, scanPos) == B_LOWER_X or string.byte(s, scanPos) == B_UPPER_X) then
			-- Hex numeric: &#x[0-9a-fA-F]{1,6};
			scanPos += 1
			local digitStart = scanPos
			while scanPos <= len and util.isHexDigitRef(string.byte(s, scanPos)) and scanPos - digitStart < 6 do
				scanPos += 1
			end
			if scanPos > digitStart and scanPos <= len and string.byte(s, scanPos) == B_SEMICOLON then
				local cp = 0
				for di = digitStart, scanPos - 1 do
					cp = cp * 16 + util.hexDigitValueRef(string.byte(s, di))
				end
				if cp == 0 then
					cp = 0xFFFD
				end
				return utf8Encode(cp), scanPos + 1
			end
		else
			-- Decimal numeric: &#[0-9]{1,7};
			local digitStart = scanPos
			while scanPos <= len and util.isDigit(string.byte(s, scanPos)) and scanPos - digitStart < 7 do
				scanPos += 1
			end
			if scanPos > digitStart and scanPos <= len and string.byte(s, scanPos) == B_SEMICOLON then
				local cp = 0
				for di = digitStart, scanPos - 1 do
					cp = cp * 10 + (string.byte(s, di) - 48)
				end
				if cp == 0 or cp > 0x10FFFF then
					cp = 0xFFFD
				end
				return utf8Encode(cp), scanPos + 1
			end
		end
	else
		-- Named entity: &[a-zA-Z][a-zA-Z0-9]*;
		local nameStart = scanPos
		while scanPos <= len do
			local sb = string.byte(s, scanPos)
			if util.isAsciiLetter(sb) or (scanPos > nameStart and util.isDigit(sb)) then
				scanPos += 1
			else
				break
			end
		end
		if scanPos > nameStart and scanPos <= len and string.byte(s, scanPos) == B_SEMICOLON then
			local name = s:sub(nameStart, scanPos - 1)
			local codepoints = HTML_ENTITIES[name]
			if codepoints then
				local buf = {}
				for _, cp in codepoints do
					table.insert(buf, utf8Encode(cp))
				end
				return table.concat(buf), scanPos + 1
			end
		end
	end
	return nil, pos
end

-- ================================================================
-- Types for the delimiter and bracket stacks
-- ================================================================

type BracketInfo = {
	isImage: boolean,
	ilNode: types.LLNode,
	delimBefore: types.LLNode,
	active: boolean,
	contentStart: number,
}

-- Delimiter resolvers are provided per-parse to `processEmphasis`.

-- ================================================================
-- processEmphasis  (CommonMark spec algorithm)
-- ================================================================

local function processEmphasis(
	dsHead: types.LLNode,
	dsTail: types.LLNode,
	stackBottom: types.LLNode?,
	resolvers: { [number]: any }?
)
	local bottom: types.LLNode = stackBottom or dsHead

	-- openers_bottom indexed by [char][origCount%3][canOpen_bool]
	local openersBottom: { [number]: { [number]: { [boolean]: types.LLNode } } } = {}

	local function initOpenersFor(ch: number)
		openersBottom[ch] = {
			[0] = { [true] = bottom, [false] = bottom },
			[1] = { [true] = bottom, [false] = bottom },
			[2] = { [true] = bottom, [false] = bottom },
		}
	end

	-- initialize core delimiters
	initOpenersFor(B_STAR)
	initOpenersFor(B_UNDERSCORE)
	-- Initialize additional delimiters registered in `resolvers`.
	if resolvers then
		for ch, _ in resolvers do
			if openersBottom[ch] == nil then
				initOpenersFor(ch)
			end
		end
	end

	local current = bottom.next

	while current ~= dsTail do
		local closer: types.DelimInfo = current.val

		if not closer.canClose then
			current = current.next
			continue
		end

		local closerChar = closer.char
		local closerMod3 = closer.origCount % 3
		local closerCanOpen = closer.canOpen
		local ob = openersBottom[closerChar][closerMod3][closerCanOpen]

		-- Search backward for a matching opener
		local openerNode = current.prev
		local openerFound = false

		while openerNode ~= bottom and openerNode ~= ob do
			local opener: types.DelimInfo = openerNode.val
			if opener.canOpen and opener.char == closerChar then
				local oddMatch = (closer.canOpen or opener.canClose)
					and (closer.origCount + opener.origCount) % 3 == 0
					and not (closer.origCount % 3 == 0 and opener.origCount % 3 == 0)
				if not oddMatch then
					openerFound = true
					break
				end
			end
			openerNode = openerNode.prev
		end

		if not openerFound then
			openersBottom[closerChar][closerMod3][closerCanOpen] = current.prev
			if not closer.canOpen then
				local nxt = current.next
				llRemove(current)
				current = nxt
			else
				current = current.next
			end
			continue
		end

		-- Found a match — determine strong vs em vs plugin-resolved delimiter
		local opener: types.DelimInfo = openerNode.val
		local useDelims: number
		local emphType: string
		-- Try chained resolvers (if any). Each resolver returns (useDelims, nodeType)
		local resolved = false
		local resolverList = resolvers and resolvers[closerChar]
		if resolverList then
			if type(resolverList) == "function" then
				local ud, et = resolverList(opener, closer)
				if ud and ud > 0 then
					useDelims, emphType = ud, et
					resolved = true
				end
			else
				for _, fn in resolverList do
					if type(fn) == "function" then
						local ud, et = fn(opener, closer)
						if ud and ud > 0 then
							useDelims, emphType = ud, et
							resolved = true
							break
						end
					end
				end
			end
		end
		if not resolved then
			useDelims = if opener.count >= 2 and closer.count >= 2 then 2 else 1
			emphType = if useDelims == 2 then "strong" else "emphasis"
		end

		-- Trim opener text (remove useDelims chars from the end)
		local openerText = opener.ilNode.val
		openerText.content = openerText.content:sub(1, #openerText.content - useDelims)
		opener.count -= useDelims

		-- Trim closer text (remove useDelims chars from the start)
		local closerText = closer.ilNode.val
		closerText.content = closerText.content:sub(useDelims + 1)
		closer.count -= useDelims

		-- Collect all inline nodes between opener and closer as children
		local children = llSpliceBetween(opener.ilNode, closer.ilNode)

		-- Insert the emphasis/strong/strikethrough node before closer's inline node
		llInsertBefore(closer.ilNode, { type = emphType, children = children })

		-- Remove all delimiter-stack entries between opener and closer
		local tmp = openerNode.next
		while tmp ~= current do
			local nxt = tmp.next
			llRemove(tmp)
			tmp = nxt
		end

		-- If opener is exhausted, remove it and its text node
		if opener.count == 0 then
			llRemove(opener.ilNode)
			llRemove(openerNode)
		end

		-- If closer is exhausted, remove it and advance
		if closer.count == 0 then
			local nxt = current.next
			llRemove(closer.ilNode)
			llRemove(current)
			current = nxt
		end
		-- Otherwise current stays on the same closer for another round
	end

	-- Clean up: remove all remaining entries above bottom
	local tmp = bottom.next
	while tmp ~= dsTail do
		local nxt = tmp.next
		llRemove(tmp)
		tmp = nxt
	end
end

-- ================================================================
-- Link destination / title helpers
-- ================================================================

--- Skip spaces, tabs, and at most one line ending.
local function skipOptionalWhitespace(s: string, pos: number, len: number): number
	local seenNewline = false
	while pos <= len do
		local b = string.byte(s, pos)
		if b == B_SPACE or b == B_TAB then
			pos += 1
		elseif not seenNewline and (b == B_LF or b == B_CR) then
			seenNewline = true
			if b == B_CR and pos + 1 <= len and string.byte(s, pos + 1) == B_LF then
				pos += 2
			else
				pos += 1
			end
		else
			break
		end
	end
	return pos
end

--- Parse a link destination. Returns (ok, destination, newPos).
local function parseLinkDestination(s: string, pos: number, len: number): (boolean, string, number)
	if pos > len then
		return false, "", pos
	end

	local b = string.byte(s, pos)

	-- Angle-bracketed: <dest>
	if b == B_LT then
		pos += 1
		local buf = {}
		while pos <= len do
			b = string.byte(s, pos)
			if b == B_GT then
				return true, table.concat(buf), pos + 1
			elseif b == B_LT or b == B_LF or b == B_CR then
				return false, "", pos
			elseif b == B_BACKSLASH and pos + 1 <= len and isAsciiPunctuation(string.byte(s, pos + 1)) then
				table.insert(buf, s:sub(pos + 1, pos + 1))
				pos += 2
			elseif b == B_AMP then
				local resolved, newPos = tryParseEntity(s, pos, len)
				if resolved then
					table.insert(buf, resolved)
					pos = newPos
				else
					table.insert(buf, "&")
					pos += 1
				end
			else
				table.insert(buf, s:sub(pos, pos))
				pos += 1
			end
		end
		return false, "", pos
	end

	-- Bare destination: balanced parens, no spaces/control chars
	local buf = {}
	local parenDepth = 0
	while pos <= len do
		b = string.byte(s, pos)
		if b == B_SPACE or b < 32 or b == 127 then
			break
		elseif b == B_LPAREN then
			parenDepth += 1
			if parenDepth > 32 then
				return false, "", pos
			end
			table.insert(buf, "(")
			pos += 1
		elseif b == B_RPAREN then
			if parenDepth == 0 then
				break
			end
			parenDepth -= 1
			table.insert(buf, ")")
			pos += 1
		elseif b == B_BACKSLASH and pos + 1 <= len and isAsciiPunctuation(string.byte(s, pos + 1)) then
			table.insert(buf, s:sub(pos + 1, pos + 1))
			pos += 2
		elseif b == B_AMP then
			local resolved, newPos = tryParseEntity(s, pos, len)
			if resolved then
				table.insert(buf, resolved)
				pos = newPos
			else
				table.insert(buf, "&")
				pos += 1
			end
		else
			table.insert(buf, s:sub(pos, pos))
			pos += 1
		end
	end
	if parenDepth ~= 0 then
		return false, "", pos
	end
	return true, table.concat(buf), pos
end

--- Parse a link title. Returns (ok, title, newPos).
local function parseLinkTitle(s: string, pos: number, len: number): (boolean, string, number)
	if pos > len then
		return false, "", pos
	end

	local opener = string.byte(s, pos)
	local closer: number
	if opener == B_DQUOTE then
		closer = B_DQUOTE
	elseif opener == B_SQUOTE then
		closer = B_SQUOTE
	elseif opener == B_LPAREN then
		closer = B_RPAREN
	else
		return false, "", pos
	end

	pos += 1
	local buf = {}
	while pos <= len do
		local b = string.byte(s, pos)
		if b == closer then
			return true, table.concat(buf), pos + 1
		elseif b == opener and opener == B_LPAREN then
			return false, "", pos
		elseif b == B_BACKSLASH and pos + 1 <= len and isAsciiPunctuation(string.byte(s, pos + 1)) then
			table.insert(buf, s:sub(pos + 1, pos + 1))
			pos += 2
		elseif b == B_AMP then
			local resolved, newPos = tryParseEntity(s, pos, len)
			if resolved then
				table.insert(buf, resolved)
				pos = newPos
			else
				table.insert(buf, "&")
				pos += 1
			end
		else
			table.insert(buf, s:sub(pos, pos))
			pos += 1
		end
	end
	return false, "", pos
end

-- ================================================================
-- Reference link helpers
-- ================================================================

--- Parse a link label starting at pos (must point to '['). Returns (ok, normalizedLabel, newPos).
local function parseLinkLabel(s: string, pos: number): (boolean, string, number)
	local slen = #s
	if pos > slen or string.byte(s, pos) ~= B_LBRACKET then
		return false, "", pos
	end
	pos += 1
	local start = pos
	local count = 0
	while pos <= slen and count <= 999 do
		local b = string.byte(s, pos)
		if b == B_RBRACKET then
			local raw = s:sub(start, pos - 1)
			-- Empty label is valid for collapsed reference
			if count == 0 then
				return true, "", pos + 1
			end
			local hasNonWS = false
			for i = 1, #raw do
				local rb = string.byte(raw, i)
				if rb ~= B_SPACE and rb ~= B_TAB and rb ~= 10 and rb ~= 13 then
					hasNonWS = true
					break
				end
			end
			if not hasNonWS then
				return false, "", pos
			end
			local normalized = (raw:gsub("[\r\n\t ]+", " "):match("^%s*(.-)%s*$") :: string):lower()
			return true, normalized, pos + 1
		elseif b == B_LBRACKET then -- unescaped [
			return false, "", pos
		elseif b == B_BACKSLASH and pos + 1 <= slen then
			pos += 2
			count += 2
		else
			pos += 1
			count += 1
		end
	end
	return false, "", pos
end

local function normalizeLabel(raw: string): string
	return (raw:gsub("[\r\n\t ]+", " "):match("^%s*(.-)%s*$") :: string):lower()
end

-- ================================================================
-- Main inline parser
-- ================================================================

local function parseInline(
	value: string,
	linkRefs: { [string]: { destination: string, title: string? } }?,
	config: types.MarkdownConfig?
): { types.InlineNode }
	local len = #value
	if len == 0 then
		return {}
	end

	local ilHead, ilTail = newLL() -- inline-content linked list
	local dsHead, dsTail = newLL() -- delimiter stack
	local brackets: { BracketInfo } = {} -- bracket stack

	local pos = 1
	local textStart = 1

	-- Prepare handler dispatch and delimiter resolvers from config.inlineExtensions
	local extensions: { types.InlineRule } = {}

	-- Build fast first-byte map and sort handlers by open length (longest first)
	local extensionMap: { [number]: { types.InlineRule } } = {}

	-- Delimiter resolvers registry (char byte -> list of resolver functions).
	-- Each entry is a list of functions: (opener, closer) -> (useDelims:number, nodeType:string?)
	local delimiterResolvers: { [number]: { (any, any) -> (number, string) } } = {}

	-- `isDelimiterChar` will be computed after loading extensions so it
	-- includes any characters registered by `inlineExtensions` or
	-- `inlineEmphasisExtensions`.
	local isDelimiterChar: { [number]: boolean }

	-- ---- scan-local helpers ----

	local function flushText(endPos: number)
		if endPos >= textStart then
			llInsertBefore(ilTail, { type = "text", content = value:sub(textStart, endPos) })
		end
	end

	--- Flush text before a line ending, trimming trailing spaces.
	--- Returns number of spaces trimmed.
	local function flushTextForNewline(): number
		local endPos = pos - 1
		while endPos >= textStart and string.byte(value, endPos) == B_SPACE do
			endPos -= 1
		end
		local trimmed = (pos - 1) - endPos
		if endPos >= textStart then
			llInsertBefore(ilTail, { type = "text", content = value:sub(textStart, endPos) })
		end
		return trimmed
	end

	local function addText(content: string): types.LLNode
		return llInsertBefore(ilTail, { type = "text", content = content })
	end

	local function addNode(node: any): types.LLNode
		return llInsertBefore(ilTail, node)
	end

	-- Load extensions specified in config.inlineExtensions
	if config and config.inlineExtensions then
		for _, ext in config.inlineExtensions do
			table.insert(extensions, ext)
		end

		if #extensions > 0 then
			table.sort(extensions, function(a: types.InlineRule, b: types.InlineRule)
				return #a.matchOpen > #b.matchOpen
			end)
			extensionMap = {}
			for _, h in extensions do
				local fb = string.byte(h.matchOpen, 1)
				extensionMap[fb] = extensionMap[fb] or {}
				table.insert(extensionMap[fb], h)
			end
		end
	end

	-- Load inline emphasis extensions from config.inlineEmphasisExtensions
	if config and config.inlineEmphasisExtensions then
		for _, rule in config.inlineEmphasisExtensions do
			local c = rule.character
			local cb: number? = nil
			if type(c) == "number" then
				cb = c
			elseif type(c) == "string" and #c > 0 then
				cb = string.byte(c, 1)
			end
			if cb then
				delimiterResolvers[cb] = delimiterResolvers[cb] or {}
				table.insert(delimiterResolvers[cb], rule.resolve)
			end
		end
	end

	-- Now compute delimiter-character map including any registered resolvers
	isDelimiterChar = { [B_STAR] = true, [B_UNDERSCORE] = true }
	for ch, _ in delimiterResolvers do
		isDelimiterChar[ch] = true
	end

	-- Context passed to handlers
	local extensionContext: types.InlineRuleContext = {
		value = value,
		len = len,
		linkRefs = linkRefs or {},
		addNode = addNode,
		addText = addText,
		flushTextBefore = function(p: number)
			flushText(p - 1)
		end,
		parseInner = function(str: string): { types.InlineNode }
			return parseInline(str, linkRefs, config)
		end,
		handlers = extensions,
	}

	-- ---- main scan loop ----

	while pos <= len do
		local byte = string.byte(value, pos)

		-- Inline handler dispatch (if any handlers registered)
		local resolvedExtensions = extensionMap[byte]
		local matched = false
		if resolvedExtensions then
			for _, ext in resolvedExtensions do
				local open = ext.matchOpen
				if pos + #open - 1 <= len and value:sub(pos, pos + #open - 1) == open then
					local handled, newPos = ext.tryParse(extensionContext, pos)
					if handled then
						pos = newPos
						textStart = pos
						matched = true
						break
					end
				end
			end
		end
		if matched then
			continue
		end

		-- ======== Backslash escape ========
		if byte == B_BACKSLASH then
			flushText(pos - 1)
			if pos + 1 <= len then
				local nb = string.byte(value, pos + 1)
				if nb == B_LF then
					addNode({ type = "hard_line_break" })
					pos += 2
				elseif nb == B_CR then
					addNode({ type = "hard_line_break" })
					pos += 2
					if pos <= len and string.byte(value, pos) == B_LF then
						pos += 1
					end
				elseif isAsciiPunctuation(nb) then
					addText(value:sub(pos + 1, pos + 1))
					pos += 2
				else
					addText("\\")
					pos += 1
				end
			else
				addText("\\")
				pos += 1
			end
			textStart = pos

		-- ======== Code span ========
		elseif byte == B_BACKTICK then
			flushText(pos - 1)
			local tickStart = pos
			while pos <= len and string.byte(value, pos) == B_BACKTICK do
				pos += 1
			end
			local tickCount = pos - tickStart

			-- Scan forward for a matching closing backtick string
			local found = false
			local scanPos = pos
			while scanPos <= len do
				if string.byte(value, scanPos) == B_BACKTICK then
					local closeStart = scanPos
					while scanPos <= len and string.byte(value, scanPos) == B_BACKTICK do
						scanPos += 1
					end
					if scanPos - closeStart == tickCount then
						-- Build content, replacing line endings with spaces
						local raw = value:sub(pos, closeStart - 1)
						local buf = {}
						local ci = 1
						while ci <= #raw do
							local cb = string.byte(raw, ci)
							if cb == B_LF then
								table.insert(buf, " ")
								ci += 1
							elseif cb == B_CR then
								table.insert(buf, " ")
								ci += 1
								if ci <= #raw and string.byte(raw, ci) == B_LF then
									ci += 1
								end
							else
								table.insert(buf, raw:sub(ci, ci))
								ci += 1
							end
						end
						local content = table.concat(buf)

						-- Strip one leading + one trailing space when both exist
						-- and content is not all spaces
						if
							#content >= 2
							and string.byte(content, 1) == B_SPACE
							and string.byte(content, #content) == B_SPACE
						then
							local allSpaces = true
							for si = 1, #content do
								if string.byte(content, si) ~= B_SPACE then
									allSpaces = false
									break
								end
							end
							if not allSpaces then
								content = content:sub(2, #content - 1)
							end
						end

						addNode({ type = "code_span", content = content })
						pos = scanPos
						found = true
						break
					end
				else
					scanPos += 1
				end
			end

			if not found then
				addText(value:sub(tickStart, tickStart + tickCount - 1))
			end
			textStart = pos

		-- ======== Emphasis delimiter run (configurable delimiters) ========
		elseif isDelimiterChar[byte] then
			flushText(pos - 1)
			local runStart = pos
			while pos <= len and string.byte(value, pos) == byte do
				pos += 1
			end
			local count = pos - runStart

			-- Flanking classification
			local precByte: number = if runStart > 1 then string.byte(value, runStart - 1) :: number else -1
			local follByte: number = if pos <= len then string.byte(value, pos) :: number else -1

			local precIsWS = precByte == -1 or isWhitespace(precByte)
			local precIsPunct = precByte ~= -1 and isAsciiPunctuation(precByte)
			local follIsWS = follByte == -1 or isWhitespace(follByte)
			local follIsPunct = follByte ~= -1 and isAsciiPunctuation(follByte)

			local leftFlanking = not follIsWS and (not follIsPunct or precIsWS or precIsPunct)
			local rightFlanking = not precIsWS and (not precIsPunct or follIsWS or follIsPunct)

			local canOpen: boolean
			local canClose: boolean
			if byte == B_UNDERSCORE then
				canOpen = leftFlanking and (not rightFlanking or precIsPunct)
				canClose = rightFlanking and (not leftFlanking or follIsPunct)
			else
				canOpen = leftFlanking
				canClose = rightFlanking
			end

			local textNode = addText(value:sub(runStart, runStart + count - 1))

			if canOpen or canClose then
				llInsertBefore(dsTail, {
					char = byte,
					count = count,
					origCount = count,
					canOpen = canOpen,
					canClose = canClose,
					active = true,
					ilNode = textNode,
				})
			end

			textStart = pos

		-- ======== Image opener ![ ========
		elseif byte == B_BANG and pos + 1 <= len and string.byte(value, pos + 1) == B_LBRACKET then
			flushText(pos - 1)
			local node = addText("![")
			table.insert(brackets, {
				isImage = true,
				ilNode = node,
				delimBefore = dsTail.prev,
				active = true,
				contentStart = pos + 2,
			})
			pos += 2
			textStart = pos

		-- ======== Footnote ref [^label] ========
		-- elseif byte == B_LBRACKET and pos + 2 <= len and string.byte(value, pos + 1) == 94 then -- [^
		-- 	-- Try to parse [^label] as a footnote reference
		-- 	local fnEnd: number? = nil
		-- 	local p = pos + 2
		-- 	while p <= len do
		-- 		local fb = string.byte(value, p)
		-- 		if fb == 93 then -- ]
		-- 			fnEnd = p
		-- 			break
		-- 		elseif fb == 91 or fb == 10 or fb == 13 or fb == 32 then -- invalid in label
		-- 			break
		-- 		end
		-- 		p += 1
		-- 	end
		-- 	if fnEnd and fnEnd > pos + 2 then
		-- 		-- Valid footnote ref
		-- 		flushText(pos - 1)
		-- 		local label = value:sub(pos + 2, fnEnd - 1)
		-- 		addNode({ type = "footnote_ref", label = label } :: any)
		-- 		pos = fnEnd + 1
		-- 		textStart = pos
		-- 	else
		-- 		-- Not a footnote ref, treat as regular [
		-- 		flushText(pos - 1)
		-- 		local node = addText("[")
		-- 		table.insert(brackets, {
		-- 			isImage = false,
		-- 			ilNode = node,
		-- 			delimBefore = dsTail.prev,
		-- 			active = true,
		-- 			contentStart = pos + 1,
		-- 		})
		-- 		pos += 1
		-- 		textStart = pos
		-- 	end

		-- ======== Link opener [ ========
		elseif byte == B_LBRACKET then
			flushText(pos - 1)
			local node = addText("[")
			table.insert(brackets, {
				isImage = false,
				ilNode = node,
				delimBefore = dsTail.prev,
				active = true,
				contentStart = pos + 1,
			})
			pos += 1
			textStart = pos

		-- ======== Link / image closer ] ========
		elseif byte == B_RBRACKET then
			flushText(pos - 1)

			-- Find the most recent bracket
			local bracketIdx: number? = nil
			for i = #brackets, 1, -1 do
				bracketIdx = i
				break
			end

			if bracketIdx == nil then
				addText("]")
				pos += 1
				textStart = pos
			elseif not brackets[bracketIdx].active then
				table.remove(brackets, bracketIdx)
				addText("]")
				pos += 1
				textStart = pos
			else
				local bracket = brackets[bracketIdx]
				local linkParsed = false
				local dest = ""
				local title: string? = nil
				local afterPos = pos + 1

				-- Try inline link:  ](destination "title")
				if afterPos <= len and string.byte(value, afterPos) == B_LPAREN then
					local p = afterPos + 1
					p = skipOptionalWhitespace(value, p, len)

					local destOk, destStr, destEnd = parseLinkDestination(value, p, len)
					if destOk then
						p = destEnd
						local pBeforeTitle = skipOptionalWhitespace(value, p, len)

						if pBeforeTitle ~= p and pBeforeTitle <= len then
							local tb = string.byte(value, pBeforeTitle)
							if tb == B_DQUOTE or tb == B_SQUOTE or tb == B_LPAREN then
								local titleOk, titleStr, titleEnd = parseLinkTitle(value, pBeforeTitle, len)
								if titleOk then
									title = titleStr
									p = titleEnd
								else
									p = pBeforeTitle
								end
							else
								p = pBeforeTitle
							end
						else
							p = pBeforeTitle
						end

						p = skipOptionalWhitespace(value, p, len)

						if p <= len and string.byte(value, p) == B_RPAREN then
							dest = destStr
							afterPos = p + 1
							linkParsed = true
						end
					end
				end

				if linkParsed then
					-- Process emphasis only within the bracket span
					processEmphasis(dsHead, dsTail, bracket.delimBefore, delimiterResolvers)

					-- Collect all inline nodes between the opener and ilTail
					local children = llSpliceBetween(bracket.ilNode, ilTail)

					-- Remove the opener text node ("[" or "![")
					llRemove(bracket.ilNode)

					-- Build the link or image node
					if bracket.isImage then
						addNode({
							type = "image",
							destination = dest,
							title = title,
							children = children,
						})
					else
						addNode({
							type = "link",
							destination = dest,
							title = title,
							children = children,
						})
					end

					-- For links, deactivate all prior [ brackets (no nested links)
					if not bracket.isImage then
						for i = bracketIdx - 1, 1, -1 do
							if not brackets[i].isImage then
								brackets[i].active = false
							end
						end
					end

					-- Remove this bracket and everything after it from the stack
					for i = #brackets, bracketIdx, -1 do
						table.remove(brackets, i)
					end

					pos = afterPos
				else
					-- ======== Try reference links ========
					local refLabel: string? = nil
					local refAfterPos = pos + 1

					local nextByte = if (pos + 1) <= len then string.byte(value, pos + 1) else nil
					if nextByte == B_LBRACKET then
						-- Try full reference [text][label] or collapsed [text][]
						local labelOk, normLabel, afterLabel = parseLinkLabel(value, pos + 1)
						if labelOk then
							if normLabel ~= "" then
								-- Full reference
								refLabel = normLabel
							else
								-- Collapsed reference []
								refLabel = normalizeLabel(value:sub(bracket.contentStart, pos - 1))
							end
							refAfterPos = afterLabel
						end
						-- If parseLinkLabel fails, refLabel stays nil (not a link)
					else
						-- Shortcut reference: use bracket content as label
						local contentLabel = normalizeLabel(value:sub(bracket.contentStart, pos - 1))
						if contentLabel ~= "" then
							refLabel = contentLabel
						end
						refAfterPos = pos + 1
					end

					local refResolved = false
					if refLabel and linkRefs and linkRefs[refLabel] then
						local ref = linkRefs[refLabel]

						processEmphasis(dsHead, dsTail, bracket.delimBefore, delimiterResolvers)
						local children = llSpliceBetween(bracket.ilNode, ilTail)
						llRemove(bracket.ilNode)

						if bracket.isImage then
							addNode({
								type = "image",
								destination = ref.destination,
								title = ref.title,
								children = children,
							})
						else
							addNode({
								type = "link",
								destination = ref.destination,
								title = ref.title,
								children = children,
							})
						end

						if not bracket.isImage then
							for i = bracketIdx - 1, 1, -1 do
								if not brackets[i].isImage then
									brackets[i].active = false
								end
							end
						end

						for i = #brackets, bracketIdx, -1 do
							table.remove(brackets, i)
						end

						pos = refAfterPos
						refResolved = true
					end

					if not refResolved then
						-- Not a valid link — remove bracket, ] is literal text
						table.remove(brackets, bracketIdx)
						addText("]")
						pos += 1
					end
				end
				textStart = pos
			end

		-- ======== Entity / character reference & ========
		elseif byte == B_AMP then
			local resolved, newPos = tryParseEntity(value, pos, len)
			if resolved then
				flushText(pos - 1)
				addText(resolved)
				pos = newPos
				textStart = pos
			else
				pos += 1
			end

		-- ======== Line endings ========
		elseif byte == B_LF or byte == B_CR then
			local trimmedSpaces = flushTextForNewline()

			if trimmedSpaces >= 2 then
				addNode({ type = "hard_line_break" })
			else
				addNode({ type = "soft_line_break" })
			end

			if byte == B_CR and pos + 1 <= len and string.byte(value, pos + 1) == B_LF then
				pos += 2
			else
				pos += 1
			end
			textStart = pos

		-- ======== Ordinary character ========
		else
			pos += 1
		end
	end

	-- Flush remaining text
	flushText(len)

	-- Final emphasis pass over entire content
	processEmphasis(dsHead, dsTail, nil, delimiterResolvers)

	-- Flatten inline LL into an array, merging adjacent text nodes
	local result: { types.InlineNode } = {}
	local cur = ilHead.next
	while cur ~= ilTail do
		local node = cur.val
		if #result > 0 and node.type == "text" and (result[#result] :: any).type == "text" then
			(result[#result] :: any).content ..= node.content
		else
			table.insert(result, node :: types.InlineNode)
		end
		cur = cur.next
	end
	return result
end

-- ================================================================
-- Public: walk block tree, parse inlines in paragraphs & headings
-- ================================================================

function parse.parse(
	document: types.DocumentBlockNode,
	orphans: { types.AnyBlockNode },
	config: types.MarkdownConfig
): types.DocumentBlockNode
	local linkRefs = (document :: any).linkReferences or {}
	local queue: { types.AnyBlockNode } = { document }

	for _, i in orphans do
		table.insert(queue, i)
	end

	while #queue > 0 do
		local node = queue[1]
		table.remove(queue, 1)

		if node.type == "paragraph" or node.type == "heading" then
			local raw = table.concat(node.raw, if config.useCrlf then "\r\n" else "\n")

			-- Strip a trailing \r\n or \n left over from the block parser
			if #raw >= 2 and raw:sub(#raw - 1, #raw) == "\r\n" then
				raw = raw:sub(1, #raw - 2)
			elseif #raw >= 1 and (raw:sub(#raw, #raw) == "\n" or raw:sub(#raw, #raw) == "\r") then
				raw = raw:sub(1, #raw - 1)
			end
			-- Strip trailing spaces/tabs from the last line
			while #raw > 0 do
				local lb = string.byte(raw, #raw)
				if lb == B_SPACE or lb == B_TAB then
					raw = raw:sub(1, #raw - 1)
				else
					break
				end
			end
			(node :: any).inlines = parseInline(raw, linkRefs, config)
		elseif node.type == "table" then
			-- Parse inlines in all table cells
			local tbl = node :: any
			local function parseCellInlines(row: any)
				for _, cell in row.cells do
					cell.inlines = parseInline(cell.raw, linkRefs, config)
				end
			end
			parseCellInlines(tbl.head)
			for _, row in tbl.body do
				parseCellInlines(row)
			end
		elseif node.type == "admonition" then
			-- Parse title inlines if present
			local adm = node :: any
			if adm.titleRaw then
				adm.titleInlines = parseInline(adm.titleRaw, linkRefs, config)
			end
		elseif node.type == "tab_panel" then
			local panel = node :: any
			panel.titleInlines = parseInline(panel.title, linkRefs, config)
		end

		-- Task list detection: check first paragraph of list items
		if node.type == "list_item" or node.type == "ordered_list_item" then
			local item = node :: any
			if #item.children > 0 and item.children[1].type == "paragraph" then
				local para = item.children[1]
				local raw = table.concat(para.raw, if config.useCrlf then "\r\n" else "\n")

				if #raw >= 4 then
					local prefix = raw:sub(1, 4)
					if prefix == "[ ] " then
						item.checked = false
						para.raw = { raw:sub(5) }
					elseif prefix == "[x] " or prefix == "[X] " then
						item.checked = true
						para.raw = { raw:sub(5) }
					end
				end
			end
		end

		local children = (node :: any).children
		if children then
			for _, child in children do
				table.insert(queue, 1, child)
			end
		end
	end

	return document
end

return table.freeze(parse)
