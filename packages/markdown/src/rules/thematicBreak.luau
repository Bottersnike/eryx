local tabUtil = require("../tabUtil")
local types = require("../types")

-- Thematic break: single-line leaf, never continues
local ThematicBreakRule: types.BlockRule<"thematic_break", {}> = {
	name = "thematic_break",
	continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		return { matched = false, cursor = cursor }
	end,
	tryStart = function(
		line: string,
		cursor: tabUtil.LineCursor,
		_tip: types.AnyBlockNode,
		_openStack: { types.AnyBlockNode }
	): types.StartResult?
		local indent = tabUtil.indentationLevel(line, cursor)
		if indent.column > 3 then
			return nil
		end
		local indented: tabUtil.LineCursor = {
			byte = indent.byte + cursor.byte,
			column = indent.column + cursor.column,
		}

		local counts = { 0, 0, 0, 0 } -- other, "-", "_", "*"
		for i = indented.byte, #line do
			local chr = line:sub(i, i)
			if chr == "-" then
				counts[2] += 1
			elseif chr == "_" then
				counts[3] += 1
			elseif chr == "*" then
				counts[4] += 1
			elseif chr == " " or chr == "\t" then
				continue
			else
				counts[1] += 1
				break
			end
		end
		if counts[1] == 0 then
			if
				(counts[2] >= 3 and counts[3] == 0 and counts[4] == 0)
				or (counts[3] >= 3 and counts[2] == 0 and counts[4] == 0)
				or (counts[4] >= 3 and counts[2] == 0 and counts[3] == 0)
			then
				return {
					blocks = { { type = "thematic_break" } },
					cursor = { byte = #line + 1, column = -1 },
					breakAfterOpen = true,
				}
			end
		end
		return nil
	end,
	toHtml = function(block, rules, config): string
		local annotation = ""
		if config.annotateHtml then
			annotation = ` class="md-rule"`
		end
		return `<hr {annotation}/>`
	end,
}

return table.freeze(ThematicBreakRule) :: types.AnyBlockRule
