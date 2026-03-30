local types = require("../types")
local util = require("../util")

local B_TAB = 9
local B_LF = 10
local B_CR = 13
local B_SPACE = 32
local B_BANG = 33
local B_DQUOTE = 34
local B_SQUOTE = 39
local B_DASH = 45
local B_DOT = 46
local B_COLON = 58
local B_LT = 60
local B_GT = 62
local B_LBRACKET = 91
local B_RBRACKET = 93
local B_UNDERSCORE = 95
local B_BACKTICK = 96

--- Try to match an inline HTML tag starting at `pos` (which points to '<').
--- Returns the position after the closing '>' on success, or nil on failure.
local function tryParseInlineHtml(s: string, pos: number, slen: number): number?
	if pos >= slen then
		return nil
	end
	local p = pos + 1
	local b = string.byte(s, p)

	-- 1. Open tag: <tagname attrs? /? >
	if b and util.isAsciiLetter(b) then
		p += 1
		-- Consume tag name: [A-Za-z][A-Za-z0-9-]*
		while p <= slen do
			local cb = string.byte(s, p)
			if util.isAsciiLetter(cb) or util.isDigit(cb) or cb == B_DASH then
				p += 1
			else
				break
			end
		end
		-- Consume attributes
		while p <= slen do
			-- Skip whitespace (at least one required before each attribute)
			local wsStart = p
			while p <= slen do
				local cb = string.byte(s, p)
				if cb == B_SPACE or cb == B_TAB or cb == B_LF or cb == B_CR then
					p += 1
				else
					break
				end
			end
			if p > slen then
				return nil
			end
			local cb = string.byte(s, p)
			-- Check for /> or >
			if cb == 47 then -- /
				p += 1
				if p <= slen and string.byte(s, p) == B_GT then
					return p + 1
				end
				return nil
			elseif cb == B_GT then
				return p + 1
			end
			-- Must have had whitespace to start an attribute
			if p == wsStart then
				return nil
			end
			-- Attribute name: [A-Za-z_:][A-Za-z0-9_.:-]*
			cb = string.byte(s, p)
			if not (util.isAsciiLetter(cb) or cb == B_UNDERSCORE or cb == B_COLON) then
				return nil
			end
			p += 1
			while p <= slen do
				cb = string.byte(s, p)
				if
					util.isAsciiLetter(cb)
					or util.isDigit(cb)
					or cb == B_UNDERSCORE
					or cb == B_DOT
					or cb == B_COLON
					or cb == B_DASH
				then
					p += 1
				else
					break
				end
			end
			-- Optional value specification
			if p <= slen then
				-- Skip optional whitespace before =
				local beforeEq = p
				while p <= slen do
					cb = string.byte(s, p)
					if cb == B_SPACE or cb == B_TAB or cb == B_LF or cb == B_CR then
						p += 1
					else
						break
					end
				end
				if p <= slen and string.byte(s, p) == 61 then -- =
					p += 1
					-- Skip optional whitespace after =
					while p <= slen do
						cb = string.byte(s, p)
						if cb == B_SPACE or cb == B_TAB or cb == B_LF or cb == B_CR then
							p += 1
						else
							break
						end
					end
					if p > slen then
						return nil
					end
					cb = string.byte(s, p)
					if cb == B_SQUOTE then
						p += 1
						while p <= slen and string.byte(s, p) ~= B_SQUOTE do
							p += 1
						end
						if p > slen then
							return nil
						end
						p += 1 -- skip closing quote
					elseif cb == B_DQUOTE then
						p += 1
						while p <= slen and string.byte(s, p) ~= B_DQUOTE do
							p += 1
						end
						if p > slen then
							return nil
						end
						p += 1 -- skip closing quote
					else
						-- Unquoted: no spaces, quotes, =, <, >, `
						if
							cb == B_SPACE
							or cb == B_TAB
							or cb == B_LF
							or cb == B_CR
							or cb == B_DQUOTE
							or cb == B_SQUOTE
							or cb == 61
							or cb == B_LT
							or cb == B_GT
							or cb == B_BACKTICK
						then
							return nil
						end
						while p <= slen do
							cb = string.byte(s, p)
							if
								cb == B_SPACE
								or cb == B_TAB
								or cb == B_LF
								or cb == B_CR
								or cb == B_DQUOTE
								or cb == B_SQUOTE
								or cb == 61
								or cb == B_LT
								or cb == B_GT
								or cb == B_BACKTICK
							then
								break
							end
							p += 1
						end
					end
				else
					-- No = sign, rewind whitespace (it's not part of the value spec)
					p = beforeEq
				end
			end
		end
		return nil
	end

	-- 2. Closing tag: </tagname whitespace? >
	if b == 47 then -- /
		p += 1
		if p > slen or not util.isAsciiLetter(string.byte(s, p)) then
			return nil
		end
		p += 1
		while p <= slen do
			local cb = string.byte(s, p)
			if util.isAsciiLetter(cb) or util.isDigit(cb) or cb == B_DASH then
				p += 1
			else
				break
			end
		end
		-- Optional whitespace
		while p <= slen do
			local cb = string.byte(s, p)
			if cb == B_SPACE or cb == B_TAB or cb == B_LF or cb == B_CR then
				p += 1
			else
				break
			end
		end
		if p <= slen and string.byte(s, p) == B_GT then
			return p + 1
		end
		return nil
	end

	-- 3. HTML comment: <!-- ... --> or <!-> or <!-->
	if b == B_BANG then
		p += 1
		if p > slen then
			return nil
		end
		local cb = string.byte(s, p)

		-- Comment: <!--
		if cb == B_DASH and p + 1 <= slen and string.byte(s, p + 1) == B_DASH then
			p += 2 -- past <!--
			-- Special cases: <!-->  and <!--->
			if p <= slen and string.byte(s, p) == B_GT then
				return p + 1 -- <!-->
			end
			if p <= slen and string.byte(s, p) == B_DASH and p + 1 <= slen and string.byte(s, p + 1) == B_GT then
				return p + 2 -- <!--->
			end
			-- General: scan for -->
			while p <= slen do
				if string.byte(s, p) == B_DASH and p + 1 <= slen and string.byte(s, p + 1) == B_DASH then
					if p + 2 <= slen and string.byte(s, p + 2) == B_GT then
						return p + 3
					end
				end
				p += 1
			end
			return nil
		end

		-- CDATA: <![CDATA[ ... ]]>
		if cb == B_LBRACKET then
			local cdataPrefix = "[CDATA["
			if p + #cdataPrefix <= slen and s:sub(p, p + #cdataPrefix - 1) == cdataPrefix then
				p += #cdataPrefix
				while p <= slen do
					if
						string.byte(s, p) == B_RBRACKET
						and p + 1 <= slen
						and string.byte(s, p + 1) == B_RBRACKET
						and p + 2 <= slen
						and string.byte(s, p + 2) == B_GT
					then
						return p + 3
					end
					p += 1
				end
			end
			return nil
		end

		-- Declaration: <! + ASCII letter + ... + >
		if util.isAsciiLetter(cb) then
			p += 1
			while p <= slen do
				if string.byte(s, p) == B_GT then
					return p + 1
				end
				p += 1
			end
		end
		return nil
	end

	-- 4. Processing instruction: <? ... ?>
	if b == 63 then -- ?
		p += 1
		while p <= slen do
			if string.byte(s, p) == 63 and p + 1 <= slen and string.byte(s, p + 1) == B_GT then
				return p + 2
			end
			p += 1
		end
		return nil
	end

	return nil
end

--- Autolink and inline-HTML inline handler builder
local inlineHtml: types.InlineRule = {
	name = "raw_html",
	matchOpen = "<",
	tryParse = function(ctx, pos)
		local htmlEnd = tryParseInlineHtml(ctx.value, pos, ctx.len)
		if htmlEnd then
			ctx.flushTextBefore(pos)
			ctx.addNode({ type = "raw_html", content = ctx.value:sub(pos, htmlEnd - 1) })
			return true, htmlEnd
		end

		return false, pos
	end,
	toHtml = function(node, rules, config)
		return node.content
	end,
}

return inlineHtml
