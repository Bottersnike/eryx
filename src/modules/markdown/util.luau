--- @ignore

local tabUtil = require("./tabUtil")
local types = require("./types")

local util = {}

local HTML_ENTITIES: { [string]: { number } } = require("./entities") :: any

function util.isAsciiLetter(b: number): boolean
	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end
function util.isDigit(b: number): boolean
	return b >= 48 and b <= 57
end

function util.isAsciiPunctuationChar(b: number): boolean
	return (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or (b >= 91 and b <= 96) or (b >= 123 and b <= 126)
end

function util.isHexDigitRef(b: number): boolean
	return (b >= 48 and b <= 57) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end

function util.hexDigitValueRef(b: number): number
	if b >= 48 and b <= 57 then
		return b - 48
	elseif b >= 65 and b <= 70 then
		return b - 55
	else
		return b - 87
	end
end

function util.utf8EncodeRef(cp: number): string
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
	return "\xEF\xBF\xBD"
end

--- Try to parse an entity at `pos` (must point to '&'). Returns (resolved, newPos) or (nil, pos).
function util.tryParseEntityRef(s: string, pos: number, len: number): (string?, number)
	if pos > len or string.byte(s, pos) ~= 38 then
		return nil, pos
	end
	local scanPos = pos + 1
	if scanPos <= len and string.byte(s, scanPos) == 35 then -- #
		scanPos += 1
		if scanPos <= len and (string.byte(s, scanPos) == 120 or string.byte(s, scanPos) == 88) then -- x/X
			scanPos += 1
			local digitStart = scanPos
			while scanPos <= len and util.isHexDigitRef(string.byte(s, scanPos)) and scanPos - digitStart < 6 do
				scanPos += 1
			end
			if scanPos > digitStart and scanPos <= len and string.byte(s, scanPos) == 59 then -- ;
				local cp = 0
				for di = digitStart, scanPos - 1 do
					cp = cp * 16 + util.hexDigitValueRef(string.byte(s, di))
				end
				if cp == 0 then
					cp = 0xFFFD
				end
				return util.utf8EncodeRef(cp), scanPos + 1
			end
		else
			local digitStart = scanPos
			while scanPos <= len and util.isDigit(string.byte(s, scanPos)) and scanPos - digitStart < 7 do
				scanPos += 1
			end
			if scanPos > digitStart and scanPos <= len and string.byte(s, scanPos) == 59 then
				local cp = 0
				for di = digitStart, scanPos - 1 do
					cp = cp * 10 + (string.byte(s, di) - 48)
				end
				if cp == 0 or cp > 0x10FFFF then
					cp = 0xFFFD
				end
				return util.utf8EncodeRef(cp), scanPos + 1
			end
		end
	else
		local nameStart = scanPos
		while scanPos <= len do
			local sb = string.byte(s, scanPos)
			if util.isAsciiLetter(sb) or (scanPos > nameStart and util.isDigit(sb)) then
				scanPos += 1
			else
				break
			end
		end
		if scanPos > nameStart and scanPos <= len and string.byte(s, scanPos) == 59 then
			local name = s:sub(nameStart, scanPos - 1)
			local codepoints = HTML_ENTITIES[name]
			if codepoints then
				local buf = {}
				for _, cp in codepoints do
					table.insert(buf, util.utf8EncodeRef(cp))
				end
				return table.concat(buf), scanPos + 1
			end
		end
	end
	return nil, pos
end

--- Parse a link label starting at pos (must point to '[').
--- Returns (ok, normalizedLabel, newPos).
local function parseLinkLabel(s: string, pos: number): (boolean, string, number)
	local len = #s
	if pos > len or string.byte(s, pos) ~= 91 then -- [
		return false, "", pos
	end
	pos += 1
	local start = pos
	local count = 0
	while pos <= len and count <= 999 do
		local b = string.byte(s, pos)
		if b == 93 then -- ]
			if count == 0 then
				return false, "", pos
			end
			local raw = s:sub(start, pos - 1)
			local hasNonWS = false
			for i = 1, #raw do
				local rb = string.byte(raw, i)
				if rb ~= 32 and rb ~= 9 and rb ~= 10 and rb ~= 13 then
					hasNonWS = true
					break
				end
			end
			if not hasNonWS then
				return false, "", pos
			end
			local normalized = (raw:gsub("[\r\n\t ]+", " "):match("^%s*(.-)%s*$") :: string):lower()
			return true, normalized, pos + 1
		elseif b == 91 then -- unescaped [
			return false, "", pos
		elseif b == 92 and pos + 1 <= len then -- backslash escape
			pos += 2
			count += 2
		else
			pos += 1
			count += 1
		end
	end
	return false, "", pos
end

--- Skip optional whitespace: spaces, tabs, and at most one line ending.
local function skipOptionalWhitespaceRef(s: string, pos: number, len: number): number
	local seenNewline = false
	while pos <= len do
		local b = string.byte(s, pos)
		if b == 32 or b == 9 then
			pos += 1
		elseif not seenNewline and (b == 10 or b == 13) then
			seenNewline = true
			if b == 13 and pos + 1 <= len and string.byte(s, pos + 1) == 10 then
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

--- Parse a link destination for reference definitions. Returns (ok, destination, newPos).
local function parseLinkDestRef(s: string, pos: number, len: number): (boolean, string, number)
	if pos > len then
		return false, "", pos
	end
	local b = string.byte(s, pos)
	-- Angle-bracketed
	if b == 60 then
		pos += 1
		local buf = {}
		while pos <= len do
			b = string.byte(s, pos)
			if b == 62 then
				return true, table.concat(buf), pos + 1
			elseif b == 60 or b == 10 or b == 13 then
				return false, "", pos
			elseif b == 92 and pos + 1 <= len and util.isAsciiPunctuationChar(string.byte(s, pos + 1)) then
				table.insert(buf, s:sub(pos + 1, pos + 1))
				pos += 2
			elseif b == 38 then
				local resolved, newPos = util.tryParseEntityRef(s, pos, len)
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
	-- Bare destination
	local buf = {}
	local parenDepth = 0
	while pos <= len do
		b = string.byte(s, pos)
		if b == 32 or b < 32 or b == 127 then
			break
		elseif b == 40 then
			parenDepth += 1
			if parenDepth > 32 then
				return false, "", pos
			end
			table.insert(buf, "(")
			pos += 1
		elseif b == 41 then
			if parenDepth == 0 then
				break
			end
			parenDepth -= 1
			table.insert(buf, ")")
			pos += 1
		elseif b == 92 and pos + 1 <= len and util.isAsciiPunctuationChar(string.byte(s, pos + 1)) then
			table.insert(buf, s:sub(pos + 1, pos + 1))
			pos += 2
		elseif b == 38 then
			local resolved, newPos = util.tryParseEntityRef(s, pos, len)
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

--- Parse a link title for reference definitions. Returns (ok, title, newPos).
local function parseLinkTitleRef(s: string, pos: number, len: number): (boolean, string, number)
	if pos > len then
		return false, "", pos
	end
	local opener = string.byte(s, pos)
	local closer: number
	if opener == 34 then -- "
		closer = 34
	elseif opener == 39 then -- '
		closer = 39
	elseif opener == 40 then -- (
		closer = 41
	else
		return false, "", pos
	end
	pos += 1
	local buf = {}
	while pos <= len do
		local b = string.byte(s, pos)
		if b == closer then
			return true, table.concat(buf), pos + 1
		elseif b == opener and opener == 40 then
			return false, "", pos
		elseif b == 92 and pos + 1 <= len and util.isAsciiPunctuationChar(string.byte(s, pos + 1)) then
			table.insert(buf, s:sub(pos + 1, pos + 1))
			pos += 2
		elseif b == 38 then
			local resolved, newPos = util.tryParseEntityRef(s, pos, len)
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

--- Try to parse one link reference definition starting at `pos`.
--- Returns (ok, normalizedLabel, destination, title, newPos).
local function tryParseLinkRefDef(s: string, pos: number): (boolean, string, string, string?, number)
	local len = #s
	local p = pos

	-- Optional 0-3 spaces of indentation
	local spaces = 0
	while p <= len and spaces < 4 do
		local b = string.byte(s, p)
		if b == 32 then
			spaces += 1
			p += 1
		elseif b == 9 then
			spaces += 4
			p += 1
		else
			break
		end
	end
	if spaces >= 4 then
		return false, "", "", nil, pos
	end

	-- Link label
	local labelOk, label, afterLabel = parseLinkLabel(s, p)
	if not labelOk then
		return false, "", "", nil, pos
	end
	p = afterLabel

	-- Colon
	if p > len or string.byte(s, p) ~= 58 then
		return false, "", "", nil, pos
	end
	p += 1

	-- Optional whitespace (spaces, tabs, up to one line ending)
	p = skipOptionalWhitespaceRef(s, p, len)

	-- Link destination (required, but can be empty with angle brackets)
	local destOk, dest, afterDest = parseLinkDestRef(s, p, len)
	if not destOk then
		return false, "", "", nil, pos
	end

	-- Empty destination without angle brackets is not allowed
	if #dest == 0 and string.byte(s, p) ~= 60 then
		return false, "", "", nil, pos
	end
	p = afterDest

	-- Try for optional title (must be separated by whitespace)
	local title: string? = nil
	local pBeforeTitle = skipOptionalWhitespaceRef(s, p, len)
	if pBeforeTitle > p and pBeforeTitle <= len then
		local tb = string.byte(s, pBeforeTitle)
		if tb == 34 or tb == 39 or tb == 40 then
			local titleOk, titleStr, afterTitle = parseLinkTitleRef(s, pBeforeTitle, len)
			if titleOk then
				-- After title, must be only spaces/tabs then line ending or end
				local pAfter = afterTitle
				local titleValid = true
				while pAfter <= len do
					local b = string.byte(s, pAfter)
					if b == 32 or b == 9 then
						pAfter += 1
					elseif b == 13 or b == 10 then
						break
					else
						titleValid = false
						break
					end
				end
				if titleValid then
					title = titleStr
					p = pAfter
				end
			end
		end
	end

	-- After destination (+optional title): must be trailing whitespace + line ending or end
	while p <= len do
		local b = string.byte(s, p)
		if b == 32 or b == 9 then
			p += 1
		elseif b == 13 then
			p += 1
			if p <= len and string.byte(s, p) == 10 then
				p += 1
			end
			return true, label, dest, title, p
		elseif b == 10 then
			p += 1
			return true, label, dest, title, p
		else
			return false, "", "", nil, pos
		end
	end

	-- Reached end of string
	return true, label, dest, title, p
end

--- Extract link reference definitions from the front of paragraph raw text.
--- Returns remaining text. Populates `refs` (first definition wins).
function util.extractLinkRefs(raw: { string }, refs: { [string]: { destination: string, title: string? } }): { string }
	local fakeRaw = table.concat(raw, "\r\n")

	local pos = 1
	while pos <= #fakeRaw do
		local ok, label, dest, title, newPos = tryParseLinkRefDef(fakeRaw, pos)
		if not ok then
			break
		end
		if not refs[label] then
			refs[label] = { destination = dest, title = title }
		end
		pos = newPos
	end

	return fakeRaw:sub(pos):split("\r\n")
end

function util.isLineBlank(line: string, offset: tabUtil.LineCursor): boolean
	for i = offset.byte, #line do
		local c = string.byte(line, i)
		if c ~= 32 and c ~= 9 then
			return false
		end
	end
	return true
end

function util.slugify(s: string): string
	s = string.lower(s)
	s = string.gsub(s, "[^%w%s%-]", "")
	s = string.gsub(s, "%s+", "-")
	s = string.gsub(s, "%-%-+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	return if #s > 0 then s else "section"
end

function util.getPlainText(nodes: { types.InlineNode }): string
	local parts: { string } = {}
	for _, n in nodes do
		if (n :: any).children then
			table.insert(parts, util.getPlainText(n.children))
		elseif (n :: any).content then
			table.insert(parts, n.content)
		elseif (n :: any).title then
			table.insert(parts, n.title)
		elseif (n :: any).destination then
			table.insert(parts, n.destination)
		elseif (n :: any).label then
			table.insert(parts, n.label)
		end
	end
	return table.concat(parts)
end

return table.freeze(util)
