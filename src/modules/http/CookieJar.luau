--[=[
	A cookie jar that stores cookies and automatically attaches them to
	matching requests.

	```luau
	local jar = http.CookieJar.new()

	-- Make requests with automatic cookie handling
	local resp = http.get("http://example.com/login", { cookies = jar })
	-- jar now contains any Set-Cookie headers from the response

	-- Subsequent requests send matching cookies automatically
	local resp2 = http.get("http://example.com/dashboard", { cookies = jar })
	```
]=]
local cookies = require("./cookies")

local CookieJar = {}
CookieJar.__index = CookieJar

type CookieJarFields = {
	_cookies: { cookies.Cookie },
}

export type CookieJar = setmetatable<CookieJarFields, typeof(CookieJar)>

--[=[
	Creates a new, empty cookie jar.

	@return CookieJar -- A new cookie jar.
]=]
function CookieJar.new(): CookieJar
	return setmetatable({ _cookies = {} :: { cookies.Cookie } }, CookieJar)
end

--[=[
	Stores cookies from a `Set-Cookie` response header.

	Parses the header value and stores the cookie with proper domain
	and path defaults derived from the request URL. Existing cookies
	with the same name/domain/path are replaced.

	@param setCookieHeader The raw `Set-Cookie` header value.
	@param requestHost     The host the request was sent to.
	@param requestPath     The path the request was sent to.
]=]
function CookieJar.parseSetCookie(self: CookieJar, setCookieHeader: string, requestHost: string, requestPath: string)
	local cookie = cookies.parseCookie(setCookieHeader, requestHost, requestPath)
	if not cookie then
		return
	end

	-- Replace existing cookie with same name+domain+path
	for i, existing in self._cookies do
		if existing.name == cookie.name and existing.domain == cookie.domain and existing.path == cookie.path then
			self._cookies[i] = cookie
			return
		end
	end

	table.insert(self._cookies, cookie)
end

--[=[
	Returns all cookies that match the given URL components.

	Expired cookies are automatically removed. Only cookies whose
	domain and path match the request are returned.

	@param scheme The request scheme (`"http"` or `"https"`).
	@param host   The request host.
	@param path   The request path.
	@return { Cookie } -- Matching cookies.
]=]
function CookieJar.getCookies(self: CookieJar, scheme: string, host: string, path: string): { cookies.Cookie }
	local now = os.time()
	local matched: { cookies.Cookie } = {}

	-- Iterate in reverse so we can remove expired cookies
	local i = #self._cookies
	while i >= 1 do
		local c = self._cookies[i]
		-- Remove expired cookies
		if c.expires and c.expires <= now then
			table.remove(self._cookies, i)
		elseif cookies.domainMatches(c.domain, host) and cookies.pathMatches(c.path, path) then
			-- Secure cookies only sent over HTTPS
			if not c.secure or scheme == "https" then
				table.insert(matched, c)
			end
		end
		i -= 1
	end

	return matched
end

--[=[
	Builds the `Cookie` header string for a request to the given URL.

	@param scheme The request scheme.
	@param host   The request host.
	@param path   The request path.
	@return string? -- The `Cookie` header value, or `nil` if no cookies match.
]=]
function CookieJar.headerFor(self: CookieJar, scheme: string, host: string, path: string): string?
	local cookies = self:getCookies(scheme, host, path)
	if #cookies == 0 then
		return nil
	end

	local pairs_: { string } = {}
	for _, c in cookies do
		table.insert(pairs_, c.name .. "=" .. c.value)
	end
	return table.concat(pairs_, "; ")
end

--[=[
	Returns the number of cookies stored in the jar.

	@return number -- The cookie count.
]=]
function CookieJar.count(self: CookieJar): number
	return #self._cookies
end

--[=[
	Removes all cookies from the jar.
]=]
function CookieJar.clear(self: CookieJar)
	table.clear(self._cookies)
end

return table.freeze(CookieJar)
