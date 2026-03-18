--[=[
	YAML encoding and decoding.

	Serialises Luau values to YAML text and parses YAML text back into
	Luau values.  Supports a practical subset of YAML 1.2 (block scalars,
	block/flow sequences and mappings, anchors & aliases, multi-line strings).

	```luau
	local yaml = require("@eryx/encoding/yaml")

	local str = yaml.encode({ name = "Alice", scores = {100, 97} })
	print(str)
	-- name: Alice
	-- scores:
	--   - 100
	--   - 97

	local tbl = yaml.decode("x: 1\ny: 2")
	print(tbl.x, tbl.y)  -- 1  2
	```

	**Mapping rules:**

	| Luau          | YAML             |
	|---------------|------------------|
	| `string`      | scalar           |
	| `number`      | scalar (numeric) |
	| `boolean`     | true / false     |
	| `nil`         | null / ~         |
	| Numeric table | sequence (- ...) |
	| Mixed table   | mapping (k: v)   |
]=]

local yaml = {}

-- ---------------------------------------------------------------------------
-- Encode
-- ---------------------------------------------------------------------------

--- Returns true when the table looks like a YAML sequence (contiguous 1..n keys).
local function isSequence(t: { [any]: any }): boolean
	local n = #t
	if n == 0 then
		return next(t) == nil
	end
	local count = 0
	for _ in t do
		count += 1
		if count > n then
			return false
		end
	end
	return count == n
end

--- Characters that force a YAML string to be quoted.
local NEEDS_QUOTE_PATTERN = '[:%#{%}%[%],&*?|%-><!%%@`"\'\n\r\t]'

--- YAML keywords that must be quoted when used as scalars.
local YAML_KEYWORDS: { [string]: boolean } = {
	["true"] = true, ["false"] = true,
	["True"] = true, ["False"] = true,
	["TRUE"] = true, ["FALSE"] = true,
	["yes"] = true, ["no"] = true,
	["Yes"] = true, ["No"] = true,
	["YES"] = true, ["NO"] = true,
	["on"] = true, ["off"] = true,
	["On"] = true, ["Off"] = true,
	["ON"] = true, ["OFF"] = true,
	["null"] = true, ["Null"] = true, ["NULL"] = true,
	["~"] = true,
	[".inf"] = true, [".Inf"] = true, [".INF"] = true,
	["-.inf"] = true, ["-.Inf"] = true, ["-.INF"] = true,
	[".nan"] = true, [".NaN"] = true, [".NAN"] = true,
}

local function yamlEscapeString(s: string): string
	-- Use double-quoted style with standard escape sequences
	local escaped = s
		:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
		:gsub("\t", "\\t")
		:gsub("\b", "\\b")
		:gsub("\0", "\\0")
	return '"' .. escaped .. '"'
end

local function needsQuoting(s: string): boolean
	if #s == 0 then
		return true
	end
	if YAML_KEYWORDS[s] then
		return true
	end
	-- Starts/ends with whitespace
	if string.byte(s, 1) == 0x20 or string.byte(s, #s) == 0x20 then
		return true
	end
	-- Could be parsed as a number
	if tonumber(s) ~= nil then
		return true
	end
	-- Contains special characters
	if string.find(s, NEEDS_QUOTE_PATTERN) then
		return true
	end
	return false
end

local function encodeScalar(v: any): string
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif t == "number" then
		if v ~= v then
			return ".nan"
		elseif v == math.huge then
			return ".inf"
		elseif v == -math.huge then
			return "-.inf"
		elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		else
			return string.format("%.17g", v)
		end
	elseif t == "string" then
		if needsQuoting(v) then
			return yamlEscapeString(v)
		end
		return v
	else
		error("Cannot encode type '" .. t .. "' as YAML")
	end
end

export type EncodeOptions = {
	-- Indentation string (default `"  "` - two spaces).
	indent: string?,
	-- Sort mapping keys alphabetically.
	sortKeys: boolean?,
	-- Use flow (inline) style for nested structures.
	flowLevel: number?,
}

local function encodeValue(v: any, opts: EncodeOptions, depth: number, buf: { string }, inline: boolean)
	local indentStr = opts.indent or "  "
	local sortKeys = opts.sortKeys or false
	local flowLevel = opts.flowLevel or math.huge

	local t = type(v)

	if t ~= "table" then
		table.insert(buf, encodeScalar(v))
		return
	end

	local asFlow = depth >= flowLevel

	-- Sequence
	if isSequence(v) then
		if #(v :: { any }) == 0 then
			table.insert(buf, "[]")
			return
		end

		if asFlow or inline then
			-- Flow sequence: [a, b, c]
			table.insert(buf, "[")
			for i = 1, #v do
				if i > 1 then
					table.insert(buf, ", ")
				end
				encodeValue(v[i], opts, depth + 1, buf, true)
			end
			table.insert(buf, "]")
			return
		end

		-- Block sequence
		for i = 1, #v do
			if i > 1 or depth > 0 then
				table.insert(buf, "\n" .. string.rep(indentStr, depth))
			end
			table.insert(buf, "- ")
			local child = v[i]
			if type(child) == "table" then
				if isSequence(child) then
					if #child == 0 then
						table.insert(buf, "[]")
					else
						encodeValue(child, opts, depth + 1, buf, false)
					end
				else
					-- Mapping as block under sequence item
					table.insert(buf, "\n")
					encodeValue(child, opts, depth + 1, buf, false)
					-- remove trailing newline that encode_value might add
				end
			else
				encodeValue(child, opts, depth + 1, buf, false)
			end
		end
		return
	end

	-- Mapping
	local keys: { string } = {}
	for k in v :: any do
		if type(k) ~= "string" and type(k) ~= "number" then
			error("YAML mapping keys must be strings or numbers, got " .. type(k))
		end
		table.insert(keys, tostring(k))
	end

	if #keys == 0 then
		table.insert(buf, "{}")
		return
	end

	if sortKeys then
		table.sort(keys)
	end

	if asFlow or inline then
		-- Flow mapping: {a: 1, b: 2}
		table.insert(buf, "{")
		for i, k in keys do
			if i > 1 then
				table.insert(buf, ", ")
			end
			local rawKey: any = k
			-- Try to use original key type
			if (v :: any)[k] == nil and tonumber(k) ~= nil then
				rawKey = tonumber(k)
			end
			table.insert(buf, encodeScalar(k))
			table.insert(buf, ": ")
			encodeValue((v :: any)[rawKey], opts, depth + 1, buf, true)
		end
		table.insert(buf, "}")
		return
	end

	-- Block mapping
	for i, k in keys do
		local rawKey: any = k
		if (v :: any)[k] == nil and tonumber(k) ~= nil then
			rawKey = tonumber(k)
		end

		if i > 1 or depth > 0 then
			table.insert(buf, "\n" .. string.rep(indentStr, depth))
		end

		table.insert(buf, encodeScalar(k))
		table.insert(buf, ":")

		local child = (v :: any)[rawKey]
		if type(child) == "table" then
			local childIsSeq = isSequence(child)
			if childIsSeq and #(child :: { any }) == 0 then
				table.insert(buf, " []")
			elseif not childIsSeq and next(child) == nil then
				table.insert(buf, " {}")
			else
				table.insert(buf, "\n")
				encodeValue(child, opts, depth + 1, buf, false)
			end
		else
			table.insert(buf, " ")
			encodeValue(child, opts, depth + 1, buf, false)
		end
	end
end

--[=[
	Encodes a Luau value as a YAML string.

	Tables with sequential integer keys (1 .. n) are encoded as YAML sequences.
	Tables with string keys are encoded as YAML mappings. Nested structures
	are fully supported.

	```luau
	local yaml = require("@eryx/encoding/yaml")
	print(yaml.encode({ a = 1, b = { 2, 3 } }))
	-- a: 1
	-- b:
	--   - 2
	--   - 3
	```

	@param value -- The value to encode.
	@param options EncodeOptions? -- Optional formatting options.
	@return string -- The YAML string.
]=]
function yaml.encode(value: any, options: EncodeOptions?): string
	local opts: EncodeOptions = options or {} :: any
	local buf: { string } = {}
	encodeValue(value, opts, 0, buf, false)
	return table.concat(buf)
end

-- ---------------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------------

-- A small recursive-descent parser for a practical subset of YAML 1.2.
-- Supports:
--   - Block mappings and sequences
--   - Flow mappings ({}) and sequences ([])
--   - Double-quoted, single-quoted, and plain scalars
--   - Literal (|) and folded (>) block scalars
--   - Comments (#)
--   - Anchors (&name) and aliases (*name)
--   - Multi-document separators (--- / ...) – first document only
--   - Core schema type resolution (null, bool, int, float)

type Line = {
	indent: number,
	text: string,
	raw: string,
}

local function splitLines(s: string): { Line }
	local lines: { Line } = {}

	-- Normalise line endings
	s = s:gsub("\r\n", "\n"):gsub("\r", "\n")

	local pos = 1
	while pos <= #s do
		local nl = s:find("\n", pos, true)
		local raw
		if nl then
			raw = s:sub(pos, nl - 1)
			pos = nl + 1
		else
			raw = s:sub(pos)
			pos = #s + 1
		end

		-- Calculate indent
		local leading = raw:match("^( *)")
		local indent = #leading

		-- Strip trailing whitespace
		local text = raw:match("^(.-)%s*$")

		table.insert(lines, { indent = indent, text = text, raw = raw })
	end

	return lines
end

--- Strip inline comment from a value string (outside of quotes).
local function stripComment(s: string): string
	local inSingle = false
	local inDouble = false
	local i = 1
	while i <= #s do
		local c = string.byte(s, i)
		if c == 0x22 and not inSingle then  -- "
			inDouble = not inDouble
		elseif c == 0x27 and not inDouble then  -- '
			inSingle = not inSingle
		elseif c == 0x23 and not inSingle and not inDouble then  -- #
			-- Must be preceded by whitespace to be a comment
			if i == 1 or string.byte(s, i - 1) == 0x20 or string.byte(s, i - 1) == 0x09 then
				return s:sub(1, i - 1):match("^(.-)%s*$")
			end
		end
		i += 1
	end
	return s
end

--- Resolve a plain scalar string to an appropriate Luau type.
local function resolveScalar(s: string): any
	-- null
	if s == "null" or s == "Null" or s == "NULL" or s == "~" or s == "" then
		return nil
	end
	-- boolean
	if s == "true" or s == "True" or s == "TRUE"
		or s == "yes" or s == "Yes" or s == "YES"
		or s == "on" or s == "On" or s == "ON" then
		return true
	end
	if s == "false" or s == "False" or s == "FALSE"
		or s == "no" or s == "No" or s == "NO"
		or s == "off" or s == "Off" or s == "OFF" then
		return false
	end
	-- special float
	if s == ".inf" or s == ".Inf" or s == ".INF" then
		return math.huge
	end
	if s == "-.inf" or s == "-.Inf" or s == "-.INF" then
		return -math.huge
	end
	if s == ".nan" or s == ".NaN" or s == ".NAN" then
		return 0 / 0
	end
	-- number (int or float)
	local n = tonumber(s)
	if n ~= nil then
		return n
	end
	-- Hex integer
	if s:match("^0x[%da-fA-F]+$") then
		return tonumber(s)
	end
	-- Octal integer
	if s:match("^0o[0-7]+$") then
		return tonumber(s:sub(3), 8)
	end
	return s
end

--- Parse a double-quoted scalar, handling escape sequences.
local function parseDoubleQuoted(s: string): string
	-- s is the content between the quotes (no surrounding quotes).
	local parts: { string } = {}
	local i = 1
	while i <= #s do
		local c = string.byte(s, i)
		if c == 0x5C then  -- backslash
			i += 1
			local esc = string.byte(s, i)
			if esc == 0x6E then      table.insert(parts, "\n")      -- \n
			elseif esc == 0x74 then  table.insert(parts, "\t")      -- \t
			elseif esc == 0x72 then  table.insert(parts, "\r")      -- \r
			elseif esc == 0x5C then  table.insert(parts, "\\")      -- \\
			elseif esc == 0x22 then  table.insert(parts, '"')       -- \"
			elseif esc == 0x2F then  table.insert(parts, "/")       -- \/
			elseif esc == 0x62 then  table.insert(parts, "\b")      -- \b
			elseif esc == 0x30 then  table.insert(parts, "\0")      -- \0
			elseif esc == 0x78 then
				-- \xHH
				local hex = s:sub(i + 1, i + 2)
				table.insert(parts, string.char(tonumber(hex, 16) :: number))
				i += 2
			else
				table.insert(parts, string.char(esc))
			end
		else
			table.insert(parts, string.char(c))
		end
		i += 1
	end
	return table.concat(parts)
end

--- Parse a single-quoted scalar (only '' is an escape for a literal ').
local function parseSingleQuoted(s: string): string
	return s:gsub("''", "'")
end

--- Try to extract a quoted string starting at position `pos` in `s`.
--- Returns (content, restOfString) or nil if not a quoted string.
local function tryQuoted(s: string): (string?, string?)
	local first = string.byte(s, 1)
	if first == 0x22 then  -- double quote
		-- Find matching close quote (handling escapes)
		local i = 2
		while i <= #s do
			local c = string.byte(s, i)
			if c == 0x5C then
				i += 2 -- skip escaped char
			elseif c == 0x22 then
				local content = s:sub(2, i - 1)
				local rest = s:sub(i + 1):match("^%s*(.*)")
				return parseDoubleQuoted(content), rest
			else
				i += 1
			end
		end
		error("Unterminated double-quoted string")
	elseif first == 0x27 then  -- single quote
		local closePos = s:find("'", 2, true)
		-- Handle escaped single quotes ('')
		while closePos and closePos < #s and string.byte(s, closePos + 1) == 0x27 do
			closePos = s:find("'", closePos + 2, true)
		end
		if not closePos then
			error("Unterminated single-quoted string")
		end
		local content = s:sub(2, closePos - 1)
		local rest = s:sub(closePos + 1):match("^%s*(.*)")
		return parseSingleQuoted(content), rest
	end
	return nil, nil
end

type ParseState = {
	lines: { Line },
	pos: number,   -- current line index (1-based)
	anchors: { [string]: any },
}

-- Forward declarations
local parseNode: (state: ParseState, minIndent: number) -> any
local parseFlow: (s: string, pos: number) -> (any, number)

--- Skip blank lines and comment-only lines from state.pos onwards.
local function skipBlanks(state: ParseState)
	while state.pos <= #state.lines do
		local text = state.lines[state.pos].text
		if text == "" or text:match("^#") then
			state.pos += 1
		else
			break
		end
	end
end

--- Collect a block scalar (literal | or folded >).
local function parseBlockScalar(state: ParseState, indicator: string, header: string): string
	-- Parse header for chomping indicator and explicit indent
	local chomp = "clip" -- default
	local explicitIndent: number? = nil

	for i = 1, #header do
		local c = string.sub(header, i, i)
		if c == "-" then
			chomp = "strip"
		elseif c == "+" then
			chomp = "keep"
		elseif tonumber(c) then
			explicitIndent = tonumber(c) :: number
		end
	end

	-- Collect content lines
	local contentLines: { string } = {}
	local blockIndent: number? = explicitIndent

	while state.pos <= #state.lines do
		local line = state.lines[state.pos]

		-- Empty lines are always included (they might be part of the scalar)
		if line.text == "" then
			table.insert(contentLines, "")
			state.pos += 1
			continue
		end

		-- Determine block indent from first non-empty line
		if blockIndent == nil then
			blockIndent = line.indent
		end

		-- If the line has less indent than block, we're done
		if line.indent < (blockIndent :: number) then
			break
		end

		-- Strip the block indent
		table.insert(contentLines, line.raw:sub((blockIndent :: number) + 1))
		state.pos += 1
	end

	-- Remove trailing empty lines for chomp processing
	local trailing = 0
	while #contentLines > 0 and contentLines[#contentLines] == "" do
		table.remove(contentLines)
		trailing += 1
	end

	local result: string
	if indicator == "|" then
		-- Literal: preserve newlines
		result = table.concat(contentLines, "\n")
	else
		-- Folded: replace single newlines with spaces, preserve double newlines
		local parts: { string } = {}
		local i = 1
		while i <= #contentLines do
			local line = contentLines[i]
			if line == "" then
				table.insert(parts, "\n\n")
				i += 1
				-- Skip consecutive empty lines
				while i <= #contentLines and contentLines[i] == "" do
					table.insert(parts, "\n")
					i += 1
				end
			else
				if #parts > 0 then
					local last = parts[#parts]
					if last ~= "\n\n" and not last:match("\n$") then
						-- Replace newline between content lines with space
						table.insert(parts, " ")
					end
				end
				table.insert(parts, line)
				i += 1
			end
		end
		result = table.concat(parts)
	end

	-- Apply chomping
	if chomp == "clip" then
		result = result .. "\n"
	elseif chomp == "keep" then
		result = result .. string.rep("\n", trailing + 1)
	end
	-- "strip" = no trailing newline, result as-is

	return result
end

--- Parse a flow sequence: [a, b, c]
--- Returns (value, nextPos) where nextPos is the position after closing ].
local function parseFlowSequence(s: string, pos: number): ({ any }, number)
	pos += 1 -- skip [
	local arr: { any } = {}

	-- skip whitespace
	while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
		pos += 1
	end

	if pos <= #s and string.byte(s, pos) == 0x5D then -- ]
		return arr, pos + 1
	end

	while pos <= #s do
		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		local value
		value, pos = parseFlow(s, pos)
		table.insert(arr, value)

		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		local b = string.byte(s, pos)
		if b == 0x5D then -- ]
			return arr, pos + 1
		elseif b == 0x2C then -- ,
			pos += 1
		else
			error("Expected ',' or ']' in flow sequence")
		end
	end
	error("Unterminated flow sequence")
end

--- Parse a flow mapping: {a: 1, b: 2}
local function parseFlowMapping(s: string, pos: number): ({ [string]: any }, number)
	pos += 1 -- skip {
	local obj: { [string]: any } = {}

	-- skip whitespace
	while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
		pos += 1
	end

	if pos <= #s and string.byte(s, pos) == 0x7D then -- }
		return obj, pos + 1
	end

	while pos <= #s do
		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		-- Parse key
		local key: any
		key, pos = parseFlow(s, pos)

		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		-- Expect colon
		if string.byte(s, pos) ~= 0x3A then
			error("Expected ':' in flow mapping")
		end
		pos += 1

		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		-- Parse value
		local value
		value, pos = parseFlow(s, pos)
		obj[tostring(key)] = value

		-- skip whitespace
		while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
			pos += 1
		end

		local b = string.byte(s, pos)
		if b == 0x7D then -- }
			return obj, pos + 1
		elseif b == 0x2C then -- ,
			pos += 1
		else
			error("Expected ',' or '}' in flow mapping")
		end
	end
	error("Unterminated flow mapping")
end

--- Parse a single flow value (scalar, flow sequence, or flow mapping).
parseFlow = function(s: string, pos: number): (any, number)
	-- skip whitespace
	while pos <= #s and (string.byte(s, pos) == 0x20 or string.byte(s, pos) == 0x09) do
		pos += 1
	end

	local b = string.byte(s, pos)
	if b == 0x5B then  -- [
		return parseFlowSequence(s, pos)
	elseif b == 0x7B then  -- {
		return parseFlowMapping(s, pos)
	elseif b == 0x22 then  -- double quote
		local i = pos + 1
		while i <= #s do
			local c = string.byte(s, i)
			if c == 0x5C then
				i += 2
			elseif c == 0x22 then
				local content = s:sub(pos + 1, i - 1)
				return parseDoubleQuoted(content), i + 1
			else
				i += 1
			end
		end
		error("Unterminated double-quoted string in flow")
	elseif b == 0x27 then  -- single quote
		local closePos = s:find("'", pos + 1, true)
		while closePos and closePos < #s and string.byte(s, closePos + 1) == 0x27 do
			closePos = s:find("'", closePos + 2, true)
		end
		if not closePos then
			error("Unterminated single-quoted string in flow")
		end
		local content = s:sub(pos + 1, closePos - 1)
		return parseSingleQuoted(content), closePos + 1
	else
		-- Plain scalar: read until , ] } : or end of string
		local start = pos
		while pos <= #s do
			local c = string.byte(s, pos)
			if c == 0x2C or c == 0x5D or c == 0x7D then  -- , ] }
				break
			end
			-- Colon followed by space or end is a mapping indicator
			if c == 0x3A and (pos + 1 > #s or string.byte(s, pos + 1) == 0x20) then
				break
			end
			pos += 1
		end
		local raw = s:sub(start, pos - 1):match("^(.-)%s*$")
		return resolveScalar(raw :: string), pos
	end
end

--- Parse a block sequence starting at the given indent.
local function parseBlockSequence(state: ParseState, seqIndent: number): { any }
	local arr: { any } = {}

	while state.pos <= #state.lines do
		skipBlanks(state)
		if state.pos > #state.lines then
			break
		end

		local line = state.lines[state.pos]
		if line.indent < seqIndent then
			break
		end
		if line.indent ~= seqIndent then
			break
		end

		-- Must start with "- "
		local trimmed = line.text:sub(line.indent + 1)
		if not trimmed:match("^- ") and trimmed ~= "-" then
			break
		end

		state.pos += 1

		-- Value after "- "
		local after = trimmed:sub(3):match("^%s*(.*)") or ""
		after = stripComment(after)

		if after == "" then
			-- Value is on subsequent indented lines
			skipBlanks(state)
			if state.pos <= #state.lines then
				local nextLine = state.lines[state.pos]
				if nextLine.indent > seqIndent then
					local value = parseNode(state, nextLine.indent)
					table.insert(arr, value)
				else
					-- Null entry
					table.insert(arr, resolveScalar(""))
				end
			else
				table.insert(arr, resolveScalar(""))
			end
		elseif after:sub(1, 1) == "[" or after:sub(1, 1) == "{" then
			-- Flow sequence or mapping
			local value = parseFlow(after, 1)
			table.insert(arr, value)
		elseif after:sub(1, 2) == "- " or after == "-" then
			-- Nested sequence on same line (compact notation)
			-- Re-process: insert a synthetic line at higher indent
			-- Actually, push back and parse as sub-sequence
			-- We need to handle: - - value
			-- Create virtual lines for the remaining content
			local virtualIndent = seqIndent + 2
			local oldPos = state.pos
			local oldLines = state.lines

			-- Insert the remaining content as a virtual line
			local virtualLine: Line = {
				indent = virtualIndent,
				text = string.rep(" ", virtualIndent) .. after,
				raw = string.rep(" ", virtualIndent) .. after,
			}

			-- Temporarily insert
			table.insert(state.lines, state.pos, virtualLine)
			local value = parseNode(state, virtualIndent)
			-- Remove virtual line if still present
			if state.pos == oldPos + 1 and #state.lines > #oldLines then
				-- already consumed
			end
			table.insert(arr, value)
		else
			-- Inline scalar or start of mapping
			-- Check if it's "key: value"
			local qVal, _ = tryQuoted(after)
			if qVal ~= nil then
				table.insert(arr, qVal)
			else
				-- Check for inline mapping (key: value)
				local colonPos = after:find(": ")
				if colonPos and not after:match("^['\"]") then
					-- This is a mapping starting on the dash line
					-- Parse as a mapping with this as first entry
					local mapping: { [string]: any } = {}
					local key = after:sub(1, colonPos - 1):match("^(.-)%s*$")
					local val = after:sub(colonPos + 2):match("^%s*(.*)")
					val = stripComment(val)

					if val == "" then
						-- Value on next lines
						skipBlanks(state)
						if state.pos <= #state.lines and state.lines[state.pos].indent > seqIndent then
							mapping[key] = parseNode(state, state.lines[state.pos].indent)
						else
							mapping[key] = resolveScalar("")
						end
					elseif val:sub(1, 1) == "[" or val:sub(1, 1) == "{" then
						mapping[key] = (parseFlow(val, 1))
					else
						local qv, _ = tryQuoted(val)
						if qv ~= nil then
							mapping[key] = qv
						else
							mapping[key] = resolveScalar(val)
						end
					end

					-- Continue reading more mapping entries at seqIndent + 2
					local mapIndent = seqIndent + 2
					while state.pos <= #state.lines do
						skipBlanks(state)
						if state.pos > #state.lines then break end
						local nextLine = state.lines[state.pos]
						if nextLine.indent < mapIndent then break end
						if nextLine.indent ~= mapIndent then break end

						local mapText = nextLine.text:sub(nextLine.indent + 1)
						local mKey, mRest
						-- Check for quoted key
						local mQKey, mQRest = tryQuoted(mapText)
						if mQKey then
							mKey = mQKey
							-- mQRest should start with ":"
							mRest = mQRest and mQRest:match("^:%s*(.*)") or ""
						else
							local cp = mapText:find(": ")
							if cp then
								mKey = mapText:sub(1, cp - 1):match("^(.-)%s*$")
								mRest = mapText:sub(cp + 2):match("^%s*(.*)")
							elseif mapText:sub(-1) == ":" then
								mKey = mapText:sub(1, -2):match("^(.-)%s*$")
								mRest = ""
							else
								break
							end
						end

						state.pos += 1
						mRest = stripComment(mRest or "")

						if mRest == "" then
							skipBlanks(state)
							if state.pos <= #state.lines and state.lines[state.pos].indent > mapIndent then
								mapping[mKey] = parseNode(state, state.lines[state.pos].indent)
							else
								mapping[mKey] = resolveScalar("")
							end
						elseif mRest:sub(1, 1) == "[" or mRest:sub(1, 1) == "{" then
							mapping[mKey] = (parseFlow(mRest, 1))
						elseif mRest:sub(1, 1) == "|" or mRest:sub(1, 1) == ">" then
							local header = mRest:sub(2):match("^(.-)%s*$") or ""
							mapping[mKey] = parseBlockScalar(state, mRest:sub(1, 1), header)
						else
							local qv2, _ = tryQuoted(mRest)
							if qv2 ~= nil then
								mapping[mKey] = qv2
							else
								mapping[mKey] = resolveScalar(mRest)
							end
						end
					end

					table.insert(arr, mapping)
				elseif after:sub(1, 1) == "|" or after:sub(1, 1) == ">" then
					local header = after:sub(2):match("^(.-)%s*$") or ""
					table.insert(arr, parseBlockScalar(state, after:sub(1, 1), header))
				else
					table.insert(arr, resolveScalar(after))
				end
			end
		end
	end

	return arr
end

--- Parse a block mapping starting at the given indent.
local function parseBlockMapping(state: ParseState, mapIndent: number): { [string]: any }
	local obj: { [string]: any } = {}

	while state.pos <= #state.lines do
		skipBlanks(state)
		if state.pos > #state.lines then break end

		local line = state.lines[state.pos]
		if line.indent < mapIndent then break end
		if line.indent ~= mapIndent then break end

		local text = line.text:sub(line.indent + 1)

		-- Skip document markers
		if text == "---" or text == "..." then
			state.pos += 1
			continue
		end

		-- Parse key
		local key: string
		local rest: string

		-- Check for quoted key
		local qKey, qRest = tryQuoted(text)
		if qKey ~= nil then
			key = qKey
			-- qRest should start with ":"
			rest = (qRest :: string):match("^:%s*(.*)") or ""
			if rest == "" and not (qRest :: string):match("^:") then
				-- Not a mapping, treat as scalar
				break
			end
		else
			-- Plain key: find ": " or trailing ":"
			local colonSpace = text:find(": ")
			if colonSpace then
				key = text:sub(1, colonSpace - 1):match("^(.-)%s*$")
				rest = text:sub(colonSpace + 2):match("^%s*(.*)")
			elseif text:sub(-1) == ":" then
				key = text:sub(1, -2):match("^(.-)%s*$")
				rest = ""
			else
				-- Not a mapping line
				break
			end
		end

		state.pos += 1
		rest = stripComment(rest)

		-- Handle anchor on value
		local anchor: string? = nil
		if rest:match("^&(%S+)") then
			anchor = rest:match("^&(%S+)")
			rest = rest:gsub("^&%S+%s*", "")
		end

		-- Handle alias
		if rest:match("^%*(%S+)$") then
			local aliasName = rest:match("^%*(%S+)$")
			local aliasVal = state.anchors[aliasName]
			if aliasVal == nil then
				error("Unknown alias: *" .. aliasName)
			end
			obj[key] = aliasVal
			if anchor then
				state.anchors[anchor] = aliasVal
			end
			continue
		end

		local value: any
		if rest == "" then
			-- Value is on subsequent indented lines
			skipBlanks(state)
			if state.pos <= #state.lines and state.lines[state.pos].indent > mapIndent then
				value = parseNode(state, state.lines[state.pos].indent)
			else
				value = resolveScalar("")
			end
		elseif rest:sub(1, 1) == "|" or rest:sub(1, 1) == ">" then
			-- Block scalar
			local header = rest:sub(2):match("^(.-)%s*$") or ""
			value = parseBlockScalar(state, rest:sub(1, 1), header)
		elseif rest:sub(1, 1) == "[" or rest:sub(1, 1) == "{" then
			-- Flow value
			value = parseFlow(rest, 1)
		else
			-- Inline scalar
			local qVal, _ = tryQuoted(rest)
			if qVal ~= nil then
				value = qVal
			else
				value = resolveScalar(rest)
			end
		end

		if anchor then
			state.anchors[anchor] = value
		end
		obj[key] = value
	end

	return obj
end

--- Main node parser: determines if the current position starts a sequence,
--- mapping, or scalar, and dispatches accordingly.
parseNode = function(state: ParseState, minIndent: number): any
	skipBlanks(state)
	if state.pos > #state.lines then
		return nil
	end

	local line = state.lines[state.pos]
	if line.indent < minIndent then
		return nil
	end

	local text = line.text:sub(line.indent + 1)

	-- Flow sequence or mapping
	if text:sub(1, 1) == "[" or text:sub(1, 1) == "{" then
		state.pos += 1
		return (parseFlow(text, 1))
	end

	-- Block sequence?
	if text:match("^- ") or text == "-" then
		return parseBlockSequence(state, line.indent)
	end

	-- Block mapping?
	-- Check if the line looks like "key: ..." or "key:" or "\"key\": ..."
	local isMapping = false
	if text:sub(1, 1) == '"' or text:sub(1, 1) == "'" then
		local _, qr = tryQuoted(text)
		if qr and (qr :: string):match("^:") then
			isMapping = true
		end
	else
		if text:find(": ") or (text:sub(-1) == ":" and #text > 1) then
			isMapping = true
		end
	end

	if isMapping then
		return parseBlockMapping(state, line.indent)
	end

	-- Scalar
	state.pos += 1

	-- Handle anchor on standalone scalar
	if text:match("^&(%S+)%s+(.+)$") then
		local a, val = text:match("^&(%S+)%s+(.+)$")
		local qVal, _ = tryQuoted(val)
		local resolved = if qVal ~= nil then qVal else resolveScalar(stripComment(val))
		state.anchors[a] = resolved
		return resolved
	end

	-- Handle alias
	if text:match("^%*(%S+)$") then
		local aliasName = text:match("^%*(%S+)$")
		local aliasVal = state.anchors[aliasName]
		if aliasVal == nil then
			error("Unknown alias: *" .. aliasName)
		end
		return aliasVal
	end

	local qVal, _ = tryQuoted(text)
	if qVal ~= nil then
		return qVal
	end

	return resolveScalar(stripComment(text))
end

--[=[
	Decodes a YAML string into a Luau value.

	Supports block and flow scalars/sequences/mappings, multi-line strings
	(literal `|` and folded `>`), anchors/aliases, and YAML 1.2 core schema
	type resolution.

	Only the first document is parsed when `---` separators are present.

	```luau
	local yaml = require("@eryx/encoding/yaml")
	local config = yaml.decode([[
	name: My App
	version: 1.2
	features:
	  - auth
	  - logging
	]])
	print(config.name)  -- "My App"
	```

	@param str string -- A valid YAML string.
	@return any -- The decoded Luau value.
]=]
function yaml.decode(str: string): any
	if #str == 0 then
		return nil
	end

	local lines = splitLines(str)
	local state: ParseState = {
		lines = lines,
		pos = 1,
		anchors = {},
	}

	-- Skip leading blank lines and document start marker
	skipBlanks(state)
	if state.pos <= #state.lines then
		local text = state.lines[state.pos].text
		if text:match("^%%") then
			-- Skip YAML directives (%YAML, %TAG)
			while state.pos <= #state.lines and state.lines[state.pos].text:match("^%%") do
				state.pos += 1
			end
			skipBlanks(state)
		end
		if state.pos <= #state.lines and state.lines[state.pos].text:sub(state.lines[state.pos].indent + 1) == "---" then
			state.pos += 1
			skipBlanks(state)
		end
	end

	if state.pos > #state.lines then
		return nil
	end

	return parseNode(state, 0)
end

return yaml
