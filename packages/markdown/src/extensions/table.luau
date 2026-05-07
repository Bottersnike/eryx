local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")

--- Split a table row into cell strings, handling escaped pipes.
--- Strips leading/trailing pipe if present.
local function splitTableRow(line: string): { string }
	-- Strip leading pipe (optional)
	local s = 1
	local len = #line
	-- Skip leading whitespace
	while s <= len do
		local b = string.byte(line, s)
		if b == 32 or b == 9 then
			s += 1
		else
			break
		end
	end
	if s <= len and string.byte(line, s) == 124 then -- |
		s += 1
	end
	-- Strip trailing pipe (optional) — also strip trailing whitespace + \r
	local e = len
	while e >= s do
		local b = string.byte(line, e)
		if b == 32 or b == 9 or b == 13 then
			e -= 1
		else
			break
		end
	end
	if e >= s and string.byte(line, e) == 124 then -- |
		e -= 1
	end

	local cells: { string } = {}
	local cur = s
	local cellStart = s
	while cur <= e do
		local b = string.byte(line, cur)
		if b == 92 and cur + 1 <= e then -- backslash escape
			cur += 2
		elseif b == 124 then -- |
			-- Trim whitespace from cell
			local cellStr = line:sub(cellStart, cur - 1)
			cellStr = cellStr:match("^%s*(.-)%s*$") or ""
			table.insert(cells, cellStr)
			cellStart = cur + 1
			cur += 1
		else
			cur += 1
		end
	end
	-- Last cell
	local cellStr = line:sub(cellStart, e)
	cellStr = cellStr:match("^%s*(.-)%s*$") or ""
	table.insert(cells, cellStr)

	return cells
end

--- Check if a line is a valid delimiter row. Returns alignments array or nil.
local function parseDelimiterRow(line: string, cursor: tabUtil.LineCursor): { any }?
	-- Allow up to 3 spaces of indentation
	local indent = tabUtil.indentationLevel(line, cursor)
	if indent.column > 3 then
		return nil
	end
	local cells = splitTableRow(line:sub(cursor.byte + indent.byte))
	if #cells == 0 then
		return nil
	end
	local alignments: { any } = {}
	for _, cell in cells do
		local left = false
		local right = false
		local s = 1
		local e = #cell
		if e == 0 then
			return nil
		end
		if string.byte(cell, s) == 58 then -- :
			left = true
			s += 1
		end
		if e >= s and string.byte(cell, e) == 58 then -- :
			right = true
			e -= 1
		end
		-- Everything between must be hyphens (at least one)
		if e < s then
			return nil
		end
		for i = s, e do
			if string.byte(cell, i) ~= 45 then -- -
				return nil
			end
		end
		if left and right then
			alignments[#alignments + 1] = "center"
		elseif right then
			alignments[#alignments + 1] = "right"
		elseif left then
			alignments[#alignments + 1] = "left"
		else
			alignments[#alignments + 1] = false -- no alignment (false as nil placeholder)
		end
	end
	return alignments
end

type TableCell = {
	raw: string, -- raw text, parsed to inlines during finalization
	inlines: { types.InlineNode },
	align: ("left" | "center" | "right")?, -- nil = default alignment
	colspan: number?, -- nil = 1 (reserved for future span support)
	rowspan: number?, -- nil = 1 (reserved for future span support)
}
type TableRow = {
	cells: { TableCell },
}

local TableRule: types.BlockRule<
	"table",
	{
		open: boolean,
		alignments: { ("left" | "center" | "right")? }, -- per-column alignment
		head: TableRow,
		body: { TableRow },
	}
> =
	{
		name = "table",
		continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			-- Tables always match continuation; closed by blank lines (onBlankLine)
			-- or when Phase 2 starts a new block that interrupts
			return { matched = true, cursor = cursor }
		end,
		convertParagraph = function(
			para: types.ParagraphBlockNode,
			line: string,
			cursor: tabUtil.LineCursor,
			_parent: any
		): types.AnyBlockNode?
			local alignments = parseDelimiterRow(line, cursor)
			if not alignments then
				return nil
			end

			-- The paragraph's raw text is the header row.
			-- It must be a single line (no line breaks in the header).
			local raw: { string } = para.raw
			-- Strip trailing \r\n
			while #raw > 0 and raw[#raw] == "" do
				table.remove(raw, #raw)
			end
			-- Header must be a single line (no embedded newlines)
			if #raw > 1 then
				return nil
			end

			local headerCells = splitTableRow(raw[1])

			-- Header cell count must match delimiter cell count (GFM spec example 203)
			if #headerCells ~= #alignments then
				return nil
			end

			-- Build head row (inlines will be parsed during finalization)
			local headRow: TableRow = { cells = {} }
			for i, cellText in headerCells do
				(headRow.cells :: any)[#headRow.cells + 1] = {
					raw = cellText,
					inlines = {},
					align = alignments[i],
				}
			end

			local tbl = {
				type = "table",
				open = true,
				alignments = alignments,
				head = headRow,
				body = {},
			}

			-- Replace the paragraph with the table in the parent
			table.remove(_parent.children, #_parent.children)
			table.insert(_parent.children, tbl)

			return tbl
		end,
		incorporateLine = function(block, remains: string): boolean
			-- Parse data row
			local cells = splitTableRow(remains)
			local row: TableRow = { cells = {} }
			local numCols = #block.alignments

			for i = 1, numCols do
				local cellText = if i <= #cells then cells[i] else ""
				(row.cells :: any)[#row.cells + 1] = {
					raw = cellText,
					inlines = {},
					align = block.alignments[i],
				}
			end

			table.insert(block.body, row)
			return true
		end,
		onBlankLine = function(_block, _openStack: { types.AnyBlockNode }): boolean
			return true -- close table on blank line
		end,
		onClose = function(block)
			block.open = false
		end,
		toHtml = function(block, rules, config)
			local class = ""
			if config.annotateHtml then
				class = ` class="md-table"`
			end

			local chunks: { string } = {}
			table.insert(chunks, `<table{class}>`)

			-- Render thead
			table.insert(chunks, "<thead>")
			table.insert(chunks, "<tr>")
			for _, cell in block.head.cells do
				local alignAttr = ""
				if cell.align then
					alignAttr = ` align="{cell.align}"`
				end
				table.insert(chunks, `<th{alignAttr}>{html.renderInline(cell.inlines, rules, config)}</th>`)
			end
			table.insert(chunks, "</tr>")
			table.insert(chunks, "</thead>")

			-- Render tbody (only if there are body rows)
			if #block.body > 0 then
				table.insert(chunks, "<tbody>")
				for _, row in block.body do
					table.insert(chunks, "<tr>")
					for _, cell in row.cells do
						local alignAttr = ""
						if cell.align then
							alignAttr = ` align="{cell.align}"`
						end
						table.insert(chunks, `<td{alignAttr}>{html.renderInline(cell.inlines, rules, config)}</td>`)
					end
					table.insert(chunks, "</tr>")
				end
				table.insert(chunks, "</tbody>")
			end

			table.insert(chunks, "</table>")
			return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
		end,
	}

return table.freeze(TableRule) :: types.AnyBlockRule
