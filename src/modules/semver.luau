--[=[
	Semantic version parsing, comparison, and range matching.

	Supported range selectors:
	- exact: `1.2.3`, `=1.2.3`
	- comparators: `<1.2.3`, `<=1.2.3`, `>1.2.3`, `>=1.2.3`
	- caret: `^1.2.3`
	- tilde: `~1.2.3`
	- AND by whitespace: `>=1.2.3 <2.0.0`
	- OR by `||`: `^1.2.3 || ^2.0.0`

	`^` means "compatible with this version". For stable versions it allows
	changes below the next major version:

	```text
	^1.2.3  :=  >=1.2.3 <2.0.0
	```

	For `0.x` versions, compatibility is narrower because `0.x` is considered
	unstable:

	```text
	^0.2.3  :=  >=0.2.3 <0.3.0
	^0.0.3  :=  >=0.0.3 <0.0.4
	```

	`~` means "approximately this version". It allows patch updates within the
	same minor version:

	```text
	~1.2.3  :=  >=1.2.3 <1.3.0
	```
]=]

export type Version = {
	major: number,
	minor: number,
	patch: number,
	prerelease: string?,
	build: string?,
}

export type ComparatorOp = "=" | "<" | "<=" | ">" | ">="

export type Comparator = {
	op: ComparatorOp,
	version: Version,
}

export type Range = {
	sets: { { Comparator } },
}

local semver = {}

local function fail(message: string): never
	error(message, 2)
end

local function isDigit(ch: string): boolean
	return ch >= "0" and ch <= "9"
end

local function isIdentifierChar(ch: string): boolean
	return (ch >= "0" and ch <= "9") or (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z") or ch == "-"
end

local function isNumericIdentifier(value: string): boolean
	if value == "" then
		return false
	end
	for i = 1, #value do
		if not isDigit(value:sub(i, i)) then
			return false
		end
	end
	return true
end

local function validateNumericPart(value: string, label: string): number
	if value == "" then
		fail(`missing {label} version number`)
	end
	if #value > 1 and value:sub(1, 1) == "0" then
		fail(`{label} version number must not contain leading zeroes`)
	end
	for i = 1, #value do
		if not isDigit(value:sub(i, i)) then
			fail(`{label} version number must be numeric`)
		end
	end
	return tonumber(value) :: number
end

local function splitIdentifiers(value: string, label: string, allowLeadingZeroNumeric: boolean): { string }
	local out = {}
	local index = 1
	while index <= #value + 1 do
		local dot = value:find(".", index, true)
		local part = if dot then value:sub(index, dot - 1) else value:sub(index)
		if part == "" then
			fail(`{label} identifiers must not be empty`)
		end
		for i = 1, #part do
			if not isIdentifierChar(part:sub(i, i)) then
				fail(`{label} identifiers may only contain ASCII letters, numbers, and hyphens`)
			end
		end
		if not allowLeadingZeroNumeric and isNumericIdentifier(part) and #part > 1 and part:sub(1, 1) == "0" then
			fail(`numeric {label} identifiers must not contain leading zeroes`)
		end
		table.insert(out, part)
		if not dot then
			break
		end
		index = dot + 1
	end
	return out
end

local function cloneVersion(value: Version): Version
	return {
		major = value.major,
		minor = value.minor,
		patch = value.patch,
		prerelease = value.prerelease,
		build = value.build,
	}
end

local function parseImpl(source: string): Version
	if type(source) ~= "string" then
		fail("version must be a string")
	end

	local buildPart: string? = nil
	local buildAt = source:find("+", 1, true)
	if buildAt then
		buildPart = source:sub(buildAt + 1)
		source = source:sub(1, buildAt - 1)
		if source:find("+", 1, true) or buildPart:find("+", 1, true) then
			fail("version must contain at most one build metadata section")
		end
	end

	local prereleasePart: string? = nil
	local prereleaseAt = source:find("-", 1, true)
	if prereleaseAt then
		prereleasePart = source:sub(prereleaseAt + 1)
		source = source:sub(1, prereleaseAt - 1)
	end

	local majorRaw, minorRaw, patchRaw, extra = source:match("^([^.]+)%.([^.]+)%.([^.]+)(.*)$")
	if not majorRaw or not minorRaw or not patchRaw or extra ~= "" then
		fail("version must be in major.minor.patch form")
		assert(false)
	end

	return {
		major = validateNumericPart(majorRaw, "major"),
		minor = validateNumericPart(minorRaw, "minor"),
		patch = validateNumericPart(patchRaw, "patch"),
		prerelease = if prereleasePart
			then table.concat(splitIdentifiers(prereleasePart, "prerelease", false), ".")
			else nil,
		build = if buildPart then table.concat(splitIdentifiers(buildPart, "build", true), ".") else nil,
	}
end

local function coerceVersion(value: Version | string): Version
	if type(value) == "string" then
		return parseImpl(value)
	end
	return value :: Version
end

--[=[
	Parse a SemVer string.
]=]
function semver.parse(source: string): Version
	return parseImpl(source)
end

--[=[
	Parse a SemVer string, returning nil instead of raising on invalid input.
]=]
function semver.tryParse(source: string): Version?
	local ok, parsed = pcall(parseImpl, source)
	if ok then
		return parsed
	end
	return nil
end

--[=[
	Return a normalized SemVer range string.
]=]
function semver.formatRange(range: Range): string
	local components = {}
	for _, i in range.sets do
		local sub = {}
		for _, j in i do
			table.insert(sub, j.op .. semver.format(j.version))
		end
		table.insert(components, table.concat(sub, "||"))
	end

	return table.concat(components, " ")
end

--[=[
	Return a normalized SemVer string.
]=]
function semver.format(version: Version | string): string
	local v = coerceVersion(version)
	local out = `{v.major}.{v.minor}.{v.patch}`
	if v.prerelease then
		out ..= "-" .. v.prerelease
	end
	if v.build then
		out ..= "+" .. v.build
	end
	return out
end

local function identifierList(value: string?): { string }
	if value == nil then
		return {}
	end
	local out = {}
	for part in value:gmatch("[^.]+") do
		table.insert(out, part)
	end
	return out
end

local function compareIdentifiers(a: string, b: string): number
	local aNumeric = isNumericIdentifier(a)
	local bNumeric = isNumericIdentifier(b)
	if aNumeric and bNumeric then
		local an = tonumber(a) :: number
		local bn = tonumber(b) :: number
		if an < bn then
			return -1
		elseif an > bn then
			return 1
		end
		return 0
	elseif aNumeric then
		return -1
	elseif bNumeric then
		return 1
	elseif a < b then
		return -1
	elseif a > b then
		return 1
	end
	return 0
end

--[=[
	Compare two versions.

	Returns `-1` when `a < b`, `1` when `a > b`, and `0` when they have equal
	precedence. Build metadata is ignored.
]=]
function semver.compare(a: Version | string, b: Version | string): number
	local av = coerceVersion(a)
	local bv = coerceVersion(b)

	if av.major ~= bv.major then
		return if av.major < bv.major then -1 else 1
	end
	if av.minor ~= bv.minor then
		return if av.minor < bv.minor then -1 else 1
	end
	if av.patch ~= bv.patch then
		return if av.patch < bv.patch then -1 else 1
	end

	local avPre = identifierList(av.prerelease)
	local bvPre = identifierList(bv.prerelease)
	local aPre = #avPre
	local bPre = #bvPre
	if aPre == 0 and bPre == 0 then
		return 0
	elseif aPre == 0 then
		return 1
	elseif bPre == 0 then
		return -1
	end

	local len = math.min(aPre, bPre)
	for i = 1, len do
		local cmp = compareIdentifiers(avPre[i], bvPre[i])
		if cmp ~= 0 then
			return cmp
		end
	end
	if aPre < bPre then
		return -1
	elseif aPre > bPre then
		return 1
	end
	return 0
end

function semver.equals(a: Version | string, b: Version | string): boolean
	return semver.compare(a, b) == 0
end

function semver.lessThan(a: Version | string, b: Version | string): boolean
	return semver.compare(a, b) < 0
end

function semver.lessThanOrEqual(a: Version | string, b: Version | string): boolean
	return semver.compare(a, b) <= 0
end

function semver.greaterThan(a: Version | string, b: Version | string): boolean
	return semver.compare(a, b) > 0
end

function semver.greaterThanOrEqual(a: Version | string, b: Version | string): boolean
	return semver.compare(a, b) >= 0
end

local function comparator(op: ComparatorOp, version: Version | string): Comparator
	return {
		op = op,
		version = cloneVersion(coerceVersion(version)),
	}
end

local function nextMajor(v: Version): Version
	return { major = v.major + 1, minor = 0, patch = 0 }
end

local function nextMinor(v: Version): Version
	return { major = v.major, minor = v.minor + 1, patch = 0 }
end

local function nextPatch(v: Version): Version
	return { major = v.major, minor = v.minor, patch = v.patch + 1 }
end

local function caretUpper(v: Version): Version
	if v.major > 0 then
		return nextMajor(v)
	elseif v.minor > 0 then
		return nextMinor(v)
	end
	return nextPatch(v)
end

local function parseComparatorToken(token: string): { Comparator }
	local op: ComparatorOp? = nil
	local versionRaw: string? = nil
	if token:sub(1, 2) == "<=" or token:sub(1, 2) == ">=" then
		op = token:sub(1, 2) :: ComparatorOp
		versionRaw = token:sub(3)
	elseif token:sub(1, 1) == "<" or token:sub(1, 1) == ">" or token:sub(1, 1) == "=" then
		op = token:sub(1, 1) :: ComparatorOp
		versionRaw = token:sub(2)
	end
	if op and versionRaw then
		if versionRaw == "" then
			fail(`missing version after '{op}'`)
		end
		return { comparator(op, versionRaw) }
	end

	local sigil, selectedRaw = token:match("^([%^~])(.+)$")
	if sigil and selectedRaw then
		local base = parseImpl(selectedRaw)
		local upper = if sigil == "^" then caretUpper(base) else nextMinor(base)
		return {
			comparator(">=", base),
			comparator("<", upper),
		}
	end

	return { comparator("=", token) }
end

local function trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitOrRanges(source: string): { string }
	local out = {}
	local index = 1
	while true do
		local found = source:find("||", index, true)
		if not found then
			table.insert(out, source:sub(index))
			break
		end
		table.insert(out, source:sub(index, found - 1))
		index = found + 2
	end
	return out
end

--[=[
	Parse a version range selector.
]=]
function semver.parseRange(selector: string): Range
	if type(selector) ~= "string" then
		fail("selector must be a string")
	end

	local sets = {}
	for _, rawSet in splitOrRanges(selector) do
		local part = trim(rawSet)
		if part == "" then
			fail("range contains an empty selector")
		end

		local set = {}
		for token in part:gmatch("%S+") do
			for _, comp in parseComparatorToken(token) do
				table.insert(set, comp)
			end
		end
		if #set == 0 then
			fail("range contains an empty selector")
		end
		table.insert(sets, set)
	end

	return { sets = sets }
end

local function compareWithOp(version: Version, comp: Comparator): boolean
	local cmp = semver.compare(version, comp.version)
	if comp.op == "=" then
		return cmp == 0
	elseif comp.op == "<" then
		return cmp < 0
	elseif comp.op == "<=" then
		return cmp <= 0
	elseif comp.op == ">" then
		return cmp > 0
	elseif comp.op == ">=" then
		return cmp >= 0
	end
	return false
end

--[=[
	Return whether `version` satisfies `selector`.
]=]
function semver.satisfies(version: Version | string, selector: Range | string): boolean
	local v = coerceVersion(version)
	local range = if type(selector) == "string" then semver.parseRange(selector :: string) else selector :: Range

	for _, set in range.sets do
		local ok = true
		for _, comp in set do
			if not compareWithOp(v, comp) then
				ok = false
				break
			end
		end
		if ok then
			return true
		end
	end

	return false
end

return table.freeze(semver)
