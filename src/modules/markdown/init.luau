local block = require("@self/parseBlock")
local inline = require("@self/parseInline")
local types = require("@self/types")
local html = require("@self/html")
local rules = require("@self/rules")
local util = require("@self/util")

-- Built-in inline extensions
local AutolinkRule = require("@self/rules/autolink")
local InlineHtmlRule = require("@self/rules/inlineHtml")

export type TocEntry = { level: number, id: string, text: string }

local EXTENSIONS: { types.AnyBlockRule } = {
	require("@eryx/markdown/extensions/table") :: types.AnyBlockRule,
	require("@eryx/markdown/extensions/footnote") :: types.AnyBlockRule,
	require("@eryx/markdown/extensions/admonition") :: types.AnyBlockRule,
	require("@eryx/markdown/extensions/tabs").TabGroupRule :: types.AnyBlockRule,
	require("@eryx/markdown/extensions/tabs").TabPanelRule :: types.AnyBlockRule,
}
local INLINE_EXTENSIONS: { types.InlineRule } = {
	require("@eryx/markdown/extensions/footnoteInline") :: types.InlineRule,
	require("@eryx/markdown/extensions/colour") :: types.InlineRule,

	-- We can't do wikilinks by default because they need a resolver
	-- wikilinkRuleBuilder(wikilinkResolver),
}
local INLINE_EMPHASIS_EXTENSIONS: { types.InlineEmphasisRule } = {
	require("@eryx/markdown/extensions/strikethrough") :: types.InlineEmphasisRule,
}

local markdown = {}

export type MarkdownConfig = types.MarkdownConfig

local function prepareConfig(config: MarkdownConfig): MarkdownConfig
	-- local start = os.clock()
	if config.extensions and config.extraExtensions then
		error("Cannot specify both extensions and extraExtensions")
	end
	if config.inlineExtensions and config.extraInlineExtensions then
		error("Cannot specify both inlineExtensions and extraInlineExtensions")
	end
	if config.inlineEmphasisExtensions and config.extraInlineEmphasisExtensions then
		error("Cannot specify both inlineEmphasisExtensions and extraInlineEmphasisExtensions")
	end

	local realConfig = table.clone(config)
	-- Join in all extensions

	if not config.extensions then
		-- Default to enabling all extensions
		realConfig.extensions = rules.collect(EXTENSIONS)
	else
		realConfig.extensions = rules.collect(config.extensions)
	end
	if not config.inlineExtensions then
		-- Default to enabling all extensions
		realConfig.inlineExtensions = table.clone(INLINE_EXTENSIONS)
	else
		realConfig.inlineExtensions = table.clone(config.inlineExtensions)
	end
	if not config.inlineEmphasisExtensions then
		realConfig.inlineEmphasisExtensions = table.clone(INLINE_EMPHASIS_EXTENSIONS)
	else
		realConfig.inlineEmphasisExtensions = table.clone(config.inlineEmphasisExtensions)
	end

	assert(realConfig.extensions)
	assert(realConfig.inlineExtensions)
	assert(realConfig.inlineEmphasisExtensions)

	if config.extraExtensions then
		for _, i in config.extraExtensions do
			table.insert(realConfig.extensions, i)
		end
	end
	if config.extraInlineExtensions then
		for _, i in config.extraInlineExtensions do
			table.insert(realConfig.inlineExtensions, i)
		end
	end
	if config.extraInlineEmphasisExtensions then
		for _, i in config.extraInlineEmphasisExtensions do
			table.insert(realConfig.inlineEmphasisExtensions, i)
		end
	end

	-- Enable built-in inline extensions
	table.insert(realConfig.inlineExtensions, AutolinkRule)
	table.insert(realConfig.inlineExtensions, InlineHtmlRule)

	return realConfig
end

local Markdown = {}
Markdown.__index = Markdown
export type Markdown = setmetatable<{ config: types.MarkdownConfig }, typeof(Markdown)>
function Markdown.new(config: MarkdownConfig): Markdown
	local this = {}

	this.config = prepareConfig(config)

	return setmetatable(this, Markdown)
end
function Markdown.parse(self: Markdown, source: string): types.DocumentBlockNode
	local doc, orphans = block.parse(source, self.config.extensions or {})
	return inline.parse(doc, orphans, self.config)
end
function Markdown.renderHtml(self: Markdown, doc: types.DocumentBlockNode): string
	return html.renderDocument(doc, self.config)
end
markdown.Markdown = table.freeze(Markdown)

function markdown.parse(source: string, config: MarkdownConfig): types.DocumentBlockNode
	local realConfig = prepareConfig(config)
	local doc, orphans = block.parse(source, realConfig.extensions or {})
	return inline.parse(doc, orphans, realConfig)
end
function markdown.toc(doc: types.DocumentBlockNode): { TocEntry }
	local entries: { TocEntry } = {}
	for _, block in doc.children do
		if block.type == "heading" then
			local text = util.getPlainText((block :: any).inlines)
			table.insert(entries, {
				level = (block :: any).level,
				id = util.slugify(text),
				text = text,
			})
		end
	end
	return entries
end
function markdown.renderHtml(doc: types.DocumentBlockNode, config: MarkdownConfig): string
	return html.renderDocument(doc, prepareConfig(config))
end

return table.freeze(markdown)
