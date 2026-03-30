--- @ignore

local rules = require("./rules")
local types = require("./types")
local render = require("./htmlRenderer")

local html = {}

function html.renderDocument(doc: types.DocumentBlockNode, config: types.MarkdownConfig): string
	local combinedRules = rules.collect(config.extensions)

	local prepend: { string } = {}
	for _, i in combinedRules do
		if i.toHtmlPrepend then
			local pre = i.toHtmlPrepend(doc, combinedRules, config)
			if pre then
				table.insert(prepend, pre)
			end
		end
	end
	local body = table.concat(prepend)

	body ..= render.renderBlock(doc, combinedRules, config)

	local append: { string } = {}
	for _, i in combinedRules do
		if i.toHtmlAppend then
			local post = i.toHtmlAppend(doc, combinedRules, config)
			if post then
				table.insert(append, post)
			end
		end
	end

	body ..= table.concat(append)

	return body
end

return html
