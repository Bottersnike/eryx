local types = require("../types")
local util = require("../util")
local html = require("../htmlRenderer")

--- Autolink and inline-HTML inline handler builder
local autolink: types.InlineRule = {
	name = "autolink",
	matchOpen = "<",
	tryParse = function(ctx, pos)
		-- attempt autolink like in main parser
		local scanPos = pos + 1
		local hasColon = false
		local hasAt = false
		local valid = true

		while scanPos <= ctx.len do
			local sb = string.byte(ctx.value, scanPos)
			if sb == string.byte(">") then
				break
			elseif sb == string.byte("<") or sb == 10 or sb == 13 or sb == 32 then
				valid = false
				break
			end
			if sb == string.byte(":") then
				hasColon = true
			end
			if sb == string.byte("@") then
				hasAt = true
			end
			scanPos += 1
		end

		if valid and scanPos <= ctx.len and string.byte(ctx.value, scanPos) == string.byte(">") then
			local content = ctx.value:sub(pos + 1, scanPos - 1)

			-- URI autolink
			if hasColon and #content > 0 then
				local firstB = string.byte(content, 1)
				if util.isAsciiLetter(firstB) then
					local schemeEnd = 1
					while schemeEnd < #content do
						local cb = string.byte(content, schemeEnd + 1)
						if
							util.isAsciiLetter(cb)
							or util.isDigit(cb)
							or cb == string.byte("+")
							or cb == string.byte("-")
							or cb == string.byte(".")
						then
							schemeEnd += 1
						else
							break
						end
					end
					if
						schemeEnd >= 2
						and schemeEnd <= 32
						and schemeEnd < #content
						and string.byte(content, schemeEnd + 1) == string.byte(":")
					then
						ctx.flushTextBefore(pos)
						ctx.addNode({ type = "autolink", destination = content })
						return true, scanPos + 1
					end
				end
			end

			-- Email autolink
			if hasAt and #content > 0 then
				local atCount = 0
				local atIdx = 0
				for ci = 1, #content do
					if string.byte(content, ci) == string.byte("@") then
						atCount += 1
						atIdx = ci
					end
				end
				if atCount == 1 and atIdx > 1 and atIdx < #content then
					-- validate local part roughly
					local localValid = true
					for ci = 1, atIdx - 1 do
						local cb = string.byte(content, ci)
						if
							not (
								util.isAsciiLetter(cb)
								or util.isDigit(cb)
								or cb == string.byte(".")
								or cb == string.byte("!")
								or cb == string.byte("#")
								or cb == 36
								or cb == 37
								or cb == string.byte("&")
								or cb == string.byte("'")
								or cb == string.byte("*")
								or cb == string.byte("+")
								or cb == string.byte("/")
								or cb == string.byte("=")
								or cb == string.byte("?")
								or cb == string.byte("^")
								or cb == string.byte("_")
								or cb == string.byte("`")
								or cb == string.byte("{")
								or cb == string.byte("|")
								or cb == string.byte("}")
								or cb == string.byte("~")
								or cb == string.byte("-")
							)
						then
							localValid = false
							break
						end
					end
					if localValid then
						ctx.flushTextBefore(pos)
						ctx.addNode({ type = "autolink", destination = "mailto:" .. content })
						return true, scanPos + 1
					end
				end
			end
		end

		return false, pos
	end,
	toHtml = function(node, rules, config)
		local display = node.destination
		if #display > 7 and display:sub(1, 7) == "mailto:" then
			display = display:sub(8)
		end
		return `<a href="{html.renderURL(node.destination)}">{html.renderLiteral(display)}</a>`
	end,
}

return autolink
