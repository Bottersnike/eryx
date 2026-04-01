local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")
local util = require("../util")

--- Resolve all entity/character references and backslash escapes in a string.
local function resolveEntities(s: string): string
	local len = #s
	local buf = {}
	local pos = 1
	local textStart = 1
	while pos <= len do
		local b = string.byte(s, pos)
		if b == 38 then -- &
			local resolved, newPos = util.tryParseEntityRef(s, pos, len)
			if resolved then
				if pos > textStart then
					table.insert(buf, s:sub(textStart, pos - 1))
				end
				table.insert(buf, resolved)
				pos = newPos
				textStart = pos
			else
				pos += 1
			end
		elseif b == 92 and pos + 1 <= len and util.isAsciiPunctuationChar(string.byte(s, pos + 1)) then -- backslash escape
			if pos > textStart then
				table.insert(buf, s:sub(textStart, pos - 1))
			end
			table.insert(buf, s:sub(pos + 1, pos + 1))
			pos += 2
			textStart = pos
		else
			pos += 1
		end
	end
	if textStart == 1 then
		return s
	end
	if textStart <= len then
		table.insert(buf, s:sub(textStart))
	end
	return table.concat(buf)
end

local CodeFenceRule: types.BlockRule<
	"code_fence",
	{
		fenceDelimiter: string, -- eg "```", "~~~~~", etc
		indentationColumns: number, -- Columns, 0 to 3
		infoString: string?,
		open: boolean,
		lines: { string },
	}
> =
	{
		name = "code_fence",
		continueBlock = function(fence, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			-- Check for a closing fence
			local ok, delta = tabUtil.matchWithLeadingIndentation(line, cursor, fence.fenceDelimiter, 3)
			if ok then
				local i = cursor.byte + delta.byte - #fence.fenceDelimiter
				local count = 0
				local fenceChar = fence.fenceDelimiter:sub(1, 1)
				while i <= #line and line:sub(i, i) == fenceChar do
					count += 1
					i += 1
				end
				if count >= #fence.fenceDelimiter then
					local valid = true
					while i <= #line do
						if not (line:sub(i, i) == " " or line:sub(i, i) == "\t") then
							valid = false
							break
						end
						i += 1
					end
					if valid then
						fence.open = false
						return {
							matched = true,
							cursor = { byte = cursor.byte + count, column = cursor.column + count },
							closed = true,
							consumedLine = true,
						}
					end
				end
			end

			-- This line is part of the code block — consume the fence's indentation
			local delta_ = tabUtil.advanceAtMostNWhitespace(line, cursor, fence.indentationColumns)
			return {
				matched = true,
				cursor = {
					byte = cursor.byte + delta_.byte,
					column = cursor.column + delta_.column,
				},
			}
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

			if
				line:sub(indented.byte, indented.byte + 2) ~= "```"
				and line:sub(indented.byte, indented.byte + 2) ~= "~~~"
			then
				return nil
			end

			local fenceDelimiter = line:sub(indented.byte, indented.byte)
			local nDelim = 3
			for i = indented.byte + 3, #line do
				if line:sub(i, i) == fenceDelimiter then
					nDelim += 1
				else
					break
				end
			end
			-- Backtick fences cannot have backticks in the info string (tilde fences can)
			if fenceDelimiter == "`" then
				for i = indented.byte + nDelim, #line do
					if line:sub(i, i) == "`" then
						return nil
					end
				end
			end

			return {
				blocks = {
					{
						type = "code_fence",
						fenceDelimiter = string.rep(fenceDelimiter, nDelim),
						indentationColumns = indent.column,
						infoString = resolveEntities(line:sub(indented.byte + nDelim):match("^%s*(.-)%s*$") :: string),
						lines = {},
						open = true,
					},
				},
				cursor = { byte = #line + 1, column = -1 },
				breakAfterOpen = false,
			}
		end,
		incorporateLine = function(fence, remains: string): boolean
			table.insert(fence.lines, remains)
			return true
		end,
		onBlankLine = function(fence, _openStack: { types.AnyBlockNode }): boolean
			table.insert(fence.lines, "")
			return false
		end,

		toHtml = function(block, rules, config: types.MarkdownConfig): string
			local content: string
			if config.useCrlf then
				content = table.concat(block.lines, "\r\n")
			else
				content = table.concat(block.lines, "\n")
			end
			-- Each content line in a fenced block carries its line ending.
			-- Preserve that even when the final content line is blank.
			if #block.lines > 0 then
				content ..= if config.useCrlf then "\r\n" else "\n"
			end

			local classStr = ""
			if block.infoString and #block.infoString > 0 then
				-- Use first word of info string as language (per CommonMark spec)
				local lang = block.infoString:match("^(%S+)")
				if lang then
					classStr = ` class="language-{html.renderLiteral(lang)}"`
				end

				if config.codeLanguages then
					local formatter = config.codeLanguages[lang]
					if formatter then
						content = formatter(content)
					else
						content = html.renderLiteral(content)
					end
				else
					content = html.renderLiteral(content)
				end
			else
				content = html.renderLiteral(content)
			end
			local annotation = ""
			if config.annotateHtml then
				annotation = ` class="md-code_block"`
			end

			return `<pre{annotation}><code{classStr}>{content}</code></pre>`
		end,
	}

return table.freeze(CodeFenceRule) :: types.AnyBlockRule
