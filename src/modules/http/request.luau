local body = require("./body")
local cookieJar = require("./CookieJar")
local json = require("@eryx/encoding/json")
local multipart = require("./multipart")
local request = {}

local util = require("./util")
local HttpConnection = require("./HttpConnection")

local function findHeaderKey(headers: { [string]: string }, target: string): string?
	for name in headers do
		if string.lower(name) == target then
			return name
		end
	end
	return nil
end

local function hasHeader(headers: { [string]: string }?, target: string): boolean
	if headers == nil then
		return false
	end
	return findHeaderKey(headers, target) ~= nil
end

local function setHeader(headers: { [string]: string }, name: string, value: string)
	local existing = findHeaderKey(headers, string.lower(name))
	if existing then
		headers[existing] = nil :: any
	end
	headers[name] = value
end

local function clearHeader(headers: { [string]: string }?, name: string)
	if headers == nil then
		return
	end
	local existing = findHeaderKey(headers, string.lower(name))
	if existing then
		headers[existing] = nil :: any
	end
end

local function clearBodyHeaders(headers: { [string]: string }?)
	clearHeader(headers, "content-length")
	clearHeader(headers, "content-type")
	clearHeader(headers, "transfer-encoding")
end

--[=[
	Options for one-shot request functions like [[request]], [[get]], and [[post]].
]=]
export type RequestOptions = {
	headers: { [string]: string }?,
	body: string?,
	--- Incremental upload source. When provided, the request body is read
	--- chunk-by-chunk from `read(size?)`.
	bodyStream: HttpConnection.UploadBodyStream?,
	--- Exact byte length for `bodyStream`. When omitted, chunked request
	--- framing is used automatically.
	bodyLength: number?,
	query: { [string]: string | number | boolean | { string | number | boolean } }?,
	--- Form fields encoded as `application/x-www-form-urlencoded`.
	--- When provided, the request body is generated automatically unless
	--- `body` is also set, which is treated as an error.
	form: { [string]: string | number | boolean | { string | number | boolean } }?,
	--- JSON payload encoded with `@eryx/encoding/json`.
	json: any?,
	--- Multipart form fields encoded as `multipart/form-data`.
	multipart: { multipart.MultipartField }?,
	expectContinue: boolean?,
	--- Applies the same timeout to connect, read, and write phases.
	timeout: number?,
	--- Timeout used while opening the TCP/TLS connection.
	connectTimeout: number?,
	--- Timeout used while waiting for response bytes.
	readTimeout: number?,
	--- Timeout used while sending request headers and body bytes.
	writeTimeout: number?,
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
local function buildTimeoutOptions(options: RequestOptions?): HttpConnection.TimeoutOptions?
	if options == nil then
		return nil
	end

	local fallback = options.timeout
	local hasAny = fallback ~= nil
		or options.connectTimeout ~= nil
		or options.readTimeout ~= nil
		or options.writeTimeout ~= nil
	if not hasAny then
		return nil
	end

	return {
		connect = if options.connectTimeout ~= nil then options.connectTimeout else fallback,
		read = if options.readTimeout ~= nil then options.readTimeout else fallback,
		write = if options.writeTimeout ~= nil then options.writeTimeout else fallback,
	}
end

local function executeRequest(
	method: string,
	url: string,
	options: RequestOptions?,
	getConnection: (
		parsedUrl: { scheme: string, host: string, port: number, path: string }
	) -> HttpConnection.HttpConnection,
	closeConnectionAfterResponse: boolean
): HttpConnection.HttpResponse
	local opts: RequestOptions = options or {}
	local maxRedirects = if opts.maxRedirects ~= nil then opts.maxRedirects else 10
	local shouldDecompress = if opts.decompress ~= nil then opts.decompress else true
	local currentMethod = method
	local currentUrl = util.appendQuery(url, opts.query)
	local currentBody = opts.body
	local currentBodyStream = opts.bodyStream
	local currentBodyLength = opts.bodyLength
	local currentHeaders: { [string]: string }? = if opts.headers then table.clone(opts.headers) else nil
	local redirectCount = 0

	local bodySourceCount = 0
	if opts.body ~= nil then
		bodySourceCount += 1
	end
	if opts.bodyStream ~= nil then
		bodySourceCount += 1
	end
	if opts.form ~= nil then
		bodySourceCount += 1
	end
	if opts.json ~= nil then
		bodySourceCount += 1
	end
	if opts.multipart ~= nil then
		bodySourceCount += 1
	end
	if bodySourceCount > 1 then
		error("Request options may specify only one of 'body', 'bodyStream', 'form', 'json', or 'multipart'")
	end

	if opts.form ~= nil then
		currentBody = util.encodeForm(opts.form)
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "content-type") then
			setHeader(currentHeaders, "Content-Type", "application/x-www-form-urlencoded")
		end
	elseif opts.json ~= nil then
		currentBody = json.encode(opts.json)
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "content-type") then
			setHeader(currentHeaders, "Content-Type", "application/json")
		end
	elseif opts.multipart ~= nil then
		local encodedBody, contentType = multipart.encodeFields(opts.multipart)
		currentBody = encodedBody
		currentHeaders = if currentHeaders then currentHeaders else {}
		setHeader(currentHeaders, "Content-Type", contentType)
	end

	if opts.expectContinue then
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "expect") then
			setHeader(currentHeaders, "Expect", "100-continue")
		end
	end

	currentHeaders = if currentHeaders then currentHeaders else {}
	if not hasHeader(currentHeaders, "connection") then
		setHeader(currentHeaders, "Connection", "close")
	end

	-- Inject Accept-Encoding when the caller hasn't set it
	if shouldDecompress then
		local hdrs: { [string]: string } = if currentHeaders then table.clone(currentHeaders) else {}
		if not hasHeader(hdrs, "accept-encoding") then
			setHeader(hdrs, "Accept-Encoding", "gzip, deflate, br")
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

		local conn = getConnection(parsed_url)
		local ok, result = pcall(function()
			conn:request(
				currentMethod,
				parsed_url.path,
				reqHeaders,
				currentBody,
				opts.expectContinue == true,
				currentBodyStream,
				currentBodyLength
			)
			return conn:getResponse()
		end)
		if closeConnectionAfterResponse then
			conn:close()
		end

		if not ok then
			conn:close()
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
				currentBodyStream = nil
				currentBodyLength = nil
				clearBodyHeaders(currentHeaders)
			elseif status == 301 or status == 302 then
				if currentMethod ~= "GET" and currentMethod ~= "HEAD" then
					currentMethod = "GET"
					currentBody = nil
					currentBodyStream = nil
					currentBodyLength = nil
					clearBodyHeaders(currentHeaders)
				end
			end
			-- 307/308: keep currentMethod and currentBody as-is

			continue
		end

		return response
	end
end

request._execute = executeRequest

--[=[
	Makes a one-shot streamed HTTP request.

	Like [[request]], this opens a connection, sends the request, and
	returns the response, but the response body is consumed incrementally
	through `read`, `readAll`, and `close` instead of being buffered
	immediately.

	@param method The HTTP method (e.g. `"GET"`, `"POST"`).
	@param url The full URL including scheme and host.
	@param options Request options.
	@return HttpResponseStream -- The streamed response.
]=]
local function executeStreamingRequest(
	method: string,
	url: string,
	options: RequestOptions?,
	getConnection: (
		parsedUrl: { scheme: string, host: string, port: number, path: string }
	) -> HttpConnection.HttpConnection,
	closeConnectionAfterResponse: boolean
): HttpConnection.HttpResponseStream
	local opts: RequestOptions = options or {}
	local maxRedirects = if opts.maxRedirects ~= nil then opts.maxRedirects else 10
	local shouldDecompress = if opts.decompress ~= nil then opts.decompress else true
	local currentMethod = method
	local currentUrl = util.appendQuery(url, opts.query)
	local currentBody = opts.body
	local currentBodyStream = opts.bodyStream
	local currentBodyLength = opts.bodyLength
	local currentHeaders: { [string]: string }? = if opts.headers then table.clone(opts.headers) else nil
	local redirectCount = 0

	local bodySourceCount = 0
	if opts.body ~= nil then
		bodySourceCount += 1
	end
	if opts.bodyStream ~= nil then
		bodySourceCount += 1
	end
	if opts.form ~= nil then
		bodySourceCount += 1
	end
	if opts.json ~= nil then
		bodySourceCount += 1
	end
	if opts.multipart ~= nil then
		bodySourceCount += 1
	end
	if bodySourceCount > 1 then
		error("Request options may specify only one of 'body', 'bodyStream', 'form', 'json', or 'multipart'")
	end

	if opts.form ~= nil then
		currentBody = util.encodeForm(opts.form)
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "content-type") then
			setHeader(currentHeaders, "Content-Type", "application/x-www-form-urlencoded")
		end
	elseif opts.json ~= nil then
		currentBody = json.encode(opts.json)
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "content-type") then
			setHeader(currentHeaders, "Content-Type", "application/json")
		end
	elseif opts.multipart ~= nil then
		local encodedBody, contentType = multipart.encodeFields(opts.multipart)
		currentBody = encodedBody
		currentHeaders = if currentHeaders then currentHeaders else {}
		setHeader(currentHeaders, "Content-Type", contentType)
	end

	if opts.expectContinue then
		currentHeaders = if currentHeaders then currentHeaders else {}
		if not hasHeader(currentHeaders, "expect") then
			setHeader(currentHeaders, "Expect", "100-continue")
		end
	end

	currentHeaders = if currentHeaders then currentHeaders else {}
	if not hasHeader(currentHeaders, "connection") then
		setHeader(currentHeaders, "Connection", if closeConnectionAfterResponse then "close" else "keep-alive")
	end

	if shouldDecompress then
		local hdrs: { [string]: string } = if currentHeaders then table.clone(currentHeaders) else {}
		if not hasHeader(hdrs, "accept-encoding") then
			setHeader(hdrs, "Accept-Encoding", "gzip, deflate, br")
		end
		currentHeaders = hdrs
	end

	local cookieJar = opts.cookies

	local function wrapDecodedResponseStream(
		response: HttpConnection.HttpResponseStream
	): HttpConnection.HttpResponseStream
		if not shouldDecompress then
			return response
		end

		local contentEncoding = response.headers["content-encoding"]
		if contentEncoding == nil then
			return response
		end

		local decoder = body.createDecoder(contentEncoding)
		if decoder == nil then
			return response
		end

		local headers = table.clone(response.headers)
		headers["content-encoding"] = nil :: any
		headers["content-length"] = nil :: any

		local pending = ""
		local sourceClosed = false
		local closed = false

		local wrapped = {
			status = response.status,
			reason = response.reason,
			headers = headers,
			trailers = response.trailers,
			httpVersion = response.httpVersion,
			read = function(self, count: number?): string
				if closed then
					return ""
				end

				local limit = count or 65536
				if limit <= 0 then
					return ""
				end

				while #pending == 0 and not sourceClosed do
					local chunk = response:read(65536)
					if #chunk == 0 then
						sourceClosed = true
						break
					end
					pending ..= decoder:write(chunk)
				end

				if #pending == 0 then
					closed = true
					decoder:close()
					return ""
				end

				local take = math.min(limit, #pending)
				local out = string.sub(pending, 1, take)
				pending = string.sub(pending, take + 1)
				return out
			end,
			readAll = function(self): string
				local parts = {}
				while true do
					local chunk: string = self:read()
					if #chunk == 0 then
						break
					end
					table.insert(parts, chunk)
				end
				return table.concat(parts)
			end,
			close = function(self)
				if closed then
					return
				end
				closed = true
				decoder:close()
				response:close()
			end,
		}

		return wrapped :: any
	end

	while true do
		local parsed_url = util.parseUrl(currentUrl)
		local reqHeaders = currentHeaders
		if cookieJar then
			local cookieHeader = cookieJar:headerFor(parsed_url.scheme, parsed_url.host, parsed_url.path)
			if cookieHeader then
				reqHeaders = if reqHeaders then table.clone(reqHeaders) else {}
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

		local conn = getConnection(parsed_url)
		local ok, result = pcall(function()
			conn:request(
				currentMethod,
				parsed_url.path,
				reqHeaders,
				currentBody,
				opts.expectContinue == true,
				currentBodyStream,
				currentBodyLength
			)
			return conn:getResponseStream()
		end)

		if not ok then
			conn:close()
			error(result :: any)
		end

		local response = result :: HttpConnection.HttpResponseStream
		if cookieJar then
			local sc = response.headers["set-cookie"]
			if sc then
				for cookie in string.gmatch(sc, "([^\n]+)") do
					cookieJar:parseSetCookie(cookie, parsed_url.host, parsed_url.path)
				end
			end
		end

		response = wrapDecodedResponseStream(response)

		local status = response.status
		if
			maxRedirects > 0
			and redirectCount < maxRedirects
			and (status == 301 or status == 302 or status == 303 or status == 307 or status == 308)
		then
			local location = response.headers["location"]
			if not location then
				return response
			end

			response:close()
			redirectCount += 1
			currentUrl = util.resolveRedirect(parsed_url, location)

			if status == 303 then
				currentMethod = "GET"
				currentBody = nil
				currentBodyStream = nil
				currentBodyLength = nil
				clearBodyHeaders(currentHeaders)
			elseif status == 301 or status == 302 then
				if currentMethod ~= "GET" and currentMethod ~= "HEAD" then
					currentMethod = "GET"
					currentBody = nil
					currentBodyStream = nil
					currentBodyLength = nil
					clearBodyHeaders(currentHeaders)
				end
			end

			continue
		end

		return response
	end
end

request._executeStream = executeStreamingRequest

function request.request(method: string, url: string, options: RequestOptions?): HttpConnection.HttpResponse
	return executeRequest(method, url, options, function(parsedUrl)
		return HttpConnection.new(
			parsedUrl.host,
			parsedUrl.port,
			buildTimeoutOptions(options),
			parsedUrl.scheme,
			options and options.verifySsl
		)
	end, true)
end

--[=[
	Makes a one-shot streamed HTTP request.

	The returned response must be fully consumed or explicitly closed.

	@param method The HTTP method (e.g. `"GET"`, `"POST"`).
	@param url The full URL including scheme and host.
	@param options Request options.
	@return HttpResponseStream -- The streamed response.
]=]
function request.stream(method: string, url: string, options: RequestOptions?): HttpConnection.HttpResponseStream
	return executeStreamingRequest(method, url, options, function(parsedUrl)
		return HttpConnection.new(
			parsedUrl.host,
			parsedUrl.port,
			buildTimeoutOptions(options),
			parsedUrl.scheme,
			options and options.verifySsl
		)
	end, true)
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

--[=[
	Raises an error for HTTP 4xx and 5xx responses.

	@param response A buffered HTTP response.
	@return HttpResponse -- The same response when the status is not an
	error.
]=]
function request.raiseForStatus(response: HttpConnection.HttpResponse): HttpConnection.HttpResponse
	if response.status >= 400 then
		error(`HTTP request failed with {response.status} {response.reason}`)
	end
	return response
end

--[=[
	Decodes a buffered response body as JSON.

	@param response A buffered HTTP response.
	@return any -- The decoded JSON value.
]=]
function request.decodeJsonBody(response: HttpConnection.HttpResponse): any
	return json.decode(response.body)
end

--[=[
	Decodes a buffered response body as `application/x-www-form-urlencoded`.

	@param response A buffered HTTP response.
	@return { [string]: string | { string } } -- The decoded form fields.
]=]
function request.decodeFormBody(response: HttpConnection.HttpResponse): { [string]: string | { string } }
	return util.decodeForm(response.body)
end

--[=[
	Decodes a buffered response body as `multipart/form-data`.

	The response must include a `content-type` header with a `boundary`
	parameter.

	@param response A buffered HTTP response.
	@return { multipart.ParsedMultipartField } -- The decoded multipart
	fields.
]=]
function request.decodeMultipartBody(response: HttpConnection.HttpResponse): { multipart.ParsedMultipartField }
	local parsed = util.parseContentType(response.headers["content-type"])
	if parsed.mediaType ~= "multipart/form-data" then
		error("Response is not multipart/form-data")
	end
	local boundary = parsed.params.boundary
	if boundary == nil or boundary == "" then
		error("Multipart response is missing a boundary")
	end
	return multipart.parse(response.body, boundary)
end

return table.freeze(request)
