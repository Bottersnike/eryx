local types = require("../types")
local html = require("../htmlRenderer")

--- GFM tilde delimiter resolver
local strikethrough: types.InlineEmphasisRule = {
	character = "~",
	name = "strikethrough",
	resolve = function(opener, closer)
		-- GFM-style strikethrough: only allow 1 or 2 tildes, never use 3+ as a single delimiter
		if opener.count > 2 or closer.count > 2 or opener.count ~= closer.count then
			return 0, ""
		end
		if opener.count == 2 then
			return 2, "strikethrough"
		end
		return 1, "strikethrough"
	end,
	toHtml = function(node, rules, config)
		return `<del>{html.renderInline(node.children, rules, config)}</del>`
	end,
}

return strikethrough
