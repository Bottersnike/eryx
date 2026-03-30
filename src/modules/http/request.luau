local body = require("./body")
local cookieJar = require("./cookieJar")
local request = {}

local util = require("./util")
local HttpConnection = require("./HttpConnection")

--[=[
	Options for one-shot request functions like [[request]], [[get]], and [[post]].
]=]
export type RequestOptions = {
	headers: { [string]: string }?,
	body: string?,
	timeout: number?,
	verifySsl: boolean?,
	--- Maximum number of redirects to follow. Set to 0 to disable redirect
	--- following. Defaults to 10.
	maxRedirects: number?,
	--- Automatically decompress gzip/deflate response bodies and send
	--- `Accept-Encoding`. Set to false to receive raw compressed bytes.
	--- Defaults to true.
	decompress: boolean?,
	--- A [[CookieJar]] for automatic cookie handling. When provided,
	--- matching cookies are sent with the request and `Set-Cookie`
	--- response headers are stored in the jar.
	cookies: cookieJar.CookieJar?,
}

--[=[
	Makes a one-shot HTTP request.

	Opens a connection, sends the request, reads the response, and closes
	the connection. For multiple requests to the same host, use
	[[HttpConnection]] directly.

	```luau
	local resp = request.request("POST", "http://example.com/api", {
	    headers = { ["Content-Type"] = "application/json" },
	    body = '{"key": "value"}',
	})
	```

	@param method The HTTP method (e.g. `"GET"`, `"POST"`).
	@param url The full URL including scheme and host.
	@param options Request options (headers, body, timeout, etc.).
	@return HttpResponse -- The parsed response.
]=]
function request.request(method: string, url: string, options: RequestOptions?): HttpConnection.HttpResponse
	local opts: RequestOptions = options or {}
	local maxRedirects = if opts.maxRedirects ~= nil then opts.maxRedirects else 10
	local shouldDecompress = if opts.decompress ~= nil then opts.decompress else true
	local currentMethod = method
	local currentUrl = url
	local currentBody = opts.body
	local currentHeaders: { [string]: string }? = opts.headers
	local redirectCount = 0

	-- Inject Accept-Encoding when the caller hasn't set it
	if shouldDecompress then
		local hdrs: { [string]: string } = if currentHeaders then table.clone(currentHeaders) else {}
		local hasAE = false
		for k in hdrs do
			if string.lower(k) == "accept-encoding" then
				hasAE = true
				break
			end
		end
		if not hasAE then
			hdrs["Accept-Encoding"] = "gzip, deflate"
		end
		currentHeaders = hdrs
	end

	local cookieJar = opts.cookies

	while true do
		local parsed_url = util.parseUrl(currentUrl)

		-- Inject cookies from the jar into the request headers
		local reqHeaders = currentHeaders
		if cookieJar then
			local cookieHeader = cookieJar:headerFor(parsed_url.scheme, parsed_url.host, parsed_url.path)
			if cookieHeader then
				reqHeaders = if reqHeaders then table.clone(reqHeaders) else {}
				-- Merge with any manually-set Cookie header
				local existing: string? = nil
				for k, v in reqHeaders :: { [string]: string } do
					if string.lower(k) == "cookie" then
						existing = v
						break
					end
				end
				if existing then
					(reqHeaders :: { [string]: string })["Cookie"] = existing .. "; " .. cookieHeader
				else
					(reqHeaders :: { [string]: string })["Cookie"] = cookieHeader
				end
			end
		end

		local conn =
			HttpConnection.new(parsed_url.host, parsed_url.port, opts.timeout, parsed_url.scheme, opts.verifySsl)
		local ok, result = pcall(function()
			conn:request(currentMethod, parsed_url.path, reqHeaders, currentBody)
			return conn:getResponse()
		end)
		conn:close()

		if not ok then
			error(result :: any)
		end

		local response = result :: HttpConnection.HttpResponse

		-- Store Set-Cookie headers in the jar.
		-- parseHeaders joins multiple Set-Cookie values with "\n".
		if cookieJar then
			local sc = response.headers["set-cookie"]
			if sc then
				for cookie in string.gmatch(sc, "([^\n]+)") do
					cookieJar:parseSetCookie(cookie, parsed_url.host, parsed_url.path)
				end
			end
		end

		-- Decompress body if needed
		if shouldDecompress then
			local ce = response.headers["content-encoding"]
			if ce then
				response.body = body.decompress(response.body, ce)
				-- Remove content-encoding since body is now decompressed
				response.headers["content-encoding"] = nil :: any
			end
		end

		local status = response.status

		-- Check for redirect status codes
		if
			maxRedirects > 0
			and redirectCount < maxRedirects
			and (status == 301 or status == 302 or status == 303 or status == 307 or status == 308)
		then
			local location = response.headers["location"]
			if not location then
				return response
			end

			redirectCount += 1
			currentUrl = util.resolveRedirect(parsed_url, location)

			-- 303: always switch to GET, drop body
			-- 301/302: switch to GET (browser behavior) unless original was GET/HEAD
			-- 307/308: preserve method and body
			if status == 303 then
				currentMethod = "GET"
				currentBody = nil
			elseif status == 301 or status == 302 then
				if currentMethod ~= "GET" and currentMethod ~= "HEAD" then
					currentMethod = "GET"
					currentBody = nil
				end
			end
			-- 307/308: keep currentMethod and currentBody as-is

			continue
		end

		return response
	end
end

--[=[
	Convenience wrapper for a `GET` request.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response.
]=]
function request.get(url: string, options: RequestOptions?): HttpConnection.HttpResponse
	return request.request("GET", url, options)
end

--[=[
	Convenience wrapper for a `POST` request.

	@param url The full URL to request.
	@param body The request body string.
	@param options Additional request options.
	@return HttpResponse -- The parsed response.
]=]
function request.post(url: string, body: string?, options: RequestOptions?): HttpConnection.HttpResponse
	local opts: RequestOptions = options or {}
	opts.body = body or opts.body
	return request.request("POST", url, opts)
end

--[=[
	Convenience wrapper for a `PUT` request.

	@param url The full URL to request.
	@param body The request body string.
	@param options Additional request options.
	@return HttpResponse -- The parsed response.
]=]
function request.put(url: string, body: string?, options: RequestOptions?): HttpConnection.HttpResponse
	local opts: RequestOptions = options or {}
	opts.body = body or opts.body
	return request.request("PUT", url, opts)
end

--[=[
	Convenience wrapper for a `DELETE` request.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response.
]=]
function request.delete(url: string, options: RequestOptions?): HttpConnection.HttpResponse
	return request.request("DELETE", url, options)
end

--[=[
	Convenience wrapper for a `HEAD` request.

	Returns headers only - the body will be empty.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response (body is empty).
]=]
function request.head(url: string, options: RequestOptions?): HttpConnection.HttpResponse
	return request.request("HEAD", url, options)
end

return table.freeze(request)
