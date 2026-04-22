--- @ignore

-- Comment collection and text processing for documentation extraction.

local luau = require("@eryx/luau/ast")
local types = require("./types")
type CommentBlock = types.CommentBlock

-- Strip common leading whitespace and dash prefixes from comment text.
local function unindent(text: string): string
	local lines = string.split(string.gsub(text, "\r\n", "\n"), "\n")
	while #lines ~= 0 and #lines[1] == 0 do
		table.remove(lines, 1)
	end
	if #lines == 0 then
		return text
	end

	-- Strip leading dashes before spaces
	for i, line in lines do
		local j = 1
		while j <= #line and line:sub(j, j) == "-" do
			j += 1
		end
		if j <= #line and line:sub(j, j) == " " then
			lines[i] = line:sub(j)
		elseif j > #line then
			lines[i] = ""
		end
	end

	-- Determine common leading whitespace from first line
	local first = lines[1]
	local n = 0
	while n < #first and (first:sub(n + 1, n + 1) == " " or first:sub(n + 1, n + 1) == "\t") do
		n += 1
	end

	for i, line in lines do
		local remove = 0
		while
			remove < n
			and remove < #line
			and (line:sub(remove + 1, remove + 1) == " " or line:sub(remove + 1, remove + 1) == "\t")
		do
			remove += 1
		end
		lines[i] = line:sub(remove + 1)
	end

	return table.concat(lines, "\n")
end

-- Collect all comment blocks and inline comments from a parse result.
-- Returns (block comments for doc association, inline comments by line number).
local function collectComments(
	result: luau.ParseResult,
	sourceLines: { string }
): ({ CommentBlock }, { [number]: string })
	local blocks: { CommentBlock } = {}
	local inline: { [number]: string } = {}

	local function sourceSlice(loc: luau.Location): string
		local sl, el = loc.beginline, loc.endline
		if sl == el then
			return sourceLines[sl]:sub(loc.begincolumn, loc.endcolumn - 1)
		end
		local parts = { sourceLines[sl]:sub(loc.begincolumn) }
		for i = sl + 1, el - 1 do
			table.insert(parts, sourceLines[i])
		end
		table.insert(parts, sourceLines[el]:sub(1, loc.endcolumn - 1))
		return table.concat(parts, "\n")
	end

	if not result.comments then
		return blocks, inline
	end

	local cur: { string } = {}
	local prevEnd = -10

	for _, c in result.comments do
		local raw = sourceSlice(c.location)
		local cLine = c.location.beginline
		local cEnd = c.location.endline
		local cCol = c.location.begincolumn

		-- Inline/trailing comment: non-whitespace precedes it on the same line
		local isInline = cCol > 1
			and sourceLines[cLine] ~= nil
			and sourceLines[cLine]:sub(1, cCol - 1):match("%S") ~= nil

		if isInline then
			local text: string
			if c.type == "BlockComment" then
				text = raw:gsub("^%-%-%[=*%[", ""):gsub("%]=*%]$", "")
			else
				text = raw
			end
			inline[cLine] = unindent(text)
		else
			if cLine > prevEnd + 1 and #cur > 0 then
				table.insert(blocks, { text = unindent(table.concat(cur, "\n")), endLine = prevEnd })
				cur = {}
			end
			if c.type == "BlockComment" then
				raw = raw:gsub("^%-%-%[=*%[", ""):gsub("%]=*%]$", "")
				table.insert(cur, raw)
			else
				for line in raw:gmatch("[^\n]+") do
					table.insert(cur, line)
				end
			end
			prevEnd = cEnd
		end
	end
	if #cur > 0 then
		table.insert(blocks, { text = unindent(table.concat(cur, "\n")), endLine = prevEnd })
	end

	return blocks, inline
end

return {
	unindent = unindent,
	collectComments = collectComments,
}
