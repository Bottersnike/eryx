local regex = require("@eryx/regex")

local function htmlEscape(s: string): string
	if not s then
		return ""
	end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

type RegexRule = {
	class: string?,
	regex: regex.Regex,
}

local function span(className: string?, text: string): string
	if not className then
		return htmlEscape(text)
	end

	return `<span class="{className}">{htmlEscape(text)}</span>`
end

local function rule(className: string?, pattern: string, flags: string?): RegexRule
	return {
		class = className,
		regex = regex.new(pattern, flags),
	}
end

local function highlightByRegex(code: string, rules: { RegexRule }): string
	if not code then
		return ""
	end

	local out = {}
	local i = 1
	local len = #code

	while i <= len do
		local matchedClass: string? = nil
		local matchedText: string? = nil

		for _, r in rules do
			local m = r.regex:find(code, i)

			if m and m.start == i and #m.match > 0 then
				matchedClass = r.class
				matchedText = m.match
				break
			end
		end

		if matchedText then
			table.insert(out, span(matchedClass, matchedText))
			i += #matchedText
		else
			table.insert(out, htmlEscape(code:sub(i, i)))
			i += 1
		end
	end

	return table.concat(out)
end

local function findSoonest(code: string, i: number, needles: { string }): number?
	local best: number? = nil

	for _, needle in needles do
		local at = code:find(needle, i, true)
		if at and (not best or at < best) then
			best = at
		end
	end

	return best
end

local TEMPLATE_RULES = {
	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'(?:\\.|[^'\\\r\n])*']==]),

	rule("syn-num", [==[\G-?(?:0|[1-9]\d*)(?:\.\d+)?]==]),

	rule(
		"syn-kw",
		[==[\G(?:if|then|elseif|else|end|for|in|do|macro|use|slot|fill|include|and|or|not|true|false|nil)\b]==]
	),

	rule(
		"syn-builtin",
		[==[\G(?:length|upper|lower|trim|capitalize|title|replace|first|last|join|reverse|keys|values|sort|abs|round|floor|ceil|default|json|type)\b]==]
	),

	rule("syn-builtin", [==[\G\|\s*[A-Za-z_][A-Za-z0-9_]*]==]),

	rule("syn-param", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*:)]==]),
	rule(nil, [==[\G[A-Za-z_][A-Za-z0-9_]*]==]),

	rule("syn-punct", [==[\G==|~=|<=|>=|[<>=+\-*/%,.[\]()]|[|]]==]),
}

local function highlightTemplateBlock(
	code: string,
	startAt: number,
	openDelim: string,
	closeDelim: string
): (string, number)
	local closeAt = code:find(closeDelim, startAt + #openDelim, true)

	if not closeAt then
		return span("syn-fn", openDelim) .. highlightByRegex(code:sub(startAt + #openDelim), TEMPLATE_RULES), #code + 1
	end

	local innerStart = startAt + #openDelim
	local innerEnd = closeAt - 1

	local html = span("syn-fn", openDelim)
		.. highlightByRegex(code:sub(innerStart, innerEnd), TEMPLATE_RULES)
		.. span("syn-fn", closeDelim)

	return html, closeAt + #closeDelim
end

local function highlightTemplated(code: string, templatedLanguage: { RegexRule }): string
	if not code then
		return ""
	end

	local out = {}
	local i = 1
	local len = #code

	while i <= len do
		local nextTemplate = findSoonest(code, i, { "{{", "{%", "{#" })

		if not nextTemplate then
			table.insert(out, highlightByRegex(code:sub(i), templatedLanguage))
			break
		end

		if nextTemplate > i then
			table.insert(out, highlightByRegex(code:sub(i, nextTemplate - 1), templatedLanguage))
		end

		local opener = code:sub(nextTemplate, nextTemplate + 1)

		if opener == "{{" then
			local html, nextI = highlightTemplateBlock(code, nextTemplate, "{{", "}}")
			table.insert(out, html)
			i = nextI
		elseif opener == "{%" then
			local html, nextI = highlightTemplateBlock(code, nextTemplate, "{%", "%}")
			table.insert(out, html)
			i = nextI
		elseif opener == "{#" then
			local closeAt = code:find("#}", nextTemplate + 2, true)

			if closeAt then
				table.insert(out, span("syn-comment", code:sub(nextTemplate, closeAt + 1)))
				i = closeAt + 2
			else
				table.insert(out, span("syn-comment", code:sub(nextTemplate)))
				break
			end
		end
	end

	return table.concat(out)
end

local LUAU_RULES = {
	rule("syn-comment", [==[\G--\[(=*)\[.*?\]\1\]]==], "s"),
	rule("syn-str", [==[\G\[(=*)\[.*?\]\1\]]==], "s"),

	rule("syn-comment", [==[\G--[^\r\n]*]==]),

	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'(?:\\.|[^'\\\r\n])*']==]),

	rule("syn-num", [==[\G0[xX][0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?[0-9_]+)?]==]),
	rule("syn-num", [==[\G\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?[\d_]+)?]==]),

	rule("syn-self", [==[\Gself\b]==]),

	rule(
		"syn-kw",
		[==[\G(?:and|break|continue|do|else|elseif|end|false|for|function|if|in|local|const|nil|not|or|repeat|return|then|true|until|while|type|export)\b]==]
	),

	rule(
		"syn-builtin",
		[==[\G(?:print|warn|error|require|tostring|tonumber|typeof|select|pcall|xpcall|pairs|ipairs|next|unpack|rawget|rawset|setmetatable|getmetatable|assert|string|table|math|coroutine|buffer)\b]==]
	),

	rule("syn-fn", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*\()]==]),
	rule("syn-fn", [==[\G(?<=:)[A-Za-z_][A-Za-z0-9_]*]==]),

	rule(nil, [==[\G[A-Za-z_][A-Za-z0-9_]*]==]),
}

local SHELL_RULES = {
	rule("syn-comment", [==[\G#[^\r\n]*]==]),

	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'[^'\r\n]*']==]),

	rule("syn-builtin", [==[\G\$[A-Za-z_][A-Za-z0-9_]*]==]),
	rule("syn-kw", [==[\G--?[A-Za-z0-9_-]+]==]),
	rule("syn-num", [==[\G[+-]?\d+(?:\.\d+)?]==]),

	rule("syn-fn", [==[\G(?m)(?<=^|\n)\s*\K\S+]==]),

	-- Not really a real syn type, but stops weird mixing of numbers in the middle of text
	rule("syn-text", [==[\G\S+]==]),
}

local JSON_RULES = {
	rule("syn-param", [==[\G"(?:\\.|[^"\\\r\n])*"(?=\s*:)]==]),
	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),

	rule("syn-num", [==[\G-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?]==]),
	rule("syn-kw", [==[\G(?:true|false|null)\b]==]),

	rule("syn-punct", [==[\G[\[\]{}:,]]==]),
}

local TOML_RULES = {
	rule("syn-comment", [==[\G#[^\r\n]*]==]),

	rule("syn-str", [==[\G"""(?:.|\r|\n)*?"""]==]),
	rule("syn-str", [==[\G'''(?:.|\r|\n)*?''']==]),
	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'[^'\r\n]*']==]),

	rule("syn-type", [==[\G\[\[[^\]\r\n]+\]\]]==]),
	rule("syn-type", [==[\G\[[^\]\r\n]+\]]==]),

	rule("syn-num", [==[\G[+-]?\d{4}-\d{2}-\d{2}[Tt ][0-9:.]+(?:Z|[+-]\d{2}:\d{2})?]==]),
	rule("syn-num", [==[\G[+-]?\d{4}-\d{2}-\d{2}]==]),
	rule("syn-num", [==[\G\d{2}:\d{2}:\d{2}(?:\.\d+)?]==]),

	rule("syn-kw", [==[\G(?:true|false|inf|nan)\b]==]),

	rule("syn-num", [==[\G[+-]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+)]==]),
	rule("syn-num", [==[\G[+-]?\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?[\d_]+)?]==]),

	rule("syn-param", [==[\G[A-Za-z_][A-Za-z0-9_-]*(?=\s*(?:=|\.))]==]),

	rule("syn-punct", [==[\G[=.,\[\]{}]]==]),
}

local SIGNATURE_RULES = {
	rule("syn-comment", [==[\G--[^\r\n]*]==]),

	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'(?:\\.|[^'\\\r\n])*']==]),

	rule("syn-num", [==[\G0[xX][0-9a-fA-F_]+]==]),
	rule("syn-num", [==[\G\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?[\d_]+)?]==]),

	rule("syn-kw", [==[\G(?:export|type|read|write|typeof|true|false|nil)\b]==]),
	rule("syn-self", [==[\Gself\b]==]),

	rule("syn-fn", [==[\G[.:][A-Za-z_][A-Za-z0-9_]*(?=\s*(?:<|\())]==]),
	rule("syn-fn", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*\()]==]),

	rule("syn-param", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*:)]==]),

	rule("syn-type", [==[\G[A-Z][A-Za-z0-9_]*]==]),
	rule("syn-type", [==[\G(?:any|unknown|never|string|number|boolean|thread|buffer|nil)\b]==]),

	-- Useful for callback: ((err: any, connection: Connection<T...>) → ())
	-- Lowercase callback argument names before :
	rule("syn-param", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*:)]==]),

	-- ... in T... / (...)
	rule("syn-punct", [==[\G%.%.%.]==]),

	-- Punctuation
	rule("syn-punct", [==[\G->|→|[:.<>{}()[\],.?|&=]]==]),

	-- Fallback identifier
	rule(nil, [==[\G[A-Za-z_][A-Za-z0-9_]*]==]),
}

local YAML_RULES = {
	rule("syn-comment", [==[\G#[^\r\n]*]==]),
	rule("syn-param", [==[\G[A-Za-z0-9_.-]+(?=\s*:)]==]),

	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'[^'\r\n]*']==]),

	rule("syn-kw", [==[\G(?:true|false|null|yes|no|on|off)\b]==]),
	rule("syn-num", [==[\G[+-]?\d+(?:\.\d+)?]==]),

	rule("syn-punct", [==[\G[-\[\]{}:,|>]]==]),
}

local INI_RULES = {
	rule("syn-comment", [==[\G[;#][^\r\n]*]==]),
	rule("syn-type", [==[\G\[[^\]\r\n]+\]]==]),
	rule("syn-param", [==[\G[A-Za-z0-9_.-]+(?=\s*=)]==]),

	rule("syn-str", [==[\G"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\G'[^'\r\n]*']==]),

	rule("syn-kw", [==[\G(?:true|false|yes|no|on|off)\b]==]),
	rule("syn-num", [==[\G[+-]?\d+(?:\.\d+)?]==]),

	rule("syn-punct", [==[\G=]==]),
}

local DIFF_RULES = {
	rule("syn-comment", [==[\G@@[^\r\n]*]==]),
	rule("syn-kw", [==[\G\+\+\+[^\r\n]*]==]),
	rule("syn-kw", [==[\G---[^\r\n]*]==]),
	rule("syn-str", [==[\G\+[^\r\n]*]==]),
	rule("syn-comment", [==[\G-[^\r\n]*]==]),
}

local XML_RULES = {
	rule("syn-comment", [==[\G<!--(?:.|\r|\n)*?-->]==]),
	rule("syn-kw", [==[\G<!\[CDATA\[(?:.|\r|\n)*?\]\>]==]),
	rule("syn-type", [==[\G</?[A-Za-z_][A-Za-z0-9_:-]*]==]),
	rule("syn-param", [==[\G\s+[A-Za-z_][A-Za-z0-9_:-]*(?=\s*=)]==]),
	rule("syn-str", [==[\G"(?:\\.|[^"])*"]==]),
	rule("syn-str", [==[\G'[^']*']==]),
	rule("syn-punct", [==[\G/?>]==]),
}

local HTML_RULES = {
	-- Comments / doctype / CDATA
	rule("syn-comment", [==[\G<!--[\s\S]*?-->]==]),
	rule("syn-kw", [==[\G<!doctype\b[^>]*>]==], "i"),
	rule("syn-kw", [==[\G<!\[CDATA\[[\s\S]*?\]\]>]==]),

	-- Closing/opening tag names
	rule("syn-type", [==[\G</?[A-Za-z][A-Za-z0-9:-]*]==]),

	-- Attribute names
	rule("syn-param", [==[\G\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?=\s*(?:=|/?>))]==]),

	-- Attribute values
	rule("syn-str", [==[\G"(?:&[A-Za-z0-9#]+;|[^"])*"]==]),
	rule("syn-str", [==[\G'(?:&[A-Za-z0-9#]+;|[^'])*']==]),
	rule("syn-str", [==[\G[^\s"'=<>`]+(?=\s|/?>)]==]),

	-- Entities
	rule("syn-kw", [==[\G&(?:[A-Za-z][A-Za-z0-9]+|#[0-9]+|#x[0-9A-Fa-f]+);]==]),

	-- Punctuation
	rule("syn-punct", [==[\G/?>]==]),
	rule("syn-punct", [==[\G=]==]),
}

local MARKDOWN_RULES = {
	-- Fenced code block markers
	rule("syn-fn", [==[\G(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\r\n]*]==]),

	-- ATX headings
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}#{1,6}(?=\s)]==]),

	-- Setext underline markers only
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}=+[ \t]*$]==]),
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}-+[ \t]*$]==]),

	-- Blockquotes, including nested quote markers: >, >>, > >
	rule("syn-fn", [==[\G(?m)^[ \t]{0,3}(?:>[ \t]?)+]==]),

	-- Thematic breaks
	rule("syn-fn", [==[\G(?m)^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$]==]),

	-- Admonitions: :::warning / :::
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}:::[A-Za-z0-9_-]*[ \t]*$]==]),

	-- Tabs: === Tab, ===+ Tab, ===! Tab, ===
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}===[+!]?(?:[ \t]+[^\r\n]+)?[ \t]*$]==]),

	-- Link definitions / footnote definitions
	rule("syn-param", [==[\G\[\^[^\]\r\n]+\](?!:)]==]),
	rule("syn-param", [==[\G(?m)^[ \t]{0,3}\[[^\]\r\n]+\]:]==]),
	rule("syn-param", [==[\G(?m)^[ \t]{0,3}\[\^[^\]\r\n]+\]:]==]),

	-- GFM / PHP Markdown Extra table separator rows
	rule("syn-fn", [==[\G(?m)^[ \t]*\|?(?:[ \t]*:?-{3,}:?[ \t]*\|)+[ \t]*:?-{3,}:?[ \t]*\|?[ \t]*$]==]),

	-- Table pipes
	rule("syn-fn", [==[\G\|]==]),

	-- Lists and task lists
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}[-+*][ \t]+(?=\[[ xX]\][ \t]+)]==]),
	rule("syn-fn", [==[\G\[[ xX]\]]==]),
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}[-+*][ \t]+]==]),
	rule("syn-kw", [==[\G(?m)^[ \t]{0,3}\d+[.)][ \t]+]==]),

	-- Inline code
	rule("syn-str", [==[\G`+[^`\r\n]*`+]==]),

	-- Images / links / wikilinks
	rule("syn-fn", [==[\G!\[]==]),
	rule("syn-str", [==[\G\[\[[^\]\r\n]+(?:\|[^\]\r\n]+)?\]\]]==]),
	rule("syn-fn", [==[\G[\[\]]]==]),
	rule("syn-str", [==[\G\([^) \t\r\n]+(?:\s+"[^"]*")?\)]==]),
	rule("syn-str", [==[\G<https?://[^>\s]+>]==]),
	rule("syn-str", [==[\Ghttps?://[^\s<>()]+]==]),

	-- Footnote references
	rule("syn-param", [==[\G\[\^[^\]\r\n]+\]]==]),

	-- Strikethrough, bold, italic markers
	rule("syn-fn", [==[\G~~?]==]),
	rule("syn-fn", [==[\G\*\*\*|___]==]),
	rule("syn-fn", [==[\G\*\*|__]==]),
	rule("syn-fn", [==[\G\*|_]==]),

	-- Entities
	rule("syn-kw", [==[\G&(?:[A-Za-z][A-Za-z0-9]+|#[0-9]+|#x[0-9A-Fa-f]+);]==]),

	-- Escaped punctuation
	rule("syn-fn", [==[\G\\[\\`*{}\[\]()#+\-.!_|>~:]]==]),
}

local C_RULES = {
	-- Preprocessor
	rule(
		"syn-kw",
		[==[\G(?m)^[ \t]*#[ \t]*(?:include|define|undef|if|ifdef|ifndef|elif|else|endif|pragma|error|warning|line)\b[^\r\n]*]==]
	),

	-- Comments
	rule("syn-comment", [==[\G//[^\r\n]*]==]),
	rule("syn-comment", [==[\G/\*[\s\S]*?\*/]==]),

	-- Strings / chars
	rule("syn-str", [==[\GL?"(?:\\.|[^"\\\r\n])*"]==]),
	rule("syn-str", [==[\GL?'(?:\\.|[^'\\\r\n])*']==]),

	-- Numbers
	rule("syn-num", [==[\G0[xX][0-9A-Fa-f]+(?:[uUlL]*)]==]),
	rule("syn-num", [==[\G(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?[fFlL]?]==]),
	rule("syn-num", [==[\G\d+(?:[eE][+-]?\d+)?[uUlL]*]==]),

	-- Keywords
	rule(
		"syn-kw",
		[==[\G(?:auto|break|case|const|continue|default|do|else|enum|extern|for|goto|if|inline|register|restrict|return|sizeof|static|struct|switch|typedef|union|volatile|while|_Alignas|_Alignof|_Atomic|_Bool|_Complex|_Generic|_Imaginary|_Noreturn|_Static_assert|_Thread_local)\b]==]
	),

	-- Builtin/common types
	rule(
		"syn-type",
		[==[\G(?:void|char|short|int|long|float|double|signed|unsigned|bool|size_t|ssize_t|ptrdiff_t|intptr_t|uintptr_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|FILE)\b]==]
	),

	-- Constants/macros
	rule("syn-kw", [==[\G(?:NULL|true|false|stdin|stdout|stderr)\b]==]),

	-- Function calls / declarations
	rule("syn-fn", [==[\G[A-Za-z_][A-Za-z0-9_]*(?=\s*\()]==]),

	-- ALL_CAPS macros
	rule("syn-builtin", [==[\G[A-Z_][A-Z0-9_]{2,}\b]==]),

	-- Identifiers
	rule(nil, [==[\G[A-Za-z_][A-Za-z0-9_]*]==]),

	-- Operators / punctuation
	rule("syn-punct", [==[\G->|\+\+|--|==|!=|<=|>=|&&|\|\||<<|>>|[{}()[\];,.:?~!%^&*+\-/|<>=#]]==]),
}

return {
	luau = function(code: string): string
		return highlightByRegex(code, LUAU_RULES)
	end,
	LUAU_SIGNATURE = function(code: string): string
		return highlightByRegex(code, SIGNATURE_RULES)
	end,
	sh = function(code: string): string
		return highlightByRegex(code, SHELL_RULES)
	end,
	toml = function(code: string): string
		return highlightByRegex(code, TOML_RULES)
	end,
	json = function(code: string): string
		return highlightByRegex(code, JSON_RULES)
	end,
	yaml = function(code: string): string
		return highlightByRegex(code, YAML_RULES)
	end,
	ini = function(code: string): string
		return highlightByRegex(code, INI_RULES)
	end,
	diff = function(code: string): string
		return highlightByRegex(code, DIFF_RULES)
	end,
	xml = function(code: string): string
		return highlightByRegex(code, XML_RULES)
	end,
	html = function(code: string): string
		return highlightByRegex(code, HTML_RULES)
	end,
	md = function(code: string): string
		return highlightByRegex(code, MARKDOWN_RULES)
	end,
	c = function(code: string): string
		return highlightByRegex(code, C_RULES)
	end,
	template = function(code: string): string
		return highlightTemplated(code, {})
	end,
	templateHtml = function(code: string): string
		return highlightTemplated(code, HTML_RULES)
	end,

	htmlEscape = htmlEscape,
} :: { [string]: (string) -> string }
