--[=[
	PCRE2-based regular expression module.
	Supports Perl-compatible regex with compilation, matching, searching,
	replacement, and splitting.

	:::note Optional capability
	This module is a typed facade over an optional PCRE2 backend. In
	builds without PCRE2 support, `require("@eryx/regex")` fails
	immediately with a clear capability error.
	:::

	Flags string characters:
	- `i` = case-insensitive
	- `m` = multiline (^ and $ match line boundaries)
	- `s` = dotall (. matches newlines)
	- `x` = extended (ignore whitespace and # comments in pattern)
	- `u` = UTF-8 mode
	- `U` = ungreedy (swap greediness of quantifiers)
	- `n` = no auto capture (plain parentheses don't capture)
]=]

local capability = require("@eryx/capability")
local regex = {}

--[=[
	A compiled regular expression pattern.
]=]
export type Regex = setmetatable<{}, {
	__index: {
		--[=[
			Test if the subject matches this pattern.
			@param subject string -- the string to test
			@param offset number? -- 1-based start position (default 1)
			@return boolean
		]=]
		isMatch: (self: Regex, subject: string, offset: number?) -> boolean,

		--[=[
			Find the first match of this pattern in the subject.
			Returns nil if no match. The result table contains:
			- `match`: the full matched text
			- `start`: 1-based start position
			- `finish`: 1-based end position (inclusive)
			- `[1]`, `[2]`, ...: numbered capture groups
			- named fields for named capture groups
			@param subject string -- the string to search
			@param offset number? -- 1-based start position (default 1)
			@return MatchResult?
		]=]
		find: (self: Regex, subject: string, offset: number?) -> MatchResult?,

		--[=[
			Find all non-overlapping matches in the subject.
			@param subject string -- the string to search
			@return {MatchResult}
		]=]
		findAll: (self: Regex, subject: string) -> { MatchResult },

		--[=[
			Replace matches in the subject with a replacement string.
			The replacement supports `$0` (full match), `$1`, `${name}` backreferences.
			@param subject string -- the input string
			@param replacement string -- the replacement template
			@param limit number? -- max replacements (0 or nil = replace all)
			@return string
		]=]
		replace: (self: Regex, subject: string, replacement: string, limit: number?) -> string,

		--[=[
			Split the subject on matches of this pattern.
			If the pattern has captures, captured groups are included between splits.
			@param subject string -- the string to split
			@param limit number? -- max number of pieces (0 or nil = no limit)
			@return {string}
		]=]
		split: (self: Regex, subject: string, limit: number?) -> { string },

		--[=[
			Return the number of capture groups in the pattern.
			@return number
		]=]
		captureCount: (self: Regex) -> number,

		--[=[
			Return a table mapping named capture group names to their group numbers.
			@return {[string]: number}
		]=]
		namedCaptures: (self: Regex) -> { [string]: number },
	},
}>

--[=[
	Result of a regex match operation.
]=]
export type MatchResult = {
	match: string,
	start: number,
	finish: number,
	[number | string]: string?,
}

--[=[
	Compile a regex pattern into a reusable Regex object.
	@param pattern string -- the PCRE2 regular expression
	@param flags string? -- flag characters: i, m, s, x, u, U, n
	@return Regex
]=]
function regex.new(pattern: string, flags: string?): Regex
	return nil :: any
end

--[=[
	Test if a pattern matches a subject. Convenience function that
	compiles the pattern each call; use `regex.new()` for repeated use.
	@param pattern string -- the PCRE2 regular expression
	@param subject string -- the string to test
	@param flags string? -- flag characters
	@return boolean
]=]
function regex.isMatch(pattern: string, subject: string, flags: string?): boolean
	return nil :: any
end

--[=[
	Find the first match of a pattern in a subject.
	@param pattern string -- the PCRE2 regular expression
	@param subject string -- the string to search
	@param flags string? -- flag characters
	@return MatchResult?
]=]
function regex.find(pattern: string, subject: string, flags: string?): MatchResult?
	return nil :: any
end

--[=[
	Find all non-overlapping matches of a pattern in a subject.
	@param pattern string -- the PCRE2 regular expression
	@param subject string -- the string to search
	@param flags string? -- flag characters
	@return {MatchResult}
]=]
function regex.findAll(pattern: string, subject: string, flags: string?): { MatchResult }
	return nil :: any
end

--[=[
	Replace all matches of a pattern in a subject.
	Replacement supports `$0`, `$1`, `${name}` backreferences.
	@param pattern string -- the PCRE2 regular expression
	@param subject string -- the input string
	@param replacement string -- the replacement template
	@param flags string? -- flag characters
	@return string
]=]
function regex.replace(pattern: string, subject: string, replacement: string, flags: string?): string
	return nil :: any
end

--[=[
	Split a subject on all matches of a pattern.
	@param pattern string -- the PCRE2 regular expression
	@param subject string -- the string to split
	@param flags string? -- flag characters
	@return {string}
]=]
function regex.split(pattern: string, subject: string, flags: string?): { string }
	return nil :: any
end

--[=[
	Escape all PCRE2 metacharacters in a string so it can be used
	as a literal pattern.
	@param str string -- the string to escape
	@return string
]=]
function regex.escape(str: string): string
	return nil :: any
end

--- Compile-time flag constants (Exact values depend on PCRE2, and are not documented here.)
regex.CASELESS = 0 :: number
regex.MULTILINE = 0 :: number
regex.DOTALL = 0 :: number
regex.EXTENDED = 0 :: number
regex.UTF = 0 :: number
regex.UNGREEDY = 0 :: number
regex.NO_AUTO_CAPTURE = 0 :: number
regex.ANCHORED = 0 :: number
regex.ENDANCHORED = 0 :: number
regex.UCP = 0 :: number
regex.DUPNAMES = 0 :: number

return capability.require(
	"@eryx/_native/regex",
	"Regular expression support",
	"Enable PCRE2 support to use @eryx/regex."
) :: typeof(regex)
