local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")

type FootnoteDefinitionBlock = types.BlockNode<
	"footnote_definition",
	{
		label: string, -- e.g. "1", "note", "abc"
		indentationColumns: number, -- columns to content after [^label]:
		children: { types.AnyBlockNode },
	}
>

local FootnoteDefinitionRule: types.BlockRule<"footnote_definition", FootnoteDefinitionBlock> = {
	name = "footnote_definition",
	tryStart = function(
		line: string,
		cursor: tabUtil.LineCursor,
		_tip: types.AnyBlockNode,
		_openStack: { types.AnyBlockNode }
	): types.StartResult?
		local pos = cursor.byte
		local col = cursor.column

		-- Up to 3 spaces of indentation
		local indent = tabUtil.indentationLevel(line, cursor)
		if indent.column > 3 then
			return nil
		end
		pos += indent.byte
		col += indent.column

		-- Must start with [^
		if pos + 1 > #line then
			return nil
		end
		if string.byte(line, pos) ~= 91 or string.byte(line, pos + 1) ~= 94 then -- [^
			return nil
		end
		pos += 2
		col += 2

		-- Parse label: one or more non-] non-[ characters
		local labelStart = pos
		while pos <= #line do
			local b = string.byte(line, pos)
			if b == 93 then -- ]
				break
			elseif b == 91 or b == 10 or b == 13 then -- [ or newline
				return nil
			end
			pos += 1
			col += 1
		end
		if pos > #line or pos == labelStart then
			return nil
		end
		local label = line:sub(labelStart, pos - 1)
		pos += 1 -- skip ]
		col += 1

		-- Must be followed by :
		if pos > #line or string.byte(line, pos) ~= 58 then -- :
			return nil
		end
		pos += 1
		col += 1

		-- Optional single space after colon
		if pos <= #line and string.byte(line, pos) == 32 then
			pos += 1
			col += 1
		end

		-- The indentation for continuation is the column we're at now
		local fnDef = {
			type = "footnote_definition",
			label = label,
			indentationColumns = col - cursor.column,
			children = {},
		}

		return {
			blocks = { fnDef },
			cursor = { byte = pos, column = col },
			breakAfterOpen = false, -- container, so content continues on same line
		}
	end,
	continueBlock = function(block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		-- Check for required indentation (like list items)
		local indent = tabUtil.indentationLevel(line, cursor)
		if indent.column >= block.indentationColumns then
			return {
				matched = true,
				cursor = {
					byte = tabUtil.advanceAtMostNWhitespace(line, cursor, block.indentationColumns).byte,
					column = block.indentationColumns,
				},
			}
		end
		-- Lazy continuation: if the line is not blank and we're in a paragraph, allow it
		-- (Similar to list item lazy continuation)
		return { matched = false, cursor = cursor }
	end,
	onBlankLine = function(_block, _openStack: { types.AnyBlockNode }): boolean
		return false -- don't close on blank line (like list items)
	end,

	toHtml = function(block, rules, config)
		return ""
	end,

	postProcessDocument = function(doc)
		local footnoteDefs: { [string]: FootnoteDefinitionBlock } = {}
		local footnoteOrder: { string } = {} -- preserve definition order
		local footnoteIndexByLabel: { [string]: number } = {}

		local function extractFootnoteDefs(node: types.AnyBlockNode)
			local children: { types.AnyBlockNode }? = (node :: any).children
			if not children then
				return
			end
			local i = 1
			while i <= #children do
				local child = children[i]
				if child.type == "footnote_definition" then
					local fn = child :: FootnoteDefinitionBlock
					if not footnoteDefs[fn.label] then
						footnoteDefs[fn.label] = fn
						table.insert(footnoteOrder, fn.label)
					end
					table.remove(children, i)
					continue
				end
				extractFootnoteDefs(child)
				i += 1
			end
		end

		extractFootnoteDefs(doc)

		for i, label in footnoteOrder do
			footnoteIndexByLabel[label] = i
		end

		doc.metadata.footnoteDefs = footnoteDefs
		doc.metadata.footnoteOrder = footnoteOrder
		doc.metadata.footnoteIndexByLabel = footnoteIndexByLabel

		local orphans = {}
		for _, i in footnoteDefs do
			for _, j in i.children do
				table.insert(orphans, j)
			end
		end
		return orphans
	end,
	toHtmlAppend = function(doc, rules, config)
		local class = ""
		if config.annotateHtml then
			class = ` class="md-footnotes"`
		end
		local classFn = ""
		if config.annotateHtml then
			classFn = ` class="md-footnote"`
		end

		local footnoteDefs = doc.metadata.footnoteDefs
		local footnoteOrder = doc.metadata.footnoteOrder
		if not footnoteDefs or not footnoteOrder or #footnoteOrder == 0 then
			return ""
		end

		local chunks: { string } = {}
		table.insert(chunks, `<section{class}>`)
		table.insert(chunks, `<ol{if config.annotateHtml then ' class="md-list md-ordered_list"' else ""}>`)
		for _, label in footnoteOrder do
			local fn = footnoteDefs[label]
			if fn then
				table.insert(chunks, `<li{classFn} id="fn:{html.renderLiteral(label)}">`)
				-- Render children, injecting backref into last paragraph
				local childChunks: { string } = {}
				for ci, child in fn.children do
					local rendered = html.renderBlock(child, rules, config)
					-- Inject backref link into the last paragraph's closing tag
					if ci == #fn.children and child.type == "paragraph" then
						-- Replace closing </p> with backref + </p>
						if #rendered >= 4 and rendered:sub(#rendered - 3) == "</p>" then
							rendered = rendered:sub(1, #rendered - 4)
								.. ` <a href="#fnref:{html.renderLiteral(label)}" class="footnote-backref">\u{21A9}\u{FE0E}</a></p>`
						end
					end
					table.insert(childChunks, rendered)
				end
				table.insert(chunks, table.concat(childChunks, if config.useCrlf then "\r\n" else "\n"))
				table.insert(chunks, `</li>`)
			end
		end
		table.insert(chunks, `</ol>`)
		table.insert(chunks, `</section>`)

		return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
	end,
}

return table.freeze(FootnoteDefinitionRule) :: types.AnyBlockRule
