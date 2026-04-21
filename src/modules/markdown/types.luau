--- @ignore

local tabUtil = require("./tabUtil")

export type ExplicitBlockNode<Name, T> = { type: Name } & T -- We can keep Name for the ones we ourselves define
-- export type BlockNode<Name, T> = { type: Name } & T
export type BlockNode<Name, T> = { type: string } & T -- ! To make the types work, we have to throw away Name

-- Fundamental block nodes
export type DocumentBlockNode = ExplicitBlockNode<
	"document",
	{ children: { AnyBlockNode }, metadata: { [string]: any } }
>
export type ParagraphBlockNode = ExplicitBlockNode<"paragraph", { raw: { string }, inlines: { InlineNode } }>

export type AnyBlockNode = BlockNode<string, {}> | DocumentBlockNode | ParagraphBlockNode

-- --------------- Block Rule System ---------------

export type ContinueResult = {
	matched: boolean,
	cursor: tabUtil.LineCursor,
	closed: boolean?, -- block self-closed (e.g. code fence closing line)
	consumedLine: boolean?, -- skip rest of line processing
}

export type StartResult = {
	blocks: { AnyBlockNode }, -- 1+ blocks to push (e.g. list wrapper + item)
	cursor: tabUtil.LineCursor,
	breakAfterOpen: boolean, -- leaf nodes: stop trying more starts
}

export type MagicRules = { __magic_rules: "Recursive types workaround" }
export type BlockRule<Name, T> = {
	-- read name: Name,
	read name: string, -- ! To make the types work, we have to throw away Name

	-- Phase 1: Does this open block continue on this line?
	read continueBlock: ((block: BlockNode<Name, T>, line: string, cursor: tabUtil.LineCursor) -> ContinueResult)?,

	-- Phase 2: Does a new block of this type start here?
	read tryStart: ((
		line: string,
		cursor: tabUtil.LineCursor,
		tip: AnyBlockNode,
		openStack: { AnyBlockNode }
	) -> StartResult?)?,

	-- Phase 1.75: Can this rule convert the current paragraph tip into something else?
	read convertParagraph: ((
		para: ParagraphBlockNode,
		line: string,
		cursor: tabUtil.LineCursor,
		parent: any
	) -> AnyBlockNode?)?,

	-- Phase 3: Incorporate remaining text into this block. Return true if handled.
	read incorporateLine: ((block: BlockNode<Name, T>, remains: string) -> boolean)?,

	-- Blank line hit with this block as tip. Return true to close the block.
	read onBlankLine: ((block: BlockNode<Name, T>, openStack: { AnyBlockNode }) -> boolean)?,

	-- Fired when block is removed from open stack.
	read onClose: ((block: BlockNode<Name, T>) -> ())?,
	-- Fired for arbitrary post-processing step
	read postProcessDocument: ((doc: DocumentBlockNode) -> { AnyBlockNode }?)?,

	-- Phase 2: If true, blank lines at this block's level set the blankSinceLast flag.
	read setsBlankFlag: boolean?,

	-- Phase 2: The wrapper container type this block requires (e.g. "list" for "list_item").
	-- The main loop creates a wrapper when open[#open].type ~= wrapperType.
	read wrapperType: string?,

	-- Phase 2: Build the wrapper node. Called when wrapperType is not at the open-stack top.
	read createWrapper: ((firstBlock: AnyBlockNode) -> AnyBlockNode)?,

	-- Phase 2: Should this container remain open to accept newBlock as its next child?
	-- Return false to close it. Only called on blocks that define this method.
	read acceptsNewChild: ((wrapper: BlockNode<Name, T>, newBlock: AnyBlockNode) -> boolean)?,

	-- Phase 2/3: Called just before a child is inserted into this container.
	-- For setsBlankFlag rules: also called pre-wrapper to propagate looseness up the open stack.
	read onBeforeChildMount: ((
		container: BlockNode<Name, T>,
		child: AnyBlockNode,
		blankSinceLast: boolean,
		openStack: { AnyBlockNode }
	) -> ())?,

	-- Phase 2: When breakAfterOpen is true, return true to close this block after opening.
	-- Default (nil): close if the rule has no incorporateLine (leaf block), otherwise stay open.
	read shouldCloseAfterOpen: ((block: BlockNode<Name, T>) -> boolean?)?,

	-- Phase 3: Called after incorporateLine. Return true to close this block.
	read afterIncorporate: ((block: BlockNode<Name, T>) -> boolean?)?,

	-- Phase 3: If false, auto-close this container when a paragraph would be created inside it.
	-- Defaults to true.
	read canContainParagraph: boolean?,

	-- Convert this block to HTML
	read toHtml: (block: BlockNode<Name, T>, rules: MagicRules, config: RenderConfig) -> string?,
	read toHtmlPrepend: ((doc: DocumentBlockNode, rules: MagicRules, config: RenderConfig) -> string)?,
	read toHtmlAppend: ((doc: DocumentBlockNode, rules: MagicRules, config: RenderConfig) -> string)?,
}
export type AnyBlockRule = BlockRule<string, {}>

export type InlineRuleContext = {
	value: string,
	len: number,
	linkRefs: { [string]: { destination: string, title: string? } },
	addNode: ({ type: string }) -> any,
	addText: (string) -> any,
	flushTextBefore: (pos: number) -> (),
	parseInner: (str: string) -> { InlineNode },
	handlers: { any },
}
export type InlineRule = {
	name: string,
	matchOpen: string,
	tryParse: (ctx: InlineRuleContext, pos: number) -> (boolean, number),
	toHtml: (node: { [string]: any }, rules: MagicRules, config: RenderConfig) -> string,
}

export type LLNode = {
	prev: LLNode,
	next: LLNode,
	val: any,
}
export type DelimInfo = {
	char: number,
	count: number,
	origCount: number,
	canOpen: boolean,
	canClose: boolean,
	active: boolean,
	ilNode: LLNode,
}
export type InlineEmphasisRule = {
	name: string,
	character: number | string,
	resolve: (opener: DelimInfo, closer: DelimInfo) -> (number, string),
	toHtml: (node: { [string]: any }, rules: MagicRules, config: RenderConfig) -> string,
}

-- --------------- Inline Nodes ---------------
export type InlineText = { type: "text", content: string }
export type InlineCodeSpan = { type: "code_span", content: string }
export type InlineEmphasis = { type: "emphasis", children: { InlineNode } }
export type InlineStrong = { type: "strong", children: { InlineNode } }
export type InlineLink = {
	type: "link",
	destination: string,
	title: string?,
	children: { InlineNode },
}
export type InlineImage = {
	type: "image",
	destination: string,
	title: string?,
	children: { InlineNode },
}
export type InlineAutolink = { type: "autolink", destination: string }
export type InlineRawHtml = { type: "raw_html", content: string }
export type InlineHardBreak = { type: "hard_line_break" }
export type InlineSoftBreak = { type: "soft_line_break" }
export type InlineStrikethrough = { type: "strikethrough", children: { InlineNode } }
export type InlineFootnoteRef = { type: "footnote_ref", label: string }

export type InlineNode =
	InlineText
	| InlineCodeSpan
	| InlineEmphasis
	| InlineStrong
	| InlineStrikethrough
	| InlineLink
	| InlineImage
	| InlineAutolink
	| InlineRawHtml
	| InlineHardBreak
	| InlineSoftBreak
	| InlineFootnoteRef

export type RenderConfig = {
	useCrlf: boolean?,
	annotateHtml: boolean?,
	codeLanguages: { [string]: (string) -> string }?,
	inlineExtensions: { InlineRule }?,
	extraInlineExtensions: { InlineRule }?,
	inlineEmphasisExtensions: { InlineEmphasisRule }?,
	extraInlineEmphasisExtensions: { InlineEmphasisRule }?,
}
export type MarkdownConfig = RenderConfig & {
	extensions: { AnyBlockRule }?,
	extraExtensions: { AnyBlockRule }?,
}

return table.freeze({})
