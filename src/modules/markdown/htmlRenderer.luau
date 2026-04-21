--- @ignore

local types = require("./types")
local util = require("./util")

local html = {}

--- Escape text for safe inclusion in HTML content or attribute values.
--- Handles the four characters that are meaningful in both contexts.
function html.renderLiteral(text: string): string
	local buf = {}
	for i = 1, #text do
		local b = string.byte(text, i)
		if b == 38 then -- &
			table.insert(buf, "&amp;")
		elseif b == 60 then -- <
			table.insert(buf, "&lt;")
		elseif b == 62 then -- >
			table.insert(buf, "&gt;")
		elseif b == 34 then -- "
			table.insert(buf, "&quot;")
		else
			table.insert(buf, text:sub(i, i))
		end
	end
	return table.concat(buf)
end

local HEX = "0123456789ABCDEF"

local function percentEncode(byte: number): string
	local hi = math.floor(byte / 16) + 1
	local lo = (byte % 16) + 1
	return "%" .. HEX:sub(hi, hi) .. HEX:sub(lo, lo)
end

local function isHexDigit(b: number): boolean
	return (b >= 48 and b <= 57) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end

-- Characters that are safe in a URL and should NOT be percent-encoded.
-- Letters, digits, and: - . _ ~ : / ? # [ ] @ ! $ & ' ( ) * + , ; = %
local URL_SAFE: { [number]: boolean } = {}
do
	-- ASCII letters
	for i = 65, 90 do
		URL_SAFE[i] = true
	end
	for i = 97, 122 do
		URL_SAFE[i] = true
	end
	-- Digits
	for i = 48, 57 do
		URL_SAFE[i] = true
	end
	-- Unreserved: - . _ ~
	for _, b in { 45, 46, 95, 126 } do
		URL_SAFE[b] = true
	end
	-- Reserved (gen-delims + sub-delims): : / ? # @ ! $ & ' ( ) * + , ; =
	-- Note: [ ] are NOT safe — they must be percent-encoded per CommonMark
	for _, b in { 58, 47, 63, 35, 64, 33, 36, 38, 39, 40, 41, 42, 43, 44, 59, 61 } do
		URL_SAFE[b] = true
	end
end

--- Escape a URL for use inside an HTML attribute (href, src).
--- Preserves existing %XX sequences, percent-encodes unsafe bytes,
--- then HTML-escapes the result so `&` becomes `&amp;` in the attribute.
function html.renderURL(url: string): string
	local buf = {}
	local i = 1
	local len = #url
	while i <= len do
		local b = string.byte(url, i)
		if b == 37 and i + 2 <= len and isHexDigit(string.byte(url, i + 1)) and isHexDigit(string.byte(url, i + 2)) then
			-- Already percent-encoded — keep as-is
			table.insert(buf, url:sub(i, i + 2))
			i += 3
		elseif URL_SAFE[b] then
			-- Safe URL char — still needs HTML escaping for the attribute
			if b == 38 then -- &
				table.insert(buf, "&amp;")
			else
				table.insert(buf, url:sub(i, i))
			end
			i += 1
		else
			-- Unsafe byte — percent-encode it
			table.insert(buf, percentEncode(b))
			i += 1
		end
	end
	return table.concat(buf)
end
--- Extract plain text from inline nodes (for image alt text per CommonMark spec).
function html.extractPlainText(nodes: { types.InlineNode }, config: types.RenderConfig): string
	return util.getPlainText(nodes)

	-- local chunks = {}
	-- for _, i in nodes do
	-- 	if i.type == "text" then
	-- 		table.insert(chunks, i.content)
	-- 	elseif i.type == "code_span" then
	-- 		table.insert(chunks, i.content)
	-- 	elseif i.type == "emphasis" or i.type == "strong" or i.type == "strikethrough" then
	-- 		table.insert(chunks, html.extractPlainText(i.children, config))
	-- 	elseif i.type == "link" then
	-- 		table.insert(chunks, html.extractPlainText(i.children, config))
	-- 	elseif i.type == "image" then
	-- 		table.insert(chunks, html.extractPlainText(i.children, config))
	-- 	elseif i.type == "soft_line_break" then
	-- 		table.insert(chunks, if config.useCrlf then "\r\n" else "\n")
	-- 	elseif i.type == "hard_line_break" then
	-- 		table.insert(chunks, if config.useCrlf then "\r\n" else "\n")
	-- 	end
	-- 	-- autolink, raw_html: skip
	-- end
	-- return table.concat(chunks)
end

function html.renderInline(node: { types.InlineNode }, rules: types.MagicRules, config: types.RenderConfig): string
	local chunks = {}
	for _, i in node do
		if i.type == "text" then
			table.insert(chunks, html.renderLiteral(i.content))
		elseif i.type == "code_span" then
			table.insert(chunks, `<code>{html.renderLiteral(i.content)}</code>`)
		elseif i.type == "emphasis" then
			table.insert(chunks, `<em>{html.renderInline(i.children, rules, config)}</em>`)
		elseif i.type == "strong" then
			table.insert(chunks, `<strong>{html.renderInline(i.children, rules, config)}</strong>`)
		elseif i.type == "link" then
			local title = ""
			if i.title then
				title = ` title="{html.renderLiteral(i.title)}"`
			end
			table.insert(
				chunks,
				`<a href="{html.renderURL(i.destination)}"{title}>{html.renderInline(i.children, rules, config)}</a>`
			)
		elseif i.type == "image" then
			local title = ""
			if i.title then
				title = ` title="{html.renderLiteral(i.title)}"`
			end
			-- alt text is the plain-text content of the children (not HTML)
			local alt = html.renderLiteral(html.extractPlainText(i.children, config))
			table.insert(chunks, `<img src="{html.renderURL(i.destination)}" alt="{alt}"{title} />`)
		elseif i.type == "hard_line_break" then
			table.insert(chunks, "<br />" .. (if config.useCrlf then "\r\n" else "\n"))
		elseif i.type == "soft_line_break" then
			table.insert(chunks, if config.useCrlf then "\r\n" else "\n")
		else
			local matched = false
			if config.inlineExtensions then
				for _, j in config.inlineExtensions do
					if j.name == i.type then
						table.insert(chunks, j.toHtml(i :: any, rules, config))
						matched = true
						break
					end
				end
			end
			if not matched then
				if config.inlineEmphasisExtensions then
					for _, j in config.inlineEmphasisExtensions do
						if j.name == i.type then
							table.insert(chunks, j.toHtml(i :: any, rules, config))
							matched = true
							break
						end
					end
				end
			end

			if not matched then
				error(`Unknown inline {i.type}`)
			end
		end
	end
	return table.concat(chunks)
end

function html.renderBlock(block: types.AnyBlockNode, rules: types.MagicRules, config: types.RenderConfig): string
	local rulesReal = rules :: { types.BlockRule<string, any> }

	for _, rule in rulesReal do
		if block.type == rule.name then
			local rendered = rule.toHtml(block :: any, rules, config)
			if rendered then
				return rendered
			end
		end
	end

	error(`Unsupported type {block.type}`)
end

return html
