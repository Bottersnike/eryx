local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")
local util = require("../util")

type OrderedListItem = types.BlockNode<
	"ordered_list_item",
	{
		delimiter: string, -- "." or ")"
		start: number,
		indentationColumns: number,
		checked: (boolean | "indeterminate")?, -- nil = not a task, false = unchecked, true = checked
		children: { types.AnyBlockNode },
		loose: boolean,
	}
>

-- Ordered list item: continues via indentation, starts with digits + . or )
local OrderedListItemRule: types.BlockRule<"ordered_list_item", OrderedListItem> = {
	name = "ordered_list_item",
	continueBlock = function(block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		-- Blank lines continue items only if they have content
		if util.isLineBlank(line, cursor) then
			if #block.children > 0 then
				return { matched = true, cursor = cursor }
			else
				return { matched = false, cursor = cursor }
			end
		end
		if tabUtil.indentationLevel(line, cursor).column >= block.indentationColumns then
			local delta = tabUtil.advanceAtMostNWhitespace(line, cursor, block.indentationColumns)
			return {
				matched = true,
				cursor = {
					byte = cursor.byte + delta.byte,
					column = cursor.column + delta.column,
				},
			}
		end
		return { matched = false, cursor = cursor }
	end,
	tryStart = function(
		line: string,
		cursor: tabUtil.LineCursor,
		tip: types.AnyBlockNode,
		openStack: { types.AnyBlockNode }
	): types.StartResult?
		local indent = tabUtil.indentationLevel(line, cursor)
		if indent.column > 3 then
			return nil
		end
		local indented: tabUtil.LineCursor = {
			byte = indent.byte + cursor.byte,
			column = indent.column + cursor.column,
		}

		local digitStart = indented.byte
		local digitEnd = digitStart
		while digitEnd <= #line and digitEnd - digitStart < 9 do
			local b = string.byte(line, digitEnd)
			if b >= 48 and b <= 57 then
				digitEnd += 1
			else
				break
			end
		end
		if digitEnd <= digitStart then
			return nil
		end

		local delim = line:sub(digitEnd, digitEnd)
		if delim ~= "." and delim ~= ")" then
			return nil
		end

		local afterMarker = digitEnd + 1
		if
			afterMarker <= #line
			and line:sub(afterMarker, afterMarker) ~= " "
			and line:sub(afterMarker, afterMarker) ~= "\t"
		then
			return nil
		end

		local startNum = tonumber(line:sub(digitStart, digitEnd - 1)) :: number

		-- §5.2.2: Ordered list paragraph interruption rules
		if tip.type == "paragraph" then
			local isBlankItem = afterMarker > #line
				or util.isLineBlank(
					line,
					{ byte = afterMarker, column = indented.column + (digitEnd - digitStart) + 1 }
				)
			-- Empty ordered items can't interrupt paragraphs
			-- start != 1 can't interrupt paragraphs (unless already in ordered list)
			if isBlankItem or startNum ~= 1 then
				local inOrderedList = false
				for _, b in openStack do
					if b.type == "ordered_list" then
						inOrderedList = true
						break
					end
				end
				if not inOrderedList then
					return nil
				end
			end
		end

		local markerWidth = (digitEnd - digitStart) + 1
		local afterDelim: tabUtil.LineCursor = {
			byte = afterMarker,
			column = indented.column + markerWidth,
		}

		-- Count actual whitespace after delimiter
		local wsLevel = tabUtil.indentationLevel(line, afterDelim)
		local contentIndent: number
		local delta: tabUtil.LineCursor
		if wsLevel.column == 0 or afterMarker > #line or util.isLineBlank(line, afterDelim) then
			-- Blank after delimiter: indent = 1
			contentIndent = 1
			delta = { byte = 0, column = 0 }
		elseif wsLevel.column >= 5 then
			-- ≥5 spaces: indented code, use indent of 1
			contentIndent = 1
			delta = tabUtil.advanceAtMostNWhitespace(line, afterDelim, 1)
		else
			contentIndent = wsLevel.column
			delta = tabUtil.advanceAtMostNWhitespace(line, afterDelim, contentIndent)
		end

		local newItem: OrderedListItem = {
			type = "ordered_list_item" :: "ordered_list_item",
			delimiter = delim,
			start = startNum,
			children = {},
			indentationColumns = indent.column + markerWidth + contentIndent,
			loose = false,
		}

		local resultCursor: tabUtil.LineCursor = {
			byte = afterDelim.byte + delta.byte,
			column = afterDelim.column + delta.column,
		}

		-- Return just the item; the main loop handles list wrapping after closing unmatched blocks
		return {
			blocks = { newItem },
			cursor = resultCursor,
			breakAfterOpen = false,
		}
	end,
	onBlankLine = function(block, openStack: { types.AnyBlockNode }): boolean
		-- Empty items: blank line closes them
		if #block.children == 0 then
			return true
		end
		-- Set maybeLoose on all ancestor lists up the stack
		for i = #openStack - 1, 1, -1 do
			local ancestor = openStack[i]
			if ancestor.type == "list" or ancestor.type == "ordered_list" then
				(ancestor :: any).maybeLoose = true
			elseif ancestor.type == "document" or ancestor.type == "block_quote" then
				break
			end
		end
		return false
	end,

	toHtml = function(block, rules, config): string
		local annotation = ""
		if config.annotateHtml then
			annotation =
				` class="md-list_item md-ordered_list_item{if block.checked ~= nil then " md-task_list_item" else ""}"`
		end
		local annotationCb = ""
		if config.annotateHtml then
			annotationCb = ` class="md-task"`
		end

		if #block.children == 0 then
			return `<li{annotation}></li>`
		end
		local checkbox = ""
		if block.checked == true then
			checkbox = `<input{annotationCb} type="checkbox" checked="" disabled="" /> `
		elseif block.checked == false then
			checkbox = `<input{annotationCb} type="checkbox" disabled="" /> `
		end
		local chunks: { string } = {}
		for ci, i in block.children do
			if i.type == "paragraph" and not block.loose then
				local para = i :: types.ParagraphBlockNode
				local content = html.renderInline(para.inlines, rules, config)
				if ci == 1 and checkbox ~= "" then
					content = checkbox .. content
				end
				table.insert(chunks, content)
			else
				local content = html.renderBlock(i, rules, config)
				if ci == 1 and checkbox ~= "" and i.type == "paragraph" then
					local para = i :: types.ParagraphBlockNode
					content = `<p>{checkbox}{html.renderInline(para.inlines, rules, config)}</p>`
				end
				table.insert(chunks, content)
			end
		end
		local pre = if config.useCrlf then "\r\n" else "\n"
		local post = if config.useCrlf then "\r\n" else "\n"
		if not block.loose then
			if block.children[1].type == "paragraph" then
				pre = ""
			end
			if block.children[#block.children].type == "paragraph" then
				post = ""
			end
		end
		return `<li{annotation}>{pre}{table.concat(chunks, if config.useCrlf then "\r\n" else "\n")}{post}</li>`
	end,
}

-- Ordered list wrapper: always continues
local OrderedListRule: types.BlockRule<
	"ordered_list",
	{
		start: number,
		delimiter: string, -- "." or ")"
		maybeLoose: boolean,
		loose: boolean,
		children: { OrderedListItem },
	}
> =
	{
		name = "ordered_list",
		continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			return { matched = true, cursor = cursor }
		end,
		onBlankLine = function(block, _openStack: { types.AnyBlockNode }): boolean
			block.maybeLoose = true
			return false
		end,
		onClose = function(block)
			for _, i in block.children do
				if i.type == "ordered_list_item" then
					i.loose = block.loose
				end
			end
		end,
		toHtml = function(block, rules, config): string
			local annotation = ""
			if config.annotateHtml then
				annotation = ` class="md-list md-ordered_list"`
			end

			local chunks: { string } = {}
			for _, i in block.children do
				table.insert(chunks, html.renderBlock(i, rules, config))
			end
			local startAttr = if block.start ~= 1 then ` start="{block.start}"` else ""

			if config.useCrlf then
				return `<ol{startAttr}{annotation}>\r\n{table.concat(chunks, "\r\n")}\r\n</ol>`
			else
				return `<ol{startAttr}{annotation}>\n{table.concat(chunks, "\n")}\n</ol>`
			end
		end,
	}

return table.freeze({
	OrderedListItemRule = table.freeze(OrderedListItemRule) :: types.AnyBlockRule,
	OrderedListRule = table.freeze(OrderedListRule) :: types.AnyBlockRule,
})
