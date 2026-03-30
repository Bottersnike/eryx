local html = require("../htmlRenderer")
local types = require("../types")

local FootnoteInlineRule: types.InlineRule = {
	name = "footnote_ref",
	matchOpen = "[^",
	tryParse = function(ctx, pos)
		-- Try to parse [^label] as a footnote reference
		local fnEnd: number? = nil
		local p = pos + 2
		while p <= ctx.len do
			local fb = string.byte(ctx.value, p)
			if fb == 93 then -- ]
				fnEnd = p
				break
			elseif fb == 91 or fb == 10 or fb == 13 or fb == 32 then -- invalid in label
				break
			end
			p += 1
		end
		if fnEnd and fnEnd > pos + 2 then
			-- Valid footnote ref
			ctx.flushTextBefore(pos)
			local label = ctx.value:sub(pos + 2, fnEnd - 1)
			ctx.addNode({ type = "footnote_ref", label = label } :: any)
			return true, fnEnd + 1
		else
			return false, pos
		end
	end,
	toHtml = function(node, rules, config): string
		local label = (node :: any).label
		return `<sup class="footnote-ref" id="fnref:{html.renderLiteral(label)}"><a href="#fn:{html.renderLiteral(label)}">{html.renderLiteral(
			label
		)}</a></sup>`
	end,
}
return FootnoteInlineRule
