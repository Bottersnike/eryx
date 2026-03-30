--- @ignore

local types = require("./types")
local tabUtil = require("./tabUtil")
local util = require("./util")

local parse = {}

-- ======================== Helpers for the main loop ========================

local function stripLeadingWhitespace(s: string): string
	local pStart = 1
	while pStart <= #s do
		local rb = string.byte(s, pStart)
		if rb == 32 or rb == 9 then
			pStart += 1
		else
			break
		end
	end
	return s:sub(pStart)
end

-- ======================== Block Rules ========================

-- ======================== Main Parse Loop ========================

function parse.parse(source: string, rules: { types.AnyBlockRule }): (types.DocumentBlockNode, { types.AnyBlockNode })
	-- Lookup by block type name for continuation/incorporation/blank-line
	local rulesByType: { [string]: types.AnyBlockRule } = {}
	for _, rule in rules do
		rulesByType[rule.name] = rule
	end

	local document: types.DocumentBlockNode = { type = "document", children = {}, metadata = {} }
	local open: { types.AnyBlockNode } = {}

	table.insert(open, document :: types.AnyBlockNode)

	local lines = source:split("\n")
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines, #lines)
	end

	local blankSinceLast = false

	for _, line in lines do
		if line:sub(#line, #line) == "\r" then
			line = line:sub(1, #line - 1)
		end

		local cursor: tabUtil.LineCursor = { byte = 1, column = 1 }

		-- ==========================================
		-- PHASE 1: Block Continuation
		-- ==========================================
		local matchedCount = 0
		local skipLine = false
		for i, block in open do
			local rule = rulesByType[block.type]
			if rule and rule.continueBlock then
				local result = rule.continueBlock(block :: any, line, cursor)
				if result.matched then
					matchedCount = i
					cursor = result.cursor

					-- Block self-closed (e.g. code fence closing line)
					if result.closed then
						if result.consumedLine then
							-- Close the block and all children up to here
							while #open >= i do
								table.remove(open, #open)
							end
							skipLine = true
							break
						end
					end
				else
					break
				end
			else
				-- No rule or no continueBlock — block doesn't match
				break
			end
		end

		if skipLine then
			blankSinceLast = false
			continue
		end

		-- ==========================================
		-- PHASE 1.5: Blank Line Handling
		-- ==========================================
		-- Unified blank-line handler. Two cases:
		-- (a) Truly blank or all content consumed by continuation (#line==0 or cursor past end)
		-- (b) Whitespace-only remaining, but NOT inside a raw-content block (code/HTML)
		--     because whitespace IS content for those blocks.
		local treatAsBlank = false
		if #line == 0 or cursor.byte > #line then
			treatAsBlank = true
		elseif util.isLineBlank(line, cursor) then
			local deepTip = open[matchedCount]
			local deepRule = if deepTip then rulesByType[deepTip.type] else nil
			-- Tables have incorporateLine but blank lines should still close them
			if not (deepRule and deepRule.incorporateLine and (deepTip :: any).type ~= "table") then
				treatAsBlank = true
			end
		end
		if treatAsBlank then
			-- Close all unmatched blocks first
			while #open > matchedCount do
				local closing = table.remove(open, #open) :: types.AnyBlockNode
				local closingRule = rulesByType[closing.type]
				if closingRule and closingRule.onClose then
					closingRule.onClose(closing :: any)
				end
			end
			-- Handle blank line on tip
			local tip = open[#open]
			local tipRule = rulesByType[tip.type]
			if tipRule and tipRule.onBlankLine then
				if tipRule.onBlankLine(tip :: any, open) then
					table.remove(open, #open)
				end
			end
			-- Propagate to new tip (e.g., after closing paragraph, list_item sees blank)
			if #open >= 1 then
				local newTip = open[#open]
				if newTip ~= tip then
					local newTipRule = rulesByType[newTip.type]
					if newTipRule and newTipRule.onBlankLine then
						if newTipRule.onBlankLine(newTip :: any, open) then
							table.remove(open, #open)
						end
					end
				end
			end

			-- Only set blankSinceLast when the blank is at a list item level.
			-- Blanks inside blockquotes or other containers within a list item
			-- should not make the parent list loose (see CommonMark §5.3).
			local blankTip = open[#open]
			if blankTip.type == "list_item" or blankTip.type == "ordered_list_item" then
				blankSinceLast = true
			end
			continue
		end

		-- ==========================================
		-- PHASE 1.75: Setext Heading Conversion
		-- ==========================================
		if open[#open].type == "paragraph" and matchedCount == #open - 1 then
			local para = open[#open] :: types.ParagraphBlockNode
			local converted = false
			for _, rule in rules do
				if rule.convertParagraph then
					local result = rule.convertParagraph(para, line, cursor, open[#open - 1] :: any)
					if result then
						table.remove(open, #open)
						-- Multi-line blocks (tables) stay on the open stack
						if (result :: any).open then
							table.insert(open, result)
						end
						converted = true
						break
					end
				end
			end
			if converted then
				continue
			end
			-- If the paragraph was emptied by link ref extraction (no content left),
			-- remove it from the open stack so the line is processed fresh
			if para.raw == "" then
				table.remove(open, #open)
				matchedCount = #open
			end
		end

		-- ==========================================
		-- PHASE 2: New Block Starts
		-- ==========================================

		-- Check if the deepest matched block accepts raw lines (code/HTML).
		-- If so, skip Phase 2 entirely — no new blocks can open inside it.
		-- Tables have incorporateLine but are interruptible by other blocks.
		local deepestMatched = open[matchedCount]
		local deepestRule = if deepestMatched then rulesByType[deepestMatched.type] else nil
		local suppressNewBlocks = deepestRule ~= nil
			and deepestRule.incorporateLine ~= nil
			and (deepestMatched :: any).type ~= "table"

		local openedNewBlock = false

		if not suppressNewBlocks then
			-- Do NOT close unmatched blocks before tryStart.
			-- tryStart needs to see the real tip (e.g., paragraph) so rules like
			-- CodeBlock and OrderedListItem can check "can't interrupt paragraph".
			-- Unmatched blocks are only closed when a new block actually starts.

			local doneOpening = false
			while not doneOpening do
				local opened = false
				for _, rule in rules do
					if rule.tryStart then
						local result = rule.tryStart(line, cursor, open[#open], open)
						if result then
							-- First match: close unmatched blocks NOW
							if not openedNewBlock then
								while #open > matchedCount do
									local closing = table.remove(open, #open) :: types.AnyBlockNode
									local closingRule = rulesByType[closing.type]
									if closingRule and closingRule.onClose then
										closingRule.onClose(closing :: any)
									end
								end
								-- Also close interruptible blocks at matchedCount (tables)
								if #open > 0 and open[#open].type == "table" then
									local closing = table.remove(open, #open) :: types.AnyBlockNode
									local closingRule = rulesByType[closing.type]
									if closingRule and closingRule.onClose then
										closingRule.onClose(closing :: any)
									end
									matchedCount = #open
								end
							end
							openedNewBlock = true

							local firstBlock = result.blocks[1]

							-- Check looseness: if mounting into a list_item whose
							-- parent list has maybeLoose, confirm it as loose
							local mountTarget = open[#open]
							if mountTarget.type == "list_item" or mountTarget.type == "ordered_list_item" then
								if #open >= 2 then
									local parentList = open[#open - 1]
									if parentList.type == "list" or parentList.type == "ordered_list" then
										if
											(parentList :: any).maybeLoose
											or (blankSinceLast and #(mountTarget :: any).children > 0)
										then
											(parentList :: any).loose = true
										end
									end
								end
							end

							-- Close incompatible list/tab wrappers
							while true do
								local top = open[#open]
								if top.type == "list" and firstBlock.type ~= "list_item" then
									table.remove(open, #open)
								elseif top.type == "ordered_list" and firstBlock.type ~= "ordered_list_item" then
									table.remove(open, #open)
								elseif
									top.type == "ordered_list"
									and firstBlock.type == "ordered_list_item"
									and (top :: types.OrderedList).delimiter
										~= (firstBlock :: types.OrderedListItem).delimiter
								then
									table.remove(open, #open)
								elseif
									top.type == "list"
									and firstBlock.type == "list_item"
									and #(top :: types.List).children > 0
									and (top :: types.List).children[1].marker
										~= (firstBlock :: types.ListItem).marker
								then
									table.remove(open, #open)
								elseif top.type == "tab_group" and firstBlock.type ~= "tab_panel" then
									table.remove(open, #open)
								elseif
									top.type == "tab_group"
									and firstBlock.type == "tab_panel"
									and (firstBlock :: any)._forceNewGroup
								then
									table.remove(open, #open)
								else
									break
								end
							end

							-- Create list wrapper if needed
							if firstBlock.type == "list_item" and open[#open].type ~= "list" then
								local wrapper: types.List = {
									type = "list",
									maybeLoose = false,
									loose = false,
									children = {},
								}
								assert((open[#open] :: any).children ~= nil)
								table.insert((open[#open] :: any).children, wrapper)
								table.insert(open, wrapper)
							elseif firstBlock.type == "ordered_list_item" and open[#open].type ~= "ordered_list" then
								local wrapper: types.OrderedList = {
									type = "ordered_list",
									start = (firstBlock :: types.OrderedListItem).start,
									delimiter = (firstBlock :: types.OrderedListItem).delimiter,
									maybeLoose = false,
									loose = false,
									children = {},
								}
								assert((open[#open] :: any).children ~= nil)
								table.insert((open[#open] :: any).children, wrapper)
								table.insert(open, wrapper)
							elseif firstBlock.type == "tab_panel" and open[#open].type ~= "tab_group" then
								local wrapper: types.TabGroup = {
									type = "tab_group",
									children = {},
								}
								assert((open[#open] :: any).children ~= nil)
								table.insert((open[#open] :: any).children, wrapper)
								table.insert(open, wrapper)
							end

							-- Handle looseness when inserting into lists
							for _, newBlock in result.blocks do
								local top = open[#open]

								if top.type == "list" or top.type == "ordered_list" then
									if (top :: any).maybeLoose or (blankSinceLast and #(top :: any).children > 0) then
										(top :: any).loose = true
									end
								elseif top.type == "list_item" or top.type == "ordered_list_item" then
									if #open >= 2 then
										local parentList = open[#open - 1]
										if parentList.type == "list" or parentList.type == "ordered_list" then
											if
												(parentList :: any).maybeLoose
												or (blankSinceLast and #(top :: any).children > 0)
											then
												(parentList :: any).loose = true
											end
										end
									end
								end

								-- Sublist looseness (§5.3)
								if (newBlock.type == "list" or newBlock.type == "ordered_list") and #open >= 3 then
									local parentItem = open[#open]
									local parentList = open[#open - 1]
									if
										(parentItem.type == "list_item" or parentItem.type == "ordered_list_item")
										and (parentList.type == "list" or parentList.type == "ordered_list")
										and (
											(parentList :: any).maybeLoose
											or (blankSinceLast and #(parentItem :: any).children > 0)
										)
									then
										(parentList :: any).loose = true
									end
								end

								assert((open[#open] :: any).children ~= nil)
								table.insert((open[#open] :: any).children, newBlock)
								table.insert(open, newBlock)
							end

							cursor = result.cursor
							matchedCount = #open
							opened = true

							if result.breakAfterOpen then
								local lastBlock = result.blocks[#result.blocks]
								if lastBlock.type == "heading" or lastBlock.type == "thematic_break" then
									table.remove(open, #open)
								elseif lastBlock.type == "html_block" then
									if not (lastBlock :: types.HtmlBlock).open then
										table.remove(open, #open)
									end
								end
								doneOpening = true
							end
							break -- restart rule scan
						end
					end
				end
				if not opened then
					break
				end
			end
		end

		-- ==========================================
		-- PHASE 3: Incorporate Remaining Text
		-- ==========================================
		local remains = line:sub(cursor.byte)

		-- Empty remainder (content fully consumed by Phase 2, e.g., heading)
		if remains == "" then
			continue
		end

		-- Skip whitespace-only remains UNLESS the tip accepts raw lines (code/HTML)
		local tipForBlankCheck = open[#open]
		local tipRuleForBlankCheck = rulesByType[tipForBlankCheck.type]
		if
			util.isLineBlank(remains, { byte = 1, column = 1 })
			and not (tipRuleForBlankCheck and tipRuleForBlankCheck.incorporateLine)
		then
			continue
		end

		-- If we've landed on a half-consumed tab, expand what's left into spaces
		if remains:sub(1, 1) == "\t" and (cursor.column - 1) % tabUtil.TAB_STOP ~= 0 then
			remains = string.rep(" ", tabUtil.TAB_STOP - ((cursor.column - 1) % tabUtil.TAB_STOP)) .. remains:sub(2)
		end

		-- If no new block opened and there are unmatched blocks, check lazy continuation
		if not openedNewBlock and #open > matchedCount then
			local tip = open[#open]
			if tip.type == "paragraph" then
				-- Lazy continuation: keep the unmatched paragraph, append text
				local para = tip :: types.ParagraphBlockNode
				table.insert(para.raw, stripLeadingWhitespace(remains))
				continue
			else
				-- Not a paragraph tip, close unmatched blocks
				while #open > matchedCount do
					local closing = table.remove(open, #open) :: types.AnyBlockNode
					local closingRule = rulesByType[closing.type]
					if closingRule and closingRule.onClose then
						closingRule.onClose(closing :: any)
					end
				end
			end
		end

		local tip = open[#open]
		local tipRule = rulesByType[tip.type]

		-- Try to incorporate into tip
		if tipRule and tipRule.incorporateLine then
			tipRule.incorporateLine(tip :: any, remains)

			-- HTML blocks: check if they self-closed after incorporation
			if tip.type == "html_block" and not (tip :: types.HtmlBlock).open then
				table.remove(open, #open)
			end
		elseif tip.type == "paragraph" then
			-- Lazy continuation: append to existing paragraph
			local para = tip :: types.ParagraphBlockNode
			table.insert(para.raw, stripLeadingWhitespace(remains))
		else
			-- Close any wrapper containers at the top that can't hold paragraphs directly
			while tip.type == "list" or tip.type == "ordered_list" or tip.type == "tab_group" do
				local closing = table.remove(open, #open) :: types.AnyBlockNode
				local closingRule = rulesByType[closing.type]
				if closingRule and closingRule.onClose then
					closingRule.onClose(closing :: any)
				end
				tip = open[#open]
			end

			-- Create a new paragraph (the fallback)
			local strippedRemains = stripLeadingWhitespace(remains)

			-- If we're adding a new paragraph into a list, check looseness
			if tip.type == "list_item" or tip.type == "ordered_list_item" then
				if #open >= 2 then
					local parentList = open[#open - 1]
					if parentList.type == "list" or parentList.type == "ordered_list" then
						if (parentList :: any).maybeLoose or (blankSinceLast and #(tip :: any).children > 0) then
							(parentList :: any).loose = true
						end
					end
				end
			end

			local para: types.ParagraphBlockNode = {
				type = "paragraph",
				raw = { strippedRemains },
				inlines = {},
			}

			assert((tip :: any).children ~= nil)
			table.insert((tip :: any).children, para)
			table.insert(open, para :: types.AnyBlockNode)
		end

		blankSinceLast = false
	end

	-- Fire onClose for all remaining open blocks
	for i = #open, 1, -1 do
		local rule = rulesByType[open[i].type]
		if rule and rule.onClose then
			rule.onClose(open[i] :: any)
		end
	end

	-- Post-processing: Extract link reference definitions from paragraphs
	local linkRefs: { [string]: { destination: string, title: string? } } = {}
	local function extractRefsFromTree(node: any)
		local children = node.children
		if not children then
			return
		end
		local i = 1
		while i <= #children do
			local child = children[i]
			if child.type == "paragraph" then
				local remaining = util.extractLinkRefs(child.raw, linkRefs)
				local hasContent = false
				local remRaw = table.concat(remaining, "\n")
				for ci = 1, #remRaw do
					local rb = string.byte(remRaw, ci)
					if rb ~= 32 and rb ~= 9 and rb ~= 10 and rb ~= 13 then
						hasContent = true
						break
					end
				end
				if not hasContent then
					table.remove(children, i)
					continue
				else
					child.raw = remaining
				end
			end
			extractRefsFromTree(child)
			i += 1
		end
	end
	extractRefsFromTree(document)
	-- Merge in any link refs extracted early (during setext heading conversion)
	local function mergeEarlyRefs(node: any)
		if node._earlyLinkRefs then
			for k, v in node._earlyLinkRefs do
				if not linkRefs[k] then
					linkRefs[k] = v
				end
			end
			node._earlyLinkRefs = nil
		end
		if node.children then
			for _, child in node.children do
				mergeEarlyRefs(child)
			end
		end
	end
	mergeEarlyRefs(document);
	(document :: any).linkReferences = linkRefs

	local orphans = {}
	for _, i in rules do
		if i.postProcessDocument then
			local newOrphans = i.postProcessDocument(document)
			if newOrphans then
				for _, i in newOrphans do
					table.insert(orphans, i)
				end
			end
		end
	end

	return document, orphans
end

return table.freeze(parse)
