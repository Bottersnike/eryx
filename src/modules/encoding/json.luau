--[=[
	JSON encoding and decoding.

	Serialises Luau values to JSON text and parses JSON text back into
	Luau values.  Follows RFC 8259 with sensible Luau-specific defaults.

	```luau
	local json = require("@eryx/encoding/json")

	local str = json.encode({ name = "Alice", scores = {100, 97} })
	print(str)  -- '{"name":"Alice","scores":[100,97]}'

	local tbl = json.decode('{"x":1,"y":2}')
	print(tbl.x, tbl.y)  -- 1  2
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

-- ---------------------------------------------------------------------------
-- Encode helpers
-- ---------------------------------------------------------------------------

--- Characters that must be escaped inside a JSON string (RFC 8259 §7).
local ESCAPE_MAP: { [number]: string } = {
	[0x22] = '\\"',   -- "
	[0x5C] = "\\\\",  -- \
	[0x08] = "\\b",   -- backspace
	[0x0C] = "\\f",   -- form feed
	[0x0A] = "\\n",   -- newline
	[0x0D] = "\\r",   -- carriage return
	[0x09] = "\\t",   -- tab
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
		-- empty table: treat as array only if there are no string keys
		return next(t) == nil
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

-- ---------------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------------

-- Lightweight recursive-descent JSON parser.  Operates on a string with an
-- integer cursor (1-based index).  Each parse_* function returns the parsed
-- value and the next cursor position.

local function skipWhitespace(s: string, pos: number): number
	while pos <= #s do
		local b = string.byte(s, pos)
		if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
			pos += 1
		else
			break
		end
	end
	return pos
end

-- Forward declaration
local parseValue: (s: string, pos: number) -> (any, number)

local function parseString(s: string, pos: number): (string, number)
	-- pos should point at the opening "
	assert(string.byte(s, pos) == 0x22, "Expected '\"'")
	pos += 1

	local parts: { string } = {}
	local start = pos

	while pos <= #s do
		local b = string.byte(s, pos)
		if b == 0x22 then
			-- closing quote
			table.insert(parts, string.sub(s, start, pos - 1))
			return table.concat(parts), pos + 1
		elseif b == 0x5C then
			-- escape
			table.insert(parts, string.sub(s, start, pos - 1))
			pos += 1
			local esc = string.byte(s, pos)
			if esc == 0x22 then
				table.insert(parts, '"')
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
					table.insert(parts, string.char(
						0xC0 + bit32.rshift(code, 6),
						0x80 + bit32.band(code, 0x3F)
					))
				elseif code <= 0xFFFF then
					table.insert(parts, string.char(
						0xE0 + bit32.rshift(code, 12),
						0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
						0x80 + bit32.band(code, 0x3F)
					))
				else
					table.insert(parts, string.char(
						0xF0 + bit32.rshift(code, 18),
						0x80 + bit32.band(bit32.rshift(code, 12), 0x3F),
						0x80 + bit32.band(bit32.rshift(code, 6), 0x3F),
						0x80 + bit32.band(code, 0x3F)
					))
				end
				pos += 4
			else
				error("Invalid escape character at position " .. tostring(pos))
			end
			pos += 1
			start = pos
		else
			pos += 1
		end
	end
	error("Unterminated string")
end

local function parseNumber(s: string, pos: number): (number, number)
	local start = pos
	-- optional minus
	if string.byte(s, pos) == 0x2D then
		pos += 1
	end
	-- integer part
	if string.byte(s, pos) == 0x30 then
		pos += 1
	else
		if pos > #s or string.byte(s, pos) < 0x31 or string.byte(s, pos) > 0x39 then
			error("Invalid number at position " .. tostring(start))
		end
		while pos <= #s and string.byte(s, pos) >= 0x30 and string.byte(s, pos) <= 0x39 do
			pos += 1
		end
	end
	-- fractional part
	if pos <= #s and string.byte(s, pos) == 0x2E then
		pos += 1
		local fracStart = pos
		while pos <= #s and string.byte(s, pos) >= 0x30 and string.byte(s, pos) <= 0x39 do
			pos += 1
		end
		if pos == fracStart then
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

local function parseArray(s: string, pos: number): ({ any }, number)
	pos += 1 -- skip [
	pos = skipWhitespace(s, pos)

	local arr = {}
	if pos <= #s and string.byte(s, pos) == 0x5D then
		return arr, pos + 1
	end

	while true do
		pos = skipWhitespace(s, pos)
		local value
		value, pos = parseValue(s, pos)
		table.insert(arr, value)

		pos = skipWhitespace(s, pos)
		local b = string.byte(s, pos)
		if b == 0x5D then
			return arr, pos + 1
		elseif b == 0x2C then
			pos += 1
		else
			error("Expected ',' or ']' at position " .. tostring(pos))
		end
	end
end

local function parseObject(s: string, pos: number): ({ [string]: any }, number)
	pos += 1 -- skip {
	pos = skipWhitespace(s, pos)

	local obj: { [string]: any } = {}
	if pos <= #s and string.byte(s, pos) == 0x7D then
		return obj, pos + 1
	end

	while true do
		pos = skipWhitespace(s, pos)
		if string.byte(s, pos) ~= 0x22 then
			error("Expected string key at position " .. tostring(pos))
		end
		local key
		key, pos = parseString(s, pos)

		pos = skipWhitespace(s, pos)
		if string.byte(s, pos) ~= 0x3A then
			error("Expected ':' at position " .. tostring(pos))
		end
		pos += 1

		pos = skipWhitespace(s, pos)
		local value
		value, pos = parseValue(s, pos)
		obj[key] = value

		pos = skipWhitespace(s, pos)
		local b = string.byte(s, pos)
		if b == 0x7D then
			return obj, pos + 1
		elseif b == 0x2C then
			pos += 1
		else
			error("Expected ',' or '}' at position " .. tostring(pos))
		end
	end
end

parseValue = function(s: string, pos: number): (any, number)
	pos = skipWhitespace(s, pos)
	if pos > #s then
		error("Unexpected end of JSON")
	end

	local b = string.byte(s, pos)

	if b == 0x22 then
		return parseString(s, pos)
	elseif b == 0x7B then
		return parseObject(s, pos)
	elseif b == 0x5B then
		return parseArray(s, pos)
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
	elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then
		return parseNumber(s, pos)
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
function json.decode(str: string): any
	if #str == 0 then
		error("Empty JSON string")
	end
	local value, pos = parseValue(str, 1)
	pos = skipWhitespace(str, pos)
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
json.null = newproxy(false)

return json
