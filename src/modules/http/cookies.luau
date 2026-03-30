local cookies = {}

--[=[
	A single HTTP cookie with its attributes.
]=]
export type Cookie = {
	name: string,
	value: string,
	domain: string,
	path: string,
	expires: number?, -- os.time() timestamp, nil = session cookie
	secure: boolean,
	httpOnly: boolean,
	sameSite: string?, -- "Strict", "Lax", or "None"
}

--- Parse a Set-Cookie header value into a Cookie table.
--- `requestHost` and `requestPath` provide defaults when the cookie
--- does not specify Domain or Path.
function cookies.parseCookie(setCookieStr: string, requestHost: string, requestPath: string): Cookie?
	-- Split on ";" to get name=value and attributes
	local parts: { string } = {}
	for part in string.gmatch(setCookieStr, "([^;]+)") do
		table.insert(parts, part)
	end

	if #parts == 0 then
		return nil
	end

	-- First part is name=value
	local nameValue = parts[1]
	local eqPos = string.find(nameValue, "=", 1, true)
	if not eqPos then
		return nil
	end

	local name = string.match(string.sub(nameValue, 1, eqPos - 1), "^%s*(.-)%s*$")
	local value = string.match(string.sub(nameValue, eqPos + 1), "^%s*(.-)%s*$")
	if not name or #name == 0 then
		return nil
	end

	local cookie: Cookie = {
		name = name :: string,
		value = value or "",
		domain = string.lower(requestHost),
		path = string.match(requestPath, "^(.*/)[^/]*$") or "/",
		expires = nil,
		secure = false,
		httpOnly = false,
		sameSite = nil,
	}

	-- Parse attributes
	for i = 2, #parts do
		local attr = string.match(parts[i], "^%s*(.-)%s*$") or ""
		local attrName, attrValue = string.match(attr, "^([^=]+)=?(.*)$")
		if attrName then
			local lowerAttr = string.lower(string.match(attrName, "^%s*(.-)%s*$") or "")
			attrValue = string.match(attrValue or "", "^%s*(.-)%s*$") or ""

			if lowerAttr == "domain" then
				local d = string.lower(attrValue)
				-- Strip leading dot (RFC 6265 §5.2.3)
				if string.sub(d, 1, 1) == "." then
					d = string.sub(d, 2)
				end
				cookie.domain = d
			elseif lowerAttr == "path" then
				if #attrValue > 0 then
					cookie.path = attrValue
				end
			elseif lowerAttr == "max-age" then
				local seconds = tonumber(attrValue)
				if seconds then
					cookie.expires = os.time() + seconds
				end
			elseif lowerAttr == "secure" then
				cookie.secure = true
			elseif lowerAttr == "httponly" then
				cookie.httpOnly = true
			elseif lowerAttr == "samesite" then
				cookie.sameSite = attrValue
			end
		end
	end

	return cookie
end

--- Check if a cookie's domain matches the request host.
--- Per RFC 6265 §5.1.3: exact match or host ends with ".domain".
function cookies.domainMatches(cookieDomain: string, requestHost: string): boolean
	requestHost = string.lower(requestHost)
	if cookieDomain == requestHost then
		return true
	end
	-- requestHost ends with ".cookieDomain"
	local suffix = "." .. cookieDomain
	if #requestHost > #suffix and string.sub(requestHost, -#suffix) == suffix then
		return true
	end
	return false
end

--- Check if a cookie's path matches the request path.
--- Per RFC 6265 §5.1.4.
function cookies.pathMatches(cookiePath: string, requestPath: string): boolean
	if cookiePath == requestPath then
		return true
	end
	if string.sub(requestPath, 1, #cookiePath) == cookiePath then
		if string.sub(cookiePath, -1) == "/" then
			return true
		end
		if string.sub(requestPath, #cookiePath + 1, #cookiePath + 1) == "/" then
			return true
		end
	end
	return false
end

return table.freeze(cookies)
