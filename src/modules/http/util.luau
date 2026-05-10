local urlEncoding = require("@eryx/encoding/url")
local uri = require("@eryx/uri")

local util = {}

type QueryScalar = string | number | boolean
type QueryValue = QueryScalar | { QueryScalar }
type QueryTable = { [string]: string | { string } }
type ParsedUrl = { scheme: string, host: string, port: number, path: string }

function util.trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeUrlHost(host: string): string
	if string.sub(host, 1, 1) == "[" and string.sub(host, -1) == "]" then
		return string.sub(host, 2, -2)
	end
	return host
end

local function formatUrlHost(host: string): string
	if string.find(host, ":", 1, true) ~= nil and string.sub(host, 1, 1) ~= "[" then
		return "[" .. host .. "]"
	end
	return host
end

--- Parse a URL into (scheme, host, port, path)
function util.parseUrl(url: string): ParsedUrl
	local parsed = uri.parseUrl(url)
	local port = parsed.authority.port
	if port == nil then
		port = if parsed.scheme == "https" then 443 else 80
	end

	local path = parsed.path
	if parsed.query ~= nil then
		path ..= "?" .. parsed.query
	end

	return {
		scheme = parsed.scheme,
		host = normalizeUrlHost(parsed.authority.host),
		port = port,
		path = path,
	}
end

--- Resolves a possibly-relative Location header against the original URL.
function util.resolveRedirect(originalUrl: ParsedUrl, location: string): string
	-- Absolute URL
	if string.match(location, "^https?://") then
		return location
	end

	-- Protocol-relative URL
	if string.sub(location, 1, 2) == "//" then
		return originalUrl.scheme .. ":" .. location
	end

	-- Absolute path
	local portSuffix = ""
	if
		(originalUrl.scheme == "http" and originalUrl.port ~= 80)
		or (originalUrl.scheme == "https" and originalUrl.port ~= 443)
	then
		portSuffix = ":" .. tostring(originalUrl.port)
	end
	local base = originalUrl.scheme .. "://" .. formatUrlHost(originalUrl.host) .. portSuffix

	if string.sub(location, 1, 1) == "/" then
		return base .. location
	end

	-- Relative path: resolve against the directory of the current path
	local sourcePath = string.match(originalUrl.path, "^([^?]*)") or originalUrl.path
	local dir = string.match(sourcePath, "^(.*/)[^/]*$") or "/"
	return base .. dir .. location
end

local function encodeQueryScalar(value: QueryScalar, spaceIsPlus: boolean): string
	return urlEncoding.encode(tostring(value), spaceIsPlus)
end

local function encodeQueryPairs(data: { [string]: QueryValue }, spaceIsPlus: boolean): string
	local names = {}
	for name in data do
		table.insert(names, name)
	end
	table.sort(names)

	local parts = {}
	for _, name in names do
		local encodedName = urlEncoding.encode(name, spaceIsPlus)
		local value = data[name]

		if type(value) == "table" then
			for _, item in value do
				table.insert(parts, `{encodedName}={encodeQueryScalar(item, spaceIsPlus)}`)
			end
		else
			table.insert(parts, `{encodedName}={encodeQueryScalar(value :: QueryScalar, spaceIsPlus)}`)
		end
	end

	return table.concat(parts, "&")
end

--- Encodes a table as a URL query string without the leading `?`.
function util.encodeQuery(data: { [string]: QueryValue }): string
	return encodeQueryPairs(data, false)
end

--- Appends encoded query parameters to a URL.
function util.appendQuery(url: string, query: { [string]: QueryValue }?): string
	if query == nil then
		return url
	end

	local encoded = util.encodeQuery(query)
	if encoded == "" then
		return url
	end

	local separator = if string.find(url, "?", 1, true) then "&" else "?"
	return url .. separator .. encoded
end

--- Encodes a table as `application/x-www-form-urlencoded`.
function util.encodeForm(data: { [string]: QueryValue }): string
	return encodeQueryPairs(data, true)
end

--- Decodes a URL query string or x-www-form-urlencoded body.
function util.decodeForm(data: string): QueryTable
	local result: QueryTable = {}
	if data == "" then
		return result
	end

	local parsed = uri.parseQueryString(data, true)
	for name, value in parsed do
		if type(name) == "string" then
			if type(value) == "table" then
				result[name] = value :: { string }
			else
				result[name] = (value :: string?) or ""
			end
		end
	end

	return result
end

--- Splits a request target into pathname and decoded query parameters.
function util.parseRequestTarget(target: string): { path: string, queryString: string, query: QueryTable }
	local parsed = uri.parseReference(target, false)
	local path = parsed.path
	local queryString = parsed.query or ""
	return {
		path = path,
		queryString = queryString,
		query = util.decodeForm(queryString),
	}
end

--- Parses a Content-Type header into its media type and lowercase parameters.
function util.parseContentType(value: string?): { mediaType: string?, params: { [string]: string } }
	local params = {}
	if value == nil or value == "" then
		return {
			mediaType = nil,
			params = params,
		}
	end

	local parts = {}
	for part in string.gmatch(value, "([^;]+)") do
		table.insert(parts, part)
	end

	local mediaType = string.lower(util.trim(parts[1] :: string))
	for i = 2, #parts do
		local part = parts[i]
		local name, paramValue = string.match(part, "^%s*([^=]+)%s*=%s*(.-)%s*$")
		if name and paramValue then
			local cleaned = paramValue
			if string.sub(cleaned, 1, 1) == '"' and string.sub(cleaned, -1) == '"' then
				cleaned = string.sub(cleaned, 2, -2)
			end
			params[string.lower(name)] = cleaned
		end
	end

	return {
		mediaType = mediaType,
		params = params,
	}
end

function util.isJsonContentType(value: string?): boolean
	local parsed = util.parseContentType(value)
	local mediaType = parsed.mediaType
	if mediaType == nil then
		return false
	end
	return mediaType == "application/json" or string.sub(mediaType, -5) == "+json"
end

function util.getHeaderLines(value: string?): { string }
	local values = {}
	if value == nil or value == "" then
		return values
	end

	for line in string.gmatch(value, "([^\n]+)") do
		table.insert(values, util.trim(line))
	end
	return values
end

function util.parseContentLength(value: string?): number?
	if value == nil then
		return nil
	end

	local parsed: number? = nil
	for _, item in util.getHeaderLines(value) do
		if not string.match(item, "^%d+$") then
			error("Invalid Content-Length")
		end
		local current = tonumber(item)
		if current == nil then
			error("Invalid Content-Length")
		end
		if parsed ~= nil and parsed ~= current then
			error("Conflicting Content-Length values")
		end
		parsed = current
	end

	return parsed
end

function util.parseTransferEncoding(value: string?): { string }
	local encodings = {}
	if value == nil or value == "" then
		return encodings
	end

	for item in string.gmatch(value, "([^,]+)") do
		table.insert(encodings, string.lower(util.trim(item)))
	end
	return encodings
end

function util.parseHeaderTokens(value: string?): { string }
	local tokens = {}
	if value == nil or value == "" then
		return tokens
	end

	for item in string.gmatch(value, "([^,]+)") do
		table.insert(tokens, string.lower(util.trim(item)))
	end
	return tokens
end

function util.headerHasToken(value: string?, token: string): boolean
	local target = string.lower(token)
	for _, item in util.parseHeaderTokens(value) do
		if item == target then
			return true
		end
	end
	return false
end

--- Parse "Header-Name: value\r\n" lines into a table.
--- Header names are lowercased for easy lookup.
function util.parseHeaders(raw: string): { [string]: string }
	local headers: { [string]: string } = {}
	for line in string.gmatch(raw, "([^\r\n]+)") do
		local name, value = string.match(line, "^([^:]+):%s*(.*)$")
		if name then
			assert(value)
			local key = string.lower(name)
			if headers[key] then
				-- Set-Cookie must NOT be folded with ", " (RFC 6265 §3);
				-- use "\n" so individual cookies can be recovered.
				if key == "set-cookie" or key == "content-length" then
					headers[key] ..= "\n" .. value
				else
					-- Concatenate duplicate headers with ", " per RFC 7230 §3.2.2
					headers[key] ..= ", " .. value
				end
			else
				headers[key] = value
			end
		end
	end
	return headers
end

return table.freeze(util)
