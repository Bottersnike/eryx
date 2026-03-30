local tabUtil = require("../tabUtil")
local types = require("../types")
local html = require("../htmlRenderer")
local util = require("../util")

local function parseHeading(line: string)
	-- Any amount of leading whitespace
	local start = 1
	while line:sub(start, start) == " " or line:sub(start, start) == "\t" and start <= #line do
		start += 1
	end
	-- Any amount of trailing whitespace...
	local end_ = #line
	while line:sub(end_, end_) == " " or line:sub(end_, end_) == "\t" do
		end_ -= 1
	end
	local endAfterHash = end_
	-- ...with any amount of hashes...
	while line:sub(end_, end_) == "#" do
		end_ -= 1
	end
	-- ...with finally any amount of trailing whitespace again
	if line:sub(end_, end_) == " " or line:sub(end_, end_) == "\t" then
		while line:sub(end_, end_) == " " or line:sub(end_, end_) == "\t" do
			end_ -= 1
		end
	else
		end_ = endAfterHash -- foo# isn't trailing hashes!
	end

	return line:sub(start, end_)
end

-- ATX Heading: single-line leaf
local ATXHeadingRule: types.BlockRule<"heading", {
	level: number,
	raw: { string },
	inlines: { types.InlineNode },
}> =
	{
		name = "heading",

		continueBlock = function(_block, _line: string, cursor: tabUtil.LineCursor): types.ContinueResult
			return { matched = false, cursor = cursor }
		end,
		tryStart = function(
			line: string,
			cursor: tabUtil.LineCursor,
			_tip: types.AnyBlockNode,
			_openStack: { types.AnyBlockNode }
		): types.StartResult?
			local indent = tabUtil.indentationLevel(line, cursor)
			if indent.column > 3 then
				return nil
			end
			local indented: tabUtil.LineCursor = {
				byte = indent.byte + cursor.byte,
				column = indent.column + cursor.column,
			}

			local copy = table.clone(indented)
			local level = 0
			while level < 7 and copy.byte <= #line and line:sub(copy.byte, copy.byte) == "#" do
				copy.byte += 1
				copy.column += 1
				level += 1
			end
			if level > 0 and level < 7 then
				local afterHash = line:sub(copy.byte, copy.byte)
				if afterHash == " " or afterHash == "\t" or afterHash == "" then
					local content = parseHeading(line:sub(copy.byte))
					return {
						blocks = {
							{
								type = "heading",
								level = level,
								raw = { content },
								inlines = {},
							},
						},
						cursor = { byte = #line + 1, column = -1 },
						breakAfterOpen = true,
					}
				end
			end
			return nil
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

return table.freeze(ATXHeadingRule) :: types.AnyBlockRule
