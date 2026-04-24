-- Luau syntax highlighting for code blocks in documentation.

local function htmlEscape(s: string): string
	if not s then
		return ""
	end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local KEYWORDS: { [string]: boolean } = {}
for _, kw in
	{
		"and",
		"break",
		"continue",
		"do",
		"else",
		"elseif",
		"end",
		"false",
		"for",
		"function",
		"if",
		"in",
		"local",
		"const",
		"nil",
		"not",
		"or",
		"repeat",
		"return",
		"then",
		"true",
		"until",
		"while",
		"type",
		"export",
	}
do
	KEYWORDS[kw] = true
end

local BUILTINS: { [string]: boolean } = {}
for _, b in
	{
		"print",
		"warn",
		"error",
		"require",
		"tostring",
		"tonumber",
		"typeof",
		"select",
		"pcall",
		"xpcall",
		"pairs",
		"ipairs",
		"next",
		"unpack",
		"rawget",
		"rawset",
		"setmetatable",
		"getmetatable",
		"assert",
		"string",
		"table",
		"math",
		"coroutine",
		"buffer",
	}
do
	BUILTINS[b] = true
end

local function trimEol(line: string, i: number): (number, string)
	local eol = line:find("\r\n", i)
	if eol then
		return eol, line:sub(i, eol - 1)
	end
	eol = line:find("\n", i)
	if eol then
		return eol, line:sub(i, eol - 1)
	end
	return #line + 1, line:sub(i, #line + 1)
end

--- Tokenize Luau source and wrap in syntax-coloring spans.
local function highlightLuau(code: string): string
	if not code then
		return ""
	end

	local out = {}
	local i = 1
	local len = #code

	while i <= len do
		local ch = code:sub(i, i)

		-- String (double or single quote)
		if ch == '"' or ch == "'" then
			local q = ch
			local j = i + 1
			while j <= len do
				local c = code:sub(j, j)
				if c == "\\" then
					j += 2
				elseif c == q then
					j += 1
					break
				else
					j += 1
				end
			end
			table.insert(out, '<span class="syn-str">' .. htmlEscape(code:sub(i, j - 1)) .. "</span>")
			i = j

		-- Comment
		elseif code:sub(i, i + 1) == "--" then
			local eol, line = trimEol(code, i)
			table.insert(out, '<span class="syn-comment">' .. htmlEscape(line) .. "</span>")
			i = eol

		-- Number
		elseif ch:match("%d") then
			local j = i
			while j <= len and code:sub(j, j):match("[%d%.xXeEaAbBcCdDfF_]") do
				j += 1
			end
			table.insert(out, '<span class="syn-num">' .. htmlEscape(code:sub(i, j - 1)) .. "</span>")
			i = j

		-- Identifier / keyword
		elseif ch:match("[%a_]") then
			local j = i
			while j <= len and code:sub(j, j):match("[%w_]") do
				j += 1
			end
			local word = code:sub(i, j - 1)
			if word == "self" then
				table.insert(out, '<span class="syn-self">' .. word .. "</span>")
			elseif KEYWORDS[word] then
				table.insert(out, '<span class="syn-kw">' .. word .. "</span>")
			elseif BUILTINS[word] then
				table.insert(out, '<span class="syn-builtin">' .. htmlEscape(word) .. "</span>")
			else
				local nextCh = if j <= len then code:sub(j, j) else ""
				local prevCh = if i > 1 then code:sub(i - 1, i - 1) else ""
				if nextCh == "(" or prevCh == ":" then
					table.insert(out, '<span class="syn-fn">' .. htmlEscape(word) .. "</span>")
				else
					table.insert(out, htmlEscape(word))
				end
			end
			i = j
		else
			table.insert(out, htmlEscape(ch))
			i += 1
		end
	end

	return table.concat(out)
end

-- Split a shell line into tokens respecting quoted strings.
local function splitShellLine(line: string)
	local t = {}
	local i = 1
	local len = #line
	while i <= len do
		local ch = line:sub(i, i)
		if ch:match("%s") then
			i += 1
		elseif ch == '"' or ch == "'" then
			local q = ch
			local j = i + 1
			while j <= len do
				local c = line:sub(j, j)
				if c == "\\" then
					j += 2
				elseif c == q then
					j += 1
					break
				else
					j += 1
				end
			end
			table.insert(t, line:sub(i, j - 1))
			i = j
		else
			local j = i
			while j <= len and not line:sub(j, j):match("%s") do
				j += 1
			end
			table.insert(t, line:sub(i, j - 1))
			i = j
		end
	end
	return t
end

-- Highlight simple shell commands: command (first token), flags, args, strings, numbers, env vars
local function highlightShell(code: string): string
	if not code then
		return ""
	end

	local lines = string.split(code, "\n")
	local out = {}

	for _, line in lines do
		if line == "" then
			table.insert(out, "")
		else
			local parts = {}
			local i = 1
			local len = #line
			local seenToken = false

			while i <= len do
				local ch = line:sub(i, i)

				-- Whitespace: preserve as-is
				if ch:match("%s") then
					local j = i
					while j <= len and line:sub(j, j):match("%s") do
						j += 1
					end
					table.insert(parts, htmlEscape(line:sub(i, j - 1)))
					i = j

				-- Shell comment: rest of line
				elseif ch == "#" then
					table.insert(parts, '<span class="syn-comment">' .. htmlEscape(line:sub(i)) .. "</span>")
					break

				-- Quoted string
				elseif ch == '"' or ch == "'" then
					local q = ch
					local j = i + 1
					while j <= len do
						local c = line:sub(j, j)
						if c == "\\" then
							j += 2
						elseif c == q then
							j += 1
							break
						else
							j += 1
						end
					end
					table.insert(parts, '<span class="syn-str">' .. htmlEscape(line:sub(i, j - 1)) .. "</span>")
					seenToken = true
					i = j

				-- Unquoted token
				else
					local j = i
					while j <= len and not line:sub(j, j):match("%s") do
						j += 1
					end
					local tok = line:sub(i, j - 1)
					local esc = htmlEscape(tok)

					if tok:match("^%$[%w_]+") then
						table.insert(parts, '<span class="syn-builtin">' .. esc .. "</span>")
					elseif tok:match("^%-") then
						table.insert(parts, '<span class="syn-kw">' .. esc .. "</span>")
					elseif tok:match("^%d+$") or tok:match("^%d+[%d%.]*$") then
						table.insert(parts, '<span class="syn-num">' .. esc .. "</span>")
					elseif not seenToken then
						table.insert(parts, '<span class="syn-fn">' .. esc .. "</span>")
						seenToken = true
					else
						table.insert(parts, '<span class="syn-param">' .. esc .. "</span>")
					end

					i = j
				end
			end

			table.insert(out, table.concat(parts, ""))
		end
	end

	return table.concat(out, "\n")
end

--- Highlight a type-signature block (struct fields, function signatures).
--- Understands `name: Type, -- comment` patterns and Luau type syntax.
local function highlightSignature(code: string): string
	if not code then
		return ""
	end

	local lines = string.split(code, "\n")
	local out = {}

	for _, line in lines do
		-- Split line into code part and comment part
		local codePart, commentPart = line:match("^(.-)(%s*%-%-.*)$")
		if not codePart then
			codePart = line
			commentPart = nil
		end

		-- Highlight the code portion
		local highlighted = {}
		local i = 1
		local len = #codePart

		while i <= len do
			local ch = codePart:sub(i, i)

			-- String literals
			if ch == '"' or ch == "'" then
				local q = ch
				local j = i + 1
				while j <= len do
					local c = codePart:sub(j, j)
					if c == "\\" then
						j += 2
					elseif c == q then
						j += 1
						break
					else
						j += 1
					end
				end
				table.insert(highlighted, '<span class="syn-str">' .. htmlEscape(codePart:sub(i, j - 1)) .. "</span>")
				i = j

			-- Numbers
			elseif ch:match("%d") then
				local j = i
				while j <= len and codePart:sub(j, j):match("[%d%.xXeE_]") do
					j += 1
				end
				table.insert(highlighted, '<span class="syn-num">' .. htmlEscape(codePart:sub(i, j - 1)) .. "</span>")
				i = j

			-- Identifiers
			elseif ch:match("[%a_]") then
				local j = i
				while j <= len and codePart:sub(j, j):match("[%w_]") do
					j += 1
				end
				local word = codePart:sub(i, j - 1)

				-- Check context: is this word followed by ':' (field name) or preceded by ':' (type name)?
				local afterColon = false
				-- Walk backwards past whitespace to check if preceded by : or ,
				local k = i - 1
				while k >= 1 and codePart:sub(k, k):match("%s") do
					k -= 1
				end
				if k >= 1 and codePart:sub(k, k) == ":" then
					afterColon = true
				end

				-- Check if followed by ':'
				local m = j
				while m <= len and codePart:sub(m, m):match("%s") do
					m += 1
				end
				local beforeColon = m <= len and codePart:sub(m, m) == ":"

				if word == "true" or word == "false" or word == "nil" then
					table.insert(highlighted, '<span class="syn-kw">' .. word .. "</span>")
				elseif afterColon then
					-- Type position (after colon)
					table.insert(highlighted, '<span class="syn-type">' .. htmlEscape(word) .. "</span>")
				elseif beforeColon then
					-- Field name position (before colon)
					table.insert(highlighted, '<span class="syn-param">' .. htmlEscape(word) .. "</span>")
				elseif word == "self" then
					table.insert(highlighted, '<span class="syn-self">' .. word .. "</span>")
				else
					-- Could be a type name in other positions (return type, generic, etc)
					-- Check if it looks like a type (starts uppercase) or is a known keyword-like
					if KEYWORDS[word] then
						table.insert(highlighted, '<span class="syn-kw">' .. word .. "</span>")
					elseif word:match("^%u") then
						table.insert(highlighted, '<span class="syn-type">' .. htmlEscape(word) .. "</span>")
					else
						table.insert(highlighted, htmlEscape(word))
					end
				end
				i = j

			-- Punctuation with semantic meaning
			elseif ch == ":" then
				table.insert(highlighted, '<span class="syn-punct">' .. ch .. "</span>")
				i += 1

			-- Arrow ->
			elseif ch == "\xe2" and codePart:sub(i, i + 2) == "\xe2\x86\x92" then
				table.insert(highlighted, '<span class="syn-punct">\xe2\x86\x92</span>')
				i += 3
			else
				table.insert(highlighted, htmlEscape(ch))
				i += 1
			end
		end

		-- Append comment if present
		if commentPart then
			table.insert(highlighted, '<span class="syn-comment">' .. htmlEscape(commentPart) .. "</span>")
		end

		table.insert(out, table.concat(highlighted))
	end

	return table.concat(out, "\n")
end

return {
	highlightLuau = highlightLuau,
	highlightSignature = highlightSignature,
	highlightShell = highlightShell,
	htmlEscape = htmlEscape,
}
