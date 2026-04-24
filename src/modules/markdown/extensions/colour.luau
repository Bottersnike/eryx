local types = require("../types")

local function parse_alpha(x: string): boolean
	local n = tonumber(x)
	if not n then
		return false
	end
	return n >= 0 and n <= 1
end

local function isRGB(s: string): boolean
	-- normalize commas -> spaces
	local body = s:match("^rgba?%((.*)%)$")
	if not body then
		return false
	end

	body = body:gsub(",", " ")

	-- split alpha
	local main, alpha = body:match("^(.-)%s*/%s*(.-)%s*$")
	if not main then
		main = body
	end

	-- extract components
	local r, g, b = (main :: string):match("^%s*([^%s]+)%s+([^%s]+)%s+([^%s]+)%s*$")
	if not (r and g and b) then
		return false
	end

	local function parse_channel(x: string)
		if x:sub(-1) == "%" then
			local n = tonumber(x:sub(1, -2))
			return n and n >= 0 and n <= 100
		else
			local n = tonumber(x)
			return n and n >= 0 and n <= 255
		end
	end

	if not (parse_channel(r) and parse_channel(g) and parse_channel(b)) then
		return false
	end

	if alpha then
		return parse_alpha(alpha)
	end

	return true
end
local function isHSL(s: string): boolean
	local body = s:match("^hsla?%((.*)%)$")
	if not body then
		return false
	end

	body = body:gsub(",", " ")

	local main, alpha = body:match("^(.-)%s*/%s*(.-)%s*$")
	if not main then
		main = body
	end

	local h, s_, l = (main :: string):match("^%s*([^%s]+)%s+([^%s]+)%s+([^%s]+)%s*$")
	if not (h and s_ and l) then
		return false
	end

	h = tonumber(h)
	if not h or h < 0 or h > 360 then
		return false
	end

	if not (s_:sub(-1) == "%" and l:sub(-1) == "%") then
		return false
	end

	local s_val = tonumber(s_:sub(1, -2))
	local l_val = tonumber(l:sub(1, -2))

	if not (s_val and l_val and s_val >= 0 and s_val <= 100 and l_val >= 0 and l_val <= 100) then
		return false
	end

	if alpha then
		return parse_alpha(alpha)
	end

	return true
end

local function isHexColour(s: string): boolean
	if not s:match("^#%x+$") then
		return false
	end
	local len = #s
	return len == 4 or len == 5 or len == 7 or len == 9
end
local function trim(s: string): string
	return (s:gsub("^[\t\r\n ]*(.-)[\t\r\n ]*$", "%1"))
end

--- GFM tilde delimiter resolver
local colour: types.InlineRule = {
	name = "colour",
	matchOpen = "`",
	tryParse = function(ctx, pos)
		local scan = pos + 1
		while scan <= ctx.len and ctx.value:sub(scan, scan) ~= "`" do
			scan += 1
		end
		if ctx.value:sub(scan, scan) ~= "`" then
			return false, pos
		end
		local chunk = trim(ctx.value:sub(pos + 1, scan - 1))

		if isHexColour(chunk) or isRGB(chunk) or isHSL(chunk) then
			ctx.flushTextBefore(pos)
			ctx.addNode({
				type = "colour",
				content = chunk,
			})
			return true, scan + 1
		end

		return false, pos
	end,
	toHtml = function(node, rules, config)
		-- No need to escape, because we already validated the content
		return `<code>{node.content}<span class="md-color_dot" style="--color: {node.content}"></span></code>`
	end,
}

return colour
