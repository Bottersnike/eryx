--[=[
	RFC 3986 URI parsing and validation utilities.

	This library provides parsing helpers for:
	- Generic URI references (`URI-reference`)
	- Absolute URIs (`URI`)
	- Network-style URLs

	The parser is split into two stages:
	1. Structural splitting into URI components
	2. Optional RFC 3986 validation

	Query string parsing is provided as a convenience helper, but query
	contents are otherwise treated as opaque URI data.

	The implementation aims to be RFC 3986 compliant for generic URI
	syntax, though IPv6 validation is intentionally permissive for now.
]=]

local regex = require("@eryx/regex")
local urlEncoding = require("@eryx/encoding/url")

local uri = {}

--[=[
	Authority component of a URI.

	Corresponds to:
	`[ userinfo "@" ] host [ ":" port ]`

	Examples:
	- `example.com`
	- `user@example.com`
	- `example.com:8080`
	- `[::1]:443`
]=]
export type Authority = {
	--- Optional user information before `@`.
	---
	--- Example:
	--- `user:password`
	userInfo: string?,

	--- Host component.
	---
	--- May contain:
	--- - Registered names
	--- - IPv4 addresses
	--- - Bracketed IP literals
	---
	--- Examples:
	--- - `example.com`
	--- - `127.0.0.1`
	--- - `[::1]`
	host: string,

	--- Raw port string after `:`.
	---
	--- Preserves formatting exactly as written.
	---
	--- Examples:
	--- - `"80"`
	--- - `"00080"`
	--- - `""`
	portRaw: string?,

	--- Parsed numeric port when representable as a Lua number.
	---
	--- Will be `nil` for:
	--- - Missing ports
	--- - Empty ports
	--- - Extremely large port values
	port: number?,
}

--[=[
	Parsed query string values.

	Keys map to either:
	- A single string value
	- An array of repeated values

	Query items without keys are stored numerically.

	Example:
	`a=1&a=2&flag&hello=world`

	Produces:
	```luau
	{
		a = { "1", "2" },
		flag = "",
		hello = "world",
	}
	```
]=]
export type Query = { [string | number]: string? | { string? } }

--[=[
	Parsed RFC 3986 URI reference.

	Represents either:
	- An absolute URI
	- A relative reference

	Examples:
	- `https://example.com`
	- `/path/to/file`
	- `../relative`
	- `?query`
	- `#fragment`
]=]
export type URI = {
	--- URI scheme.
	---
	--- Examples:
	--- - `https`
	--- - `mailto`
	--- - `urn`
	scheme: string?,

	--- Parsed authority component.
	authority: Authority?,

	--- URI path component.
	---
	--- May be:
	--- - Empty
	--- - Absolute
	--- - Relative
	--- - Rootless
	path: string,

	--- Raw query string after `?`.
	---
	--- Does not include the leading `?`.
	query: string?,

	--- Fragment after `#`.
	---
	--- Does not include the leading `#`.
	fragment: string?,
}

--[=[
	Parsed absolute URI.

	Unlike `URI`, this always contains a scheme.

	Examples:
	- `https://example.com`
	- `mailto:user@example.com`
	- `urn:isbn:123456789`
]=]
export type URIWithScheme = URI & {
	scheme: string,
}

--[=[
	Parsed network-style URL.

	URLs are a restricted subset of URI intended for locating network
	resources.

	Unlike generic URIs, URLs always contain:
	- A scheme
	- An authority
	- A non-empty host

	Query strings are automatically parsed into `queryValues`.

	Examples:
	- `https://example.com`
	- `https://example.com/path?a=1`
]=]
export type URL = URIWithScheme & {
	authority: Authority,

	path: string,

	--- Parsed query string values using
	--- `application/x-www-form-urlencoded` conventions.
	---
	--- `+` is interpreted as space during parsing.
	queryValues: Query?,
}

--[=[
	Parses an `application/x-www-form-urlencoded` style query string.

	Repeated keys are collected into arrays.

	Keys without values produce empty strings.

	Examples:
	```luau
	uri.parseQueryString("a=1&a=2")
	-- { a = { "1", "2" } }

	uri.parseQueryString("flag")
	-- { flag = "" }
	```

	@param raw Raw query string without leading `?`
	@param plusIsSpace Whether `+` should decode to space
	@return Parsed query structure
]=]
function uri.parseQueryString(raw: string, plusIsSpace: boolean?): Query
	local query: Query = {}
	local key: string = ""
	local value: string = ""
	local cursor = 1
	local state = 1

	local function hasPair()
		return key ~= "" or value ~= "" or state == 2
	end

	local function flushPair()
		key = urlEncoding.decode(key, plusIsSpace or false)
		value = urlEncoding.decode(value, plusIsSpace or false)

		if key == "" then
			query[#query + 1] = value
		else
			if query[key] == nil then
				query[key] = value
			else
				if typeof(query[key]) ~= "table" then
					query[key] = { query[key] :: any }
				end
				table.insert(query[key] :: any, value)
			end
		end

		key = ""
		value = ""
		state = 1
	end

	while cursor <= #raw do
		local chr = raw:byte(cursor)
		if not chr then
			break
		end

		cursor += 1

		if chr == 61 and state == 1 then -- =
			state = 2
			continue
		end
		if chr == 38 then -- &
			if not hasPair() then
				continue
			end
			flushPair()
			continue
		end

		if state == 1 then
			key ..= raw:sub(cursor - 1, cursor - 1)
		else
			value ..= raw:sub(cursor - 1, cursor - 1)
		end
	end

	if hasPair() then
		flushPair()
	end

	return query
end

local URI_SPLIT = regex.new([=[^(?:([A-Za-z][A-Za-z0-9+.-]*):)?(?:\/\/([^\/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$]=])
local AUTHORITY_SPLIT = regex.new([=[^(?:(.*)@)?(\[[^\]]*\]|[^:]*)(?::([0-9]*))?$]=])

local function isAlpha(b: number): boolean
	return (65 <= b and b <= 90) or (97 <= b and b <= 122)
end

local function isDigit(b: number): boolean
	return 48 <= b and b <= 57
end

local function isHexDigit(b: number): boolean
	return isDigit(b) or (65 <= b and b <= 70) or (97 <= b and b <= 102)
end

local function isUnreserved(b: number): boolean
	-- ALPHA / DIGIT / "-" / "." / "_" / "~"
	return isAlpha(b) or isDigit(b) or b == 45 or b == 46 or b == 95 or b == 126
end

local function isSubDelim(b: number): boolean
	-- "!" / "$" / "&" / "'" / "(" / ")" / "*" / "+" / "," / ";" / "="
	return b == 33
		or b == 36
		or b == 38
		or b == 39
		or b == 40
		or b == 41
		or b == 42
		or b == 43
		or b == 44
		or b == 59
		or b == 61
end

local function validatePctAware(raw: string, allow: (number) -> boolean, what: string)
	local i = 1
	while i <= #raw do
		local b = raw:byte(i) :: number

		if b == 37 then -- %
			local a = raw:byte(i + 1)
			local c = raw:byte(i + 2)

			if not a or not c or not isHexDigit(a) or not isHexDigit(c) then
				error(`Invalid percent-encoding in {what}`)
			end

			i += 3
		else
			if not allow(b) then
				error(`Invalid character in {what}`)
			end

			i += 1
		end
	end
end

local function isPChar(b: number): boolean
	-- unreserved / pct-encoded / sub-delims / ":" / "@"
	return isUnreserved(b) or isSubDelim(b) or b == 58 or b == 64
end

local function validateUserInfo(raw: string)
	validatePctAware(raw, function(b)
		-- unreserved / pct-encoded / sub-delims / ":"
		return isUnreserved(b) or isSubDelim(b) or b == 58
	end, "userinfo")
end

local function validateRegName(raw: string)
	validatePctAware(raw, function(b)
		-- unreserved / pct-encoded / sub-delims
		return isUnreserved(b) or isSubDelim(b)
	end, "host")
end

local function validateIPv4(raw: string): boolean
	local parts = string.split(raw, ".")
	if #parts ~= 4 then
		return false
	end

	for _, part in parts do
		if part == "" then
			return false
		end

		for i = 1, #part do
			if not isDigit(part:byte(i) :: number) then
				return false
			end
		end

		-- RFC dec-octet does not allow leading zero for multi-digit octets.
		if #part > 1 and part:sub(1, 1) == "0" then
			return false
		end

		local n = tonumber(part)
		if not n or n > 255 then
			return false
		end
	end

	return true
end

local function validateIPvFuture(inner: string): boolean
	-- "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )
	if inner:sub(1, 1) ~= "v" and inner:sub(1, 1) ~= "V" then
		return false
	end

	local dot = inner:find(".", 2, true)
	if not dot or dot == 2 or dot == #inner then
		return false
	end

	for i = 2, dot - 1 do
		if not isHexDigit(inner:byte(i) :: number) then
			return false
		end
	end

	for i = dot + 1, #inner do
		local b = inner:byte(i) :: number
		if not (isUnreserved(b) or isSubDelim(b) or b == 58) then
			return false
		end
	end

	return true
end

local function validateIPv6Loose(inner: string): boolean
	-- Quick and dirty validation; good enough to stop nonsense characters,
	-- but doesn't validate "real" IPv6
	if inner == "" then
		return false
	end

	for i = 1, #inner do
		local b = inner:byte(i) :: number
		if not (isHexDigit(b) or b == 58 or b == 46) then
			return false
		end
	end

	return inner:find(":", 1, true) ~= nil
end

local function validateIPLiteral(raw: string)
	if raw:sub(1, 1) ~= "[" or raw:sub(#raw, #raw) ~= "]" then
		error("Invalid IP-literal")
	end

	local inner = raw:sub(2, #raw - 1)

	if validateIPvFuture(inner) then
		return
	end

	if validateIPv6Loose(inner) then
		return
	end

	error("Invalid IP-literal")
end

local function validateHost(raw: string)
	if raw:sub(1, 1) == "[" then
		validateIPLiteral(raw)
		return
	end

	-- RFC host = IP-literal / IPv4address / reg-name.
	-- If it is not valid IPv4, it may still be a valid reg-name.
	if validateIPv4(raw) then
		return
	end

	validateRegName(raw)
end

local function isPCharOrSlash(b: number): boolean
	return isPChar(b) or b == 47
end

local function validatePath(raw: string, hasScheme: boolean, hasAuthority: boolean)
	validatePctAware(raw, isPCharOrSlash, "path")

	if hasAuthority then
		-- path-abempty: empty or starts with "/"
		if raw ~= "" and raw:sub(1, 1) ~= "/" then
			error("Path must be empty or absolute when authority is present")
		end

		return
	end

	if hasScheme then
		-- hier-part without authority allows path-absolute / path-rootless / path-empty.
		return
	end

	-- relative-part: path-absolute / path-noscheme / path-empty.
	-- If relative path is rootless, first segment must not contain ":".
	if raw ~= "" and raw:sub(1, 1) ~= "/" then
		local slash = raw:find("/", 1, true)
		local first = if slash then raw:sub(1, slash - 1) else raw

		if first:find(":", 1, true) then
			error("Relative path first segment must not contain ':'")
		end
	end
end

local function validateQuery(raw: string)
	validatePctAware(raw, function(b)
		return isPChar(b) or b == 47 or b == 63
	end, "query")
end

local function validateFragment(raw: string)
	validatePctAware(raw, function(b)
		return isPChar(b) or b == 47 or b == 63
	end, "fragment")
end

local function validateURIParts(scheme: string?, authority: Authority?, path: string, query: string?, fragment: string?)
	if authority then
		if authority.userInfo ~= nil then
			validateUserInfo(authority.userInfo)
		end

		validateHost(authority.host)

		-- portRaw should be valid because of AUTHORITY_SPLIT.
		-- This is just a sanity check in case that regex changes.
		if authority.portRaw ~= nil then
			for i = 1, #authority.portRaw do
				if not isDigit(authority.portRaw:byte(i) :: number) then
					error("Invalid port")
				end
			end
		end
	end

	validatePath(path, scheme ~= nil, authority ~= nil)

	if query ~= nil then
		validateQuery(query)
	end

	if fragment ~= nil then
		validateFragment(fragment)
	end
end

--[=[
	Parses a generic RFC 3986 URI reference.

	Supports both:
	- Absolute URIs
	- Relative references

	Examples:
	- `https://example.com`
	- `/path`
	- `../relative`
	- `?query`
	- `#fragment`

	Validation is optional and validates generic RFC 3986 syntax.

	@param raw URI reference to parse
	@param validate Whether RFC validation should be performed
	@return Parsed URI reference
]=]
function uri.parseReference(raw: string, validate: boolean?): URI
	local match = URI_SPLIT:find(raw)
	if not match then
		error("Invalid URI")
	end

	local scheme = match[1]
	local authorityRaw = match[2]
	local path = match[3]
	assert(path) -- Should always match in regex
	local query = match[4]
	local fragment = match[5]

	local authority: Authority? = nil
	if authorityRaw then
		local auth = AUTHORITY_SPLIT:find(authorityRaw)
		if not auth then
			error("Invalid URI authority")
		end
		local host = auth[2]
		assert(host) -- Should always match in regex

		authority = {
			userInfo = auth[1],
			host = host,
			portRaw = auth[3],
			-- Bound on 15 characters to avoid tonumber returning 0 on really large ports
			port = if auth[3] and auth[3] ~= "" and #(auth[3] :: string) <= 15 then tonumber(auth[3]) else nil,
		}
	end

	if validate then
		validateURIParts(scheme, authority, path, query, fragment)
	end

	return {
		scheme = scheme,
		authority = authority,
		path = path,
		query = query,
		fragment = fragment,
	}
end

--[=[
	Parses an absolute URI.

	Unlike `parseReference`, this requires a scheme.

	Examples:
	- `https://example.com`
	- `mailto:user@example.com`
	- `urn:isbn:123456789`

	@param raw URI to parse
	@param validate Whether RFC validation should be performed
	@return Parsed URI
]=]
function uri.parseUri(raw: string, validate: boolean?): URIWithScheme
	local parsed = uri.parseReference(raw, validate)
	if not parsed.scheme then
		error("URI must have a scheme")
	end
	return parsed
end

--[=[
	Parses a network-style URL.

	URLs must contain:
	- A scheme
	- An authority
	- A non-empty host

	Query strings are automatically parsed into `queryValues`.

	Empty paths are normalised to `/`.

	Examples:
	- `https://example.com`
	- `https://example.com/path?a=1`

	@param raw URL to parse
	@return Parsed URL
]=]
function uri.parseUrl(raw: string): URL
	-- A URL must be a well-formed URI
	local parsed = uri.parseReference(raw, true)
	if not parsed.scheme then
		error("URL must have a scheme")
	end
	-- Discard URI scheme case
	local scheme = string.lower(parsed.scheme)

	if not parsed.authority then
		error("URL must have an authority")
	end

	if parsed.authority.host == "" then
		error("URL host must not be empty")
	end

	-- For HTTP-ish URLs, path-empty is equivalent to "/".
	if parsed.path == "" then
		parsed.path = "/"
	end

	local url: URL = {
		scheme = scheme :: any, -- Why on earth is ":: string" causing type errors
		authority = parsed.authority :: any,
		path = parsed.path,
		query = parsed.query,
		queryValues = if parsed.query then uri.parseQueryString(parsed.query, true) else nil,
		fragment = parsed.fragment,
	}

	return url
end

return table.freeze(uri)
