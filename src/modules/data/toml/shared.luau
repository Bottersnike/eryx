local regex = require("@eryx/regex")

local shared = {}

shared.regex = regex
shared.TOML_ARRAY_MT = {}
shared.TOML_AOT_MT = {}

shared.BARE_KEY_RE = regex.new("^[A-Za-z0-9_-]+")
shared.BARE_KEY_FULL_RE = regex.new("^[A-Za-z0-9_-]+$")
shared.DEC_INT_RE = regex.new("^[+-]?(?:0|[1-9](?:_?[0-9])*)$")
shared.HEX_INT_RE = regex.new("^0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*$")
shared.OCT_INT_RE = regex.new("^0o[0-7](?:_?[0-7])*$")
shared.BIN_INT_RE = regex.new("^0b[01](?:_?[01])*$")
shared.FLOAT_RE = regex.new(
	"^[+-]?(?:(?:(?:0|[1-9](?:_?[0-9])*)\\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?)|(?:(?:0|[1-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)))$"
)
shared.OFFSET_DT_RE = regex.new(
	"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\\.[0-9]+)?)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$"
)
shared.LOCAL_DT_RE = regex.new("^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\\.[0-9]+)?)?$")
shared.LOCAL_DATE_RE = regex.new("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
shared.LOCAL_TIME_RE = regex.new("^[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\\.[0-9]+)?)?$")
shared.OFFSET_DT_MINUTE_RE = regex.new("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$")
shared.LOCAL_DT_MINUTE_RE = regex.new("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$")
shared.LOCAL_TIME_MINUTE_RE = regex.new("^[0-9]{2}:[0-9]{2}$")

local function isDigit(byte: number): boolean
	return byte >= 0x30 and byte <= 0x39
end

local function isHexDigit(byte: number): boolean
	return isDigit(byte) or (byte >= 0x41 and byte <= 0x46) or (byte >= 0x61 and byte <= 0x66)
end

local function isDigitOrUnderscore(byte: number): boolean
	return isDigit(byte) or byte == 0x5F
end

local function isUnsignedDecimalIntegerRange(token: string, startIndex: number, endIndex: number): boolean
	if startIndex > endIndex then
		return false
	end

	local first = string.byte(token, startIndex)
	if not isDigit(first) then
		return false
	end
	if first == 0x30 then
		return startIndex == endIndex
	end

	local prevUnderscore = false
	for i = startIndex + 1, endIndex do
		local byte = string.byte(token, i)
		if isDigit(byte) then
			prevUnderscore = false
		elseif byte == 0x5F then
			if prevUnderscore or i == endIndex then
				return false
			end
			prevUnderscore = true
		else
			return false
		end
	end
	return not prevUnderscore
end

local function isDigitSequenceRange(token: string, startIndex: number, endIndex: number): boolean
	if startIndex > endIndex then
		return false
	end

	local prevUnderscore = false
	local sawDigit = false
	for i = startIndex, endIndex do
		local byte = string.byte(token, i)
		if isDigit(byte) then
			sawDigit = true
			prevUnderscore = false
		elseif byte == 0x5F then
			if prevUnderscore or not sawDigit or i == endIndex then
				return false
			end
			prevUnderscore = true
		else
			return false
		end
	end
	return sawDigit and not prevUnderscore
end

local function isAllDigitsWithOptionalUnderscores(token: string, startIndex: number): boolean
	local prevUnderscore = false
	local sawDigit = false
	for i = startIndex, #token do
		local byte = string.byte(token, i)
		if isDigit(byte) then
			sawDigit = true
			prevUnderscore = false
		elseif byte == 0x5F then
			if prevUnderscore or not sawDigit or i == #token then
				return false
			end
			prevUnderscore = true
		else
			return false
		end
	end
	return sawDigit and not prevUnderscore
end

local function isAllBaseDigitsWithOptionalUnderscores(
	token: string,
	startIndex: number,
	predicate: (number) -> boolean
): boolean
	local prevUnderscore = false
	local sawDigit = false
	for i = startIndex, #token do
		local byte = string.byte(token, i)
		if predicate(byte) then
			sawDigit = true
			prevUnderscore = false
		elseif byte == 0x5F then
			if prevUnderscore or not sawDigit or i == #token then
				return false
			end
			prevUnderscore = true
		else
			return false
		end
	end
	return sawDigit and not prevUnderscore
end

function shared.isSpaceByte(byte: number): boolean
	return byte == 0x20 or byte == 0x09 or byte == 0x0D or byte == 0x0A
end

function shared.isInlineSpaceByte(byte: number): boolean
	return byte == 0x20 or byte == 0x09
end

function shared.sortKeys(keys: { string })
	table.sort(keys)
end

function shared.tableIsArray(value: { [any]: any }): boolean
	local mt = getmetatable(value)
	if mt == shared.TOML_ARRAY_MT or mt == shared.TOML_AOT_MT then
		return true
	end

	local n = #value
	if n == 0 then
		return false
	end

	local count = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return false
		end
		count += 1
		if count > n then
			return false
		end
	end
	return count == n
end

function shared.isArrayOfTables(value: any): boolean
	if type(value) ~= "table" then
		return false
	end

	local mt = getmetatable(value)
	if mt == shared.TOML_AOT_MT then
		return true
	end

	if not shared.tableIsArray(value) then
		return false
	end

	if #value == 0 then
		return false
	end

	for i = 1, #value do
		if type((value :: any)[i]) ~= "table" then
			return false
		end
	end
	return true
end

function shared.parseIntegerToken(token: string, kind: string?): number
	local function stripUnderscores(value: string): string
		if string.find(value, "_", 1, true) == nil then
			return value
		end
		return string.gsub(value, "_", "")
	end

	if kind == "hex" or (kind == nil and shared.HEX_INT_RE:isMatch(token)) then
		local cleaned = stripUnderscores(string.sub(token, 3))
		return tonumber(cleaned, 16) :: number
	elseif kind == "oct" or (kind == nil and shared.OCT_INT_RE:isMatch(token)) then
		local cleaned = stripUnderscores(string.sub(token, 3))
		return tonumber(cleaned, 8) :: number
	elseif kind == "bin" or (kind == nil and shared.BIN_INT_RE:isMatch(token)) then
		local digits = string.sub(token, 3)
		local value = 0
		for i = 1, #digits do
			local byte = string.byte(digits, i)
			if byte ~= 0x5F then
				value = value * 2 + if byte == 0x31 then 1 else 0
			end
		end
		return value
	end

	local cleaned = stripUnderscores(token)
	return tonumber(cleaned) :: number
end

function shared.classifyIntegerToken(token: string): string?
	local len = #token
	if len == 0 then
		return nil
	end

	local first = string.byte(token, 1)
	local startIndex = 1
	local hasSign = false
	if first == 0x2B or first == 0x2D then
		if len == 1 then
			return nil
		end
		hasSign = true
		startIndex = 2
		first = string.byte(token, 2)
	end

	if first == 0x30 and startIndex < len then
		local prefix = string.byte(token, startIndex + 1)
		if prefix == 0x78 then
			if hasSign then
				return nil
			end
			return if isAllBaseDigitsWithOptionalUnderscores(token, startIndex + 2, isHexDigit) then "hex" else nil
		elseif prefix == 0x6F then
			if hasSign then
				return nil
			end
			return if isAllBaseDigitsWithOptionalUnderscores(token, startIndex + 2, function(byte)
					return byte >= 0x30 and byte <= 0x37
				end)
				then "oct"
				else nil
		elseif prefix == 0x62 then
			if hasSign then
				return nil
			end
			return if isAllBaseDigitsWithOptionalUnderscores(token, startIndex + 2, function(byte)
					return byte == 0x30 or byte == 0x31
				end)
				then "bin"
				else nil
		end
	end

	if first == 0x30 and startIndex ~= len then
		return nil
	end

	return if isAllDigitsWithOptionalUnderscores(token, startIndex) then "dec" else nil
end

function shared.isLocalDateToken(token: string): boolean
	return #token == 10
		and isDigit(string.byte(token, 1))
		and isDigit(string.byte(token, 2))
		and isDigit(string.byte(token, 3))
		and isDigit(string.byte(token, 4))
		and string.byte(token, 5) == 0x2D
		and isDigit(string.byte(token, 6))
		and isDigit(string.byte(token, 7))
		and string.byte(token, 8) == 0x2D
		and isDigit(string.byte(token, 9))
		and isDigit(string.byte(token, 10))
end

function shared.isLocalTimeToken(token: string): boolean
	local len = #token
	if len ~= 5 and len < 8 then
		return false
	end
	if
		not isDigit(string.byte(token, 1))
		or not isDigit(string.byte(token, 2))
		or string.byte(token, 3) ~= 0x3A
		or not isDigit(string.byte(token, 4))
		or not isDigit(string.byte(token, 5))
	then
		return false
	end
	if len == 5 then
		return true
	end
	if string.byte(token, 6) ~= 0x3A or not isDigit(string.byte(token, 7)) or not isDigit(string.byte(token, 8)) then
		return false
	end
	if len == 8 then
		return true
	end
	if string.byte(token, 9) ~= 0x2E then
		return false
	end
	for i = 10, len do
		if not isDigit(string.byte(token, i)) then
			return false
		end
	end
	return len >= 10
end

function shared.classifyDateTimeToken(token: string): string?
	local len = #token
	if len < 5 then
		return nil
	end

	if shared.isLocalDateToken(token) then
		return "date"
	end
	if shared.isLocalTimeToken(token) then
		return "time"
	end
	if len < 16 or not shared.isLocalDateToken(string.sub(token, 1, 10)) then
		return nil
	end

	local sep = string.byte(token, 11)
	if sep ~= 0x54 and sep ~= 0x74 and sep ~= 0x20 then
		return nil
	end

	local rest = string.sub(token, 12)
	if #rest < 5 then
		return nil
	end

	if
		not isDigit(string.byte(rest, 1))
		or not isDigit(string.byte(rest, 2))
		or string.byte(rest, 3) ~= 0x3A
		or not isDigit(string.byte(rest, 4))
		or not isDigit(string.byte(rest, 5))
	then
		return nil
	end

	local idx = 6
	if idx <= #rest and string.byte(rest, idx) == 0x3A then
		if idx + 2 > #rest then
			return nil
		end
		if not isDigit(string.byte(rest, idx + 1)) or not isDigit(string.byte(rest, idx + 2)) then
			return nil
		end
		idx += 3
		if idx <= #rest and string.byte(rest, idx) == 0x2E then
			idx += 1
			local fracStart = idx
			while idx <= #rest and isDigit(string.byte(rest, idx)) do
				idx += 1
			end
			if idx == fracStart then
				return nil
			end
		end
	end

	if idx > #rest then
		return "local-datetime"
	end

	local tz = string.byte(rest, idx)
	if tz == 0x5A or tz == 0x7A then
		return if idx == #rest then "offset-datetime" else nil
	end
	if tz ~= 0x2B and tz ~= 0x2D then
		return nil
	end
	if idx + 5 ~= #rest then
		return nil
	end
	return if isDigit(string.byte(rest, idx + 1))
			and isDigit(string.byte(rest, idx + 2))
			and string.byte(rest, idx + 3) == 0x3A
			and isDigit(string.byte(rest, idx + 4))
			and isDigit(string.byte(rest, idx + 5))
		then "offset-datetime"
		else nil
end

function shared.encodeString(value: string): string
	local out = table.create(#value)
	local index = 1

	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte == 0x22 then
			out[index] = '\\"'
		elseif byte == 0x5C then
			out[index] = "\\\\"
		elseif byte == 0x08 then
			out[index] = "\\b"
		elseif byte == 0x09 then
			out[index] = "\\t"
		elseif byte == 0x0A then
			out[index] = "\\n"
		elseif byte == 0x0C then
			out[index] = "\\f"
		elseif byte == 0x0D then
			out[index] = "\\r"
		elseif byte < 0x20 or byte == 0x7F then
			out[index] = string.format("\\u%04X", byte)
		else
			out[index] = string.sub(value, i, i)
		end
		index += 1
	end

	return '"' .. table.concat(out) .. '"'
end

function shared.encodeKeyPart(key: string): string
	if shared.BARE_KEY_FULL_RE:isMatch(key) then
		return key
	end
	return shared.encodeString(key)
end

function shared.joinDottedPath(path: { string }): string
	local out = table.create(#path)
	for i, part in path do
		out[i] = shared.encodeKeyPart(part)
	end
	return table.concat(out, ".")
end

return shared
