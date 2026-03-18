--[=[
	Markdown parser and HTML renderer.

	Converts a Markdown string to an IR (intermediate representation) of
	nested Luau tables via [[parse]], then renders the IR to HTML via
	[[@eryx/markdown/html.render|html.render]].  A table of contents can be extracted with [[toc]].

	**Two-step pipeline:**
	```luau
	local md   = require("@eryx/markdown")
	local html = require("@eryx/markdown/html")
	local doc  = md.parse(source)
	print(html.render(doc))
	```

	**Block syntax:**
	- Headings: `# H1` through `###### H6` (with auto-ID anchors)
	- Paragraphs (blank-line separated)
	- Fenced code blocks ` ```lang ... ``` `
	- Unordered lists (`- item`, `* item`)
	- Ordered lists (`1. item`)
	- Blockquotes (`> text`)
	- Tables (`| col | col |`)
	- Admonitions (`:::caution ... :::`)
	- Horizontal rules (`---`, `***`, `___`)

	**Inline syntax:**
	- Bold: `**text**` or `__text__`
	- Italic: `*text*` or `_text_`
	- Bold+italic: `***text***`
	- Strikethrough: `~~text~~`
	- Inline code: `` `code` ``
	- Links: `[text](url)`
	- Wiki-links: `[[target]]` or `[[target|label]]`
]=]

local parse = require("@self/parse")

--- A single entry in a table of contents, as returned by [[toc]].
export type TocEntry = { level: number, id: string, text: string }

local markdown = {}

--[=[
	Parses a Markdown string into a [[parse.DocumentNode|DocumentNode]] IR tree.

	```luau
	local doc = md.parse("# Hello\n\n**World**!\n\n> A quote.")
	print(doc.type)              -- "document"
	print(doc.children[1].type)  -- "heading"
	print(doc.children[1].id)    -- "hello"
	```

	@param source The Markdown source string.
	@return DocumentNode -- The root of the IR tree.
]=]
function markdown.parse(source: string): parse.DocumentNode
	return { type = "document", children = parse.parseBlocks(source) }
end

--[=[
	Extracts a flat table of contents from a parsed document.

	Returns one [[TocEntry]] per heading in document order.

	```luau
	local doc = md.parse(source)
	for _, entry in md.toc(doc) do
	    print(entry.level, entry.id, entry.text)
	end
	```

	@param doc The [[parse.DocumentNode|DocumentNode]] to extract headings from.
	@return {TocEntry} -- Ordered list of heading entries.
]=]
function markdown.toc(doc: parse.DocumentNode): { TocEntry }
	local entries: { TocEntry } = {}
	for _, block in doc.children do
		if block.type == "heading" then
			table.insert(entries, {
				level = block.level,
				id = block.id,
				text = parse.inlineText(block.children),
			})
		end
	end
	return entries
end

return markdown
