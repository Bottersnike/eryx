local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")

-- Admonition: fenced container block (:::+ label[title])
local AdmonitionRule: types.BlockRule<
	"admonition",
	{
		label: string, -- e.g. "warning", "note", "tip"
		titleRaw: string?, -- raw title text from [...]
		titleInlines: { types.InlineNode }?, -- parsed inline content of title
		fenceLength: number, -- number of ':' characters (>= 3)
		children: { types.AnyBlockNode },
	}
> =
	{
		name = "admonition",
		continueBlock = function(block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			-- Check for closing fence: same number of ':'s, optional trailing whitespace
			local indent = tabUtil.indentationLevel(line, cursor)
			if indent.column <= 3 then
				local indented: tabUtil.LineCursor = {
					byte = cursor.byte + indent.byte,
					column = cursor.column + indent.column,
				}
				-- Count colons
				local colonCount = 0
				local i = indented.byte
				while i <= #line and line:sub(i, i) == ":" do
					colonCount += 1
					i += 1
				end
				if colonCount == block.fenceLength then
					-- Check only whitespace remains after the colons
					local valid = true
					while i <= #line do
						local ch = line:sub(i, i)
						if ch ~= " " and ch ~= "\t" and ch ~= "\r" then
							valid = false
							break
						end
						i += 1
					end
					if valid then
						return {
							matched = true,
							cursor = cursor,
							closed = true,
							consumedLine = true,
						}
					end
				end
			end

			-- Otherwise, continue (content lines parsed as blocks by the main loop)
			return { matched = true, cursor = cursor }
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
				byte = cursor.byte + indent.byte,
				column = cursor.column + indent.column,
			}

			-- Must start with at least 3 colons
			if line:sub(indented.byte, indented.byte + 2) ~= ":::" then
				return nil
			end

			-- Count total colons
			local fenceLength = 0
			local i = indented.byte
			while i <= #line and line:sub(i, i) == ":" do
				fenceLength += 1
				i += 1
			end

			-- Skip optional whitespace after colons
			while i <= #line and (line:sub(i, i) == " " or line:sub(i, i) == "\t") do
				i += 1
			end

			-- Parse label (required — word characters)
			local labelStart = i
			while i <= #line do
				local b = string.byte(line, i)
				-- Allow alphanumeric, hyphen, underscore
				if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 45 or b == 95 then
					i += 1
				else
					break
				end
			end
			if i == labelStart then
				return nil -- no label
			end
			local label = line:sub(labelStart, i - 1):lower()

			-- Parse optional title in [...]
			local titleRaw: string? = nil
			if i <= #line and line:sub(i, i) == "[" then
				-- Find matching ], handling escapes
				local depth = 1
				local j = i + 1
				while j <= #line and depth > 0 do
					local b = string.byte(line, j)
					if b == 92 and j + 1 <= #line then -- backslash escape
						j += 2
					elseif b == 91 then -- [
						depth += 1
						j += 1
					elseif b == 93 then -- ]
						depth -= 1
						if depth == 0 then
							titleRaw = line:sub(i + 1, j - 1)
						end
						j += 1
					else
						j += 1
					end
				end
				if titleRaw then
					i = j
				else
					return nil -- unclosed title bracket
				end
			end

			-- Rest of line must be whitespace only
			while i <= #line do
				local ch = line:sub(i, i)
				if ch ~= " " and ch ~= "\t" and ch ~= "\r" then
					return nil
				end
				i += 1
			end

			local adm = {
				type = "admonition",
				label = label,
				titleRaw = titleRaw,
				titleInlines = nil,
				fenceLength = fenceLength,
				children = {},
			}

			return {
				blocks = { adm },
				cursor = { byte = #line + 1, column = indented.column + fenceLength },
				breakAfterOpen = false, -- container: allow children
			}
		end,

		toHtml = function(block, rules, config)
			local chunks: { string } = {}
			table.insert(chunks, `<div class="md-admonition" data-label="{html.renderLiteral(block.label)}">`)

			-- Render title if present
			if block.titleInlines and #block.titleInlines > 0 then
				table.insert(
					chunks,
					`<p class="md-admonition-title">{html.renderInline(block.titleInlines, rules, config)}</p>`
				)
			elseif block.label then
				-- Default title: capitalize the label
				local defaultTitle = block.label:sub(1, 1):upper() .. block.label:sub(2)
				table.insert(chunks, `<p class="md-admonition-title">{html.renderLiteral(defaultTitle)}</p>`)
			end

			-- Render children
			for _, child in block.children :: { types.AnyBlockNode } do
				table.insert(chunks, html.renderBlock(child, rules, config))
			end

			table.insert(chunks, "</div>")
			return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
		end,
	}

return table.freeze(AdmonitionRule) :: types.AnyBlockRule
