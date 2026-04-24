local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")
local util = require("../util")

type ListItem = types.BlockNode<
	"list_item",
	{
		marker: string,
		indentationColumns: number,
		checked: (boolean | "indeterminate")?, -- nil = not a task, false = unchecked, true = checked
		children: { types.AnyBlockNode },
		loose: boolean,
	}
>

-- List (unordered): continues via indentation, starts with - or *
local ListItemRule: types.BlockRule<"list_item", ListItem> = {
	name = "list_item",
	continueBlock = function(block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		-- Blank lines continue list items only if they have content
		-- Empty items (no children) are closed by blank lines (§5.2.2)
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

		local ch = line:sub(indented.byte, indented.byte)
		if ch ~= "-" and ch ~= "*" and ch ~= "+" then
			return nil
		end

		local afterMarker = indented.byte + 1
		if
			afterMarker <= #line
			and line:sub(afterMarker, afterMarker) ~= " "
			and line:sub(afterMarker, afterMarker) ~= "\t"
		then
			return nil
		end

		local marker = ch

		-- §5.2.2: An empty list item cannot interrupt a paragraph (unless in existing matching list)
		local isBlankItem = afterMarker > #line
			or util.isLineBlank(line, { byte = afterMarker, column = indented.column + 1 })
		if _tip.type == "paragraph" and isBlankItem then
			local inMatchingList = false
			for _, b in _openStack do
				if b.type == "list" then
					inMatchingList = true
					break
				end
			end
			if not inMatchingList then
				return nil
			end
		end

		local markerCursor: tabUtil.LineCursor = {
			byte = indented.byte + 1,
			column = indented.column + 1,
		}

		-- Count actual whitespace after marker
		local wsLevel = tabUtil.indentationLevel(line, markerCursor)
		local contentIndent: number
		local delta: tabUtil.LineCursor
		if wsLevel.column == 0 or afterMarker > #line or util.isLineBlank(line, markerCursor) then
			-- Blank after marker: indent = 1
			contentIndent = 1
			delta = { byte = 0, column = 0 }
		elseif wsLevel.column >= 5 then
			-- ≥5 spaces: indented code, use indent of 1
			contentIndent = 1
			delta = tabUtil.advanceAtMostNWhitespace(line, markerCursor, 1)
		else
			contentIndent = wsLevel.column
			delta = tabUtil.advanceAtMostNWhitespace(line, markerCursor, contentIndent)
		end

		-- Return just the item; the main loop handles list wrapping after closing unmatched blocks
		return {
			blocks = {
				{
					type = "list_item",
					marker = marker,
					children = {},
					indentationColumns = indent.column + 1 + contentIndent,
					loose = false,
				},
			},
			cursor = {
				byte = markerCursor.byte + delta.byte,
				column = markerCursor.column + delta.column,
			},
			breakAfterOpen = false,
		}
	end,
	onBlankLine = function(block, openStack: { types.AnyBlockNode }): boolean
		-- Empty items: blank line closes them
		if #block.children == 0 then
			return true
		end
		-- Set maybeLoose on immediate parent list only
		if #openStack >= 2 then
			local parentList = openStack[#openStack - 1]
			if parentList.type == "list" or parentList.type == "ordered_list" then
				(parentList :: any).maybeLoose = true
			end
		end
		return false -- don't close the list item
	end,

	setsBlankFlag = true,
	wrapperType = "list",
	createWrapper = function(_firstBlock): types.AnyBlockNode
		return {
			type = "list",
			maybeLoose = false,
			loose = false,
			children = {},
		}
	end,
	onBeforeChildMount = function(container, _child, blankSinceLast, openStack)
		if #openStack >= 2 then
			local parentList = openStack[#openStack - 1]
			if parentList.type == "list" or parentList.type == "ordered_list" then
				if (parentList :: any).maybeLoose or (blankSinceLast and #container.children > 0) then
					(parentList :: any).loose = true
				end
			end
		end
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
			checkbox = `<input{annotationCb} checked="" disabled="" type="checkbox"> `
		elseif block.checked == false then
			checkbox = `<input{annotationCb} disabled="" type="checkbox"> `
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

-- List wrapper: always continues (items control actual continuation)
local ListRule: types.BlockRule<"list", {
	maybeLoose: boolean,
	loose: boolean,
	children: { ListItem },
}> = {
	name = "list",
	continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		return { matched = true, cursor = cursor }
	end,
	onBlankLine = function(block, _openStack: { types.AnyBlockNode }): boolean
		-- Blank line hitting the list directly (e.g. after empty item closed) -> mark as maybe loose
		block.maybeLoose = true
		return false
	end,
	onClose = function(block)
		for _, i in block.children do
			if i.type == "list_item" then
				i.loose = block.loose
			end
		end
	end,
	canContainParagraph = false,
	acceptsNewChild = function(wrapper, newBlock): boolean
		if newBlock.type ~= "list_item" then
			return false
		end
		if #wrapper.children > 0 and (wrapper.children[1] :: any).marker ~= (newBlock :: any).marker then
			return false
		end
		return true
	end,
	onBeforeChildMount = function(container, _child, blankSinceLast, _openStack)
		if (container :: any).maybeLoose or (blankSinceLast and #(container :: any).children > 0) then
			(container :: any).loose = true
		end
	end,

	toHtml = function(block, rules, config): string
		local annotation = ""
		if config.annotateHtml then
			annotation = ` class="md-list"`
		end

		local chunks: { string } = {}
		for _, i in block.children do
			table.insert(chunks, html.renderBlock(i, rules, config))
		end

		local le = if config.useCrlf then "\r\n" else "\n"
		return `<ul{annotation}>{le}{table.concat(chunks, le)}{le}</ul>`
	end,
}

return table.freeze({
	ListItemRule = table.freeze(ListItemRule) :: types.AnyBlockRule,
	ListRule = table.freeze(ListRule) :: types.AnyBlockRule,
})
