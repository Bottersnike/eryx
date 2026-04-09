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

local function extractRefsFromTree(node: any, linkRefs: { [string]: { destination: string, title: string? } })
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
		extractRefsFromTree(child, linkRefs)
		i += 1
	end
end

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

	local function closeTop()
		local closing = table.remove(open, #open) :: types.AnyBlockNode
		local closingRule = rulesByType[closing.type]
		if closingRule and closingRule.onClose then
			closingRule.onClose(closing :: any)
		end
	end

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
								closeTop()
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
					closeTop()
				end
			end
			-- Propagate to new tip (e.g., after closing paragraph, list_item sees blank)
			if #open >= 1 then
				local newTip = open[#open]
				if newTip ~= tip then
					local newTipRule = rulesByType[newTip.type]
					if newTipRule and newTipRule.onBlankLine then
						if newTipRule.onBlankLine(newTip :: any, open) then
							closeTop()
						end
					end
				end
			end

			-- Only set blankSinceLast when the blank is at a list item level.
			-- Blanks inside blockquotes or other containers within a list item
			-- should not make the parent list loose (see CommonMark §5.3).
			local blankTip = open[#open]
			local blankTipRule = rulesByType[blankTip.type]
			if blankTipRule and blankTipRule.setsBlankFlag then
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
			if #para.raw == 0 then
				closeTop()
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
					if not rule.tryStart then
						continue
					end

					local result = rule.tryStart(line, cursor, open[#open], open)
					if not result then
						continue
					end

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

					-- Pre-wrapper: notify item-level containers (e.g. list_item) so they
					-- can propagate looseness to their parent list before any wrapper is created.
					local mountTarget = open[#open]
					local mountTargetRule = rulesByType[mountTarget.type]
					if mountTargetRule and mountTargetRule.setsBlankFlag and mountTargetRule.onBeforeChildMount then
						mountTargetRule.onBeforeChildMount(mountTarget :: any, firstBlock, blankSinceLast, open)
					end

					-- Close incompatible wrapper containers
					while true do
						local top = open[#open]
						local topRule = rulesByType[top.type]
						if
							topRule
							and topRule.acceptsNewChild
							and not topRule.acceptsNewChild(top :: any, firstBlock)
						then
							closeTop()
						else
							break
						end
					end
					-- If we're at a bare list wrapper and this is not a list item,
					-- the list must end before mounting the new block.
					while #open > 0 do
						local top = open[#open]
						local isListWrapper = top.type == "list" or top.type == "ordered_list"
						local isListItem = firstBlock.type == "list_item" or firstBlock.type == "ordered_list_item"
						if isListWrapper and not isListItem then
							closeTop()
						else
							break
						end
					end

					-- Create wrapper container if needed
					local firstBlockRule = rulesByType[firstBlock.type]
					if
						firstBlockRule
						and firstBlockRule.wrapperType
						and open[#open].type ~= firstBlockRule.wrapperType
					then
						if firstBlockRule.createWrapper then
							local wrapper = firstBlockRule.createWrapper(firstBlock)
							assert((open[#open] :: any).children ~= nil)
							table.insert((open[#open] :: any).children, wrapper)
							table.insert(open, wrapper)
						end
					end

					-- Mount each block, notifying the container before each insertion
					for _, newBlock in result.blocks do
						local mountInto = open[#open]
						local mountIntoRule = rulesByType[mountInto.type]
						if mountIntoRule and mountIntoRule.onBeforeChildMount then
							mountIntoRule.onBeforeChildMount(mountInto :: any, newBlock, blankSinceLast, open)
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
						local lastRule = rulesByType[lastBlock.type]
						-- Leaf blocks (no incorporateLine) are always closed immediately.
						-- Multi-line blocks stay open unless shouldCloseAfterOpen says otherwise.
						local isLeaf = lastRule == nil or lastRule.incorporateLine == nil
						local close = isLeaf
							or (
								lastRule.shouldCloseAfterOpen ~= nil
								and lastRule.shouldCloseAfterOpen(lastBlock :: any)
							)
						if close then
							closeTop()
						end
						doneOpening = true
					end

					break -- restart rule scan
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

			if tipRule.afterIncorporate and tipRule.afterIncorporate(tip :: any) then
				table.remove(open, #open)
			end
		elseif tip.type == "paragraph" then
			-- Lazy continuation: append to existing paragraph
			local para = tip :: types.ParagraphBlockNode
			table.insert(para.raw, stripLeadingWhitespace(remains))
		else
			-- Close containers that can't hold paragraphs directly
			while true do
				local tipRule2 = rulesByType[tip.type]
				if tipRule2 and tipRule2.canContainParagraph == false then
					local closing = table.remove(open, #open) :: types.AnyBlockNode
					local closingRule = rulesByType[closing.type]
					if closingRule and closingRule.onClose then
						closingRule.onClose(closing :: any)
					end
					tip = open[#open]
				else
					break
				end
			end

			-- Create a new paragraph (the fallback)
			local strippedRemains = stripLeadingWhitespace(remains)

			local para: types.ParagraphBlockNode = {
				type = "paragraph",
				raw = { strippedRemains },
				inlines = {},
			}

			local tipRuleForPara = rulesByType[tip.type]
			if tipRuleForPara and tipRuleForPara.onBeforeChildMount then
				tipRuleForPara.onBeforeChildMount(tip :: any, para :: types.AnyBlockNode, blankSinceLast, open)
			end

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

	extractRefsFromTree(document, linkRefs)
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
