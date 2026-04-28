local shared = require("@self/shared")

local TOML_ARRAY_MT = shared.TOML_ARRAY_MT
local TOML_AOT_MT = shared.TOML_AOT_MT
local FLOAT_RE = shared.FLOAT_RE
local OFFSET_DT_MINUTE_RE = shared.OFFSET_DT_MINUTE_RE
local LOCAL_DT_MINUTE_RE = shared.LOCAL_DT_MINUTE_RE
local LOCAL_TIME_MINUTE_RE = shared.LOCAL_TIME_MINUTE_RE

local isSpaceByte = shared.isSpaceByte
local isInlineSpaceByte = shared.isInlineSpaceByte
local parseIntegerToken = shared.parseIntegerToken
local classifyIntegerToken = shared.classifyIntegerToken
local classifyDateTimeToken = shared.classifyDateTimeToken
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
	explicitTables: { [any]: boolean },
	inlineTables: { [any]: boolean },
	dottedTables: { [any]: boolean },
	captureCST: boolean,
	assignmentByPath: { [string]: AssignmentRecord }?,
	headerByPath: { [string]: HeaderRecord }?,
}

local function pathKey(path: { string }): string
	return table.concat(path, "\0")
end

local function parserError(parser: Parser, message: string): never
	error(`TOML parse error at {parser.pos}: {message}`)
end

local function validateSourceUtf8(source: string)
	if utf8.len(source) == nil then
		error("TOML parse error at 1: source is not valid UTF-8")
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

local function isBareCR(parser: Parser, byte: number): boolean
	return byte == 0x0D and string.byte(parser.source, parser.pos + 1) ~= 0x0A
end

local function isTomlArray(value: any): boolean
	return type(value) == "table" and getmetatable(value) == TOML_ARRAY_MT
end

local function isTomlArrayOfTables(value: any): boolean
	return type(value) == "table" and getmetatable(value) == TOML_AOT_MT
end

local function skipWhitespaceAndComments(parser: Parser)
	while parser.pos <= parser.len do
		local byte = string.byte(parser.source, parser.pos)
		if isBareCR(parser, byte) then
			parserError(parser, "bare CR is not allowed")
		end
		if isSpaceByte(byte) then
			parser.pos += 1
		elseif byte == 0x23 then
			while parser.pos <= parser.len do
				local c = string.byte(parser.source, parser.pos)
				if isBareCR(parser, c) then
					parserError(parser, "bare CR is not allowed")
				end
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

	local code = 0
	for offset = 0, digits - 1 do
		local byte = string.byte(parser.source, parser.pos + offset)
		local digit: number
		if byte >= 0x30 and byte <= 0x39 then
			digit = byte - 0x30
		elseif byte >= 0x41 and byte <= 0x46 then
			digit = byte - 0x41 + 10
		elseif byte >= 0x61 and byte <= 0x66 then
			digit = byte - 0x61 + 10
		else
			parserError(parser, "invalid unicode escape")
		end
		code = code * 16 + digit
	end
	parser.pos += digits
	return code
end

local function utf8FromCodePoint(parser: Parser, code: number): string
	if code < 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
		parserError(parser, "invalid unicode escape")
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
		return utf8FromCodePoint(parser, parseHexCode(parser, 2))
	elseif esc == 0x75 then
		return utf8FromCodePoint(parser, parseHexCode(parser, 4))
	elseif esc == 0x55 then
		return utf8FromCodePoint(parser, parseHexCode(parser, 8))
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

	local out: { string }? = nil
	local chunkStart = parser.pos
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
					local chunk = string.sub(parser.source, chunkStart, parser.pos - 1)
					if out == nil then
						consume(parser)
						consume(parser)
						consume(parser)
						for _ = 1, extra do
							consume(parser)
						end
						if extra == 0 then
							return chunk
						end
						return chunk .. string.rep('"', extra)
					end
					if #chunk > 0 then
						table.insert(out, chunk)
					end
					for _ = 1, extra do
						table.insert(out, '"')
					end
					for _ = 1, 3 + extra do
						consume(parser)
					end
					return table.concat(out)
				end

				consume(parser)
				continue
			else
				local chunk = string.sub(parser.source, chunkStart, parser.pos - 1)
				consume(parser)
				if out == nil then
					return chunk
				end
				if #chunk > 0 then
					table.insert(out, chunk)
				end
				return table.concat(out)
			end
		elseif byte == 0x5C then
			if out == nil then
				out = {}
			end
			if parser.pos > chunkStart then
				table.insert(out :: { string }, string.sub(parser.source, chunkStart, parser.pos - 1))
			end
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
					chunkStart = scanPos
					continue
				end
			end

			consume(parser)
			table.insert(out :: { string }, parseEscapedCodePoint(parser, esc :: number))
			chunkStart = parser.pos
		else
			if
				(byte == 0x0D and string.byte(parser.source, parser.pos + 1) ~= 0x0A)
				or (byte < 0x20 and byte ~= 0x09 and (not multiline or (byte ~= 0x0A and byte ~= 0x0D)))
				or byte == 0x7F
			then
				parserError(parser, "control characters are not allowed in strings")
			end
			consume(parser)
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
		if byte == 0x0D and string.byte(parser.source, parser.pos + 1) ~= 0x0A then
			parserError(parser, "bare CR is not allowed")
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

	local start = parser.pos
	while parser.pos <= parser.len do
		local b = string.byte(parser.source, parser.pos)
		local isBareKeyByte = (b >= 0x30 and b <= 0x39)
			or (b >= 0x41 and b <= 0x5A)
			or (b >= 0x61 and b <= 0x7A)
			or b == 0x5F
			or b == 0x2D
		if not isBareKeyByte then
			break
		end
		parser.pos += 1
	end

	if parser.pos == start then
		parserError(parser, "invalid bare key")
	end

	return string.sub(parser.source, start, parser.pos - 1)
end

local function parseDottedKey(parser: Parser, terminators: { [number]: boolean }): { string }
	local parts: { string } = {}
	local count = 0
	while true do
		local part = parseKeyPart(parser)
		count += 1
		parts[count] = part
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
		if isBareCR(parser, byte) then
			parserError(parser, "bare CR is not allowed")
		end
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

local function tokenLooksNumeric(token: string): boolean
	local first = string.byte(token, 1)
	if first == nil then
		return false
	end

	if first == 0x2B or first == 0x2D then
		first = string.byte(token, 2)
		if first == nil then
			return false
		end
	end

	return (first >= 0x30 and first <= 0x39) or first == 0x2E
end

local function tokenLooksDateLike(token: string): boolean
	return string.find(token, "-", 1, true) ~= nil or string.find(token, ":", 1, true) ~= nil
end

local parseValue: (parser: Parser) -> any

local function markInlineValue(parser: Parser, value: any)
	if type(value) ~= "table" then
		return
	end

	if isTomlArray(value) then
		for i = 1, #(value :: any) do
			local entry = (value :: any)[i]
			if type(entry) == "table" then
				markInlineValue(parser, entry)
			end
		end
		return
	end

	local valueTable = value :: { [any]: any }
	parser.inlineTables[valueTable] = true
	for _, child in valueTable do
		if type(child) == "table" then
			markInlineValue(parser, child)
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
			markInlineValue(parser, value)
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
			elseif isTomlArrayOfTables(existing) or isTomlArray(existing) then
				parserError(parser, "cannot redefine non-table as table in inline table")
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
		markInlineValue(parser, parsed)

		skipWhitespaceAndComments(parser)
		local sep = peek(parser)
		if sep == 0x2C then
			consume(parser)
		elseif sep == 0x7D then
			markInlineValue(parser, value)
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
	local count = 0
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

		count += 1
		value[count] = parseValue(parser)
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
	local kind = classifyDateTimeToken(token)
	if kind == "offset-datetime" then
		local out = token
		if string.sub(out, 11, 11) == " " or string.sub(out, 11, 11) == "t" then
			out = string.sub(out, 1, 10) .. "T" .. string.sub(out, 12)
		end
		if string.sub(out, -1) == "z" then
			out = string.sub(out, 1, -2) .. "Z"
		end
		if OFFSET_DT_MINUTE_RE:isMatch(out) then
			local head = string.sub(out, 1, 16)
			local tail = string.sub(out, 17)
			out = head .. ":00" .. tail
		end
		return out
	elseif kind == "local-datetime" then
		local out = token
		if string.sub(out, 11, 11) == " " or string.sub(out, 11, 11) == "t" then
			out = string.sub(out, 1, 10) .. "T" .. string.sub(out, 12)
		end
		if LOCAL_DT_MINUTE_RE:isMatch(out) then
			out ..= ":00"
		end
		return out
	elseif kind == "time" then
		if LOCAL_TIME_MINUTE_RE:isMatch(token) then
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
	end

	local isDecInt = false
	local isHexInt = false
	local isOctInt = false
	local isBinInt = false
	local isFloat = false
	local isOffsetDateTime = false
	local isLocalDateTime = false
	local isLocalDate = false
	local isLocalTime = false

	if tokenLooksNumeric(token) then
		local intKind = classifyIntegerToken(token)
		if intKind == "dec" then
			isDecInt = true
		elseif intKind == "hex" then
			isHexInt = true
		elseif intKind == "oct" then
			isOctInt = true
		elseif intKind == "bin" then
			isBinInt = true
		else
			isFloat = FLOAT_RE:isMatch(token)
		end
	end

	if
		not isDecInt
		and not isHexInt
		and not isOctInt
		and not isBinInt
		and not isFloat
		and tokenLooksDateLike(token)
	then
		local dtKind = classifyDateTimeToken(token)
		if dtKind == "offset-datetime" then
			isOffsetDateTime = true
		elseif dtKind == "local-datetime" then
			isLocalDateTime = true
		elseif dtKind == "date" then
			isLocalDate = true
		elseif dtKind == "time" then
			isLocalTime = true
		end
	end

	if isLocalDate and peek(parser) == 0x20 then
		local before = parser.pos
		consume(parser)
		local nextByte = peek(parser)
		if not isTokenDelimiter(nextByte) then
			local rest = parseToken(parser)
			local merged = token .. " " .. rest
			local mergedKind = classifyDateTimeToken(merged)
			local mergedIsOffsetDateTime = mergedKind == "offset-datetime"
			local mergedIsLocalDateTime = mergedKind == "local-datetime"
			if mergedIsOffsetDateTime or mergedIsLocalDateTime then
				token = merged
				isOffsetDateTime = mergedIsOffsetDateTime
				isLocalDateTime = mergedIsLocalDateTime
				isLocalDate = false
			else
				parser.pos = before
			end
		else
			parser.pos = before
		end
	end

	if isDecInt or isHexInt or isOctInt or isBinInt then
		local intKind = if isHexInt then "hex" elseif isOctInt then "oct" elseif isBinInt then "bin" else "dec"
		return parseIntegerToken(token, intKind)
	elseif isFloat then
		local cleaned = string.gsub(token, "_", "")
		return tonumber(cleaned) :: number
	elseif isOffsetDateTime or isLocalDateTime or isLocalDate or isLocalTime then
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
	elseif isTomlArrayOfTables(existing) then
		parserError(parser, `cannot use key '{key}' as a table because it is already an array-of-tables`)
	elseif isTomlArray(existing) then
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
	elseif isTomlArrayOfTables(existing) then
		local arr = existing :: { [number]: { [string]: any } }
		if #arr == 0 then
			parserError(parser, `cannot define child table under array '{key}' before any array entries`)
		end
		return arr[#arr]
	elseif isTomlArray(existing) then
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
	local pathLen = #path
	if pathLen == 1 then
		local leaf = path[1]
		if container[leaf] ~= nil then
			parserError(parser, `duplicate key '{leaf}'`)
		end
		container[leaf] = value
		markInlineValue(parser, value)
		return
	end

	local cursor = container
	for i = 1, pathLen - 1 do
		cursor = ensureSubtable(parser, cursor, path[i])
		if parser.explicitTables[cursor] then
			parserError(parser, "cannot append to explicitly declared table using dotted keys")
		end
		parser.dottedTables[cursor] = true
	end

	local leaf = path[pathLen]
	if cursor[leaf] ~= nil then
		parserError(parser, `duplicate key '{leaf}'`)
	end
	cursor[leaf] = value
	markInlineValue(parser, value)
end

local function parseHeader(parser: Parser)
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
			if c == 0x0D and string.byte(parser.source, parser.pos) ~= 0x0A then
				parserError(parser, "bare CR is not allowed")
			end
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

	local pathLen = #path
	if isArrayHeader then
		local parent = parser.root
		for i = 1, pathLen - 1 do
			parent = ensureSubtableForHeader(parser, parent, path[i])
		end

		local leaf = path[pathLen]
		local existing = parent[leaf]
		local arrayContainer: { [number]: { [string]: any } }
		if existing == nil then
			local created: { [number]: { [string]: any } } = {}
			setmetatable(created :: any, TOML_AOT_MT)
			parent[leaf] = created
			arrayContainer = created
		elseif isTomlArrayOfTables(existing) then
			arrayContainer = existing :: any
		elseif type(existing) == "table" then
			parserError(parser, "array-of-tables conflicts with existing table: " .. joinDottedPath(path))
		else
			parserError(parser, "array-of-tables conflicts with existing scalar: " .. joinDottedPath(path))
		end

		local newEntry = {}
		table.insert(arrayContainer, newEntry)
		parser.currentTable = newEntry
		parser.currentPath = path
	else
		local cursor = parser.root
		if pathLen > 1 then
			for i = 1, pathLen - 1 do
				cursor = ensureSubtableForHeader(parser, cursor, path[i])
			end
		end

		local leaf = path[pathLen]
		local existing = cursor[leaf]
		if existing == nil then
			local created = {}
			cursor[leaf] = created
			cursor = created
		elseif isTomlArrayOfTables(existing) then
			parserError(parser, "table conflicts with existing array-of-tables: " .. joinDottedPath(path))
		elseif isTomlArray(existing) then
			parserError(parser, "table conflicts with existing array: " .. joinDottedPath(path))
		elseif type(existing) == "table" then
			if parser.inlineTables[existing] then
				parserError(parser, "cannot redefine inline table as table header: " .. joinDottedPath(path))
			end
			cursor = existing
		else
			parserError(parser, "table conflicts with existing scalar: " .. joinDottedPath(path))
		end

		if parser.explicitTables[cursor] then
			parserError(parser, "table header redefined: " .. joinDottedPath(path))
		end
		if parser.dottedTables[cursor] then
			parserError(parser, "table created by dotted keys cannot be redefined: " .. joinDottedPath(path))
		end
		parser.explicitTables[cursor] = true
		parser.currentTable = cursor
		parser.currentPath = path
	end
end

local function parseHeaderCST(parser: Parser)
	local lineStart = parser.pos
	parseHeader(parser)

	local newline = ""
	local b = if parser.pos <= parser.len then string.byte(parser.source, parser.pos) else nil
	if b == 0x0D and string.byte(parser.source, parser.pos + 1) == 0x0A then
		newline = "\r\n"
	elseif b == 0x0A then
		newline = "\n"
	end

	local path = parser.currentPath
	local headerByPath = parser.headerByPath :: { [string]: HeaderRecord }
	headerByPath[pathKey(path)] = {
		path = table.clone(path),
		lineStart = lineStart,
		lineEndExclusive = parser.pos + #newline,
		newline = newline,
	}
end

local function parseKeyValue(parser: Parser)
	local path = parseDottedKey(parser, { [0x3D] = true })

	if consume(parser) ~= 0x3D then
		parserError(parser, "expected '='")
	end

	skipInlineWhitespace(parser)
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
			if c == 0x0D and string.byte(parser.source, parser.pos) ~= 0x0A then
				parserError(parser, "bare CR is not allowed")
			end
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
end

local function parseKeyValueCST(parser: Parser)
	local lineStart = parser.pos
	local path = parseDottedKey(parser, { [0x3D] = true })
	local fullPath = table.clone(parser.currentPath)
	for i = 1, #path do
		table.insert(fullPath, path[i])
	end
	local keySegment = string.sub(parser.source, lineStart, parser.pos - 1)

	if consume(parser) ~= 0x3D then
		parserError(parser, "expected '='")
	end

	local postEqStart = parser.pos
	skipInlineWhitespace(parser)
	local postEqWhitespace = string.sub(parser.source, postEqStart, parser.pos - 1)
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
			if c == 0x0D and string.byte(parser.source, parser.pos) ~= 0x0A then
				parserError(parser, "bare CR is not allowed")
			end
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

		local lineSuffix = string.sub(parser.source, suffixStart, suffixEndExclusive - 1)
		local assignmentByPath = parser.assignmentByPath :: { [string]: AssignmentRecord }
		assignmentByPath[pathKey(fullPath)] = {
			path = fullPath,
			sectionPathKey = pathKey(parser.currentPath),
			lineStart = lineStart,
			lineEndExclusive = parser.pos + #newline,
			keySegment = keySegment,
			postEqWhitespace = postEqWhitespace,
			lineSuffix = lineSuffix,
			newline = newline,
		}
	end
end

local function decodeInternal(source: string, captureCST: boolean): ({ [string]: any }, any)
	validateSourceUtf8(source)

	local parser: Parser = {
		source = source,
		len = #source,
		pos = 1,
		root = {},
		currentTable = {},
		currentPath = {},
		explicitTables = {},
		inlineTables = {},
		dottedTables = {},
		captureCST = captureCST,
		assignmentByPath = if captureCST then {} else nil,
		headerByPath = if captureCST then {} else nil,
	}
	parser.currentTable = parser.root
	parser.currentPath = {}
	local parseHeaderImpl = if captureCST then parseHeaderCST else parseHeader
	local parseKeyValueImpl = if captureCST then parseKeyValueCST else parseKeyValue

	while true do
		skipWhitespaceAndComments(parser)
		if parser.pos > parser.len then
			break
		end

		local byte = peek(parser)
		if byte == 0x5B then
			parseHeaderImpl(parser)
		else
			parseKeyValueImpl(parser)
		end
	end

	return parser.root,
		{
			assignmentByPath = parser.assignmentByPath or {},
			headerByPath = parser.headerByPath or {},
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
