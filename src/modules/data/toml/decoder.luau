local shared = require("@self/shared")

local regex = shared.regex
local TOML_ARRAY_MT = shared.TOML_ARRAY_MT
local TOML_AOT_MT = shared.TOML_AOT_MT
local BARE_KEY_RE = shared.BARE_KEY_RE
local DEC_INT_RE = shared.DEC_INT_RE
local HEX_INT_RE = shared.HEX_INT_RE
local OCT_INT_RE = shared.OCT_INT_RE
local BIN_INT_RE = shared.BIN_INT_RE
local FLOAT_RE = shared.FLOAT_RE
local OFFSET_DT_RE = shared.OFFSET_DT_RE
local LOCAL_DT_RE = shared.LOCAL_DT_RE
local LOCAL_DATE_RE = shared.LOCAL_DATE_RE
local LOCAL_TIME_RE = shared.LOCAL_TIME_RE

local isSpaceByte = shared.isSpaceByte
local isInlineSpaceByte = shared.isInlineSpaceByte
local tableIsArray = shared.tableIsArray
local isArrayOfTables = shared.isArrayOfTables
local parseIntegerToken = shared.parseIntegerToken
local joinDottedPath = shared.joinDottedPath

local decoder = {}
type AssignmentRecord = {
	path: { string },
	sectionPathKey: string,
	lineStart: number,
	lineEndExclusive: number,
	keySegment: string,
	postEqWhitespace: string,
	lineSuffix: string,
	newline: string,
}

type HeaderRecord = {
	path: { string },
	lineStart: number,
	lineEndExclusive: number,
	newline: string,
}

type Parser = {
	source: string,
	len: number,
	pos: number,
	root: { [string]: any },
	currentTable: { [string]: any },
	currentPath: { string },
	explicitHeaders: { [string]: boolean },
	explicitTables: { [any]: boolean },
	inlineTables: { [any]: boolean },
	dottedTables: { [any]: boolean },
	captureCST: boolean,
	assignmentByPath: { [string]: AssignmentRecord },
	headerByPath: { [string]: HeaderRecord },
}

local function pathKey(path: { string }): string
	return table.concat(path, "\0")
end

local function parserError(parser: Parser, message: string): never
	error(`TOML parse error at {parser.pos}: {message}`)
end

local function validateSourceEncoding(source: string)
	if utf8.len(source) == nil then
		error("TOML parse error at 1: source is not valid UTF-8")
	end

	local i = 1
	while i <= #source do
		local b = string.byte(source, i)
		if b == 0x0D then
			if string.byte(source, i + 1) ~= 0x0A then
				error(`TOML parse error at {i}: bare CR is not allowed`)
			end
			i += 2
		else
			if (b < 0x20 and b ~= 0x09 and b ~= 0x0A) or b == 0x7F then
				error(`TOML parse error at {i}: invalid control character`)
			end
			i += 1
		end
	end
end

local function peek(parser: Parser): number?
	if parser.pos > parser.len then
		return nil
	end
	local byte = string.byte(parser.source, parser.pos)
	return byte
end

local function consume(parser: Parser): number
	local byte = string.byte(parser.source, parser.pos)
	parser.pos += 1
	return byte
end

local function skipWhitespaceAndComments(parser: Parser)
	while parser.pos <= parser.len do
		local byte = string.byte(parser.source, parser.pos)
		if isSpaceByte(byte) then
			parser.pos += 1
		elseif byte == 0x23 then
			while parser.pos <= parser.len do
				local c = string.byte(parser.source, parser.pos)
				if (c < 0x20 and c ~= 0x09 and c ~= 0x0A and c ~= 0x0D) or c == 0x7F then
					parserError(parser, "invalid control character in comment")
				end
				parser.pos += 1
				if c == 0x0A then
					break
				end
			end
		elseif (byte < 0x20 and byte ~= 0x09 and byte ~= 0x0A and byte ~= 0x0D) or byte == 0x7F then
			parserError(parser, "invalid control character")
		else
			break
		end
	end
end

local function skipInlineWhitespace(parser: Parser)
	while parser.pos <= parser.len do
		local byte = string.byte(parser.source, parser.pos)
		if isInlineSpaceByte(byte) then
			parser.pos += 1
		else
			break
		end
	end
end

local function parseHexCode(parser: Parser, digits: number): number
	if parser.pos + digits - 1 > parser.len then
		parserError(parser, "unterminated unicode escape")
	end

	local hex = string.sub(parser.source, parser.pos, parser.pos + digits - 1)
	if not string.match(hex, "^[0-9A-Fa-f]+$") then
		parserError(parser, "invalid unicode escape")
	end
	local code = tonumber(hex, 16)
	if code == nil then
		parserError(parser, "invalid unicode escape")
	end
	parser.pos += digits
	return code :: number
end

local function utf8FromCodePoint(code: number): string
	if code < 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
		error("invalid unicode codepoint")
	end

	if code <= 0x7F then
		return string.char(code)
	elseif code <= 0x7FF then
		return string.char(0xC0 + bit32.rshift(code, 6), 0x80 + bit32.band(code, 0x3F))
	elseif code <= 0xFFFF then
		return string.char(
			0xE0 + bit32.rshift(code, 12),
			0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
			0x80 + bit32.band(code, 0x3F)
		)
	end
	return string.char(
		0xF0 + bit32.rshift(code, 18),
		0x80 + bit32.band(bit32.rshift(code, 12), 0x3F),
		0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
		0x80 + bit32.band(code, 0x3F)
	)
end

local function parseEscapedCodePoint(parser: Parser, esc: number): string
	if esc == 0x22 then
		return '"'
	elseif esc == 0x5C then
		return "\\"
	elseif esc == 0x62 then
		return "\b"
	elseif esc == 0x74 then
		return "\t"
	elseif esc == 0x6E then
		return "\n"
	elseif esc == 0x66 then
		return "\f"
	elseif esc == 0x72 then
		return "\r"
	elseif esc == 0x65 then
		return string.char(0x1B)
	elseif esc == 0x78 then
		local ok, out = pcall(function()
			return utf8FromCodePoint(parseHexCode(parser, 2))
		end)
		if not ok then
			parserError(parser, "invalid unicode escape")
		end
		return out :: string
	elseif esc == 0x75 then
		local ok, out = pcall(function()
			return utf8FromCodePoint(parseHexCode(parser, 4))
		end)
		if not ok then
			parserError(parser, "invalid unicode escape")
		end
		return out :: string
	elseif esc == 0x55 then
		local ok, out = pcall(function()
			return utf8FromCodePoint(parseHexCode(parser, 8))
		end)
		if not ok then
			parserError(parser, "invalid unicode escape")
		end
		return out :: string
	end

	parserError(parser, "invalid string escape")
	return ""
end

local function parseBasicString(parser: Parser, allowMultiline: boolean): string
	if consume(parser) ~= 0x22 then
		parserError(parser, 'expected "')
	end

	local multiline = false
	if peek(parser) == 0x22 and string.byte(parser.source, parser.pos + 1) == 0x22 then
		if not allowMultiline then
			parserError(parser, "multiline strings are not allowed here")
		end
		consume(parser)
		consume(parser)
		multiline = true
	end

	if multiline then
		local first = peek(parser)
		if first == 0x0D then
			consume(parser)
			if peek(parser) == 0x0A then
				consume(parser)
			end
		elseif first == 0x0A then
			consume(parser)
		end
	end

	local out: { string } = {}
	while true do
		local byte = peek(parser)
		if byte == nil then
			parserError(parser, "unterminated string")
		elseif byte == 0x22 then
			if multiline then
				local run = 0
				local scan = parser.pos
				while string.byte(parser.source, scan) == 0x22 do
					run += 1
					scan += 1
				end

				if run >= 3 then
					local extra = math.min(run - 3, 2)
					for _ = 1, extra do
						table.insert(out, '"')
					end
					for _ = 1, 3 + extra do
						consume(parser)
					end
					return table.concat(out)
				else
					table.insert(out, '"')
					consume(parser)
					continue
				end
			else
				consume(parser)
				return table.concat(out)
			end
		elseif byte == 0x5C then
			consume(parser)
			local esc = peek(parser)
			if esc == nil then
				parserError(parser, "unterminated escape")
			end

			if multiline then
				local scanPos = parser.pos
				local sawNewline = false
				while scanPos <= parser.len do
					local b = string.byte(parser.source, scanPos)
					if b == 0x20 or b == 0x09 then
						scanPos += 1
					elseif b == 0x0A then
						sawNewline = true
						scanPos += 1
					elseif b == 0x0D then
						sawNewline = true
						scanPos += 1
						if string.byte(parser.source, scanPos) == 0x0A then
							scanPos += 1
						end
					else
						break
					end
				end
				if sawNewline then
					parser.pos = scanPos
					continue
				end
			end

			consume(parser)
			table.insert(out, parseEscapedCodePoint(parser, esc :: number))
		else
			if
				(byte < 0x20 and byte ~= 0x09 and (not multiline or (byte ~= 0x0A and byte ~= 0x0D)))
				or byte == 0x7F
			then
				parserError(parser, "control characters are not allowed in strings")
			end
			table.insert(out, string.char(consume(parser)))
		end
	end
end

local function parseLiteralString(parser: Parser, allowMultiline: boolean): string
	if consume(parser) ~= 0x27 then
		parserError(parser, "expected '''")
	end

	local multiline = false
	if peek(parser) == 0x27 and string.byte(parser.source, parser.pos + 1) == 0x27 then
		if not allowMultiline then
			parserError(parser, "multiline strings are not allowed here")
		end
		consume(parser)
		consume(parser)
		multiline = true
	end

	if multiline then
		local first = peek(parser)
		if first == 0x0D then
			consume(parser)
			if peek(parser) == 0x0A then
				consume(parser)
			end
		elseif first == 0x0A then
			consume(parser)
		end
	end

	local start = parser.pos
	while true do
		local maybeByte = peek(parser)
		if maybeByte == nil then
			parserError(parser, "unterminated literal string")
		end

		local byte = maybeByte :: number
		if byte == 0x27 then
			if multiline then
				local run = 0
				local scan = parser.pos
				while string.byte(parser.source, scan) == 0x27 do
					run += 1
					scan += 1
				end

				if run >= 3 then
					local extra = math.min(run - 3, 2)
					local result = string.sub(parser.source, start, parser.pos - 1) .. string.rep("'", extra)
					for _ = 1, 3 + extra do
						consume(parser)
					end
					return result
				else
					consume(parser)
					continue
				end
			else
				local result = string.sub(parser.source, start, parser.pos - 1)
				consume(parser)
				return result
			end
		end
		if (byte < 0x20 and byte ~= 0x09 and (not multiline or (byte ~= 0x0A and byte ~= 0x0D))) or byte == 0x7F then
			parserError(parser, "control characters are not allowed in literal strings")
		end
		consume(parser)
	end
end

local function parseKeyPart(parser: Parser): string
	skipInlineWhitespace(parser)
	local byte = peek(parser)
	if byte == nil then
		parserError(parser, "unexpected end while parsing key")
	end

	if byte == 0x22 then
		return parseBasicString(parser, false)
	elseif byte == 0x27 then
		return parseLiteralString(parser, false)
	end

	local rest = string.sub(parser.source, parser.pos)
	local maybeMatch = BARE_KEY_RE:find(rest)
	if not maybeMatch or maybeMatch.start ~= 1 then
		parserError(parser, "invalid bare key")
	end
	local match = maybeMatch :: any
	parser.pos += #match.match
	return match.match
end

local function parseDottedKey(parser: Parser, terminators: { [number]: boolean }): { string }
	local parts: { string } = {}
	while true do
		local part = parseKeyPart(parser)
		table.insert(parts, part)
		skipInlineWhitespace(parser)
		local byte = peek(parser)
		if byte == 0x2E then
			consume(parser)
			skipInlineWhitespace(parser)
		elseif byte ~= nil and terminators[byte] then
			break
		else
			parserError(parser, "expected '.' or key terminator")
		end
	end
	return parts
end

local function parseToken(parser: Parser): string
	local start = parser.pos
	while parser.pos <= parser.len do
		local byte = string.byte(parser.source, parser.pos)
		if (byte < 0x20 and byte ~= 0x09 and byte ~= 0x0A and byte ~= 0x0D) or byte == 0x7F then
			parserError(parser, "invalid control character in value")
		end
		if
			byte == 0x20
			or byte == 0x09
			or byte == 0x0D
			or byte == 0x0A
			or byte == 0x2C
			or byte == 0x5D
			or byte == 0x7D
			or byte == 0x23
		then
			break
		end
		parser.pos += 1
	end

	if parser.pos == start then
		parserError(parser, "expected value")
	end
	return string.sub(parser.source, start, parser.pos - 1)
end

local function isTokenDelimiter(byte: number?): boolean
	if byte == nil then
		return true
	end
	return byte == 0x20
		or byte == 0x09
		or byte == 0x0D
		or byte == 0x0A
		or byte == 0x2C
		or byte == 0x5D
		or byte == 0x7D
		or byte == 0x23
end

local parseValue: (parser: Parser) -> any

local function markInlineTableRecursive(parser: Parser, value: { [any]: any })
	parser.inlineTables[value] = true
	for _, child in value do
		if type(child) == "table" then
			parser.inlineTables[child] = true
			if tableIsArray(child :: any) then
				for i = 1, #(child :: any) do
					local entry = (child :: any)[i]
					if type(entry) == "table" then
						markInlineTableRecursive(parser, entry)
					end
				end
			else
				markInlineTableRecursive(parser, child :: any)
			end
		end
	end
end

local function parseInlineTable(parser: Parser): { [string]: any }
	if consume(parser) ~= 0x7B then
		parserError(parser, "expected '{'")
	end

	local value: { [string]: any } = {}
	while true do
		skipWhitespaceAndComments(parser)
		local nextByte = peek(parser)
		if nextByte == nil then
			parserError(parser, "unterminated inline table")
		elseif nextByte == 0x7D then
			consume(parser)
			markInlineTableRecursive(parser, value :: any)
			return value
		end

		local keyPath = parseDottedKey(parser, { [0x3D] = true })
		if consume(parser) ~= 0x3D then
			parserError(parser, "expected '=' in inline table")
		end
		skipWhitespaceAndComments(parser)
		local parsed = parseValue(parser)

		local cursor = value
		for i = 1, #keyPath - 1 do
			local key = keyPath[i]
			local existing = cursor[key]
			if existing == nil then
				local created = {}
				cursor[key] = created
				cursor = created
			elseif type(existing) == "table" then
				if parser.inlineTables[existing] then
					parserError(parser, "cannot extend inline table")
				end
				cursor = existing
			else
				parserError(parser, "cannot redefine non-table as table in inline table")
			end
		end

		local leaf = keyPath[#keyPath]
		if cursor[leaf] ~= nil then
			parserError(parser, "duplicate key in inline table")
		end
		cursor[leaf] = parsed
		if type(parsed) == "table" then
			markInlineTableRecursive(parser, parsed :: any)
		end

		skipWhitespaceAndComments(parser)
		local sep = peek(parser)
		if sep == 0x2C then
			consume(parser)
		elseif sep == 0x7D then
			markInlineTableRecursive(parser, value :: any)
			continue
		else
			parserError(parser, "expected ',' or '}' in inline table")
		end
	end
end

local function parseArray(parser: Parser): { any }
	if consume(parser) ~= 0x5B then
		parserError(parser, "expected '['")
	end

	local value = {}
	setmetatable(value, TOML_ARRAY_MT)
	while true do
		skipWhitespaceAndComments(parser)
		local nextByte = peek(parser)
		if nextByte == nil then
			parserError(parser, "unterminated array")
		elseif nextByte == 0x5D then
			consume(parser)
			return value
		end

		table.insert(value, parseValue(parser))
		skipWhitespaceAndComments(parser)
		local sep = peek(parser)
		if sep == 0x2C then
			consume(parser)
		elseif sep == 0x5D then
			continue
		else
			parserError(parser, "expected ',' or ']' in array")
		end
	end
end

local function normalizeDateTimeLikeToken(token: string): string
	if OFFSET_DT_RE:isMatch(token) then
		local out = token
		if string.sub(out, 11, 11) == " " or string.sub(out, 11, 11) == "t" then
			out = string.sub(out, 1, 10) .. "T" .. string.sub(out, 12)
		end
		if string.sub(out, -1) == "z" then
			out = string.sub(out, 1, -2) .. "Z"
		end
		if regex.isMatch("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$", out) then
			local head = string.sub(out, 1, 16)
			local tail = string.sub(out, 17)
			out = head .. ":00" .. tail
		end
		return out
	elseif LOCAL_DT_RE:isMatch(token) then
		local out = token
		if string.sub(out, 11, 11) == " " or string.sub(out, 11, 11) == "t" then
			out = string.sub(out, 1, 10) .. "T" .. string.sub(out, 12)
		end
		if regex.isMatch("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$", out) then
			out ..= ":00"
		end
		return out
	elseif LOCAL_TIME_RE:isMatch(token) then
		if regex.isMatch("^[0-9]{2}:[0-9]{2}$", token) then
			return token .. ":00"
		end
		return token
	end
	return token
end

local function isLeapYear(year: number): boolean
	if year % 400 == 0 then
		return true
	end
	if year % 100 == 0 then
		return false
	end
	return year % 4 == 0
end

local function daysInMonth(year: number, month: number): number
	if month == 2 then
		return if isLeapYear(year) then 29 else 28
	elseif month == 4 or month == 6 or month == 9 or month == 11 then
		return 30
	end
	return 31
end

local function parseNumberField(field: string?): number?
	if field == nil then
		return nil
	end
	return tonumber(field)
end

local function validateTemporalToken(token: string): boolean
	local y, mo, d, h, mi, s = token:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if y ~= nil then
		local year = parseNumberField(y) :: number
		local month = parseNumberField(mo) :: number
		local day = parseNumberField(d) :: number
		local hour = parseNumberField(h) :: number
		local minute = parseNumberField(mi) :: number
		local second = parseNumberField(s) :: number
		if month < 1 or month > 12 then
			return false
		end
		if day < 1 or day > daysInMonth(year, month) then
			return false
		end
		if hour < 0 or hour > 23 then
			return false
		end
		if minute < 0 or minute > 59 then
			return false
		end
		if second < 0 or second > 60 then
			return false
		end

		local offsetHour, offsetMinute = token:match("[+-](%d%d):(%d%d)$")
		if offsetHour ~= nil and offsetMinute ~= nil then
			local oh = parseNumberField(offsetHour) :: number
			local om = parseNumberField(offsetMinute) :: number
			if oh < 0 or oh > 23 or om < 0 or om > 59 then
				return false
			end
		end
		return true
	end

	local dateY, dateM, dateD = token:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if dateY ~= nil then
		local year = parseNumberField(dateY) :: number
		local month = parseNumberField(dateM) :: number
		local day = parseNumberField(dateD) :: number
		if month < 1 or month > 12 then
			return false
		end
		if day < 1 or day > daysInMonth(year, month) then
			return false
		end
		return true
	end

	local timeH, timeM, timeS = token:match("^(%d%d):(%d%d):(%d%d)")
	if timeH ~= nil then
		local hour = parseNumberField(timeH) :: number
		local minute = parseNumberField(timeM) :: number
		local second = parseNumberField(timeS) :: number
		if hour < 0 or hour > 23 then
			return false
		end
		if minute < 0 or minute > 59 then
			return false
		end
		if second < 0 or second > 60 then
			return false
		end
		return true
	end

	return false
end

parseValue = function(parser: Parser): any
	skipWhitespaceAndComments(parser)
	local byte = peek(parser)
	if byte == nil then
		parserError(parser, "expected value")
	end

	if byte == 0x22 then
		return parseBasicString(parser, true)
	elseif byte == 0x27 then
		return parseLiteralString(parser, true)
	elseif byte == 0x5B then
		return parseArray(parser)
	elseif byte == 0x7B then
		return parseInlineTable(parser)
	end

	local token = parseToken(parser)
	if LOCAL_DATE_RE:isMatch(token) and peek(parser) == 0x20 then
		local before = parser.pos
		consume(parser)
		local nextByte = peek(parser)
		if not isTokenDelimiter(nextByte) then
			local rest = parseToken(parser)
			local merged = token .. " " .. rest
			if OFFSET_DT_RE:isMatch(merged) or LOCAL_DT_RE:isMatch(merged) then
				token = merged
			else
				parser.pos = before
			end
		else
			parser.pos = before
		end
	end

	if token == "true" then
		return true
	elseif token == "false" then
		return false
	elseif token == "inf" or token == "+inf" then
		return math.huge
	elseif token == "-inf" then
		return -math.huge
	elseif token == "nan" or token == "+nan" or token == "-nan" then
		return 0 / 0
	elseif
		DEC_INT_RE:isMatch(token)
		or HEX_INT_RE:isMatch(token)
		or OCT_INT_RE:isMatch(token)
		or BIN_INT_RE:isMatch(token)
	then
		return parseIntegerToken(token)
	elseif FLOAT_RE:isMatch(token) then
		local cleaned = string.gsub(token, "_", "")
		return tonumber(cleaned) :: number
	elseif
		OFFSET_DT_RE:isMatch(token)
		or LOCAL_DT_RE:isMatch(token)
		or LOCAL_DATE_RE:isMatch(token)
		or LOCAL_TIME_RE:isMatch(token)
	then
		local normalized = normalizeDateTimeLikeToken(token)
		if not validateTemporalToken(normalized) then
			parserError(parser, "invalid date/time value")
		end
		return normalized
	end

	parserError(parser, "unsupported or invalid TOML value: " .. token)
	return nil
end

local function ensureSubtable(parser: Parser, container: { [string]: any }, key: string): { [string]: any }
	local existing = container[key]
	if existing == nil then
		local created = {}
		container[key] = created
		return created
	elseif isArrayOfTables(existing) then
		parserError(parser, `cannot use key '{key}' as a table because it is already an array-of-tables`)
	elseif tableIsArray(existing :: any) then
		parserError(parser, `cannot use key '{key}' as a table because it is already an array`)
	elseif type(existing) == "table" then
		if parser.inlineTables[existing] then
			parserError(parser, `cannot extend inline table key '{key}'`)
		end
		return existing
	end
	parserError(parser, `cannot use key '{key}' as a table because it is already a scalar`)
	return {}
end

local function ensureSubtableForHeader(parser: Parser, container: { [string]: any }, key: string): { [string]: any }
	local existing = container[key]
	if existing == nil then
		local created = {}
		container[key] = created
		return created
	elseif isArrayOfTables(existing) then
		if getmetatable(existing :: any) ~= TOML_AOT_MT then
			parserError(parser, `cannot define child table under inline array '{key}'`)
		end
		local arr = existing :: { [number]: { [string]: any } }
		if #arr == 0 then
			parserError(parser, `cannot define child table under array '{key}' before any array entries`)
		end
		return arr[#arr]
	elseif tableIsArray(existing :: any) then
		parserError(parser, `cannot use key '{key}' as a table because it is already an array`)
	elseif type(existing) == "table" then
		if parser.inlineTables[existing] then
			parserError(parser, `cannot extend inline table key '{key}'`)
		end
		return existing
	end
	parserError(parser, `cannot use key '{key}' as a table because it is already a scalar`)
	return {}
end

local function assignValue(parser: Parser, container: { [string]: any }, path: { string }, value: any)
	local cursor = container
	for i = 1, #path - 1 do
		cursor = ensureSubtable(parser, cursor, path[i])
		if parser.explicitTables[cursor] then
			parserError(parser, "cannot append to explicitly declared table using dotted keys")
		end
		parser.dottedTables[cursor] = true
	end

	local leaf = path[#path]
	if cursor[leaf] ~= nil then
		parserError(parser, `duplicate key '{leaf}'`)
	end
	cursor[leaf] = value
	if type(value) == "table" then
		if tableIsArray(value) then
			for i = 1, #(value :: any) do
				local entry = (value :: any)[i]
				if type(entry) == "table" then
					markInlineTableRecursive(parser, entry :: any)
				end
			end
		else
			markInlineTableRecursive(parser, value :: any)
		end
	end
end

local function parseHeader(parser: Parser)
	local lineStart = parser.pos
	if consume(parser) ~= 0x5B then
		parserError(parser, "expected '['")
	end

	local isArrayHeader = false
	if peek(parser) == 0x5B then
		consume(parser)
		isArrayHeader = true
	end

	skipInlineWhitespace(parser)
	local path = parseDottedKey(parser, { [0x5D] = true })
	if consume(parser) ~= 0x5D then
		parserError(parser, "expected closing ']' for table header")
	end
	if isArrayHeader and consume(parser) ~= 0x5D then
		parserError(parser, "expected closing ']]' for array-of-tables header")
	end

	if #path == 0 then
		parserError(parser, "empty table header")
	end

	skipInlineWhitespace(parser)
	local byte = peek(parser)
	if byte == 0x23 then
		while parser.pos <= parser.len do
			local c = consume(parser)
			if (c < 0x20 and c ~= 0x09 and c ~= 0x0A and c ~= 0x0D) or c == 0x7F then
				parserError(parser, "invalid control character in comment")
			end
			if c == 0x0A then
				break
			end
		end
	elseif byte ~= nil and byte ~= 0x0A and byte ~= 0x0D then
		parserError(parser, "unexpected characters after table header")
	end

	local newline = ""
	local b = if parser.pos <= parser.len then string.byte(parser.source, parser.pos) else nil
	if b == 0x0D and string.byte(parser.source, parser.pos + 1) == 0x0A then
		newline = "\r\n"
	elseif b == 0x0A then
		newline = "\n"
	end
	local lineEndExclusive = parser.pos + #newline

	if isArrayHeader then
		local parent = parser.root
		for i = 1, #path - 1 do
			parent = ensureSubtableForHeader(parser, parent, path[i])
		end

		local leaf = path[#path]
		local existing = parent[leaf]
		local arrayContainer: { [number]: { [string]: any } }
		if existing == nil then
			local created: { [number]: { [string]: any } } = {}
			setmetatable(created :: any, TOML_AOT_MT)
			parent[leaf] = created
			arrayContainer = created
		elseif isArrayOfTables(existing) then
			if getmetatable(existing :: any) ~= TOML_AOT_MT then
				parserError(parser, "array-of-tables conflicts with existing inline array: " .. joinDottedPath(path))
			end
			arrayContainer = existing :: any
			if getmetatable(arrayContainer :: any) ~= TOML_AOT_MT then
				setmetatable(arrayContainer :: any, TOML_AOT_MT)
			end
		elseif type(existing) == "table" then
			parserError(parser, "array-of-tables conflicts with existing table: " .. joinDottedPath(path))
		else
			parserError(parser, "array-of-tables conflicts with existing scalar: " .. joinDottedPath(path))
		end

		local newEntry = {}
		table.insert(arrayContainer, newEntry)
		parser.currentTable = newEntry
		parser.currentPath = table.clone(path)
	else
		local cursor = parser.root
		for i, part in path do
			if i < #path then
				cursor = ensureSubtableForHeader(parser, cursor, part)
			else
				local existing = cursor[part]
				if existing == nil then
					local created = {}
					cursor[part] = created
					cursor = created
				elseif isArrayOfTables(existing) then
					parserError(parser, "table conflicts with existing array-of-tables: " .. joinDottedPath(path))
				elseif tableIsArray(existing :: any) then
					parserError(parser, "table conflicts with existing array: " .. joinDottedPath(path))
				elseif type(existing) == "table" then
					if parser.inlineTables[existing] then
						parserError(parser, "cannot redefine inline table as table header: " .. joinDottedPath(path))
					end
					cursor = existing
				else
					parserError(parser, "table conflicts with existing scalar: " .. joinDottedPath(path))
				end
			end
		end
		if parser.explicitTables[cursor] then
			parserError(parser, "table header redefined: " .. joinDottedPath(path))
		end
		if parser.dottedTables[cursor] then
			parserError(parser, "table created by dotted keys cannot be redefined: " .. joinDottedPath(path))
		end
		parser.explicitTables[cursor] = true
		parser.currentTable = cursor
		parser.currentPath = table.clone(path)
	end

	if parser.captureCST then
		parser.headerByPath[pathKey(path)] = {
			path = table.clone(path),
			lineStart = lineStart,
			lineEndExclusive = lineEndExclusive,
			newline = newline,
		}
	end
end

local function parseKeyValue(parser: Parser)
	local lineStart = parser.pos
	local path = parseDottedKey(parser, { [0x3D] = true })
	local fullPath = table.clone(parser.currentPath)
	for i = 1, #path do
		table.insert(fullPath, path[i])
	end

	local eqPos = parser.pos
	local keySegment = string.sub(parser.source, lineStart, eqPos - 1)

	if consume(parser) ~= 0x3D then
		parserError(parser, "expected '='")
	end

	local postEqStart = parser.pos
	skipInlineWhitespace(parser)
	local valueStart = parser.pos
	local postEqWhitespace = string.sub(parser.source, postEqStart, valueStart - 1)
	local firstValueByte = peek(parser)
	if firstValueByte == nil or firstValueByte == 0x0A or firstValueByte == 0x0D or firstValueByte == 0x23 then
		parserError(parser, "expected value on same line after '='")
	end

	local value = parseValue(parser)
	assignValue(parser, parser.currentTable, path, value)

	local suffixStart = parser.pos
	skipInlineWhitespace(parser)
	local byte = peek(parser)
	if byte == 0x23 then
		while parser.pos <= parser.len do
			local c = consume(parser)
			if (c < 0x20 and c ~= 0x09 and c ~= 0x0A and c ~= 0x0D) or c == 0x7F then
				parserError(parser, "invalid control character in comment")
			end
			if c == 0x0A then
				break
			end
		end
	elseif byte ~= nil and byte ~= 0x0A and byte ~= 0x0D then
		parserError(parser, "unexpected trailing characters")
	end

	if parser.captureCST then
		local preTrailing = string.sub(parser.source, lineStart, suffixStart - 1)

		-- Only preserve single-line assignments.
		-- This includes scalars, inline tables, and single-line arrays.
		if not string.find(preTrailing, "[\r\n]") then
			local suffixEndExclusive = parser.pos
			local newline = ""
			local b = if parser.pos <= parser.len then string.byte(parser.source, parser.pos) else nil

			if b == 0x0D and string.byte(parser.source, parser.pos + 1) == 0x0A then
				newline = "\r\n"
			elseif b == 0x0A then
				newline = "\n"
			end

			local lineEndExclusive = parser.pos + #newline
			local lineSuffix = string.sub(parser.source, suffixStart, suffixEndExclusive - 1)

			parser.assignmentByPath[pathKey(fullPath)] = {
				path = fullPath,
				sectionPathKey = pathKey(parser.currentPath),
				lineStart = lineStart,
				lineEndExclusive = lineEndExclusive,
				keySegment = keySegment,
				postEqWhitespace = postEqWhitespace,
				lineSuffix = lineSuffix,
				newline = newline,
			}
		end
	end
end

local function decodeInternal(source: string, captureCST: boolean): ({ [string]: any }, any)
	validateSourceEncoding(source)

	local parser: Parser = {
		source = source,
		len = #source,
		pos = 1,
		root = {},
		currentTable = {},
		currentPath = {},
		explicitHeaders = {},
		explicitTables = {},
		inlineTables = {},
		dottedTables = {},
		captureCST = captureCST,
		assignmentByPath = {},
		headerByPath = {},
	}
	parser.currentTable = parser.root
	parser.currentPath = {}

	while true do
		skipWhitespaceAndComments(parser)
		if parser.pos > parser.len then
			break
		end

		local byte = peek(parser)
		if byte == 0x5B then
			parseHeader(parser)
		else
			parseKeyValue(parser)
		end
	end

	return parser.root, {
		assignmentByPath = parser.assignmentByPath,
		headerByPath = parser.headerByPath,
	}
end

function decoder.decode(source: string): { [string]: any }
	local value, _ = decodeInternal(source, false)
	return value
end

function decoder.decodeWithCST(source: string): ({ [string]: any }, any)
	return decodeInternal(source, true)
end

function decoder.parse(source: string): { [string]: any }
	return decoder.decode(source)
end

return decoder
