local hex = require("@eryx/encoding/hex")
local pprint = {}

local function isLegalName(name: string): boolean
	if #name == 0 then
		return false
	end

	if
		name == "and"
		or name == "break"
		or name == "do"
		or name == "else"
		or name == "elseif"
		or name == "end"
		or name == "false"
		or name == "for"
		or name == "function"
		or name == "goto"
		or name == "if"
		or name == "in"
		or name == "local"
		or name == "nil"
		or name == "not"
		or name == "or"
		or name == "repeat"
		or name == "return"
		or name == "then"
		or name == "true"
		or name == "until"
		or name == "while"
	then
		return false
	end

	-- Valid characters
	return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local formatTable: (val: { [any]: any }, depth: number) -> string

local function formatValue(val: any, depth: number): string
	local t = type(val)

	if t == "nil" then
		return "nil"
	end
	if t == "boolean" then
		return `{val}`
	end
	if t == "number" then
		return `{val}`
	end
	if t == "vector" then
		-- TODO: Can we do something nicer?
		return `{val}`
	end
	if t == "string" then
		return `"{val}"`
	end
	if t == "table" then
		return formatTable(val :: { [any]: any }, depth)
	end
	if t == "function" or t == "userdata" or t == "thread" then
		-- TODO: We should be able to do nicer here
		return `{val}`
	end
	if t == "buffer" then
		-- TODO: This
		if buffer.len(val) <= 16 then
			return `buffer({buffer.len(val)}, "{hex.encode(val)}")`
		else
			return `buffer({buffer.len(val)}, "{hex.encode(buffer.readstring(val, 0, 16))}...")`
		end
	end

	error(`Unknown value type {t}`)
end

local function formatKey(val: any, depth: number): string
	if type(val) == "string" then
		if isLegalName(val) then
			return val
		else
			return `["{val}"]`
		end
	end
	return `[{formatValue(val, depth)}]`
end

formatTable = function(val: { [any]: any }, depth: number): string
	local str = "{\n"

	-- Print array part
	for i = 1, #val do
		str ..= string.rep(" ", (depth + 2) :: number)
		str ..= formatValue(val[i], depth + 2)
		str ..= ",\n"
	end

	-- Print hash part
	for k, v in val do
		if type(k) == "number" and k <= #val then
			continue
		end

		str ..= string.rep(" ", (depth + 2) :: number)
		str ..= formatKey(k, depth + 2)
		str ..= " = "
		str ..= formatValue(v, depth + 2)
		str ..= ",\n"
	end

	-- TODO: This
	str ..= string.rep(" ", depth :: number) .. "}"
	return str
end

function pprint.format(val: any, depth: number?): string
	if type(val) == "table" then
		return formatTable(val :: { [any]: any }, depth or 0)
	end
	return formatValue(val, depth or 0)
end
function pprint.pprint(val: any): ()
	print(pprint.format(val))
end

return pprint
