--[=[
	Text-processing helpers for everyday string manipulation.

	This library provides a small set of "boring but useful" text utilities:
	indentation helpers, wrapping and truncation, prefix/suffix checks, simple
	literal substring counting, and configurable trimming.

	The functions in this library operate on Lua strings as byte sequences. They
	do not perform Unicode-aware grapheme segmentation, display-width
	calculation, locale-sensitive casing, or language-aware hyphenation. That
	makes them a good fit for:

	- logs and diagnostics
	- source-like text blocks
	- configuration and protocol text
	- formatting machine-oriented strings such as identifiers or base64 blocks

	Line-oriented helpers normalize output line breaks to `\n`. Where wrapping
	or truncation takes a `width`, that width is measured using Lua's `#string`
	length.
]=]

local text = {}

local DEFAULT_TRIM_CHARACTERS = { " ", "\t", "\n", "\r", "\v", "\f" }

local function buildCharacterSet(characters: { string }?): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, character in characters or DEFAULT_TRIM_CHARACTERS do
		assert(#character > 0, "trim characters must not contain empty strings")
		set[character] = true
	end
	return set
end

local function splitLines(value: string): { string }
	local lines = {}
	local startIndex = 1

	while startIndex <= #value do
		local newlineStart = string.find(value, "\n", startIndex, true)
		if newlineStart == nil then
			break
		end

		local lineEnd = newlineStart - 1
		if lineEnd >= startIndex and string.sub(value, lineEnd, lineEnd) == "\r" then
			lineEnd -= 1
		end

		table.insert(lines, string.sub(value, startIndex, lineEnd))
		startIndex = newlineStart + 1
	end

	table.insert(lines, string.sub(value, startIndex))

	return lines
end

local function joinLines(lines: { string }): string
	return table.concat(lines, "\n")
end

local function repeatSpaces(columns: number): string
	assert(columns >= 0 and math.floor(columns) == columns, "columns must be a non-negative integer")
	return string.rep(" ", columns)
end

local function trimOneSide(value: string, fromStart: boolean, characterSet: { [string]: boolean }): string
	if value == "" then
		return value
	end

	if fromStart then
		local index = 1
		while index <= #value do
			local char = string.sub(value, index, index)
			if not characterSet[char] then
				break
			end
			index += 1
		end
		return string.sub(value, index)
	end

	local index = #value
	while index >= 1 do
		local char = string.sub(value, index, index)
		if not characterSet[char] then
			break
		end
		index -= 1
	end
	return string.sub(value, 1, index)
end

--[=[
	Removes shared leading indentation from lines in a string.

	When `columns` is omitted, the smallest indentation shared by all
	non-blank lines is removed. When `columns` is provided, up to that many
	leading spaces or tabs are removed from each line. Blank lines do not
	contribute to the inferred indentation level. Output uses `\n` line
	endings.

	@param value The string whose lines should be unindented.
	@param columns Optional explicit number of leading columns to remove.
	@return string -- The unindented string.
]=]
function text.unindent(value: string, columns: number?): string
	local lines = splitLines(value)
	local minIndent = columns

	if minIndent ~= nil then
		assert(minIndent >= 0 and math.floor(minIndent) == minIndent, "columns must be a non-negative integer")
	end

	if minIndent == nil then
		for _, line in lines do
			if line:match("^%s*$") == nil then
				local indent = #(line:match("^[ \t]*") or "")
				if minIndent == nil or indent < minIndent then
					minIndent = indent
				end
			end
		end
	end

	if minIndent == nil or minIndent == 0 then
		return value
	end

	for index, line in lines do
		local remove = 0
		while remove < minIndent and remove < #line do
			local char = string.sub(line, remove + 1, remove + 1)
			if char ~= " " and char ~= "\t" then
				break
			end
			remove += 1
		end
		lines[index] = string.sub(line, remove + 1)
	end

	return joinLines(lines)
end

--[=[
	Prefixes each line in a string with spaces.

	Blank lines are indented too. Output uses `\n` as the line separator.

	@param value The string whose lines should be indented.
	@param columns Number of spaces to insert at the start of each line.
	@return string -- The indented string.
]=]
function text.indent(value: string, columns: number): string
	local prefix = repeatSpaces(columns)
	local lines = splitLines(value)

	for index, line in lines do
		lines[index] = prefix .. line
	end

	return joinLines(lines)
end

--[=[
	Wraps text to a target width.

	Wrapping prefers whitespace boundaries. `breakWordThreshold` controls
	when word-breaking is allowed or preferred:

	- `nil` or `0`: never break words
	- `1` or `2`: break only words that are themselves longer than `width`
	- `3+`: also prefer word-breaking when a whitespace wrap would leave at
	  least that many unused columns at the end of the line

	When a word is broken, `breakWordMarker` is appended to the broken
	fragment and its width counts against `width`. The marker defaults to
	`"-"`. Use `""` to break without a marker.

	Lines are measured in bytes and output uses `\n` line endings.

	@param value The string to wrap.
	@param width Maximum width of each output line, measured in bytes.
	@param breakWordThreshold Controls when word-breaking is allowed or preferred.
	@param breakWordMarker Marker appended to broken word fragments.
	@return string -- The wrapped string.
]=]
function text.wrap(value: string, width: number, breakWordThreshold: number?, breakWordMarker: string?): string
	assert(width > 0 and math.floor(width) == width, "width must be a positive integer")

	local threshold = breakWordThreshold or 0
	assert(threshold >= 0 and math.floor(threshold) == threshold, "breakWordThreshold must be a non-negative integer")
	local marker = breakWordMarker
	if marker == nil and threshold >= 1 then
		marker = "-"
	end
	marker = marker or ""
	local markerWidth = #marker

	local whitespaceSet = buildCharacterSet()
	local wrappedLines = {}
	for _, rawLine in splitLines(value) do
		if rawLine == "" then
			table.insert(wrappedLines, "")
		else
			local line = rawLine
			while #line > width do
				local segment = string.sub(line, 1, width)
				local breakAt = segment:match("^.*()%s+[^%s]*$")
				local boundaryChar = string.sub(line, width + 1, width + 1)
				if boundaryChar ~= "" and whitespaceSet[boundaryChar] then
					breakAt = width
				end
				if breakAt == nil or breakAt == 0 then
					if threshold >= 1 and markerWidth < width then
						local fragmentWidth = width - markerWidth
						table.insert(wrappedLines, string.sub(line, 1, fragmentWidth) .. marker)
						line = string.sub(line, fragmentWidth + 1)
						continue
					end

					local nextWhitespace = string.find(line, "%s")
					if nextWhitespace == nil then
						table.insert(wrappedLines, line)
						line = ""
					else
						table.insert(wrappedLines, string.sub(line, 1, nextWhitespace - 1))
						line = trimOneSide(string.sub(line, nextWhitespace + 1), true, whitespaceSet)
					end
					continue
				end

				local prefix = trimOneSide(string.sub(line, 1, breakAt), false, whitespaceSet)
				local rest = trimOneSide(string.sub(line, (breakAt :: number) + 1), true, whitespaceSet)

				if threshold >= 3 and markerWidth < width then
					local gap = width - #prefix
					local separatorWidth = if prefix == "" then 0 else 1
					local available = gap - separatorWidth
					if gap >= threshold and available > markerWidth then
						local fragmentLength = available - markerWidth
						table.insert(
							wrappedLines,
							if prefix == ""
								then string.sub(rest, 1, fragmentLength) .. marker
								else prefix .. " " .. string.sub(rest, 1, fragmentLength) .. marker
						)
						line = string.sub(rest, fragmentLength + 1)
						continue
					end
				end

				table.insert(wrappedLines, prefix)
				line = rest
			end
			if line ~= "" then
				table.insert(wrappedLines, line)
			end
		end
	end

	return joinLines(wrappedLines)
end

--[=[
	Shortens a string to a maximum width, optionally appending a marker.

	The marker counts against the width budget. If the marker itself is wider
	than `width`, the marker is returned unchanged.

	@param value The string to truncate.
	@param width Maximum output width, measured in bytes.
	@param suffix Optional marker appended to truncated output.
	@return string -- The original or truncated string.
]=]
function text.truncate(value: string, width: number, suffix: string?): string
	assert(width >= 0 and math.floor(width) == width, "width must be a non-negative integer")

	local suffix_ = suffix or ""
	if #suffix_ > width then
		return suffix_
	end
	if #value <= width then
		return value
	end

	return string.sub(value, 1, width - #suffix_) .. suffix_
end

--[=[
	Counts non-overlapping literal occurrences of a substring.

	This uses plain substring matching rather than Lua patterns.

	@param value The string to search within.
	@param needle The literal substring to count.
	@return number -- Number of non-overlapping matches.
]=]
function text.count(value: string, needle: string): number
	assert(needle ~= "", "needle must not be empty")

	local count = 0
	local startIndex = 1
	while true do
		local foundStart, foundEnd = string.find(value, needle, startIndex, true)
		if foundStart == nil or foundEnd == nil then
			break
		end
		count += 1
		startIndex = foundEnd + 1
	end
	return count
end

--[=[
	Returns whether a string begins with the given prefix.

	@param value The string to inspect.
	@param prefix The prefix to test for.
	@return boolean -- `true` when `value` starts with `prefix`.
]=]
function text.startsWith(value: string, prefix: string): boolean
	return string.sub(value, 1, #prefix) == prefix
end

--[=[
	Returns whether a string ends with the given suffix.

	@param value The string to inspect.
	@param suffix The suffix to test for.
	@return boolean -- `true` when `value` ends with `suffix`.
]=]
function text.endsWith(value: string, suffix: string): boolean
	return suffix == "" or string.sub(value, -#suffix) == suffix
end

--[=[
	Removes a prefix when it is present.

	If `value` does not start with `prefix`, the original string is returned.

	@param value The string to inspect.
	@param prefix The prefix to remove.
	@return string -- The string without the prefix, or the original string.
]=]
function text.removeStart(value: string, prefix: string): string
	if text.startsWith(value, prefix) then
		return string.sub(value, #prefix + 1)
	end
	return value
end

--[=[
	Removes a suffix when it is present.

	If `value` does not end with `suffix`, the original string is returned.

	@param value The string to inspect.
	@param suffix The suffix to remove.
	@return string -- The string without the suffix, or the original string.
]=]
function text.removeEnd(value: string, suffix: string): string
	if text.endsWith(value, suffix) then
		return string.sub(value, 1, #value - #suffix)
	end
	return value
end

--[=[
	Trims characters from one or both sides of a string.

	When `trimCharacters` is omitted, ASCII whitespace characters are removed:
	space, tab, line feed, carriage return, vertical tab, and form feed.
	Characters are matched literally and individually rather than as Lua
	patterns.

	@param value The string to trim.
	@param side Which side to trim: `"start"`, `"end"`, or `"both"`.
	@param trimCharacters Characters that should be removed while scanning inward.
	@return string -- The trimmed string.
]=]
function text.trim(value: string, side: ("start" | "end" | "both")?, trimCharacters: { string }?): string
	local characterSet = buildCharacterSet(trimCharacters)
	local trimSide = side or "both"

	if trimSide == "start" then
		return trimOneSide(value, true, characterSet)
	end
	if trimSide == "end" then
		return trimOneSide(value, false, characterSet)
	end
	assert(trimSide == "both", "side must be 'start', 'end', or 'both'")
	return trimOneSide(trimOneSide(value, true, characterSet), false, characterSet)
end

return table.freeze(text)
