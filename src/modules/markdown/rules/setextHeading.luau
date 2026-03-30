local html = require("../htmlRenderer")
local tabUtil = require("../tabUtil")
local types = require("../types")
local util = require("../util")

--- Check if the line from `offset` is a setext heading underline.
--- Returns 1 for `=`, 2 for `-`, or nil if not a valid underline.
local function isSetextUnderline(line: string, offset: tabUtil.LineCursor): number?
	local indent = tabUtil.indentationLevel(line, offset)
	if indent.column > 3 then
		return nil
	end
	local p = offset.byte + indent.byte
	if p > #line then
		return nil
	end
	local ch = string.byte(line, p)
	if ch ~= 61 and ch ~= 45 then -- = or -
		return nil
	end
	while p <= #line and string.byte(line, p) == ch do
		p += 1
	end
	-- Rest must be only spaces/tabs
	while p <= #line do
		local b = string.byte(line, p)
		if b ~= 32 and b ~= 9 then
			return nil
		end
		p += 1
	end
	return if ch == 61 then 1 else 2
end

local SetextHeadingRule: types.BlockRule<"setext_heading", { level: number, raw: { string }, inlines: { types.InlineNode } }> =
	{
		name = "setext_heading",
		convertParagraph = function(
			para: types.ParagraphBlockNode,
			line: string,
			cursor: tabUtil.LineCursor,
			parent: any
		): types.AnyBlockNode?
			local setextLevel = isSetextUnderline(line, cursor)
			if not setextLevel then
				return nil
			end

			-- §4.3: Extract link reference definitions from the beginning of the paragraph
			-- before converting to a heading. If nothing remains, the line is not a heading.
			local raw = para.raw
			local earlyRefs: { [string]: { destination: string, title: string? } } = {}
			raw = util.extractLinkRefs(raw, earlyRefs)

			-- Store early-extracted refs on the parent document for later use
			if next(earlyRefs) then
				-- Walk up to find document or store on parent
				if not parent._earlyLinkRefs then
					parent._earlyLinkRefs = {}
				end
				for k, v in earlyRefs do
					parent._earlyLinkRefs[k] = v
				end
			end

			-- Check if anything remains after link ref extraction
			local hasContent = false
			local remRaw = table.concat(raw, "\n")
			for ci = 1, #remRaw do
				local rb = string.byte(remRaw, ci)
				if rb ~= 32 and rb ~= 9 and rb ~= 10 and rb ~= 13 then
					hasContent = true
					break
				end
			end
			if not hasContent then
				-- All content was link refs — nothing to become a heading.
				-- Remove the empty paragraph from parent so the === line starts fresh.
				table.remove(parent.children, #parent.children)
				-- Signal to the main loop to treat the paragraph as removed
				para.raw = {}
				return nil
			end

			-- Strip leading and trailing spaces/tabs
			local strippedRaw: { string } = {}
			for _, line in raw do
				local trimStart = 1
				while
					trimStart <= #line and (string.byte(line, trimStart) == 32 or string.byte(line, trimStart) == 9)
				do
					trimStart += 1
				end
				local trimEnd = #line
				while trimEnd >= trimStart and (string.byte(line, trimEnd) == 32 or string.byte(line, trimEnd) == 9) do
					trimEnd -= 1
				end
				table.insert(strippedRaw, line:sub(trimStart, trimEnd))
			end
			-- Strip trailing \r\n
			while #strippedRaw > 1 and strippedRaw[#strippedRaw] == "" do
				table.remove(strippedRaw, #strippedRaw)
			end

			local heading = {
				type = "heading",
				level = setextLevel,
				raw = strippedRaw,
				inlines = {},
			}
			-- Replace paragraph with heading in parent's children
			parent.children[#parent.children] = heading
			return heading
		end,

		toHtml = function(block, rules, config): string
			local annotation = ""
			if config.annotateHtml then
				annotation =
					` class="md-heading" id="{html.renderLiteral(util.slugify(util.getPlainText(block.inlines)))}"`
			end

			return `<h{block.level}{annotation}>{html.renderInline(block.inlines, rules, config)}</h{block.level}>`
		end,
	}

return table.freeze(SetextHeadingRule) :: types.AnyBlockRule
