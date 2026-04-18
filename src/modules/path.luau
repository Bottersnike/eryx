--[=[
	High-level lexical path handling for Unix and NT/Windows grammars.

	`@eryx/path` is the place to parse, inspect, and manipulate filesystem
	paths without touching the filesystem. It keeps path handling lexical:
	no implicit filesystem resolution, symlink expansion, or canonicalization.
	Use `@eryx/fs` for I/O and filesystem queries.

	For most code, the common workflow is simple:
	1. Construct a path with [[new]], [[newNt]], or [[newUnix]]
	2. Use [[Path.join]], [[Path.parent]], [[Path.name]], [[Path.stem]], or [[Path.extension]]
	3. Pass the resulting [[Path]] directly into filesystem APIs, since they
	   generally accept [[PathLike]] (`Path | string`)
	4. Use `tostring(path)` when you explicitly need the rendered string form

	Most of the more specialized methods exist for Windows edge cases:
	UNC shares, verbatim paths, device namespaces, reserved DOS names, and
	other situations where a plain string is too lossy.

	```luau
	local fs = require("@eryx/fs")
	local os = require("@eryx/os")
	local path = require("@eryx/path")

	local root = path.new(os.cwd())
	local configFile = root:join("config"):join("app.json")

	print(configFile:name())      -- "app.json"
	print(configFile:stem())      -- "app"
	print(configFile:extension()) -- "json"
	print(configFile:parent())    -- Path(".../config")

	if fs.exists(configFile) then
		local file = fs.open(configFile, "r")
		print(file:read())
		file:close()
	end
	```

	If you only need everyday path manipulation, these methods are usually
	enough:
	- [[new]] / [[newNt]] / [[newUnix]]
	- [[join]]
	- [[dirname]]
	- [[basename]]
	- [[stem]]
	- [[extension]]
	- [[canonicalize]]
	- `tostring(path)`
	- or the instance equivalents on [[Path]]

	The top-level helpers are convenience wrappers around the `Path` object
	API. They are especially useful when you want familiar `fs.path.*`-style
	ergonomics while still working with parsed `Path` values.

	If you only need the instance-style API, these methods are usually
	enough:
	- [[new]] / [[newNt]] / [[newUnix]]
	- [[Path.join]]
	- [[Path.parent]]
	- [[Path.name]]
	- [[Path.stem]]
	- [[Path.extension]]
	- [[Path.normalizeDots]]
	- `tostring(path)`

	:::warning
	`path.new(...)` uses the host platform grammar. For deterministic parsing
	across platforms, prefer `path.newNt(...)` or `path.newUnix(...)`.
	:::
]=]

local nativePath = require("@eryx/_native/_path")

type Platform = "nt" | "unix"
type PrefixKind = "disk" | "unc" | "verbatim_disk" | "verbatim_unc" | "device" | "verbatim"

--[=[
	Windows/NT path prefix descriptor.

	These variants distinguish ordinary drive paths, UNC shares, verbatim
	paths, and device namespace paths without collapsing them into a single
	string form.
]=]
export type NtPrefix =
	{
		--- Prefix variant discriminator.
		kind: "disk",
		--- Drive letter, for example `"C"`.
		letter: string,
	}
	| {
		--- Prefix variant discriminator.
		kind: "unc",
		--- UNC server name.
		server: string,
		--- UNC share name.
		share: string,
	}
	| {
		--- Prefix variant discriminator.
		kind: "verbatim_disk",
		--- Drive letter, for example `"C"`.
		letter: string,
	}
	| {
		--- Prefix variant discriminator.
		kind: "verbatim_unc",
		--- UNC server name.
		server: string,
		--- UNC share name.
		share: string,
	}
	| {
		--- Prefix variant discriminator.
		kind: "device",
		--- Device namespace head, for example `"COM56"` or `"PhysicalDrive0"`.
		name: string,
	}
	| {
		--- Prefix variant discriminator.
		kind: "verbatim",
		--- Generic verbatim namespace head, for example `"pipe"`.
		head: string,
	}

type Prefix = NtPrefix?

type PathData = {
	_platform: Platform,
	_prefix: Prefix,
	_rooted: boolean,
	_components: { string },
	_raw: string,
	_hadTrailingSeparator: boolean,
}

local path = {}
local Path = {}
Path.__index = Path

export type Path = setmetatable<PathData, typeof(Path)>
--[=[
	A filesystem path accepted by high-level and native path-taking APIs.

	This may be either a raw string or a parsed [[Path]] object.
]=]
export type PathLike = Path | string

local function cloneArray<T>(values: { T }): { T }
	local out = table.create(#values)
	for i, value in values do
		out[i] = value
	end
	return out
end

local function clonePrefix(prefix: Prefix): Prefix
	if prefix == nil then
		return nil
	end

	if prefix.kind == "disk" then
		return {
			kind = prefix.kind,
			letter = prefix.letter,
		}
	end
	if prefix.kind == "verbatim_disk" then
		return {
			kind = prefix.kind,
			letter = prefix.letter,
		}
	end

	if prefix.kind == "unc" then
		return {
			kind = prefix.kind,
			server = prefix.server,
			share = prefix.share,
		}
	end
	if prefix.kind == "verbatim_unc" then
		return {
			kind = prefix.kind,
			server = prefix.server,
			share = prefix.share,
		}
	end

	if prefix.kind == "device" then
		return {
			kind = "device",
			name = prefix.name,
		}
	end

	return {
		kind = "verbatim",
		head = prefix.head,
	}
end

local function isPath(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Path
end

local function pathlikeString(value: PathLike): string
	if isPath(value) then
		return tostring(value :: Path)
	end
	if type(value) == "string" then
		return value
	end
	error("expected PathLike (string or Path)")
end

local function hostPlatform(): Platform
	local ok, os = pcall(require, "@eryx/os")
	if ok and os.platform() == "windows" then
		return "nt"
	end
	return "unix"
end

local function hasSuffix(input: string, suffix: string): boolean
	return #input >= #suffix and string.sub(input, #input - #suffix + 1) == suffix
end

local function splitOrdinaryNtComponents(remainder: string): { string }
	local normalized = string.gsub(remainder, "/", "\\")
	local components = {}
	for part in string.gmatch(normalized, "[^\\]+") do
		table.insert(components, part)
	end
	return components
end

local function splitUnixComponents(remainder: string): { string }
	local components = {}
	for part in string.gmatch(remainder, "[^/]+") do
		table.insert(components, part)
	end
	return components
end

local function splitVerbatimComponents(remainder: string): { string }
	local components = {}
	for part in string.gmatch(remainder, "[^\\]+") do
		table.insert(components, part)
	end
	return components
end

local function trimLeadingOrdinaryNtSeparators(value: string): string
	local out = value
	while true do
		local first = string.sub(out, 1, 1)
		if first ~= "\\" and first ~= "/" then
			break
		end
		out = string.sub(out, 2)
	end
	return out
end

local function trimLeadingUnixSeparators(value: string): string
	local out = value
	while string.sub(out, 1, 1) == "/" do
		out = string.sub(out, 2)
	end
	return out
end

local function renderNtPrefix(prefix: Prefix): string
	if prefix == nil then
		return ""
	end
	if prefix.kind == "disk" then
		return prefix.letter .. ":"
	end
	if prefix.kind == "unc" then
		return "\\\\" .. prefix.server .. "\\" .. prefix.share
	end
	if prefix.kind == "verbatim_disk" then
		return "\\\\?\\" .. prefix.letter .. ":"
	end
	if prefix.kind == "verbatim_unc" then
		return "\\\\?\\UNC\\" .. prefix.server .. "\\" .. prefix.share
	end
	if prefix.kind == "device" then
		return "\\\\.\\" .. prefix.name
	end
	return "\\\\?\\" .. prefix.head
end

local function ntSeparatorFor(prefix: Prefix): string
	if
		prefix ~= nil and (prefix.kind == "verbatim_disk" or prefix.kind == "verbatim_unc" or prefix.kind == "verbatim")
	then
		return "\\"
	end
	return "\\"
end

local function prefixImpliesRoot(prefix: Prefix): boolean
	return prefix ~= nil and (prefix.kind == "unc" or prefix.kind == "verbatim_unc")
end

local function parseUnix(raw: string): PathData
	local rooted = string.sub(raw, 1, 1) == "/"
	local hadTrailingSeparator = #raw > 1 and hasSuffix(raw, "/")
	local remainder = if rooted then trimLeadingUnixSeparators(raw) else raw
	return {
		_platform = "unix",
		_prefix = nil,
		_rooted = rooted,
		_components = splitUnixComponents(remainder),
		_raw = raw,
		_hadTrailingSeparator = hadTrailingSeparator,
	}
end

local function parseNt(raw: string): PathData
	local prefix: Prefix = nil
	local rooted = false
	local remainder = raw

	if string.sub(raw, 1, 8) == "\\\\?\\UNC\\" then
		local tail = string.sub(raw, 9)
		local server, share, rest = string.match(tail, "^([^\\]+)\\([^\\]+)(.*)$")
		if server and share then
			prefix = { kind = "verbatim_unc" :: "verbatim_unc", server = server, share = share }
			rooted = true
			remainder = if rest then string.sub(rest, 2) else ""
		else
			prefix = { kind = "verbatim", head = tail }
			rooted = false
			remainder = ""
		end
	elseif string.sub(raw, 1, 4) == "\\\\?\\" then
		local tail = string.sub(raw, 5)
		local letter = string.match(tail, "^([A-Za-z]):")
		if letter ~= nil then
			prefix = { kind = "verbatim_disk" :: "verbatim_disk", letter = letter }
			remainder = string.sub(tail, 3)
			rooted = string.sub(remainder, 1, 1) == "\\" or string.sub(remainder, 1, 1) == "/"
			if rooted then
				remainder = string.sub(remainder, 2)
			end
		else
			local splitAt = string.find(tail, "\\", 1, true)
			if splitAt == nil then
				prefix = { kind = "verbatim", head = tail }
				rooted = false
				remainder = ""
			else
				local head = string.sub(tail, 1, splitAt - 1)
				local rest = string.sub(tail, splitAt)
				prefix = { kind = "verbatim", head = head }
				rooted = string.sub(rest, 1, 1) == "\\" or string.sub(rest, 1, 1) == "/"
				remainder = if rooted then string.sub(rest, 2) else rest
			end
		end
	elseif string.sub(raw, 1, 4) == "\\\\.\\" or string.sub(raw, 1, 4) == "//./" then
		local tail = string.gsub(string.sub(raw, 5), "/", "\\")
		local name, rest = string.match(tail, "^([^\\]+)(.*)$")
		prefix = { kind = "device" :: "device", name = name or tail }
		rooted = string.sub(rest or "", 1, 1) == "\\"
		remainder = if rooted then string.sub(rest or "", 2) else (rest or "")
	elseif string.sub(raw, 1, 2) == "\\\\" or string.sub(raw, 1, 2) == "//" then
		local tail = string.gsub(string.sub(raw, 3), "/", "\\")
		local server, share, rest = string.match(tail, "^([^\\]+)\\([^\\]+)(.*)$")
		if server and share then
			prefix = { kind = "unc" :: "unc", server = server, share = share }
			rooted = true
			remainder = if rest then string.sub(rest, 2) else ""
		end
	end

	if prefix == nil then
		local drive = string.match(raw, "^([A-Za-z]):")
		if drive ~= nil then
			prefix = { kind = "disk" :: "disk", letter = drive }
			remainder = string.sub(raw, 3)
			rooted = string.sub(remainder, 1, 1) == "\\" or string.sub(remainder, 1, 1) == "/"
			if rooted then
				remainder = string.sub(remainder, 2)
			end
		elseif string.sub(raw, 1, 1) == "\\" or string.sub(raw, 1, 1) == "/" then
			rooted = true
			remainder = trimLeadingOrdinaryNtSeparators(raw)
		end
	end

	local hadTrailingSeparator = false
	if
		prefix ~= nil and (prefix.kind == "verbatim_disk" or prefix.kind == "verbatim_unc" or prefix.kind == "verbatim")
	then
		hadTrailingSeparator = #raw > 0 and hasSuffix(raw, "\\")
	else
		hadTrailingSeparator = #raw > 0 and (hasSuffix(raw, "\\") or hasSuffix(raw, "/"))
	end

	local components = if prefix ~= nil
			and (prefix.kind == "verbatim_disk" or prefix.kind == "verbatim_unc" or prefix.kind == "verbatim")
		then splitVerbatimComponents(remainder)
		else splitOrdinaryNtComponents(remainder)

	if prefixImpliesRoot(prefix) then
		rooted = true
	end

	return {
		_platform = "nt",
		_prefix = prefix,
		_rooted = rooted,
		_components = components,
		_raw = raw,
		_hadTrailingSeparator = hadTrailingSeparator,
	}
end

local function fromParsed(parsed: PathData): Path
	return setmetatable({
		_platform = parsed._platform,
		_prefix = clonePrefix(parsed._prefix),
		_rooted = parsed._rooted,
		_components = cloneArray(parsed._components),
		_raw = parsed._raw,
		_hadTrailingSeparator = parsed._hadTrailingSeparator,
	}, Path)
end

local function parseWithPlatform(platformName: Platform, input: string): Path
	if platformName == "nt" then
		return fromParsed(parseNt(input))
	end
	return fromParsed(parseUnix(input))
end

local function coerceForPlatform(platformName: Platform, value: PathLike): Path
	if isPath(value) then
		local p = value :: Path
		if p._platform == platformName then
			return p
		end
		return parseWithPlatform(platformName, tostring(p))
	end
	return parseWithPlatform(platformName, value :: string)
end

local function prefixEquals(a: Prefix, b: Prefix): boolean
	if a == nil or b == nil then
		return a == b
	end
	if a.kind ~= b.kind then
		return false
	end
	if a.kind == "disk" or a.kind == "verbatim_disk" then
		return string.lower(a.letter) == string.lower((b :: any).letter)
	end
	if a.kind == "unc" or a.kind == "verbatim_unc" then
		return string.lower(a.server) == string.lower((b :: any).server)
			and string.lower(a.share) == string.lower((b :: any).share)
	end
	if a.kind == "device" then
		return string.lower(a.name) == string.lower((b :: any).name)
	end
	return a.head == (b :: any).head
end

local function buildPath(
	platformName: Platform,
	prefix: Prefix,
	rooted: boolean,
	components: { string },
	hadTrailingSeparator: boolean
): Path
	local parsed = {
		_platform = platformName,
		_prefix = clonePrefix(prefix),
		_rooted = rooted,
		_components = cloneArray(components),
		_raw = "",
		_hadTrailingSeparator = hadTrailingSeparator,
	}
	return fromParsed(parsed)
end

--[=[
	Returns the grammar this path was parsed with.

	@return "nt" | "unix" -- Path grammar platform.
]=]
function Path.platform(self: Path): Platform
	return self._platform
end

--[=[
	Returns the parsed NT prefix, if any.

	Unix paths always return `nil`.

	@return NtPrefix? -- Prefix descriptor for NT/Windows paths.
]=]
function Path.prefix(self: Path): Prefix
	return clonePrefix(self._prefix)
end

--[=[
	Returns the lexical path components excluding any prefix/root marker.

	@return {string} -- Parsed path components.
]=]
function Path.components(self: Path): { string }
	return cloneArray(self._components)
end

--[=[
	Returns the original string passed to the parser.

	This is primarily useful for round-tripping and diagnostics.

	@return string -- Original input string.
]=]
function Path.raw(self: Path): string
	return self._raw
end

--[=[
	Returns whether the path has an explicit NT prefix such as a drive,
	UNC share, verbatim prefix, or device namespace.

	@return boolean -- `true` when a prefix is present.
]=]
function Path.hasPrefix(self: Path): boolean
	return self._prefix ~= nil
end

--[=[
	Returns whether the path is rooted.

	On Windows this includes drive-rooted and rooted-without-prefix forms,
	but does not by itself imply the path is fully absolute.

	@return boolean -- `true` when the path is rooted.
]=]
function Path.hasRoot(self: Path): boolean
	return self._rooted or prefixImpliesRoot(self._prefix)
end

--[=[
	Returns whether the path is absolute in the current grammar.

	On Windows this distinguishes `C:\foo` from drive-relative `C:foo`
	and rooted-relative `\foo`.

	@return boolean -- `true` when the path is absolute.
]=]
function Path.isAbsolute(self: Path): boolean
	if self._platform == "unix" then
		return self._rooted
	end

	if self._prefix == nil then
		return false
	end

	if self._prefix.kind == "disk" then
		return self._rooted
	end

	if self._prefix.kind == "verbatim_disk" then
		return self._rooted
	end

	return true
end

--[=[
	Returns whether the path is not absolute.

	@return boolean -- `true` when the path is relative.
]=]
function Path.isRelative(self: Path): boolean
	return not self:isAbsolute()
end

--[=[
	Returns whether the path targets a UNC share.

	This includes both ordinary UNC paths and verbatim UNC paths.

	@return boolean -- `true` when the path is UNC-like.
]=]
function Path.isUnc(self: Path): boolean
	local prefix = self._prefix
	return prefix ~= nil and (prefix.kind == "unc" or prefix.kind == "verbatim_unc")
end

--[=[
	Returns whether the path uses a verbatim `\\?\...` namespace.

	@return boolean -- `true` when the path is verbatim.
]=]
function Path.isVerbatim(self: Path): boolean
	local prefix = self._prefix
	return prefix ~= nil
		and (prefix.kind == "verbatim_disk" or prefix.kind == "verbatim_unc" or prefix.kind == "verbatim")
end

--[=[
	Returns whether the path uses the `\\.\...` device namespace.

	@return boolean -- `true` when the path is a device path.
]=]
function Path.isDevice(self: Path): boolean
	local prefix = self._prefix
	return prefix ~= nil and prefix.kind == "device"
end

--[=[
	Returns whether the path is Windows drive-relative, such as `C:foo`.

	@return boolean -- `true` when the path is drive-relative.
]=]
function Path.isDriveRelative(self: Path): boolean
	local prefix = self._prefix
	return self._platform == "nt" and prefix ~= nil and prefix.kind == "disk" and not self._rooted
end

--[=[
	Returns whether the path is Windows rooted-relative, such as `\foo`.

	@return boolean -- `true` when the path is rooted-relative.
]=]
function Path.isRootedRelative(self: Path): boolean
	return self._platform == "nt" and self._prefix == nil and self._rooted
end

--[=[
	Returns whether the original input ended with a separator.

	@return boolean -- `true` when a trailing separator was preserved.
]=]
function Path.hasTrailingSeparator(self: Path): boolean
	return self._hadTrailingSeparator
end

local function finalComponent(self: Path): string?
	return self._components[#self._components]
end

local function reservedBaseName(name: string): string
	local value = name
	value = string.gsub(value, "[%. ]+$", "")
	local stem = string.match(value, "^(.*)%.") or value
	return string.upper(stem)
end

--[=[
	Returns whether the final component is a reserved DOS device name.

	This is a query only; reserved names remain representable and are not
	parse failures.

	@return boolean -- `true` when the final component is reserved on Windows.
]=]
function Path.isReservedName(self: Path): boolean
	if self._platform ~= "nt" then
		return false
	end

	local name = finalComponent(self)
	if name == nil then
		return false
	end

	local base = reservedBaseName(name)
	if base == "CON" or base == "PRN" or base == "AUX" or base == "NUL" then
		return true
	end

	local com = string.match(base, "^COM([1-9])$")
	if com ~= nil then
		return true
	end

	local lpt = string.match(base, "^LPT([1-9])$")
	return lpt ~= nil
end

--[=[
	Returns whether the final component ends in a trailing dot or space.

	These names often require verbatim handling on Windows.

	@return boolean -- `true` when the final component has problematic trailing characters.
]=]
function Path.hasProblematicTrailingChars(self: Path): boolean
	if self._platform ~= "nt" then
		return false
	end
	local name = finalComponent(self)
	return name ~= nil and (hasSuffix(name, ".") or hasSuffix(name, " "))
end

--[=[
	Returns whether this path likely benefits from a verbatim Windows form.

	The current heuristic checks for problematic trailing characters and long
	rendered paths.

	@return boolean -- `true` when a verbatim form is recommended.
]=]
function Path.needsVerbatim(self: Path): boolean
	if self._platform ~= "nt" then
		return false
	end
	return self:hasProblematicTrailingChars() or #tostring(self) >= 240
end

--[=[
	Returns the final path component, if any.

	@return string? -- Final component, or `nil` for roots/share roots.
]=]
function Path.name(self: Path): string?
	return finalComponent(self)
end

--[=[
	Returns the final component without its last extension.

	@return string? -- Stem of the final component, or `nil` when absent.
]=]
function Path.stem(self: Path): string?
	local name = finalComponent(self)
	if name == nil then
		return nil
	end
	local stem = string.match(name, "^(.*)%.")
	if stem == nil or stem == "" then
		return name
	end
	return stem
end

--[=[
	Returns the last extension of the final component without a leading dot.

	@return string? -- Extension text, or `nil` when absent.
]=]
function Path.extension(self: Path): string?
	local name = finalComponent(self)
	if name == nil then
		return nil
	end
	local ext = string.match(name, "%.([^%.]+)$")
	return ext
end

--[=[
	Returns the lexical parent path, or `nil` for roots/share roots.

	@return Path? -- Parent path when one exists.
]=]
function Path.parent(self: Path): Path?
	if #self._components == 0 then
		return nil
	end
	local components = cloneArray(self._components)
	table.remove(components)
	return buildPath(self._platform, self._prefix, self._rooted, components, false)
end

--[=[
	Returns a copy of the path with the final component replaced.

	@param name Replacement final component. Must be a single component.
	@return Path -- New path with the updated name.
]=]
function Path.withName(self: Path, name: string): Path
	if name == "" or string.find(name, "[/\\]") then
		error("name must be a single path component")
	end
	if #self._components == 0 then
		error("cannot replace the name of a root path")
	end
	local components = cloneArray(self._components)
	components[#components] = name
	return buildPath(self._platform, self._prefix, self._rooted, components, false)
end

--[=[
	Returns a copy of the path with the final component's extension changed.

	Leading dots in `ext` are ignored. Pass an empty string to remove the
	extension entirely.

	@param ext New extension text.
	@return Path -- New path with the updated extension.
]=]
function Path.withExtension(self: Path, ext: string): Path
	local name = finalComponent(self)
	if name == nil then
		error("cannot change the extension of a root path")
	end
	local clean = string.gsub(ext, "^%.+", "")
	local base = self:stem() or name
	local newName = if clean == "" then base else `{base}.{clean}`
	return self:withName(newName)
end

--[=[
	Appends a single normal path component.

	This rejects separators and the special `"."` / `".."` components.

	@param name Path component to append.
	@return Path -- New path with the appended component.
]=]
function Path.joinComponent(self: Path, name: string): Path
	if name == "" or string.find(name, "[/\\]") or name == "." or name == ".." then
		error("joinComponent expects a single normal path component")
	end
	local components = cloneArray(self._components)
	table.insert(components, name)
	return buildPath(self._platform, self._prefix, self._rooted, components, false)
end

local function isGenericDeviceBase(self: Path): boolean
	local prefix = self._prefix
	if prefix == nil or prefix.kind ~= "device" then
		return false
	end
	if prefix.name == "UNC" or string.match(prefix.name, "^[A-Za-z]:$") ~= nil then
		return false
	end
	return not self._rooted and #self._components == 0
end

--[=[
	Joins another path onto this one using lexical platform rules.

	On Unix, rooted RHS values replace the whole path. On Windows, fully
	qualified RHS values replace the whole path, while rooted-without-prefix
	RHS values preserve the current volume where appropriate.

	@param rhs PathLike value to join.
	@return Path -- Joined path.
]=]
function Path.join(self: Path, rhs: PathLike): Path
	local other = coerceForPlatform(self._platform, rhs)

	if self._platform == "unix" then
		if other._rooted then
			return other
		end
		local components = cloneArray(self._components)
		for _, component in other._components do
			table.insert(components, component)
		end
		return buildPath("unix", nil, self._rooted, components, other._hadTrailingSeparator)
	end

	if isGenericDeviceBase(self) then
		error("cannot join relative paths onto a device-only base")
	end

	if other._prefix ~= nil then
		return other
	end

	if other._rooted then
		local prefix = self._prefix
		if prefix ~= nil then
			if prefix.kind == "disk" or prefix.kind == "verbatim_disk" then
				return buildPath("nt", prefix, true, other._components, other._hadTrailingSeparator)
			end
			if prefix.kind == "unc" or prefix.kind == "verbatim_unc" then
				return buildPath("nt", prefix, true, other._components, other._hadTrailingSeparator)
			end
			if
				prefix.kind == "device"
				and (
					prefix.name == "UNC"
					or (typeof(prefix.name) == "string" and string.match(prefix.name, "^[A-Za-z]:$") ~= nil)
				)
			then
				return buildPath("nt", prefix, true, other._components, other._hadTrailingSeparator)
			end
		end
		return other
	end

	local components = cloneArray(self._components)
	for _, component in other._components do
		table.insert(components, component)
	end
	return buildPath("nt", self._prefix, self._rooted, components, other._hadTrailingSeparator)
end

local function normalizeDotsComponents(components: { string }, rooted: boolean): { string }
	local out = {}
	for _, component in components do
		if component == "." then
			continue
		end
		if component == ".." then
			local top = out[#out]
			if top ~= nil and top ~= ".." then
				table.remove(out)
			elseif not rooted then
				table.insert(out, component)
			end
		else
			table.insert(out, component)
		end
	end
	return out
end

--[=[
	Performs lexical `.` / `..` cleanup.

	On verbatim Windows paths this is intentionally a no-op by default.

	@return Path -- Normalized path.
]=]
function Path.normalizeDots(self: Path): Path
	if self._platform == "nt" and self:isVerbatim() then
		return self
	end
	return buildPath(
		self._platform,
		self._prefix,
		self._rooted,
		normalizeDotsComponents(self._components, self:hasRoot()),
		self._hadTrailingSeparator
	)
end

--[=[
	Performs lexical `.` / `..` cleanup even for verbatim paths.

	Use this only when you explicitly want that behavior.

	@return Path -- Normalized path.
]=]
function Path.normalizeDotsUnsafe(self: Path): Path
	return buildPath(
		self._platform,
		self._prefix,
		self._rooted,
		normalizeDotsComponents(self._components, self:hasRoot()),
		self._hadTrailingSeparator
	)
end

--[=[
	Returns a copy of the path in normalized separator form.

	For verbatim Windows paths this is conservative and currently returns the
	path unchanged.

	@return Path -- Path with normalized separators.
]=]
function Path.normalizeSeparators(self: Path): Path
	if self._platform == "nt" and self:isVerbatim() then
		return self
	end
	return buildPath(self._platform, self._prefix, self._rooted, self._components, self._hadTrailingSeparator)
end

--[=[
	Computes a lexical relative path from `base` to this path.

	This is purely syntactic and refuses paths with mismatched platforms,
	volumes, prefixes, or rootedness.

	@param base Base path to relativize against.
	@return Path? -- Relative path, or `nil` when no lexical relative form exists.
]=]
function Path.relativeTo(self: Path, base: PathLike): Path?
	local other = coerceForPlatform(self._platform, base)
	if
		self._platform ~= other._platform
		or not prefixEquals(self._prefix, other._prefix)
		or self._rooted ~= other._rooted
	then
		return nil
	end

	local maxCommon = math.min(#self._components, #other._components)
	local index = 1
	while index <= maxCommon do
		local a = self._components[index]
		local b = other._components[index]
		if self._platform == "nt" then
			if string.lower(a) ~= string.lower(b) then
				break
			end
		elseif a ~= b then
			break
		end
		index += 1
	end

	local rel = {}
	for _ = index, #other._components do
		table.insert(rel, "..")
	end
	for i = index, #self._components do
		table.insert(rel, self._components[i])
	end
	return buildPath(self._platform, nil, false, rel, self._hadTrailingSeparator)
end

--[=[
	Returns the native string form used when crossing into C++ path-taking APIs.

	@return string -- Native path string.
]=]
function Path.toNativeString(self: Path): string
	return tostring(self)
end

--[=[
	Returns a display-oriented string form.

	For verbatim disk/UNC paths this strips the verbatim marker while
	preserving the lexical structure.

	@return string -- Display-friendly path string.
]=]
function Path.toDisplayString(self: Path): string
	local prefix = self._prefix
	if self._platform == "nt" and prefix ~= nil then
		if prefix.kind == "verbatim_disk" then
			return tostring(
				buildPath(
					"nt",
					{ kind = "disk", letter = prefix.letter },
					true,
					self._components,
					self._hadTrailingSeparator
				)
			)
		end
		if prefix.kind == "verbatim_unc" then
			return tostring(
				buildPath(
					"nt",
					{ kind = "unc", server = prefix.server, share = prefix.share },
					true,
					self._components,
					self._hadTrailingSeparator
				)
			)
		end
	end
	return tostring(self)
end

--[=[
	Returns a verbatim Windows string form when possible.

	Unix paths and already-verbatim paths are returned unchanged.

	@return string -- Verbatim or unchanged path string.
]=]
function Path.toVerbatimString(self: Path): string
	if self._platform ~= "nt" then
		return tostring(self)
	end
	local prefix = self._prefix
	if prefix == nil then
		return tostring(self)
	end
	if prefix.kind == "verbatim_disk" or prefix.kind == "verbatim_unc" or prefix.kind == "verbatim" then
		return tostring(self)
	end
	if prefix.kind == "disk" and self._rooted then
		return tostring(
			buildPath(
				"nt",
				{ kind = "verbatim_disk", letter = prefix.letter },
				true,
				self._components,
				self._hadTrailingSeparator
			)
		)
	end
	if prefix.kind == "unc" then
		return tostring(
			buildPath(
				"nt",
				{ kind = "verbatim_unc", server = prefix.server, share = prefix.share },
				true,
				self._components,
				self._hadTrailingSeparator
			)
		)
	end
	return tostring(self)
end

--[=[
	Returns the native filesystem string used by native `PathLike` coercion.

	@return string -- Native path string.
]=]
function Path.__fspath(self: Path): string
	return tostring(self)
end

--[=[
	Renders the path back to its string form.

	Most callers should use `tostring(path)` rather than calling this
	metamethod directly.

	@return string -- Rendered path string.
]=]
function Path.__tostring(self: Path): string
	if self._platform == "unix" then
		local out = if self._rooted then "/" else ""
		out ..= table.concat(self._components, "/")
		if self._hadTrailingSeparator and #self._components > 0 and not hasSuffix(out, "/") then
			out ..= "/"
		end
		if out == "" and self._raw ~= "" then
			return self._raw
		end
		return out
	end

	if self:isVerbatim() and self._raw ~= "" then
		return self._raw
	end

	local prefix = self._prefix
	local sep = ntSeparatorFor(prefix)
	local out = renderNtPrefix(prefix)

	if prefix == nil then
		if self._rooted then
			out = sep
		end
	elseif self._rooted then
		if not hasSuffix(out, sep) then
			out ..= sep
		end
	end

	if #self._components > 0 then
		local joined = table.concat(self._components, sep)
		local needsSep = #out > 0 and not hasSuffix(out, sep)
		if
			prefix ~= nil
			and not self._rooted
			and (
				prefix.kind == "disk"
				or prefix.kind == "verbatim_disk"
				or prefix.kind == "device"
				or prefix.kind == "verbatim"
			)
		then
			needsSep = false
		end
		if needsSep then
			out ..= sep
		end
		out ..= joined
	end

	if self._hadTrailingSeparator and #self._components > 0 and not hasSuffix(out, sep) then
		out ..= sep
	end

	if out == "" and self._raw ~= "" then
		return self._raw
	end
	return out
end

--[=[
	Parses a string using the host platform grammar.

	Prefer [[newNt]] or [[newUnix]] when deterministic grammar selection
	matters.

	@param input Path string to parse.
	@return Path -- Parsed path object.
]=]
function path.parseNative(input: string): Path
	return parseWithPlatform(hostPlatform(), input)
end

--[=[
	Parses a string using Windows/NT path rules.

	@param input Path string to parse.
	@return Path -- Parsed NT path object.
]=]
function path.parseNt(input: string): Path
	return parseWithPlatform("nt", input)
end

--[=[
	Parses a string using Unix path rules.

	@param input Path string to parse.
	@return Path -- Parsed Unix path object.
]=]
function path.parseUnix(input: string): Path
	return parseWithPlatform("unix", input)
end

--[=[
	Constructs a path using the host platform grammar.

	If `input` is already a [[Path]], it is returned unchanged.

	:::warning
	This constructor is host-native and may be unpredictable for
	cross-platform-sensitive code. Prefer [[newNt]] or [[newUnix]] for
	deterministic parsing.
	:::

	@param input Path string or existing Path.
	@return Path -- Parsed path object.
]=]
function path.new(input: PathLike): Path
	if isPath(input) then
		return input :: Path
	end
	return parseWithPlatform(hostPlatform(), pathlikeString(input))
end

--[=[
	Constructs a path using Windows/NT path rules.

	If `input` is already an NT [[Path]], it is returned unchanged.

	@param input Path string or existing Path.
	@return Path -- Parsed NT path object.
]=]
function path.newNt(input: PathLike): Path
	if isPath(input) and (input :: Path)._platform == "nt" then
		return input :: Path
	end
	return parseWithPlatform("nt", pathlikeString(input))
end

--[=[
	Constructs a path using Unix path rules.

	If `input` is already a Unix [[Path]], it is returned unchanged.

	@param input Path string or existing Path.
	@return Path -- Parsed Unix path object.
]=]
function path.newUnix(input: PathLike): Path
	if isPath(input) and (input :: Path)._platform == "unix" then
		return input :: Path
	end
	return parseWithPlatform("unix", pathlikeString(input))
end

--[=[
	Joins path segments using the lexical rules of the first argument.

	This is a convenience wrapper over repeated [[Path.join]] calls and
	accepts a [[PathLike]] as its first argument.

	@param base Base path.
	@param ... Additional path segments to join.
	@return Path -- Joined path.
]=]
function path.join(base: PathLike, ...: PathLike): Path
	local current = path.new(base)
	for i = 1, select("#", ...) do
		current = current:join(select(i, ...))
	end
	return current
end

--[=[
	Returns the lexical parent directory of a path.

	This is a convenience wrapper over [[Path.parent]].

	@param input Path to inspect.
	@return Path? -- Parent path, or `nil` for roots/share roots.
]=]
function path.dirname(input: PathLike): Path?
	return path.new(input):parent()
end

--[=[
	Returns the final component of a path.

	This is a convenience wrapper over [[Path.name]].

	@param input Path to inspect.
	@return string? -- Final component, or `nil` when absent.
]=]
function path.basename(input: PathLike): string?
	return path.new(input):name()
end

--[=[
	Returns the final component without its last extension.

	This is a convenience wrapper over [[Path.stem]].

	@param input Path to inspect.
	@return string? -- Stem text, or `nil` when absent.
]=]
function path.stem(input: PathLike): string?
	return path.new(input):stem()
end

--[=[
	Returns the last extension of the final component without a leading dot.

	This is a convenience wrapper over [[Path.extension]].

	@param input Path to inspect.
	@return string? -- Extension text, or `nil` when absent.
]=]
function path.extension(input: PathLike): string?
	return path.new(input):extension()
end

--[=[
	Resolves a path to an absolute canonical form via the filesystem.

	Unlike most of `@eryx/path`, this helper is not purely lexical. It bridges
	into a native filesystem helper and returns the canonicalized result as a
	[[Path]].

	@param input Path to canonicalize.
	@return Path -- Canonical absolute path.
]=]
function path.canonicalize(input: PathLike): Path
	return path.new(nativePath.canonicalize(input))
end

--[=[
	Returns whether a value is a parsed [[Path]] object.

	@param value Value to test.
	@return boolean -- `true` when the value is a Path.
]=]
function path.isPath(value: any): boolean
	return isPath(value)
end

path.Path = Path

return table.freeze(path)
