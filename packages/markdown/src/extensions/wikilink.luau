local html = require("../htmlRenderer")
local types = require("../types")

local function trim(s: string): string
	return (s:gsub("^[\t\r\n ]*(.-)[\t\r\n ]*$", "%1"))
end

return function(linkResolver): types.InlineRule
	return {
		name = "wikilink",
		matchOpen = "[[",
		tryParse = function(ctx, p)
			if p + 1 > ctx.len or ctx.value:sub(p, p + 1) ~= "[[" then
				return false, p
			end
			local scan = p + 2
			while scan <= ctx.len do
				local cb = string.byte(ctx.value, scan)
				if cb == 92 then -- backslash
					scan += 2
				elseif scan + 1 <= ctx.len and ctx.value:sub(scan, scan + 1) == "]]" then
					break
				else
					scan += 1
				end
			end
			if scan > ctx.len or ctx.value:sub(scan, scan + 1) ~= "]]" then
				return false, p
			end

			local innerRaw = ctx.value:sub(p + 2, scan - 1)
			local sep = nil
			local i = 1
			while i <= #innerRaw do
				local ch = innerRaw:sub(i, i)
				if ch == "\\" then
					i += 2
				elseif ch == "|" then
					sep = i
					break
				else
					i += 1
				end
			end

			local targetRaw: string, labelRaw: string?
			if sep then
				targetRaw = innerRaw:sub(1, sep - 1)
				labelRaw = innerRaw:sub(sep + 1)
			else
				targetRaw = innerRaw
				labelRaw = nil
			end

			local target = trim(targetRaw)

			local children
			if labelRaw and #labelRaw > 0 then
				children = ctx.parseInner(labelRaw)
			else
				children = ctx.parseInner(target)
			end

			ctx.flushTextBefore(p)

			local link = linkResolver(target)

			ctx.addNode({ type = "wikilink", target = link, children = children })
			return true, scan + 2
		end,
		toHtml = function(
			node: { type: "wikilink", target: any, children: { types.InlineNode } },
			rules,
			config
		): string
			local href = if type(node.target) == "table" then node.target.href else node.target
			local extraAttrs = ""
			if typeof(node.target) == "table" then
				if
					node.target.className
					and typeof(node.target.className) == "string"
					and node.target.className ~= ""
				then
					extraAttrs ..= ` class="md-wikilink {html.renderLiteral(node.target.className)}"`
				end
				if
					node.target.hoverHtml
					and typeof(node.target.hoverHtml) == "string"
					and node.target.hoverHtml ~= ""
				then
					extraAttrs ..= ` data-hover-html="{html.renderLiteral(node.target.hoverHtml)}"`
				end
			end
			if extraAttrs == "" then
				extraAttrs = ' class="md-wikilink"'
			elseif not extraAttrs:find('class="', 1, true) then
				extraAttrs = ` class="md-wikilink"{extraAttrs}`
			end
			return `<a{extraAttrs} href={html.renderURL(href)}>{html.renderInline(node.children, rules, config)}</a>`
		end,
	}
end
