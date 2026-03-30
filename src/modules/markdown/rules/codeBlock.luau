local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")
local util = require("../util")

-- Indented code block: continues with 4+ indent, starts with 4+ indent
local CodeBlockRule: types.BlockRule<"code_block", { lines: { string } }> = {
	name = "code_block",
	continueBlock = function(_block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		if tabUtil.indentationLevel(line, cursor).column >= 4 then
			local delta = tabUtil.advanceAtMostNWhitespace(line, cursor, 4)
			return {
				matched = true,
				cursor = {
					byte = cursor.byte + delta.byte,
					column = cursor.column + delta.column,
				},
			}
		end
		-- Blank/whitespace-only lines continue
		if util.isLineBlank(line, cursor) then
			return { matched = true, cursor = { byte = #line + 1, column = cursor.column } }
		end
		return { matched = false, cursor = cursor }
	end,
	tryStart = function(
		line: string,
		cursor: tabUtil.LineCursor,
		tip: types.AnyBlockNode,
		_openStack: { types.AnyBlockNode }
	): types.StartResult?
		local indent = tabUtil.indentationLevel(line, cursor)
		-- Can't interrupt a paragraph
		if indent.column < 4 or tip.type == "paragraph" then
			return nil
		end
		local delta = tabUtil.advanceAtMostNWhitespace(line, cursor, 4)
		return {
			blocks = { { type = "code_block", lines = {} } },
			cursor = {
				byte = cursor.byte + delta.byte,
				column = cursor.column + delta.column,
			},
			breakAfterOpen = true,
		}
	end,
	incorporateLine = function(block, remains: string): boolean
		table.insert(block.lines, remains)
		return true
	end,
	onBlankLine = function(block, _openStack: { types.AnyBlockNode }): boolean
		table.insert(block.lines, "")
		return false
	end,
	onClose = function(block)
		-- Strip trailing blank lines from indented code blocks
		while #block.lines > 1 and block.lines[#block.lines] == "" and block.lines[#block.lines - 1] == "" do
			table.remove(block.lines, #block.lines)
		end
	end,

	toHtml = function(block, rules, config): string
		local content: string
		if config.useCrlf then
			content = table.concat(block.lines, "\r\n")
		else
			content = table.concat(block.lines, "\n")
		end
		if block.lines[#block.lines] and #block.lines[#block.lines] ~= 0 then
			content ..= if config.useCrlf then "\r\n" else "\n"
		end

		local class = ""
		if config.annotateHtml then
			class = ` class="md-code_block"`
		end

		return `<pre{class}><code>{html.renderLiteral(content)}</code></pre>`
	end,
}

return table.freeze(CodeBlockRule) :: types.AnyBlockRule
