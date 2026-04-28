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
	if kind == "hex" or (kind == nil and shared.HEX_INT_RE:isMatch(token)) then
		local cleaned = string.gsub(string.sub(token, 3), "_", "")
		return tonumber(cleaned, 16) :: number
	elseif kind == "oct" or (kind == nil and shared.OCT_INT_RE:isMatch(token)) then
		local cleaned = string.gsub(string.sub(token, 3), "_", "")
		return tonumber(cleaned, 8) :: number
	elseif kind == "bin" or (kind == nil and shared.BIN_INT_RE:isMatch(token)) then
		local digits = string.gsub(string.sub(token, 3), "_", "")
		local value = 0
		for i = 1, #digits do
			value = value * 2 + if string.sub(digits, i, i) == "1" then 1 else 0
		end
		return value
	end

	local cleaned = string.gsub(token, "_", "")
	return tonumber(cleaned) :: number
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
