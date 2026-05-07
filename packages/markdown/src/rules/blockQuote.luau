local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")

-- Block quote: continues with ">", starts with ">"
local BlockQuoteRule: types.BlockRule<"block_quote", { children: { types.AnyBlockNode } }> = {
	name = "block_quote",
	continueBlock = function(_block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		local ok, delta = tabUtil.matchWithLeadingIndentation(line, cursor, ">", 3)
		if ok then
			local newCursor = {
				byte = cursor.byte + delta.byte,
				column = cursor.column + delta.column,
			}
			-- Consume optional space or tab after ">"
			if newCursor.byte <= #line then
				local ch = line:sub(newCursor.byte, newCursor.byte)
				if ch == " " then
					newCursor.byte += 1
					newCursor.column += 1
				elseif ch == "\t" then
					if (newCursor.column - 1) % tabUtil.TAB_STOP == tabUtil.TAB_STOP - 1 then
						newCursor.byte += 1
						newCursor.column += 1
					else
						newCursor.column += 1
					end
				end
			end
			return { matched = true, cursor = newCursor }
		end
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

		if line:sub(indented.byte, indented.byte) ~= ">" then
			return nil
		end

		indented.byte += 1
		indented.column += 1

		if line:sub(indented.byte, indented.byte) == " " then
			indented.byte += 1
			indented.column += 1
		elseif line:sub(indented.byte, indented.byte) == "\t" then
			if (indented.column - 1) % tabUtil.TAB_STOP == tabUtil.TAB_STOP - 1 then
				indented.byte += 1
				indented.column += 1
			else
				indented.column += 1
			end
		end

		return {
			blocks = { { type = "block_quote", children = {} } },
			cursor = indented,
			breakAfterOpen = false,
		}
	end,

	toHtml = function(block, rules, config): string
		local class = ""
		if config.annotateHtml then
			class = ` class="md-quote"`
		end
		local le = if config.useCrlf then "\r\n" else "\n"

		if #block.children == 0 then
			return `<blockquote{class}>{le}</blockquote>`
		end
		local chunks: { string } = {}
		for _, i in block.children do
			table.insert(chunks, html.renderBlock(i, rules, config))
		end

		return `<blockquote{class}>{le}{table.concat(chunks, le)}{le}</blockquote>`
	end,
}

return table.freeze(BlockQuoteRule) :: types.AnyBlockRule
