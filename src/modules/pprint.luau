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

local formatTable: (val: { [any]: any }, depth: number, seen: { [any]: boolean }) -> string

local function formatValue(val: any, depth: number, seen: { [any]: boolean }): string
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
	if t == "integer" then
		return `{val}i`
	end
	if t == "vector" then
		-- TODO: Can we do something nicer?
		return `{val}`
	end
	if t == "string" then
		return `"{val}"`
	end
	if t == "table" then
		local tableVal = val :: { [any]: any }
		if seen[tableVal] then
			return "{...}"
		end
		return formatTable(tableVal, depth, seen)
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

local function formatKey(val: any, depth: number, seen: { [any]: boolean }): string
	if type(val) == "string" then
		if isLegalName(val) then
			return val
		else
			return `["{val}"]`
		end
	end
	return `[{formatValue(val, depth, seen)}]`
end

formatTable = function(val: { [any]: any }, depth: number, seen: { [any]: boolean }): string
	seen[val] = true
	local newline = false
	local str = "{"

	-- Print array part
	for i = 1, #val do
		if not newline then
			str ..= "\n"
			newline = true
		end

		str ..= string.rep(" ", (depth + 2) :: number)
		str ..= formatValue(val[i], depth + 2, seen)
		str ..= ",\n"
	end

	-- Print hash part
	for k, v in val do
		local kt = type(k)
		if (kt == "number" or kt == "integer") and k <= #val then
			continue
		end

		if not newline then
			str ..= "\n"
			newline = true
		end

		str ..= string.rep(" ", (depth + 2) :: number)
		str ..= formatKey(k, depth + 2, seen)
		str ..= " = "
		str ..= formatValue(v, depth + 2, seen)
		str ..= ",\n"
	end

	-- TODO: This
	if newline then
		str ..= string.rep(" ", depth :: number)
	end
	str ..= "}"
	seen[val] = nil
	return str
end

function pprint.format(val: any, depth: number?): string
	local seen: { [any]: boolean } = {}
	if type(val) == "table" then
		return formatTable(val :: { [any]: any }, depth or 0, seen)
	end
	return formatValue(val, depth or 0, seen)
end
function pprint.pprint(val: any): ()
	print(pprint.format(val))
end

return table.freeze(pprint)
