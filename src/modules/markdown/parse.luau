--[=[
	Markdown IR types and low-level parser internals.

	This module defines every node type in the Markdown intermediate
	representation (IR) and exposes two public functions used by the
	higher-level [[markdown]] and [[@eryx/markdown/html|html]] modules.

	Most code should use [[markdown.parse]] rather than calling
	[[parseBlocks]] directly.

	## IR overview

	The document tree has two layers:

	**Block nodes** - the top-level structure of a document:
	- [[ParagraphNode]] - body text
	- [[HeadingNode]] - `# H1` through `###### H6`, with a slug `id`
	- [[CodeBlockNode]] - fenced ` ```lang ``` ` blocks
	- [[HrNode]] - thematic breaks (`---`, `***`, `___`)
	- [[ListNode]] - ordered (`1. item`) or unordered (`- item`) lists
	- [[BlockquoteNode]] - `> quoted` content (nested block tree)
	- [[TableNode]] - pipe-delimited tables
	- [[AdmonitionNode]] - `:::kind ... :::` callout blocks

	**Inline nodes** - span-level markup nested inside block content:
	- [[TextNode]] - plain text run
	- [[CodeNode]] - `` `code` `` span
	- [[BoldNode]] - `**bold**` or `__bold__`
	- [[ItalicNode]] - `*italic*` or `_italic_`
	- [[BoldItalicNode]] - `***bold italic***`
	- [[StrikethroughNode]] - `~~strike~~`
	- [[LinkNode]] - `[text](url)`
	- [[WikiLinkNode]] - `[[target]]` or `[[target|label]]`
]=]
local parse = {}


--- A plain text run.
export type TextNode = { type: "text", content: string }


--- Inline code span (`` `code` ``).
export type CodeNode = { type: "code", content: string }


--- Bold text (`**...**` or `__...__`).
export type BoldNode = { type: "bold", children: { InlineNode } }


--- Italic text (`*...*` or `_..._`).
export type ItalicNode = { type: "italic", children: { InlineNode } }


--- Bold and italic simultaneously (`***...***` or `___...___`).
export type BoldItalicNode = { type: "bold_italic", children: { InlineNode } }


--- Strikethrough text (`~~...~~`).
export type StrikethroughNode = { type: "strikethrough", children: { InlineNode } }

--- A hyperlink (`[text](url)`).
export type LinkNode = { type: "link", href: string, children: { InlineNode } }

--[=[
	A wiki-style cross-reference (`[[target]]` or `[[target|label]]`).
	`target` is the link destination; `label` is the display text (falls
	back to `target` when omitted).
]=]
export type WikiLinkNode = { type: "wiki_link", target: string, label: string }

--- Union of all inline nodes.
export type InlineNode =
	TextNode
	| CodeNode
	| BoldNode
	| ItalicNode
	| BoldItalicNode
	| StrikethroughNode
	| LinkNode
	| WikiLinkNode

-- ─────────────────────────────────────────────────────────────────────────────
-- IR: Block nodes
-- ─────────────────────────────────────────────────────────────────────────────

--- A paragraph block.
export type ParagraphNode = { type: "paragraph", children: { InlineNode } }

--- A heading block (`# H1` through `###### H6`).
--- `level` is 1–6.  `id` is a URL-safe slug for use as an HTML anchor.
export type HeadingNode = {
	type: "heading",
	level: number,
	id: string,
	children: { InlineNode },
}

--- A fenced code block.
--- `lang` is the language tag (e.g. `"lua"`), or `""` when none given.
export type CodeBlockNode = { type: "code_block", lang: string, content: string }

--- A thematic break (`---`, `***`, or `___` on its own line).
export type HrNode = { type: "hr" }

--- A single item in a [[ListNode]].
export type ListItemNode = { type: "list_item", children: { InlineNode } }

--- An ordered or unordered list.
--- `ordered` is `true` for `1. item` lists, `false` for `- item` / `* item`.
export type ListNode = { type: "list", ordered: boolean, items: { ListItemNode } }

--- A blockquote.  The inner content is a nested block tree.
export type BlockquoteNode = { type: "blockquote", children: { BlockNode } }

--- A single table cell.
--- `align` is `"left"`, `"center"`, `"right"`, or `""` for default.
export type TableCellNode = {
	type: "table_cell",
	align: string,
	children: { InlineNode },
}

--- A row of [[TableCellNode]]s.
export type TableRowNode = { type: "table_row", cells: { TableCellNode } }

--- A Markdown table with a header row and zero or more body rows.
export type TableNode = {
	type: "table",
	head: TableRowNode,
	rows: { TableRowNode },
}

--- A fenced admonition block (`:::kind ... :::`).
--- `kind` is the type (e.g. `"caution"`, `"note"`, `"tip"`).
--- The inner content is a nested block tree.
export type AdmonitionNode = {
	type: "admonition",
	kind: string,
	children: { BlockNode },
}

--- Union of all block-level nodes.
export type BlockNode =
	ParagraphNode
	| HeadingNode
	| CodeBlockNode
	| HrNode
	| ListNode
	| BlockquoteNode
	| TableNode
	| AdmonitionNode

--- The root document node returned by [[markdown.parse]].
export type DocumentNode = { type: "document", children: { BlockNode } }

--[=[
	Extracts the visible plain text from an array of inline nodes.

	Recursively descends into bold, italic, link, and other container
	nodes. Used internally to derive heading slug IDs and TOC entry
	text, but also useful for stripping formatting when indexing or
	comparing headings.

	```luau
	local parse = require("@eryx/markdown/parse")
	local nodes = -- ... InlineNode array from a HeadingNode ...
	local text = parse.inlineText(nodes)
	```

	@param nodes An array of [[InlineNode]]s to flatten.
	@return string -- The concatenated plain text.
]=]
function parse.inlineText(nodes: { InlineNode }): string
	local parts: { string } = {}
	for _, n in nodes do
		if n.type == "text" then
			table.insert(parts, n.content)
		elseif n.type == "code" then
			table.insert(parts, n.content)
		elseif n.type == "bold" then
			table.insert(parts, parse.inlineText(n.children))
		elseif n.type == "italic" then
			table.insert(parts, parse.inlineText(n.children))
		elseif n.type == "bold_italic" then
			table.insert(parts, parse.inlineText(n.children))
		elseif n.type == "strikethrough" then
			table.insert(parts, parse.inlineText(n.children))
		elseif n.type == "link" then
			table.insert(parts, parse.inlineText(n.children))
		elseif n.type == "wiki_link" then
			table.insert(parts, n.label)
		end
	end
	return table.concat(parts)
end

--- Converts a heading text to a URL-safe slug suitable for use as an HTML id.
local function slugify(s: string): string
	s = string.lower(s)
	s = string.gsub(s, "[^%w%s%-]", "")
	s = string.gsub(s, "%s+", "-")
	s = string.gsub(s, "%-%-+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	return if #s > 0 then s else "section"
end

--- Searches s for needle (plain) starting at `from`.  Returns the match start
--- position only when it falls entirely within [from, limit], else nil.
local function findClose(s: string, needle: string, from: number, limit: number): number?
	local pos = string.find(s, needle, from, true)
	if pos and pos + #needle - 1 <= limit then
		return pos
	end
	return nil
end

--- Appends a TextNode for s[from..to] (1-based, inclusive) when non-empty.
local function pushText(out: { InlineNode }, s: string, from: number, to: number)
	if from <= to then
		table.insert(out, { type = "text" :: "text", content = string.sub(s, from, to) })
	end
end

--- Parses inline Markdown within s[from..to] (1-based, both inclusive).
--- Priority: code > wiki-link > bold+italic > bold > italic > strikethrough > link
local function parseInline(s: string, from: number, to: number): { InlineNode }
	local nodes: { InlineNode } = {}
	local pos = from
	local seg = from -- start of the current unprocessed text segment

	while pos <= to do
		local ch = string.sub(s, pos, pos)
		local two = string.sub(s, pos, pos + 1)
		local three = string.sub(s, pos, pos + 2)

		-- ── Inline code: `...` (no recursive parsing inside) ─────────
		if ch == "`" then
			local close = findClose(s, "`", pos + 1, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local raw = string.sub(s, pos + 1, close - 1)
				-- Trim a single leading/trailing space (CommonMark §6.1).
				local code = string.match(raw, "^ (.-) $") or raw
				table.insert(nodes, { type = "code" :: "code", content = code })
				pos = close + 1
				seg = pos
				continue
			end
		end

		-- ── Wiki-link: [[target]] or [[target|label]] ─────────────────
		if two == "[[" then
			local close = findClose(s, "]]", pos + 2, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local inner = string.sub(s, pos + 2, close - 1)
				local sep = string.find(inner, "|", 1, true)
				local target: string
				local label: string
				if sep then
					target = string.sub(inner, 1, sep - 1)
					label = string.sub(inner, sep + 1)
				else
					target = inner
					label = inner
				end
				table.insert(nodes, {
					type = "wiki_link" :: "wiki_link",
					target = target,
					label = label,
				})
				pos = close + 2
				seg = pos
				continue
			end
		end

		-- ── Bold+italic: *** or ___ ───────────────────────────────────
		if three == "***" or three == "___" then
			local close = findClose(s, three, pos + 3, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local inner = parseInline(s, pos + 3, close - 1)
				table.insert(nodes, { type = "bold_italic" :: "bold_italic", children = inner })
				pos = close + 3
				seg = pos
				continue
			end
		end

		-- ── Bold: ** or __ ────────────────────────────────────────────
		if two == "**" or two == "__" then
			local close = findClose(s, two, pos + 2, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local inner = parseInline(s, pos + 2, close - 1)
				table.insert(nodes, { type = "bold" :: "bold", children = inner })
				pos = close + 2
				seg = pos
				continue
			end
		end

		-- ── Italic: * or _ (single, not part of ** / __ / *** / ___) ─
		if (ch == "*" or ch == "_") and string.sub(s, pos + 1, pos + 1) ~= ch then
			local close = findClose(s, ch, pos + 1, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local inner = parseInline(s, pos + 1, close - 1)
				table.insert(nodes, { type = "italic" :: "italic", children = inner })
				pos = close + 1
				seg = pos
				continue
			end
		end

		-- ── Strikethrough: ~~ ────────────────────────────────────────
		if two == "~~" then
			local close = findClose(s, "~~", pos + 2, to)
			if close then
				pushText(nodes, s, seg, pos - 1)
				local inner = parseInline(s, pos + 2, close - 1)
				table.insert(nodes, { type = "strikethrough" :: "strikethrough", children = inner })
				pos = close + 2
				seg = pos
				continue
			end
		end

		-- ── Link: [text](url) ─────────────────────────────────────────
		if ch == "[" then
			local closeBracket = findClose(s, "]", pos + 1, to)
			if closeBracket and string.sub(s, closeBracket + 1, closeBracket + 1) == "(" then
				local closeParen = findClose(s, ")", closeBracket + 2, to)
				if closeParen then
					pushText(nodes, s, seg, pos - 1)
					local linkText = string.sub(s, pos + 1, closeBracket - 1)
					local href = string.sub(s, closeBracket + 2, closeParen - 1)
					local inner = parseInline(linkText, 1, #linkText)
					table.insert(nodes, { type = "link" :: "link", href = href, children = inner })
					pos = closeParen + 1
					seg = pos
					continue
				end
			end
		end

		pos += 1
	end

	pushText(nodes, s, seg, to)
	return nodes
end

--- Splits a "| a | b | c |" table row string into trimmed cell strings.
--- \| is treated as an escaped pipe and does not split the row.
local function splitTableRow(line: string): { string }
	local PIPE_PLACEHOLDER = "\0"
	local escaped = string.gsub(line, "\\|", PIPE_PLACEHOLDER)
	local cells: { string } = {}
	for cell in string.gmatch(escaped, "|([^|]*)") do
		local trimmed = string.match(cell, "^%s*(.-)%s*$") or cell
		trimmed = string.gsub(trimmed, PIPE_PLACEHOLDER, "|")
		table.insert(cells, trimmed)
	end
	-- A trailing "|" produces a spurious empty last cell.
	if #cells > 0 and cells[#cells] == "" then
		table.remove(cells)
	end
	return cells
end

--- Returns column alignment from a separator cell like "---", ":---:", "---:".
local function tableAlign(sep: string): string
	local _match = string.match(sep, "^%s*(.-)%s*$")
	local s = if _match then _match else sep
	local l = string.sub(s, 1, 1) == ":"
	local r = string.sub(s, #s, #s) == ":"
	if l and r then
		return "center"
	elseif r then
		return "right"
	elseif l then
		return "left"
	end
	return ""
end

--- Returns true when `line` is a thematic break (---, ***, ___).
local function isHr(line: string): boolean
	local stripped = string.gsub(line, "%s", "")
	return #stripped >= 3
		and (
			string.match(stripped, "^%-+$") ~= nil
			or string.match(stripped, "^%*+$") ~= nil
			or string.match(stripped, "^_+$") ~= nil
		)
end

--- Flushes accumulated paragraph lines as a single ParagraphNode.
local function flushPara(lines: { string }, out: { BlockNode })
	if #lines == 0 then
		return
	end
	local raw = table.concat(lines, " ")
	local children = parseInline(raw, 1, #raw)
	table.insert(out, { type = "paragraph" :: "paragraph", children = children })
	table.clear(lines)
end

--- Parses a run of `|...|` lines into a TableNode.
local function buildTable(tlines: { string }): TableNode
	-- Row 1 = header, row 2 = separator, rows 3+ = body.
	local headerRaw = splitTableRow(tlines[1] or "")
	local sepRaw = splitTableRow(tlines[2] or "")

	local aligns: { string } = {}
	for _, sep in sepRaw do
		table.insert(aligns, tableAlign(sep))
	end

	local function buildRow(rawCells: { string }, cellTag: string?): TableRowNode
		local cells: { TableCellNode } = {}
		for ci, cell in rawCells do
			table.insert(cells, {
				type = "table_cell" :: "table_cell",
				align = aligns[ci] or "",
				children = parseInline(cell, 1, #cell),
			})
		end
		return { type = "table_row" :: "table_row", cells = cells }
	end

	local rows: { TableRowNode } = {}
	for li = 3, #tlines do
		table.insert(rows, buildRow(splitTableRow(tlines[li])))
	end

	return {
		type = "table" :: "table",
		head = buildRow(headerRaw),
		rows = rows,
	}
end

--[=[
	Parses a Markdown source string into an array of top-level [[BlockNode]]s.

	Normalises line endings, then processes the source line-by-line,
	recognising fenced code blocks, admonitions, headings, horizontal
	rules, blockquotes, tables, and lists before falling back to
	paragraphs. Inline markup within text content is parsed recursively.

	Heading IDs are guaranteed to be unique across the whole document,
	including inside nested blockquotes and admonitions, by passing the
	same `seenIds` table through recursive calls.

	:::note
	Most callers should use [[markdown.parse]] instead, which wraps
	this function and returns a [[DocumentNode]] root.
	:::

	```luau
	local parse = require("@eryx/markdown/parse")
	local blocks = parse.parseBlocks("# Hello\n\nWorld")
	print(blocks[1].type)  -- "heading"
	print(blocks[2].type)  -- "paragraph"
	```

	@param source The Markdown source string to parse.
	@param seenIds Optional ID collision-tracking table (used by recursive calls).
	@return {BlockNode} -- The parsed block nodes in document order.
]=]
function parse.parseBlocks(source: string, seenIds: { [string]: number }?): { BlockNode }
	local norm = string.gsub(source, "\r\n", "\n")
	norm = string.gsub(norm, "\r", "\n")

	-- `ids` is shared across recursive calls so heading IDs stay unique
	-- across the whole document (including blockquotes / admonitions).
	local ids: { [string]: number } = seenIds or {}

	local blocks: { BlockNode } = {}
	local paraLines: { string } = {}

	local lines: { string } = {}
	for line in string.gmatch(norm .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end

	-- Returns a unique heading ID, appending -2, -3, … on collision.
	local function uniqueId(base: string): string
		if not ids[base] then
			ids[base] = 1
			return base
		end
		local n = ids[base] + 1
		ids[base] = n
		return base .. "-" .. tostring(n)
	end

	local i = 1
	while i <= #lines do
		local line = lines[i]

		-- ── Fenced code block: ```[lang] ... ``` ──────────────────────
		local fenceLang = string.match(line, "^```(.*)")
		if fenceLang ~= nil then
			flushPara(paraLines, blocks)
			local lang: string = (string.match(fenceLang, "^%s*(.-)%s*$") or fenceLang)
			local codeLines: { string } = {}
			i += 1
			while i <= #lines do
				if string.match(lines[i], "^```%s*$") then
					i += 1
					break
				end
				table.insert(codeLines, lines[i])
				i += 1
			end
			table.insert(blocks, {
				type = "code_block" :: "code_block",
				lang = lang,
				content = table.concat(codeLines, "\n"),
			})
			continue
		end

		-- ── Admonition: :::kind ... ::: ───────────────────────────────
		local admonKind = string.match(line, "^:::([%w%-]+)")
		if admonKind ~= nil then
			flushPara(paraLines, blocks)
			local innerLines: { string } = {}
			i += 1
			while i <= #lines do
				if string.match(lines[i], "^:::%s*$") then
					i += 1
					break
				end
				table.insert(innerLines, lines[i])
				i += 1
			end
			local inner = parse.parseBlocks(table.concat(innerLines, "\n"), ids)
			table.insert(blocks, {
				type = "admonition" :: "admonition",
				kind = admonKind,
				children = inner,
			})
			continue
		end

		-- ── Blank line: flush paragraph ───────────────────────────────
		if string.match(line, "^%s*$") then
			flushPara(paraLines, blocks)
			i += 1
			continue
		end

		-- ── ATX heading: # through ###### ─────────────────────────────
		local hashes, headingText = string.match(line, "^(#+)%s+(.*)")
		if hashes and #hashes <= 6 then
			flushPara(paraLines, blocks)
			local h: string = hashes
			local ht: string = (headingText or "")
			-- Strip optional trailing fence (e.g. `## Title ##`).
			local trimmed: string = (string.match(ht, "^(.-)%s*#+%s*$") or ht)
			local children = parseInline(trimmed, 1, #trimmed)
			local id = uniqueId(slugify(parse.inlineText(children)))
			table.insert(blocks, {
				type = "heading" :: "heading",
				level = #h,
				id = id,
				children = children,
			})
			i += 1
			continue
		end

		-- ── Horizontal rule: --- / *** / ___ ─────────────────────────
		if isHr(line) then
			flushPara(paraLines, blocks)
			table.insert(blocks, { type = "hr" :: "hr" })
			i += 1
			continue
		end

		-- ── Blockquote: > ... ────────────────────────────────────────
		if string.match(line, "^>") then
			flushPara(paraLines, blocks)
			local bqLines: { string } = {}
			while i <= #lines and string.match(lines[i], "^>") do
				local stripped = (string.match(lines[i], "^>%s?(.*)") or "")
				table.insert(bqLines, stripped)
				i += 1
			end
			local inner = parse.parseBlocks(table.concat(bqLines, "\n"), ids)
			table.insert(blocks, { type = "blockquote" :: "blockquote", children = inner })
			continue
		end

		-- ── Table: lines starting with | ─────────────────────────────
		if string.sub(line, 1, 1) == "|" then
			flushPara(paraLines, blocks)
			local tblLines: { string } = {}
			while i <= #lines and string.sub(lines[i], 1, 1) == "|" do
				table.insert(tblLines, lines[i])
				i += 1
			end
			if #tblLines >= 2 then
				table.insert(blocks, buildTable(tblLines))
			else
				-- Degenerate single row - fall back to paragraph.
				for _, tl in tblLines do
					table.insert(paraLines, tl)
				end
			end
			continue
		end

		-- ── Unordered list: - or * ────────────────────────────────────
		if string.match(line, "^[%-*]%s+") then
			flushPara(paraLines, blocks)
			local items: { ListItemNode } = {}
			while i <= #lines and string.match(lines[i], "^[%-*]%s+") do
				local text: string = (string.match(lines[i], "^[%-*]%s+(.*)") or "")
				table.insert(items, {
					type = "list_item" :: "list_item",
					children = parseInline(text, 1, #text),
				})
				i += 1
			end
			table.insert(blocks, { type = "list" :: "list", ordered = false, items = items })
			continue
		end

		-- ── Ordered list: 1. ... ─────────────────────────────────────
		if string.match(line, "^%d+%.%s+") then
			flushPara(paraLines, blocks)
			local items: { ListItemNode } = {}
			while i <= #lines and string.match(lines[i], "^%d+%.%s+") do
				local text: string = (string.match(lines[i], "^%d+%.%s+(.*)") or "")
				table.insert(items, {
					type = "list_item" :: "list_item",
					children = parseInline(text, 1, #text),
				})
				i += 1
			end
			table.insert(blocks, { type = "list" :: "list", ordered = true, items = items })
			continue
		end

		-- ── Paragraph (default) ───────────────────────────────────────
		table.insert(paraLines, line)
		i += 1
	end

	flushPara(paraLines, blocks)
	return blocks
end

return parse
