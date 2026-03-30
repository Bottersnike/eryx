--- @ignore

local types = require("@self/../types")
local tabUtil = require("@self/../tabUtil")
local html = require("@self/../htmlRenderer")

local HtmlBlockRule = require("@self/html")
local ATXHeadingRule = require("@self/atxHeading")
local SetextHeadingRule = require("@self/setextHeading")
local BlockQuoteRule = require("@self/blockQuote")
local ThematicBreakRule = require("@self/thematicBreak")
local CodeFenceRule = require("@self/codeFence")
local CodeBlockRule = require("@self/codeBlock")
local unorderedList = require("@self/unorderedList")
local orderedList = require("@self/orderedList")

-- Document: always continues, never starts (it's the root)
local DocumentRule: types.BlockRule<"document", types.DocumentBlockNode> = {
	name = "document",
	continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		return { matched = true, cursor = cursor }
	end,
	toHtml = function(block, rules, config): string
		local chunks: { string } = {}
		for _, i in block.children do
			table.insert(chunks, html.renderBlock(i, rules, config))
		end
		-- Append footnote section if present
		-- local fnSection = html.renderFootnoteSection(block :: any)
		-- if fnSection then
		-- 	table.insert(chunks, fnSection)
		-- end
		return table.concat(chunks, if config.useCrlf then "\r\n" else "\n")
	end,
}

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

-- Paragraph: never matches continuation (lazy continuation handled in Phase 3),
-- closes on blank lines
local ParagraphRule: types.BlockRule<"paragraph", types.ParagraphBlockNode> = {
	name = "paragraph",
	continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
		return { matched = false, cursor = cursor }
	end,
	incorporateLine = function(block, remains: string): boolean
		table.insert(block.raw, stripLeadingWhitespace(remains))
		return true
	end,
	onBlankLine = function(_block, _openStack: { types.AnyBlockNode }): boolean
		return true -- close paragraph
	end,
	toHtml = function(block, rules, config): string
		local class = ""
		if config.annotateHtml then
			class = ` class="md-paragraph"`
		end
		return `<p{class}>{html.renderInline(block.inlines, rules, config)}</p>`
	end,
}

-- ======================== Table Extension (GFM + PHP Markdown Extra) ========================

-- ======================== Rule Registry ========================

local BUILTIN_RULES: { types.AnyBlockRule } = {
	-- Block rules
	ThematicBreakRule,
	ATXHeadingRule,
	CodeFenceRule,
	HtmlBlockRule,
	BlockQuoteRule,
	unorderedList.ListItemRule,
	orderedList.OrderedListItemRule,
	CodeBlockRule,

	-- Convert rules
	SetextHeadingRule,

	-- Misc
	DocumentRule :: types.AnyBlockRule,
	ParagraphRule :: types.AnyBlockRule,
	unorderedList.ListRule,
	orderedList.OrderedListRule,
}

local rules = {}

function rules.collect(extraRules: { types.AnyBlockRule }?)
	if not extraRules then
		return BUILTIN_RULES
	end
	local combinedRules = table.clone(BUILTIN_RULES)
	for _, i in extraRules do
		table.insert(combinedRules, i)
	end
	return combinedRules
end

return table.freeze(rules)
