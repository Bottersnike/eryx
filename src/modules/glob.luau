--[=[
	Path globbing for strings, arrays, and filesystem traversal.

	Supported pattern features:
	- `*`  : zero or more characters (within one path segment)
	- `?`  : exactly one character (within one path segment)
	- `[abc]`, `[a-z]`, `[!abc]` : character classes
	- `**` : zero or more path segments (globstar, segment-only)
	- `\\` escapes metacharacters for literal matching

	The engine is pure Luau and shared by both array matching and filesystem
	traversal helpers.
]=]

local fs = require("@eryx/fs")

local glob = {}

--[=[
	Options used by string/array-based glob matching.
]=]
export type MatchOptions = {
	--- Whether wildcard segments may match names beginning with `.`.
	--- Defaults to `false`.
	includeHidden: boolean?,
	--- Whether comparisons are case-sensitive.
	--- Defaults to `true`.
	caseSensitive: boolean?,
}

--[=[
	Options used by filesystem glob expansion.
	Extends [[MatchOptions]] with traversal controls.
]=]
export type GlobOptions = MatchOptions & {
	--- Root directory used for filesystem traversal.
	--- Defaults to `"."`.
	root: string?,
	--- Ignore pattern(s) evaluated against relative paths.
	--- Can be a single pattern or an array of patterns.
	ignore: string | { string }?,
	--- Whether directory symlinks should be traversed recursively.
	--- Defaults to `false`.
	followSymlinks: boolean?,
	--- If `true`, only files are returned.
	onlyFiles: boolean?,
	--- If `true`, only directories are returned.
	onlyDirectories: boolean?,
}

--[=[
	A compiled glob pattern that can be reused for repeated matching.
]=]
export type Compiled = {
	--- The original pattern string used for compilation.
	read pattern: string,
	--- Match a candidate path against this compiled pattern.
	read match: (self: Compiled, path: string) -> boolean,
}

type CharClass = {
	negated: boolean,
	chars: { [string]: boolean },
	ranges: { { number } },
}

type SegmentToken =
	{ kind: "literal", value: string }
	| { kind: "star" }
	| { kind: "qmark" }
	| { kind: "class", value: CharClass }

type Segment = {
	kind: "segment",
	tokens: { SegmentToken },
	startsWithLiteralDot: boolean,
}

type GlobStar = {
	kind: "globstar",
}

type Part = Segment | GlobStar

local function normalize(path: string): string
	local out = string.gsub(path, "\\", "/")
	out = string.gsub(out, "/+", "/")
	out = string.gsub(out, "^%./", "")
	if #out > 1 then
		out = string.gsub(out, "/$", "")
	end
	return out
end

local function splitPath(path: string): { string }
	local normalized = normalize(path)
	local parts = {}
	for part in string.gmatch(normalized, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

local function startsWithDot(name: string): boolean
	return string.sub(name, 1, 1) == "."
end

local function parseClass(raw: string, startIndex: number): (CharClass?, number?)
	local i = startIndex + 1
	if i > #raw then
		return nil, nil
	end

	local negated = false
	local first = string.sub(raw, i, i)
	if first == "!" or first == "^" then
		negated = true
		i += 1
	end

	local class: CharClass = {
		negated = negated,
		chars = {},
		ranges = {},
	}

	local sawAny = false
	local prevChar: string? = nil
	local prevWasLiteral = false

	while i <= #raw do
		local ch = string.sub(raw, i, i)
		if ch == "]" and sawAny then
			return class, i
		end

		local literal = ch
		if ch == "\\" and i < #raw then
			i += 1
			literal = string.sub(raw, i, i)
		end

		if literal == "-" and prevWasLiteral and i < #raw then
			local nextIndex = i + 1
			local nextChar = string.sub(raw, nextIndex, nextIndex)
			if nextChar ~= "]" then
				if nextChar == "\\" and nextIndex < #raw then
					nextIndex += 1
					nextChar = string.sub(raw, nextIndex, nextIndex)
				end
				local startByte = string.byte(prevChar :: string)
				local endByte = string.byte(nextChar)
				if startByte <= endByte then
					table.insert(class.ranges, { startByte, endByte })
				else
					table.insert(class.ranges, { endByte, startByte })
				end
				class.chars[prevChar :: string] = nil
				prevWasLiteral = false
				prevChar = nil
				i = nextIndex + 1
				sawAny = true
				continue
			end
		end

		class.chars[literal] = true
		prevChar = literal
		prevWasLiteral = true
		i += 1
		sawAny = true
	end

	return nil, nil
end

local function parseSegment(raw: string): Segment
	local tokens: { SegmentToken } = {}
	local i = 1

	while i <= #raw do
		local ch = string.sub(raw, i, i)

		if ch == "\\" then
			if i < #raw then
				i += 1
				table.insert(tokens, { kind = "literal" :: "literal", value = string.sub(raw, i, i) })
			else
				table.insert(tokens, { kind = "literal" :: "literal", value = "\\" })
			end
		elseif ch == "*" then
			table.insert(tokens, { kind = "star" :: "star" })
		elseif ch == "?" then
			table.insert(tokens, { kind = "qmark" :: "qmark" })
		elseif ch == "[" then
			local class, endIndex = parseClass(raw, i)
			if class and endIndex then
				table.insert(tokens, { kind = "class" :: "class", value = class })
				i = endIndex
			else
				table.insert(tokens, { kind = "literal" :: "literal", value = "[" })
			end
		else
			table.insert(tokens, { kind = "literal" :: "literal", value = ch })
		end

		i += 1
	end

	local startsWithLiteralDot = false
	if #tokens > 0 then
		local t = tokens[1]
		if t.kind == "literal" and t.value == "." then
			startsWithLiteralDot = true
		end
	end

	return {
		kind = "segment",
		tokens = tokens,
		startsWithLiteralDot = startsWithLiteralDot,
	}
end

local function splitPattern(pattern: string): { string }
	local segments = {}
	local chunk = table.create(#pattern)
	local chunkLen = 0
	local i = 1

	while i <= #pattern do
		local ch = string.sub(pattern, i, i)
		if ch == "/" then
			table.insert(segments, table.concat(chunk, "", 1, chunkLen))
			chunkLen = 0
		elseif ch == "\\" then
			if i < #pattern then
				chunkLen += 1
				chunk[chunkLen] = "\\"
				chunkLen += 1
				chunk[chunkLen] = string.sub(pattern, i + 1, i + 1)
				i += 1
			else
				chunkLen += 1
				chunk[chunkLen] = "\\"
			end
		else
			chunkLen += 1
			chunk[chunkLen] = ch
		end
		i += 1
	end

	table.insert(segments, table.concat(chunk, "", 1, chunkLen))
	return segments
end

local function compileParts(pattern: string): { Part }
	local pieces = splitPattern(pattern)
	local parts: { Part } = {}
	for _, raw in pieces do
		if raw == "" then
			continue
		elseif raw == "**" then
			table.insert(parts, { kind = "globstar" :: "globstar" })
		else
			table.insert(parts, parseSegment(raw))
		end
	end
	return parts
end

local function classContains(class: CharClass, ch: string): boolean
	local inSet = class.chars[ch] == true
	if not inSet then
		local b = string.byte(ch)
		for _, range in class.ranges do
			if b >= range[1] and b <= range[2] then
				inSet = true
				break
			end
		end
	end

	if class.negated then
		return not inSet
	end
	return inSet
end

local function segmentMatches(segment: Segment, name: string, includeHidden: boolean): boolean
	if not includeHidden and startsWithDot(name) and not segment.startsWithLiteralDot then
		return false
	end

	local tokens = segment.tokens
	local star = 0
	local starNameIndex = 0
	local tokenIndex = 1
	local nameIndex = 1

	while nameIndex <= #name do
		local token = tokens[tokenIndex]
		local ch = string.sub(name, nameIndex, nameIndex)

		if token and token.kind == "literal" and token.value == ch then
			tokenIndex += 1
			nameIndex += 1
		elseif token and token.kind == "qmark" then
			tokenIndex += 1
			nameIndex += 1
		elseif token and token.kind == "class" and classContains(token.value, ch) then
			tokenIndex += 1
			nameIndex += 1
		elseif token and token.kind == "star" then
			star = tokenIndex
			starNameIndex = nameIndex
			tokenIndex += 1
		elseif star > 0 then
			starNameIndex += 1
			nameIndex = starNameIndex
			tokenIndex = star + 1
		else
			return false
		end
	end

	while tokens[tokenIndex] and tokens[tokenIndex].kind == "star" do
		tokenIndex += 1
	end

	return tokenIndex > #tokens
end

local function compileInternal(pattern: string, options: MatchOptions?): (string) -> boolean
	local opts = options or ({} :: MatchOptions)
	local caseSensitive = if opts.caseSensitive ~= nil then opts.caseSensitive else true
	local includeHidden = if opts.includeHidden ~= nil then opts.includeHidden else false
	local parts = compileParts(if caseSensitive then pattern else string.lower(pattern))

	return function(path: string): boolean
		local normalized = normalize(path)
		if normalized == "" then
			return #parts == 0
		end

		local pathToMatch = if caseSensitive then normalized else string.lower(normalized)
		local names = splitPath(pathToMatch)
		local memo: { [string]: boolean } = {}

		local function walk(partIndex: number, nameIndex: number): boolean
			local key = tostring(partIndex) .. ":" .. tostring(nameIndex)
			local cached = memo[key]
			if cached ~= nil then
				return cached
			end

			if partIndex > #parts then
				local done = nameIndex > #names
				memo[key] = done
				return done
			end

			local part = parts[partIndex]
			if part.kind == "globstar" then
				local nextPart = partIndex + 1
				while nextPart <= #parts and parts[nextPart].kind == "globstar" do
					nextPart += 1
				end

				if nextPart > #parts then
					memo[key] = true
					return true
				end

				for i = nameIndex, #names + 1 do
					if walk(nextPart, i) then
						memo[key] = true
						return true
					end
				end

				memo[key] = false
				return false
			end

			if nameIndex > #names then
				memo[key] = false
				return false
			end

			local ok = segmentMatches(part :: Segment, names[nameIndex], includeHidden)
			if ok and walk(partIndex + 1, nameIndex + 1) then
				memo[key] = true
				return true
			end

			memo[key] = false
			return false
		end

		return walk(1, 1)
	end
end

local function normalizeIgnore(ignore: string | { string }?): { string }
	if ignore == nil then
		return {}
	end
	if type(ignore) == "string" then
		return { ignore }
	end
	return ignore
end

--[=[
	Escape glob metacharacters in `literal` so the result matches literally.

	@param literal string -- raw text to treat as a literal path fragment
	@return string -- escaped glob pattern
]=]
function glob.escape(literal: string): string
	return (string.gsub(literal, "([%*%?%[%]\\])", "\\%1"))
end

--[=[
	Return whether `pattern` contains unescaped glob metacharacters.

	@param pattern string -- pattern text to inspect
	@return boolean -- `true` when `*`, `?`, or `[` appears unescaped
]=]
function glob.hasMagic(pattern: string): boolean
	local i = 1
	while i <= #pattern do
		local ch = string.sub(pattern, i, i)
		if ch == "\\" then
			i += 2
			continue
		end
		if ch == "*" or ch == "?" or ch == "[" then
			return true
		end
		i += 1
	end
	return false
end

--[=[
	Compile a glob pattern into a reusable matcher object.

	@param pattern string -- glob pattern to compile
	@param options MatchOptions? -- matching behavior options
	@return Compiled -- frozen compiled matcher with `pattern` and `match`
]=]
function glob.compile(pattern: string, options: MatchOptions?): Compiled
	local matcher = compileInternal(pattern, options)
	local compiled = {
		pattern = pattern,
		match = function(self: Compiled, path: string): boolean
			return matcher(path)
		end,
	}
	return table.freeze(compiled)
end

--[=[
	Test whether `path` matches `pattern`.

	@param path string -- candidate path
	@param pattern string -- glob pattern
	@param options MatchOptions? -- matching behavior options
	@return boolean -- `true` when the path matches
]=]
function glob.match(path: string, pattern: string, options: MatchOptions?): boolean
	local matcher = compileInternal(pattern, options)
	return matcher(path)
end

--[=[
	Filter an array of paths, returning only entries that match `pattern`.

	@param paths {string} -- candidate paths
	@param pattern string -- glob pattern
	@param options MatchOptions? -- matching behavior options
	@return {string} -- matching paths in original order
]=]
function glob.filter(paths: { string }, pattern: string, options: MatchOptions?): { string }
	local matcher = compileInternal(pattern, options)
	local out = {}
	for _, path in paths do
		if matcher(path) then
			table.insert(out, path)
		end
	end
	return out
end

--[=[
	Create an iterator over entries in `paths` that match `pattern`.

	@param paths {string} -- candidate paths
	@param pattern string -- glob pattern
	@param options MatchOptions? -- matching behavior options
	@return () -> string? -- iterator yielding matching paths, then `nil`
]=]
function glob.gmatch(paths: { string }, pattern: string, options: MatchOptions?): () -> string?
	local matcher = compileInternal(pattern, options)
	local index = 0
	return function()
		while true do
			index += 1
			local value = paths[index]
			if value == nil then
				return nil
			end
			if matcher(value) then
				return value
			end
		end
	end
end

local function compileIgnoreMatchers(options: GlobOptions?): { (string) -> boolean }
	local ignores = normalizeIgnore(if options then options.ignore else nil)
	local out = {}
	for _, pattern in ignores do
		table.insert(out, compileInternal(pattern, options))
	end
	return out
end

local function isIgnored(path: string, ignoreMatchers: { (string) -> boolean }): boolean
	for _, matcher in ignoreMatchers do
		if matcher(path) then
			return true
		end
	end
	return false
end

--[=[
	Expand a filesystem glob relative to `options.root`.

	Returned paths are relative to the root and normalized to `/` separators.

	@param pattern string -- glob pattern to evaluate
	@param options GlobOptions? -- traversal and matching options
	@return {string} -- matched paths
]=]
function glob.glob(pattern: string, options: GlobOptions?): { string }
	local opts: GlobOptions = options or {}
	local root = opts.root or "."
	local rootNormalized = normalize(root)
	local matcher = compileInternal(pattern, opts)
	local ignoreMatchers = compileIgnoreMatchers(opts)
	local onlyFiles = opts.onlyFiles == true
	local onlyDirectories = opts.onlyDirectories == true
	local followSymlinks = opts.followSymlinks == true
	local results = {}

	local function walk(absDir: string, relDir: string)
		local entries = fs.listDir(absDir)
		table.sort(entries)
		for _, entry in entries do
			local abs = fs.path.join(absDir, entry)
			local rel = if relDir == "" then entry else relDir .. "/" .. entry
			local relNormalized = normalize(rel)
			local dir = fs.isDirectory(abs)

			if not isIgnored(relNormalized, ignoreMatchers) then
				if matcher(relNormalized) then
					if (not onlyFiles or not dir) and (not onlyDirectories or dir) then
						table.insert(results, relNormalized)
					end
				end

				if dir then
					local shouldWalk = true
					if not followSymlinks and fs.isSymlink(abs) then
						shouldWalk = false
					end
					if shouldWalk then
						walk(abs, relNormalized)
					end
				end
			end
		end
	end

	if fs.exists(rootNormalized) and fs.isDirectory(rootNormalized) then
		walk(rootNormalized, "")
	end

	return results
end

--[=[
	Create an iterator over filesystem glob results.

	@param pattern string -- glob pattern to evaluate
	@param options GlobOptions? -- traversal and matching options
	@return () -> string? -- iterator yielding matched paths, then `nil`
]=]
function glob.iglob(pattern: string, options: GlobOptions?): () -> string?
	local results = glob.glob(pattern, options)
	local i = 0
	return function()
		i += 1
		return results[i]
	end
end

return table.freeze(glob)
