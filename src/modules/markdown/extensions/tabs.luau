local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")

type TabPanelBlock = types.BlockNode<
	"tab_panel",
	{
		title: string, -- raw title text
		titleInlines: { types.InlineNode }?, -- parsed inline content
		active: boolean, -- marked with ===+
		fenceLength: number, -- number of '=' characters (>= 3)
		children: { types.AnyBlockNode },
	}
>

-- Tab panel: fenced container block (===+ Title)
local TabPanelRule: types.BlockRule<"tab_panel", TabPanelBlock> = {
	name = "tab_panel",
	continueBlock = function(block, line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		-- Check for closing fence: same number of '='s, optional trailing whitespace
		local indent = tabUtil.indentationLevel(line, cursor)
		if indent.column <= 3 then
			local indented: tabUtil.LineCursor = {
				byte = cursor.byte + indent.byte,
				column = cursor.column + indent.column,
			}
			local eqCount = 0
			local i = indented.byte
			while i <= #line and line:sub(i, i) == "=" do
				eqCount += 1
				i += 1
			end
			if eqCount == block.fenceLength then
				-- Check what follows the '='s
				local j = i
				-- Skip optional flags (+, !)
				if j <= #line and (line:sub(j, j) == "+" or line:sub(j, j) == "!") then
					j += 1
				end
				-- Skip whitespace
				while j <= #line and (line:sub(j, j) == " " or line:sub(j, j) == "\t") do
					j += 1
				end
				-- Check if there's title content after
				local hasTitle = false
				for k = j, #line do
					local ch = line:sub(k, k)
					if ch ~= " " and ch ~= "\t" and ch ~= "\r" then
						hasTitle = true
						break
					end
				end
				if hasTitle then
					-- New tab opener — close this panel, let Phase 2 open the next
					return { matched = false, cursor = cursor }
				else
					-- Explicit closing fence (only whitespace after ='s)
					return {
						matched = true,
						cursor = cursor,
						closed = true,
						consumedLine = true,
					}
				end
			end
		end
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

		-- Must start with at least 3 '='s
		if line:sub(indented.byte, indented.byte + 2) ~= "===" then
			return nil
		end

		-- Count total '='s
		local fenceLength = 0
		local i = indented.byte
		while i <= #line and line:sub(i, i) == "=" do
			fenceLength += 1
			i += 1
		end

		-- Check for flags: + (active) or ! (force new group)
		local active = false
		local forceNewGroup = false
		if i <= #line and line:sub(i, i) == "+" then
			active = true
			i += 1
		elseif i <= #line and line:sub(i, i) == "!" then
			forceNewGroup = true
			i += 1
		end

		-- Skip whitespace after '='s/flag
		while i <= #line and (line:sub(i, i) == " " or line:sub(i, i) == "\t") do
			i += 1
		end

		-- Parse title (rest of line, trimmed)
		local titleStart = i
		local titleEnd = #line
		-- Strip trailing whitespace and \r
		while titleEnd >= titleStart do
			local b = string.byte(line, titleEnd)
			if b == 32 or b == 9 or b == 13 then
				titleEnd -= 1
			else
				break
			end
		end
		if titleEnd < titleStart then
			return nil -- no title
		end
		local title = line:sub(titleStart, titleEnd)

		-- Close incompatible tab_group wrappers if forcing new group
		-- (handled in Phase 2 wrapper logic via the forceNewGroup flag)
		local panel = {
			type = "tab_panel",
			title = title,
			titleInlines = nil,
			active = active,
			fenceLength = fenceLength,
			children = {},
		} -- Store forceNewGroup on the panel for wrapper logic
		(panel :: any)._forceNewGroup = forceNewGroup

		return {
			blocks = { panel },
			cursor = { byte = #line + 1, column = indented.column + fenceLength },
			breakAfterOpen = false,
		}
	end,
	wrapperType = "tab_group",
	createWrapper = function(_firstBlock): types.AnyBlockNode
		return {
			type = "tab_group",
			children = {},
		}
	end,
	toHtml = function(block, rules, config)
		local chunks: { string } = {}
		local activeAttr = if block.active then ` active=""` else ""
		local titleHtml = if block.titleInlines and #block.titleInlines > 0
			then html.renderInline(block.titleInlines, rules, config)
			else html.renderLiteral(block.title)
		table.insert(chunks, `<div class="md-tab_panel"{activeAttr} data-title="{titleHtml}">`)
		for _, child in block.children do
			table.insert(chunks, html.renderBlock(child, rules, config))
		end
		table.insert(chunks, "</div>")
		return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
	end,
}

-- Tab group: wrapper around consecutive tab panels (always continues)
local TabGroupRule: types.BlockRule<"tab_group", { children: { TabPanelBlock } }> = {
	name = "tab_group",
	continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		return { matched = true, cursor = cursor }
	end,
	canContainParagraph = false,
	acceptsNewChild = function(_wrapper, newBlock): boolean
		if newBlock.type ~= "tab_panel" then
			return false
		end
		if (newBlock :: any)._forceNewGroup then
			return false
		end
		return true
	end,
	postProcessDocument = function(doc)
		local function setDefaultTab(node: types.AnyBlockNode)
			local children: { types.AnyBlockNode }? = (node :: any).children
			if not children then
				return
			end

			if node.type == "tab_group" then
				local hasActiveChild = false
				for _, child in children do
					if child.type == "tab_panel" and (child :: any).active then
						hasActiveChild = true
					end
				end
				if not hasActiveChild then
					for _, child in children do
						if child.type == "tab_panel" then
							(child :: any).active = true
							break
						end
					end
				end

				for _, child in children do
					if (child :: any).children then
						for _, grandchild in child.children do
							setDefaultTab(grandchild)
						end
					end
				end
			else
				for _, child in children do
					setDefaultTab(child)
				end
			end
		end
		setDefaultTab(doc)
	end,
	toHtml = function(block, rules, config)
		local chunks: { string } = {}
		table.insert(chunks, `<div class="md-tab_group">`)
		table.insert(chunks, `<div class="md-tab_group_header">`)
		for _, child in block.children do
			if child.type ~= "tab_panel" then
				continue
			end

			local activeAttr = if child.active then ` active=""` else ""
			local titleHtml = if child.titleInlines and #child.titleInlines > 0
				then html.renderInline(child.titleInlines, rules, config)
				else html.renderLiteral(child.title)

			table.insert(chunks, `<div class="md-tab_group_button"{activeAttr}>{titleHtml}</div>`)
		end
		table.insert(chunks, `</div>`)

		for _, child in block.children do
			table.insert(chunks, html.renderBlock(child, rules, config))
		end
		table.insert(chunks, "</div>")
		return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
	end,
}

return table.freeze({
	TabPanelRule = table.freeze(TabPanelRule) :: types.AnyBlockRule,
	TabGroupRule = table.freeze(TabGroupRule) :: types.AnyBlockRule,
})
