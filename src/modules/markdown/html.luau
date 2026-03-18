--[=[
	HTML renderer for the Markdown IR produced by [[markdown.parse]].

	Takes [[parse.DocumentNode|DocumentNode]] trees (or individual
	[[parse.BlockNode|BlockNode]] / [[parse.InlineNode|InlineNode]]
	arrays) and converts them to HTML strings with stable CSS class names.

	**Typical usage:**
	```luau
	local md   = require("@eryx/markdown")
	local html = require("@eryx/markdown/html")

	local doc = md.parse(source)
	local out = html.render(doc)           -- full document
	local nav = html.renderToc(md.toc(doc)) -- optional navigation tree
	```

	**Syntax highlighting:**
	Pass a `languages` map to apply custom highlighting to fenced code blocks:
	```luau
	html.render(doc, {
	    languages = {
	        luau = function(code) return myHighlighter(code) end,
	    },
	})
	```

	**Wiki-link resolution:**
	Supply a `wikiResolver` to convert `[[target]]` references to URLs:
	```luau
	html.render(doc, {
	    wikiResolver = function(target) return "/docs/" .. target .. ".html" end,
	})
	```
]=]
local parse = require("@self/parse")
local markdown = require("@self/")

local html = {}

--[=[
	Configuration for [[render]], [[blockNodeToHtml]], and [[inlineNodesToHtml]].

	Both fields are optional; omitting them produces plain unstyled HTML
	with no syntax highlighting and raw `[[target]]` strings used as
	link `href` values.
]=]
export type MarkdownRenderConfig = {
	--[=[
		A map from language tag (e.g. `"luau"`, `"json"`) to a function
		that receives the raw code string and returns an HTML string with
		highlighting markup applied.  Called for fenced code blocks whose
		language tag matches a key in the map.
	]=]
	languages: {
		[string]: (string) -> string,
	}?,
	--[=[
		Called with the `target` string of each `[[target]]` or
		`[[target|label]]` wiki-link to produce the final `href` value.
		When absent, `target` is used as the `href` verbatim.
	]=]
	wikiResolver: ((string) -> string)?,
}

local ADMON_ICONS: { [string]: string } = {
	caution = "&#9888;",
	warning = "&#128680;",
	danger = "&#128680;",
	tip = "&#128161;",
	note = "&#128221;",
}

local function htmlEscape(s: string): string
	s = string.gsub(s, "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	s = string.gsub(s, '"', "&quot;")
	return s
end

local function inlineNodeToHtml(node: parse.InlineNode, config: MarkdownRenderConfig): string
	if node.type == "text" then
		return htmlEscape(node.content)
	elseif node.type == "code" then
		return '<code class="md-code">' .. htmlEscape(node.content) .. "</code>"
	elseif node.type == "bold" then
		return '<strong class="md-bold">' .. html.inlineNodesToHtml(node.children, config) .. "</strong>"
	elseif node.type == "italic" then
		return '<em class="md-italic">' .. html.inlineNodesToHtml(node.children, config) .. "</em>"
	elseif node.type == "bold_italic" then
		return '<strong class="md-bold_italic"><em>'
			.. html.inlineNodesToHtml(node.children, config)
			.. "</em></strong>"
	elseif node.type == "strikethrough" then
		return '<del class="md-strike">' .. html.inlineNodesToHtml(node.children, config) .. "</del>"
	elseif node.type == "link" then
		return '<a class="md-link" href="'
			.. htmlEscape(node.href)
			.. '">'
			.. html.inlineNodesToHtml(node.children, config)
			.. "</a>"
	elseif node.type == "wiki_link" then
		local target: string
		if config.wikiResolver then
			target = config.wikiResolver(node.target)
		else
			target = node.target
		end

		return '<a class="md-link md-link-wiki" href="'
			.. htmlEscape(target)
			.. '">'
			.. htmlEscape(node.label)
			.. "</a>"
	end
	return ""
end

--[=[
	Renders an array of [[parse.InlineNode|InlineNode]]s to an HTML string.

	Handles all inline types: text (HTML-escaped), code spans, bold,
	italic, bold-italic, strikethrough, links, and wiki-links.
	The `wikiResolver` in `config` is called for wiki-link `href` values.

	@param nodes The inline nodes to render.
	@param config Render configuration (wiki resolver, etc.).
	@return string -- The rendered HTML fragment.
]=]
function html.inlineNodesToHtml(nodes: { parse.InlineNode }, config: MarkdownRenderConfig): string
	local parts: { string } = {}
	for _, n in nodes do
		table.insert(parts, inlineNodeToHtml(n, config))
	end
	return table.concat(parts)
end

local function blockNodesToHtml(blocks: { parse.BlockNode }, config: MarkdownRenderConfig): string
	local parts: { string } = {}
	for _, block in blocks do
		table.insert(parts, html.blockNodeToHtml(block, config))
	end
	return table.concat(parts, "\n")
end

--[=[
	Renders a single [[parse.BlockNode|BlockNode]] to an HTML string.

	Each block type maps to a predictable HTML structure with stable CSS
	class names (e.g. `md-paragraph`, `md-heading`, `md-code_block`,
	`md-admonition`). Nested block content (blockquotes, admonitions)
	is rendered recursively. The `languages` map in `config` is applied
	to fenced code blocks.

	@param node The block node to render.
	@param config Render configuration (syntax highlighters, wiki resolver).
	@return string -- The rendered HTML fragment.
]=]
function html.blockNodeToHtml(node: parse.BlockNode, config: MarkdownRenderConfig): string
	if node.type == "paragraph" then
		return '<p class="md-paragraph">' .. html.inlineNodesToHtml(node.children, config) .. "</p>"
	elseif node.type == "heading" then
		local tag = "h" .. tostring(node.level)
		return "<"
			.. tag
			.. ' id="'
			.. node.id
			.. '" class="md-heading">'
			.. html.inlineNodesToHtml(node.children, config)
			.. "</"
			.. tag
			.. ">"
	elseif node.type == "code_block" then
		local body
		if config.languages and config.languages[node.lang] then
			body = config.languages[node.lang](node.content)
		else
			body = htmlEscape(node.content)
		end
		local open = if #node.lang > 0
			then '<pre class="md-code_block"><code class="language-' .. node.lang .. '">'
			else '<pre class="md-code_block"><code>'
		return open .. body .. "</code></pre>"
	elseif node.type == "hr" then
		return '<hr class="md-rule" />'
	elseif node.type == "list" then
		local tag = if node.ordered then "ol" else "ul"
		local parts: { string } = {}
		for _, item in node.items do
			table.insert(parts, "<li>" .. html.inlineNodesToHtml(item.children, config) .. "</li>")
		end
		return "<" .. tag .. ' class="md-list">\n' .. table.concat(parts, "\n") .. "\n</" .. tag .. ">"
	elseif node.type == "blockquote" then
		return '<blockquote class="md-quote">\n' .. blockNodesToHtml(node.children, config) .. "\n</blockquote>"
	elseif node.type == "table" then
		local function renderCell(cell: parse.TableCellNode, tag: string): string
			local alignAttr = if #cell.align > 0 then ' style="text-align:' .. cell.align .. '"' else ""
			return "<"
				.. tag
				.. alignAttr
				.. ">"
				.. html.inlineNodesToHtml(cell.children, config)
				.. "</"
				.. tag
				.. ">"
		end

		local function renderRow(row: parse.TableRowNode, ctag: string): string
			local cells: { string } = {}
			for _, cell in row.cells do
				table.insert(cells, renderCell(cell, ctag))
			end
			return "<tr>" .. table.concat(cells) .. "</tr>"
		end

		local bodyRows: { string } = {}
		for _, row in node.rows do
			table.insert(bodyRows, renderRow(row, "td"))
		end

		return '<table class="md-table">\n<thead>\n'
			.. renderRow(node.head, "th")
			.. "\n</thead>\n<tbody>\n"
			.. table.concat(bodyRows, "\n")
			.. "\n</tbody>\n</table>"
	elseif node.type == "admonition" then
		local icon = ADMON_ICONS[node.kind] or "&#8505;"
		-- Capitalize first letter for the title.
		local title = string.upper(string.sub(node.kind, 1, 1)) .. string.sub(node.kind, 2)
		return '<div class="md-admonition '
			.. node.kind
			.. '">\n'
			.. '<div class="md-admonition-title">'
			.. icon
			.. " "
			.. htmlEscape(title)
			.. "</div>\n"
			.. blockNodesToHtml(node.children, config)
			.. "\n</div>"
	end

	return ""
end

--[=[
	Renders a [[parse.DocumentNode|DocumentNode]] IR tree to an HTML string.

	```luau
	local doc = markdown.parse("# Hello\n\nHello **world**!")
	print(html.render(doc))
	-- <h1 id="hello">Hello</h1>
	-- <p>Hello <strong>world</strong>!</p>
	```

	@param doc The [[parse.DocumentNode|DocumentNode]] to render.
	@return string -- The HTML output.
]=]
function html.render(doc: parse.DocumentNode, config: MarkdownRenderConfig?): string
	return blockNodesToHtml(doc.children, if config then config else {})
end

--[=[
	Renders a [[markdown.toc]] result as an HTML `<nav>` / nested `<ul>` tree.

	Nesting depth follows the heading levels present in `entries`.

	```luau
	local doc = markdown.parse(source)
	print(html.renderToc(markdown.toc(doc)))
	```

	@param entries The [[markdown.TocEntry]] array returned by [[markdown.toc]].
	@return string -- The HTML navigation tree.
]=]
function html.renderToc(entries: { markdown.TocEntry }): string
	if #entries == 0 then
		return ""
	end

	local parts: { string } = {}
	local prevLevel = entries[1].level

	table.insert(parts, '<nav class="toc">')
	table.insert(parts, "<ul>")

	for _, entry in entries do
		if entry.level > prevLevel then
			-- Open nested lists for each level jumped.
			for _ = 1, entry.level - prevLevel do
				table.insert(parts, "<ul>")
			end
		elseif entry.level < prevLevel then
			-- Close nested lists for each level backed out.
			for _ = 1, prevLevel - entry.level do
				table.insert(parts, "</ul>")
			end
		end
		table.insert(parts, '<li><a href="#' .. entry.id .. '">' .. htmlEscape(entry.text) .. "</a></li>")
		prevLevel = entry.level
	end

	-- Close any remaining open lists.
	for _ = 1, prevLevel - entries[1].level do
		table.insert(parts, "</ul>")
	end

	table.insert(parts, "</ul>")
	table.insert(parts, "</nav>")
	return table.concat(parts, "\n")
end

return html
