--[=[
	JSON encoding and decoding.

	Serialises Luau values to JSON text and parses JSON text back into
	Luau values. By default decoding follows RFC 8259 JSON, with optional
	flags for JSON5-style and JSONC-style extensions.

	```luau
	local json = require("@eryx/data/json")

	local str = json.encode({ name = "Alice", scores = {100, 97} })
	print(str)  -- '{"name":"Alice","scores":[100,97]}'

	local tbl = json.decode('{"x":1,"y":2}')
	print(tbl.x, tbl.y)  -- 1  2

	local json5 = json.decode("{foo: 0x2A, bar: 'hi'}", json.JSON5)
	print(json5.foo, json5.bar) -- 42  hi
	```

	**Mapping rules:**

	| Luau          | JSON          |
	|---------------|---------------|
	| `string`      | string        |
	| `number`      | number        |
	| `boolean`     | true / false  |
	| `nil`         | null          |
	| Numeric table | array  []     |
	| Mixed table   | object {}     |
]=]

local json = {}
local unicode = require("@eryx/unicode")

local JSON_ARRAY_MT = {}

-- ---------------------------------------------------------------------------
-- Encode helpers
-- ---------------------------------------------------------------------------

--- Characters that must be escaped inside a JSON string (RFC 8259 §7).
local ESCAPE_MAP: { [number]: string } = {
	[0x22] = '\\"', -- "
	[0x5C] = "\\\\", -- \
	[0x08] = "\\b", -- backspace
	[0x0C] = "\\f", -- form feed
	[0x0A] = "\\n", -- newline
	[0x0D] = "\\r", -- carriage return
	[0x09] = "\\t", -- tab
}

local function encodeString(s: string): string
	local parts = table.create(#s)
	local o = 1
	for i = 1, #s do
		local b = string.byte(s, i)
		local esc = ESCAPE_MAP[b]
		if esc then
			parts[o] = esc
		elseif b < 0x20 then
			parts[o] = string.format("\\u%04x", b)
		else
			parts[o] = string.sub(s, i, i)
		end
		o += 1
	end
	return '"' .. table.concat(parts) .. '"'
end

--- Returns true when the table looks like a JSON array (contiguous 1..n keys).
local function isArray(t: { [any]: any }): boolean
	local n = #t
	if n == 0 then
		-- Empty tables are ambiguous in Luau, so only a tagged empty table is an
		-- array. Also require no entries to avoid silently dropping keyed values.
		return getmetatable(t) == JSON_ARRAY_MT and next(t) == nil
	end
	-- Fast check: if the table has exactly n entries and #t == n it's an array.
	local count = 0
	for _ in t do
		count += 1
		if count > n then
			return false
		end
	end
	return count == n
end

export type EncodeOptions = {
	--- Insert newlines and indentation for readability.
	pretty: boolean?,
	--- Indentation string used when `pretty` is enabled (default `"  "` - two spaces).
	indent: string?,
	--- Sort object keys alphabetically.
	sortKeys: boolean?,
}

export type DecodeOptions = {
	--- Allow comments using `//` or `/* ... */`
	comments: boolean?,
	--- Allow trailing commas, eg `[1, 2, 3, ]`
	trailingComma: boolean?,
	--- Allow single quoted strings, eg `'foo'`
	singleQuotedStrings: boolean?,
	--- Allow escaping a newline in a string with a backslash
	multilineStrings: boolean?,

	--- Allow unquoted keys, eg `{foo: "bar"}`
	unquotedKeys: boolean?,
	--- Add support for JSON5's additional numbers (NaN, Infinity, 0xFF, +1, .5, 5.)
	json5Numbers: boolean?,
	--- Allow JSON5's additional whitespace characters such as NBSP, BOM, LS/PS, and other Zs characters.
	json5Whitespace: boolean?,
	--- Allow JSON5 string escapes such as \xNN, \v, and \0.
	json5Escapes: boolean?,
}

--- Preset decode options for JSON5-style parsing.
json.DECODE_JSON5 = {
	comments = true,
	trailingComma = true,
	singleQuotedStrings = true,
	multilineStrings = true,
	unquotedKeys = true,
	json5Numbers = true,
	json5Whitespace = true,
	json5Escapes = true,
} :: DecodeOptions

--- Preset decode options for JSONC-style parsing.
json.DECODE_JSONC = {
	comments = true,
	trailingComma = true,
	singleQuotedStrings = false,
	multilineStrings = false,
	unquotedKeys = false,
	json5Numbers = false,
	json5Whitespace = false,
	json5Escapes = false,
} :: DecodeOptions

local function encodeValue(v: any, opts: EncodeOptions, depth: number, buf: { string })
	local pretty = opts.pretty or false
	local indentStr = opts.indent or "  "
	local sortKeys = opts.sortKeys or false

	local t = type(v)

	if t == "nil" then
		table.insert(buf, "null")
	elseif t == "boolean" then
		table.insert(buf, if v then "true" else "false")
	elseif t == "number" then
		-- Reject inf / nan as they are not valid JSON.
		if v ~= v then
			error("Cannot encode NaN as JSON")
		elseif v == math.huge or v == -math.huge then
			error("Cannot encode Infinity as JSON")
		end
		-- Use integer notation when the number is a whole number.
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			table.insert(buf, string.format("%d", v))
		else
			table.insert(buf, string.format("%.17g", v))
		end
	elseif t == "string" then
		table.insert(buf, encodeString(v))
	elseif t == "table" then
		if isArray(v) then
			if #v == 0 then
				table.insert(buf, "[]")
				return
			end
			table.insert(buf, "[")
			local inner = depth + 1
			for i = 1, #v do
				if i > 1 then
					table.insert(buf, ",")
				end
				if pretty then
					table.insert(buf, "\n" .. string.rep(indentStr, inner))
				end
				encodeValue(v[i], opts, inner, buf)
			end
			if pretty then
				table.insert(buf, "\n" .. string.rep(indentStr, depth))
			end
			table.insert(buf, "]")
		else
			-- Object
			local keys: { string } = {}
			for k in v :: any do
				if type(k) ~= "string" then
					error("JSON object keys must be strings, got " .. type(k))
				end
				table.insert(keys, k)
			end

			if #keys == 0 then
				table.insert(buf, "{}")
				return
			end

			if sortKeys then
				table.sort(keys)
			end

			table.insert(buf, "{")
			local inner = depth + 1
			for i, k in keys do
				if i > 1 then
					table.insert(buf, ",")
				end
				if pretty then
					table.insert(buf, "\n" .. string.rep(indentStr, inner))
				end
				table.insert(buf, encodeString(k))
				table.insert(buf, if pretty then ": " else ":")
				encodeValue((v :: any)[k], opts, inner, buf)
			end
			if pretty then
				table.insert(buf, "\n" .. string.rep(indentStr, depth))
			end
			table.insert(buf, "}")
		end
	else
		error("Cannot encode type '" .. t .. "' as JSON")
	end
end

--[=[
	Encodes a Luau value as a JSON string.

	Tables with sequential integer keys (1 .. n) are encoded as JSON arrays.
	Tables with string keys are encoded as JSON objects.  Nested structures
	are fully supported.

	Set `options.pretty` to `true` for indented, human-readable output.
	Set `options.sortKeys` to `true` to emit object keys in alphabetical order.

	@param value -- The value to encode.
	@param options EncodeOptions? -- Optional formatting options.
	@return string -- The JSON string.
]=]
function json.encode(value: any, options: EncodeOptions?): string
	local opts: EncodeOptions = options or {} :: any
	local buf: { string } = {}
	encodeValue(value, opts, 0, buf)
	return table.concat(buf)
end

--[=[
	Preset decode options for JSON5.

	Enables comments, trailing commas, single-quoted strings, multiline
	strings, unquoted keys, JSON5 number forms, JSON5 whitespace, and JSON5
	string escapes.
]=]
json.JSON5 = table.freeze({
	comments = true,
	trailingComma = true,
	singleQuotedStrings = true,
	multilineStrings = true,
	unquotedKeys = true,
	json5Numbers = true,
	json5Whitespace = true,
	json5Escapes = true,
} :: DecodeOptions)

--[=[
	Preset decode options for JSONC.

	Enables comments and trailing commas while keeping the rest of the parser
	close to standard JSON.
]=]
json.JSONC = table.freeze({
	comments = true,
	trailingComma = true,
} :: DecodeOptions)

local function nextUtf8Pos(s: string, pos: number): number
	local nextPos = utf8.offset(s, 2, pos)
	return nextPos or (#s + 1)
end

local function isJson5WhitespaceCodepoint(cp: number): boolean
	if cp == 0x0009 or cp == 0x000A or cp == 0x000B or cp == 0x000C or cp == 0x000D or cp == 0x0020 then
		return true
	end

	if cp == 0x00A0 or cp == 0x2028 or cp == 0x2029 or cp == 0xFEFF then
		return true
	end

	return unicode.category(cp) == "Zs"
end

local function isJson5LineTerminatorAt(s: string, pos: number): number?
	local b1 = string.byte(s, pos)
	if b1 == nil then
		return nil
	end

	if b1 == 0x0A then
		return 1
	end

	if b1 == 0x0D then
		if string.byte(s, pos + 1) == 0x0A then
			return 2
		end
		return 1
	end

	if b1 == 0xE2 and string.byte(s, pos + 1) == 0x80 then
		local b3 = string.byte(s, pos + 2)
		if b3 == 0xA8 or b3 == 0xA9 then
			return 3
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------------

-- Lightweight recursive-descent JSON parser.  Operates on a string with an
-- integer cursor (1-based index).  Each parse_* function returns the parsed
-- value and the next cursor position.

local function skipWhitespace(s: string, pos: number, options: DecodeOptions?): number
	local comments = options and options.comments
	local json5Whitespace = options and options.json5Whitespace

	while pos <= #s do
		local b = string.byte(s, pos)
		-- normal whitespace
		if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
			pos += 1
		elseif json5Whitespace and b ~= nil and b < 0x80 and (b == 0x0B or b == 0x0C) then
			pos += 1
		elseif json5Whitespace and b ~= nil and b >= 0x80 then
			local cp = utf8.codepoint(s, pos)
			if isJson5WhitespaceCodepoint(cp) then
				pos = nextUtf8Pos(s, pos)
			else
				break
			end
		-- line comment //
		elseif comments and b == 0x2F and string.byte(s, pos + 1) == 0x2F then
			pos += 2
			while pos <= #s do
				if isJson5LineTerminatorAt(s, pos) or string.byte(s, pos) == 0x0A or string.byte(s, pos) == 0x0D then
					break
				end
				pos += 1
			end
		-- block comment /*
		elseif comments and b == 0x2F and string.byte(s, pos + 1) == 0x2A then
			pos += 2

			while pos <= #s - 1 do
				if string.byte(s, pos) == 0x2A and string.byte(s, pos + 1) == 0x2F then
					pos += 2
					break
				end
				pos += 1
			end

			if pos > #s then
				error("Unterminated block comment")
			end
		else
			break
		end
	end

	return pos
end

-- Forward declaration
local parseValue: (s: string, pos: number, options: DecodeOptions?) -> (any, number)

local function parseString(s: string, pos: number, delimiter: number, options: DecodeOptions?): (string, number)
	-- pos should point at the opening "
	assert(string.byte(s, pos) == delimiter, "Expected '\"'")
	pos += 1

	local parts: { string } = {}
	local start = pos
	local multilineStrings = options and options.multilineStrings
	local json5Escapes = options and options.json5Escapes

	while pos <= #s do
		local b = string.byte(s, pos)
		if b == delimiter then
			-- closing quote
			table.insert(parts, string.sub(s, start, pos - 1))
			return table.concat(parts), pos + 1
		elseif b == 0x5C then
			-- escape
			table.insert(parts, string.sub(s, start, pos - 1))
			pos += 1
			if pos > #s then
				error("Unterminated string")
			end
			local esc = string.byte(s, pos)
			local continuationLen = if multilineStrings then isJson5LineTerminatorAt(s, pos) else nil
			if continuationLen then
				pos += continuationLen - 1
			elseif esc == 0x22 then
				table.insert(parts, '"')
			elseif esc == 0x27 and (delimiter == 0x27 or json5Escapes) then
				table.insert(parts, "'")
			elseif esc == 0x5C then
				table.insert(parts, "\\")
			elseif esc == 0x2F then
				table.insert(parts, "/")
			elseif esc == 0x62 then
				table.insert(parts, "\b")
			elseif esc == 0x66 then
				table.insert(parts, "\f")
			elseif esc == 0x6E then
				table.insert(parts, "\n")
			elseif esc == 0x72 then
				table.insert(parts, "\r")
			elseif esc == 0x74 then
				table.insert(parts, "\t")
			elseif esc == 0x76 and json5Escapes then
				table.insert(parts, "\v")
			elseif esc == 0x30 and json5Escapes then
				local nextByte = string.byte(s, pos + 1)
				if nextByte and nextByte >= 0x30 and nextByte <= 0x39 then
					error("Invalid \\0 escape at position " .. tostring(pos))
				end
				table.insert(parts, "\0")
			elseif esc == 0x78 and json5Escapes then
				local hex = string.sub(s, pos + 1, pos + 2)
				if #hex ~= 2 then
					error("Invalid \\x escape at position " .. tostring(pos))
				end
				local code = tonumber(hex, 16)
				if code == nil then
					error("Invalid \\x escape at position " .. tostring(pos))
				end
				table.insert(parts, string.char(code))
				pos += 2
			elseif esc == 0x75 then
				-- \uXXXX
				local hex = string.sub(s, pos + 1, pos + 4)
				if #hex ~= 4 then
					error("Invalid \\u escape at position " .. tostring(pos))
				end
				local code = tonumber(hex, 16)
				if code == nil then
					error("Invalid \\u escape at position " .. tostring(pos))
				end

				-- Handle surrogate pairs (\uD800-\uDBFF followed by \uDC00-\uDFFF)
				if code >= 0xD800 and code <= 0xDBFF then
					-- High surrogate, expect low surrogate
					if string.sub(s, pos + 5, pos + 6) == "\\u" then
						local hex2 = string.sub(s, pos + 7, pos + 10)
						local low = tonumber(hex2, 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
							pos += 6 -- skip the second \uXXXX
						else
							error("Invalid surrogate pair at position " .. tostring(pos))
						end
					else
						error("Expected low surrogate at position " .. tostring(pos + 5))
					end
				end

				-- Encode code point as UTF-8
				if code <= 0x7F then
					table.insert(parts, string.char(code))
				elseif code <= 0x7FF then
					table.insert(parts, string.char(0xC0 + bit32.rshift(code, 6), 0x80 + bit32.band(code, 0x3F)))
				elseif code <= 0xFFFF then
					table.insert(
						parts,
						string.char(
							0xE0 + bit32.rshift(code, 12),
							0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
							0x80 + bit32.band(code, 0x3F)
						)
					)
				else
					table.insert(
						parts,
						string.char(
							0xF0 + bit32.rshift(code, 18),
							0x80 + bit32.band(bit32.rshift(code, 12), 0x3F),
							0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
							0x80 + bit32.band(code, 0x3F)
						)
					)
				end
				pos += 4
			elseif json5Escapes then
				if esc >= 0x30 and esc <= 0x39 then
					error("Invalid escape character at position " .. tostring(pos) .. " (" .. tostring(esc) .. ")")
				end

				local escapedEnd = nextUtf8Pos(s, pos) - 1
				table.insert(parts, string.sub(s, pos, escapedEnd))
				pos = escapedEnd
			else
				error(`Invalid escape character at position {pos} ({esc})`)
			end
			pos += 1
			start = pos
		elseif isJson5LineTerminatorAt(s, pos) then
			error("Unterminated string")
		elseif b ~= nil and b < 0x20 then
			error("Invalid control character in string at position " .. tostring(pos))
		else
			pos += 1
		end
	end
	error("Unterminated string")
end

local function isAsciiIdentifierStart(b: number): boolean
	return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x24 or b == 0x5F
end

local function isAsciiIdentifierPart(b: number): boolean
	return isAsciiIdentifierStart(b) or (b >= 0x30 and b <= 0x39)
end

local function parseIdentifierAscii(s: string, pos: number): (string, number)
	local start = pos
	local b = string.byte(s, pos)

	if not b or not isAsciiIdentifierStart(b) then
		error("Expected identifier at position " .. tostring(pos))
	end

	pos += 1

	while pos <= #s do
		local part = string.byte(s, pos)
		if not part or not isAsciiIdentifierPart(part) then
			break
		end
		pos += 1
	end

	return string.sub(s, start, pos - 1), pos
end

local function parseUnicodeEscape(s: string, pos: number): (number, number)
	if string.byte(s, pos) ~= 0x5C or string.byte(s, pos + 1) ~= 0x75 then
		error("Invalid identifier escape at position " .. tostring(pos))
	end

	local hex = string.sub(s, pos + 2, pos + 5)
	if #hex ~= 4 then
		error("Invalid identifier escape at position " .. tostring(pos))
	end

	local cp = tonumber(hex, 16)
	if cp == nil then
		error("Invalid identifier escape at position " .. tostring(pos))
	end

	return cp, pos + 6
end

local function isIdentifierStartCodepoint(cp: number): boolean
	if cp == 0x24 or cp == 0x5F then
		return true
	end

	local category = unicode.category(cp)
	return category == "Lu"
		or category == "Ll"
		or category == "Lt"
		or category == "Lm"
		or category == "Lo"
		or category == "Nl"
end

local function isIdentifierPartCodepoint(cp: number): boolean
	if isIdentifierStartCodepoint(cp) then
		return true
	end

	if cp == 0x200C or cp == 0x200D then
		return true
	end

	local category = unicode.category(cp)
	return category == "Mn" or category == "Mc" or category == "Nd" or category == "Pc"
end

local function parseIdentifierName(s: string, pos: number): (string, number)
	local parts: { string } = {}
	local start = pos
	local expectStart = true

	while pos <= #s do
		local b = string.byte(s, pos)
		local cp: number
		local nextPos: number

		if b == 0x5C then
			table.insert(parts, string.sub(s, start, pos - 1))
			cp, nextPos = parseUnicodeEscape(s, pos)
		else
			cp = utf8.codepoint(s, pos)
			nextPos = nextUtf8Pos(s, pos)
		end

		if expectStart then
			if not isIdentifierStartCodepoint(cp) then
				error("Expected identifier at position " .. tostring(pos))
			end
			expectStart = false
		elseif not isIdentifierPartCodepoint(cp) then
			if b == 0x5C then
				error("Invalid identifier escape at position " .. tostring(pos))
			end
			break
		end

		if b == 0x5C then
			table.insert(parts, utf8.char(cp))
			start = nextPos
		end

		pos = nextPos
	end

	if expectStart then
		error("Expected identifier at position " .. tostring(pos))
	end

	table.insert(parts, string.sub(s, start, pos - 1))
	return table.concat(parts), pos
end

local function parseNumber(s: string, pos: number, options: DecodeOptions?): (number, number)
	local start = pos
	local positive = true
	local json5Numbers = options and options.json5Numbers

	-- optional minus or plus
	if string.byte(s, pos) == 0x2D then
		positive = false
		pos += 1
	elseif json5Numbers and string.byte(s, pos) == 0x2B then
		pos += 1
	end

	if json5Numbers then
		if string.byte(s, pos) == 0x49 then
			if string.sub(s, pos, pos + 7) == "Infinity" then
				if positive then
					return math.huge, pos + 8
				else
					return -math.huge, pos + 8
				end
			end
		end
		if string.byte(s, pos) == 0x4E then
			if string.sub(s, pos, pos + 2) == "NaN" then
				return math.nan, pos + 3
			end
		end
	end

	if
		json5Numbers
		and string.byte(s, pos) == 0x30
		and pos + 1 <= #s
		and (string.byte(s, pos + 1) == 0x78 or string.byte(s, pos + 1) == 0x58)
	then
		local hexStart = pos + 2
		pos = hexStart

		while pos <= #s do
			local b = string.byte(s, pos)
			local isDigit = b >= 0x30 and b <= 0x39
			local isLower = b >= 0x61 and b <= 0x66
			local isUpper = b >= 0x41 and b <= 0x46

			if not (isDigit or isLower or isUpper) then
				break
			end

			pos += 1
		end

		if pos == hexStart then
			error("Invalid number at position " .. tostring(start))
		end

		local n = tonumber(string.sub(s, hexStart, pos - 1), 16)
		if n == nil then
			error("Invalid number at position " .. tostring(start))
		end

		return if positive then n else -n, pos
	end

	-- integer part
	local sawInteger = false
	if json5Numbers and string.byte(s, pos) == 0x2E then
		-- JSON5 allows decimals like `.5`.
	elseif string.byte(s, pos) == 0x30 then
		sawInteger = true
		pos += 1
	else
		if pos > #s or string.byte(s, pos) < 0x31 or string.byte(s, pos) > 0x39 then
			error("Invalid number at position " .. tostring(start))
		end
		sawInteger = true
		while pos <= #s and string.byte(s, pos) >= 0x30 and string.byte(s, pos) <= 0x39 do
			pos += 1
		end
	end

	-- fractional part
	local sawFraction = false
	if pos <= #s and string.byte(s, pos) == 0x2E then
		pos += 1
		local fracStart = pos
		while pos <= #s and string.byte(s, pos) >= 0x30 and string.byte(s, pos) <= 0x39 do
			pos += 1
		end
		sawFraction = pos > fracStart
		if not sawFraction and (not json5Numbers or not sawInteger) then
			error("Invalid number at position " .. tostring(start))
		end
	end

	-- exponent
	if pos <= #s and (string.byte(s, pos) == 0x65 or string.byte(s, pos) == 0x45) then
		pos += 1
		if pos <= #s and (string.byte(s, pos) == 0x2B or string.byte(s, pos) == 0x2D) then
			pos += 1
		end
		local expStart = pos
		while pos <= #s and string.byte(s, pos) >= 0x30 and string.byte(s, pos) <= 0x39 do
			pos += 1
		end
		if pos == expStart then
			error("Invalid number at position " .. tostring(start))
		end
	end

	local raw = string.sub(s, start, pos - 1)
	local n = tonumber(raw)
	if n == nil then
		error("Invalid number: " .. raw)
	end
	return n, pos
end

local function parseArray(s: string, pos: number, options: DecodeOptions?): ({ any }, number)
	pos += 1 -- skip [
	pos = skipWhitespace(s, pos, options)

	local arr = {}

	if pos <= #s and string.byte(s, pos) == 0x5D then
		setmetatable(arr, JSON_ARRAY_MT)
		return arr, pos + 1
	end

	while true do
		local value
		value, pos = parseValue(s, pos, options)
		table.insert(arr, value)

		pos = skipWhitespace(s, pos, options)

		local b = string.byte(s, pos)

		if b == 0x5D then
			return arr, pos + 1
		elseif b == 0x2C then
			pos += 1
			pos = skipWhitespace(s, pos, options)

			-- trailing comma support
			if options and options.trailingComma and string.byte(s, pos) == 0x5D then
				return arr, pos + 1
			end
		else
			error("Expected ',' or ']' at position " .. tostring(pos))
		end
	end
end

local function parseObject(s: string, pos: number, options: DecodeOptions?): ({ [string]: any }, number)
	pos += 1 -- skip {
	pos = skipWhitespace(s, pos, options)

	local obj: { [string]: any } = {}

	if pos <= #s and string.byte(s, pos) == 0x7D then
		return obj, pos + 1
	end

	while true do
		pos = skipWhitespace(s, pos, options)

		local ch = string.byte(s, pos)
		local key
		if ch == 0x22 or (options and options.singleQuotedStrings and ch == 0x27) then
			key, pos = parseString(s, pos, ch, options)
		elseif options and options.unquotedKeys then
			key, pos = parseIdentifierName(s, pos)
		else
			error("Expected string key at position " .. tostring(pos))
		end

		pos = skipWhitespace(s, pos, options)

		if string.byte(s, pos) ~= 0x3A then
			error("Expected ':' at position " .. tostring(pos))
		end

		pos += 1
		pos = skipWhitespace(s, pos, options)

		local value
		value, pos = parseValue(s, pos, options)
		obj[key] = value

		pos = skipWhitespace(s, pos, options)

		local b = string.byte(s, pos)

		if b == 0x7D then
			return obj, pos + 1
		elseif b == 0x2C then
			pos += 1
			pos = skipWhitespace(s, pos, options)

			-- trailing comma support
			if options and options.trailingComma and string.byte(s, pos) == 0x7D then
				return obj, pos + 1
			end
		else
			error("Expected ',' or '}' at position " .. tostring(pos))
		end
	end
end

parseValue = function(s: string, pos: number, options: DecodeOptions?): (any, number)
	pos = skipWhitespace(s, pos, options)
	if pos > #s then
		error("Unexpected end of JSON")
	end

	local b = string.byte(s, pos)

	if b == 0x22 then
		return parseString(s, pos, 0x22, options)
	elseif b == 0x27 and options and options.singleQuotedStrings then
		return parseString(s, pos, 0x27, options)
	elseif b == 0x7B then
		return parseObject(s, pos, options)
	elseif b == 0x5B then
		return parseArray(s, pos, options)
	elseif b == 0x74 then
		-- true
		if string.sub(s, pos, pos + 3) == "true" then
			return true, pos + 4
		end
		error("Invalid value at position " .. tostring(pos))
	elseif b == 0x66 then
		-- false
		if string.sub(s, pos, pos + 4) == "false" then
			return false, pos + 5
		end
		error("Invalid value at position " .. tostring(pos))
	elseif b == 0x6E then
		-- null
		if string.sub(s, pos, pos + 3) == "null" then
			return nil, pos + 4
		end
		error("Invalid value at position " .. tostring(pos))
	elseif
		b == 0x2D
		or (b >= 0x30 and b <= 0x39)
		or (options and options.json5Numbers and (b == 0x2B or b == 0x2E or b == 0x49 or b == 0x4E))
	then
		return parseNumber(s, pos, options)
	else
		error("Unexpected character '" .. string.char(b) .. "' at position " .. tostring(pos))
	end
end

--[=[
	Decodes a JSON string into a Luau value.

	| JSON          | Luau          |
	|---------------|---------------|
	| string        | `string`      |
	| number        | `number`      |
	| true / false  | `boolean`     |
	| null          | `nil`         |
	| array  []     | Numeric table    |
	| object {}     | `{ [string]: any }` |

	> **Note:** JSON `null` values inside arrays will create holes in the
	> resulting Luau table.  Standalone `null` at the top level returns `nil`.

	@param str string -- A valid JSON string.
	@return any -- The decoded Luau value.
]=]
function json.decode(str: string, options: DecodeOptions?): any
	if #str == 0 then
		error("Empty JSON string")
	end
	local value, pos = parseValue(str, 1, options)
	pos = skipWhitespace(str, pos, options)
	if pos <= #str then
		error("Trailing data after JSON value at position " .. tostring(pos))
	end
	return value
end

--[=[
	A sentinel value representing JSON `null`.

	Because Luau `nil` cannot be stored in tables, use this sentinel when
	you need to explicitly represent a `null` value inside an array or
	object during encoding.

	```luau
	local t = { 1, json.null, 3 }
	print(json.encode(t))  -- "[1,null,3]"
	```
]=]
-- json.null = newproxy(false)

--[=[
	A Luau table with 0 entries could be a json object (`{}`) or a JSON
	array (`[]`).

	Use this function on the values returned by [[decode]] if you need
	to decern the difference.
]=]
function json.tableIsArray(table: { [any]: any })
	return isArray(table)
end

--[=[
	A Luau table with 0 entries could be a json object (`{}`) or a JSON
	array (`[]`).

	Use this function on a value being passed to [[encode]] to
	explicitly mark it as an array
]=]
function json.tableAsArray(table: { [number]: any })
	-- For non-empty tables, only allow tagging if they're already valid arrays.
	-- This prevents accidental data loss such as { a = 1 } being encoded as [].
	if next(table) ~= nil and not isArray(table :: any) then
		error("json.tableAsArray expects an empty table or an existing array table")
	end
	return setmetatable(table, JSON_ARRAY_MT)
end

return json
