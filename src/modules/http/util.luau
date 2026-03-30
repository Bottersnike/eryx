local util = {}

--- Parse a URL into (scheme, host, port, path)
function util.parseUrl(url: string): { scheme: string, host: string, port: number, path: string }
	-- scheme://host[:port][/path]
	local scheme, rest = string.match(url, "^(https?)://(.+)$")
	if not scheme then
		error("Unsupported or malformed URL: " .. url)
	end

	-- Split host and path
	local hostport, path = string.match(rest :: string, "^([^/]+)(/.*)$")
	if not hostport then
		hostport = rest :: string
		path = "/"
	end

	-- Split host and port
	-- Handle IPv6: [::1]:port
	local host: string, port: number
	local bracket_host, bracket_port = string.match(hostport :: string, "^%[([^%]]+)%]:(%d+)$")
	if bracket_host then
		host = bracket_host
		port = tonumber(bracket_port) :: number
	else
		local bracket_host_only = string.match(hostport :: string, "^%[([^%]]+)%]$")
		if bracket_host_only then
			host = bracket_host_only
			port = if scheme == "https" then 443 else 80
		else
			local h, p = string.match(hostport :: string, "^(.+):(%d+)$")
			if h then
				host = h
				port = tonumber(p) :: number
			else
				host = hostport :: string
				port = if scheme == "https" then 443 else 80
			end
		end
	end

	return { scheme = scheme :: string, host = host, port = port, path = path :: string }
end

--- Resolves a possibly-relative Location header against the original URL.
function util.resolveRedirect(
	originalUrl: { scheme: string, host: string, port: number, path: string },
	location: string
): string
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
	local base = originalUrl.scheme .. "://" .. originalUrl.host .. portSuffix

	if string.sub(location, 1, 1) == "/" then
		return base .. location
	end

	-- Relative path: resolve against the directory of the current path
	local dir = string.match(originalUrl.path, "^(.*/)[^/]*$") or "/"
	return base .. dir .. location
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
				if key == "set-cookie" then
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
