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
	read postProcessDocument: ((doc: DocumentBlockNode) -> ())?,

	-- Convert this block to HTML
	read toHtml: (block: BlockNode<Name, T>, rules: { BlockRule<string, any> }, config: MarkdownConfig) -> string?,
	read toHtmlPrepend: (
		(doc: DocumentBlockNode, rules: { BlockRule<string, any> }, config: MarkdownConfig) -> string
	)?,
	read toHtmlAppend: ((doc: DocumentBlockNode, rules: { BlockRule<string, any> }, config: MarkdownConfig) -> string)?,
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
	toHtml: (node: { [string]: any }, rules: { AnyBlockRule }, config: MarkdownConfig) -> string,
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
	toHtml: (node: { [string]: any }, rules: { AnyBlockRule }, config: MarkdownConfig) -> string,
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

export type MarkdownConfig = {
	useCrlf: boolean?,
	annotateHtml: boolean?,
	extensions: { AnyBlockRule }?,
	extraExtensions: { AnyBlockRule }?,
	inlineExtensions: { InlineRule }?,
	extraInlineExtensions: { InlineRule }?,
	inlineEmphasisExtensions: { InlineEmphasisRule }?,
	extraInlineEmphasisExtensions: { InlineEmphasisRule }?,
	codeLanguages: { [string]: (string) -> string }?,
}

return table.freeze({})
