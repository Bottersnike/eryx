--[=[
	HTTP/1.1 client and server library.

	Built on top of `@eryx/_socket` and `@eryx/_ssl`, this module provides
	both one-shot convenience functions and lower-level connection and
	server classes for HTTP and HTTPS.

	**Client - one-shot request:**
	```luau
	local http = require("@eryx/http")

	local response = http.get("http://example.com/")
	print(response.status, response.reason)
	print(response.body)
	```

	**Client - persistent connection:**
	```luau
	local conn = http.HttpConnection.new("example.com", 80)
	conn:Request("GET", "/")
	local resp = conn:GetResponse()
	conn:Close()
	```

	**Server:**
	```luau
	local server = http.createServer(function(req, res)
	    res:Send(200, "Hello, world!")
	end, { port = 8080 })
	server:Listen(function(host, port)
	    print("Listening on " .. host .. ":" .. tostring(port))
	end)
	```

	**HTTPS Server:**
	```luau
	local ssl  = require("@eryx/_ssl")
	local ctx  = ssl.create_server_context("cert.pem", "key.pem")
	local server = http.createServer(handler, { port = 443, sslCtx = ctx })
	server:Listen()
	```
]=]

local _socket = require("@eryx/_socket")
local _ssl = require("@eryx/_ssl")

-- ───────────────────────────────────────────────────────────────────────────
-- Helpers
-- ───────────────────────────────────────────────────────────────────────────

--- String -> buffer
local function strToBuf(s: string): buffer
	return buffer.fromstring(s)
end

--- Buffer -> string
local function bufToStr(b: buffer): string
	return buffer.tostring(b)
end

--- Parse a URL into (scheme, host, port, path)
local function parseUrl(url: string): { scheme: string, host: string, port: number, path: string }
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

--- Parse "Header-Name: value\r\n" lines into a table.
--- Header names are lowercased for easy lookup.
local function parseHeaders(raw: string): { [string]: string }
	local headers: { [string]: string } = {}
	for line in string.gmatch(raw, "([^\r\n]+)") do
		local name, value = string.match(line, "^([^:]+):%s*(.*)$")
		if name then
			assert(value)
			local key = string.lower(name)
			-- Concatenate duplicate headers with ", " per RFC 7230 §3.2.2
			if headers[key] then
				headers[key] ..= ", " .. value
			else
				headers[key] = value
			end
		end
	end
	return headers
end

-- ───────────────────────────────────────────────────────────────────────────
-- HttpResponse
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	A completed HTTP response returned by [[HttpConnection.GetResponse]]
	and the convenience request functions.
]=]
export type HttpResponse = {
	status: number,
	reason: string,
	headers: { [string]: string },
	body: string,
	httpVersion: string,
}

-- ───────────────────────────────────────────────────────────────────────────
-- HttpConnection  –  persistent connection to a single host:port
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	A persistent HTTP connection to a single host and port.

	Supports both HTTP and HTTPS. Multiple requests can be sent over
	the same connection when the server supports keep-alive.

	```luau
	local conn = http.HttpConnection.new("example.com", 443, nil, "https")
	conn:Request("GET", "/")
	local resp = conn:GetResponse()
	print(resp.status, resp.body)
	conn:Close()
	```
]=]
local HttpConnection = {}
HttpConnection.__index = HttpConnection

type HttpConnectionFields = {
	host: string,
	port: number,
	timeout: number?,
	_scheme: string,
	_verifySsl: boolean,
	_sock: any?, -- _socket.Socket or _ssl.SSLSocket (same send/sendall/recv/close interface)
	_leftover: string,
}

export type HttpConnection = typeof(setmetatable({} :: HttpConnectionFields, HttpConnection))

--[=[
	Creates a new [[HttpConnection]] to the given host.

	The connection is not established until the first request is sent
	(or [[HttpConnection.Connect]] is called explicitly).

	@param host The remote hostname or IP address.
	@param port The remote port number. Defaults to 80 for HTTP, 443 for HTTPS.
	@param timeout Request timeout in seconds.
	@param scheme `"http"` (default) or `"https"`.
	@param verifySsl Whether to verify the server's TLS certificate. Defaults to `true`.
	@return HttpConnection -- A new connection object.
]=]
function HttpConnection.new(
	host: string,
	port: number?,
	timeout: number?,
	scheme: string?,
	verifySsl: boolean?
): HttpConnection
	local s = scheme or "http"
	local self = setmetatable(
		{
			host = host,
			port = port or (if s == "https" then 443 else 80),
			timeout = timeout,
			_scheme = s,
			_verifySsl = if verifySsl == nil then true else verifySsl,
			_sock = nil :: any?,
			_leftover = "",
		} :: HttpConnectionFields,
		HttpConnection
	)
	return self
end

--[=[
	Opens the underlying TCP (and optionally TLS) connection.

	This is called automatically on the first request, so you rarely
	need to call it directly.
]=]
function HttpConnection.Connect(self: HttpConnection)
	if self._sock then
		return
	end

	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	if self.timeout then
		sock:SetTimeout(self.timeout)
	end
	sock:SetSockOpt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, true)
	sock:Connect(self.host, self.port)

	if self._scheme == "https" then
		-- Wrap the raw TCP socket with TLS
		local ctx = _ssl.createDefaultContext()
		if not self._verifySsl then
			ctx:SetVerify(_ssl.VERIFY_NONE)
		end
		local ssock = ctx:WrapSocket(sock, self.host)
		self._sock = ssock
	else
		self._sock = sock
	end
	self._leftover = ""
end

--[=[
	Closes the connection and releases associated resources.

	It is safe to call `Close` multiple times.
]=]
function HttpConnection.Close(self: HttpConnection)
	if self._sock then
		pcall(function()
			(self._sock :: any):Close()
		end)
		self._sock = nil
		self._leftover = ""
	end
end

--[=[
	Sends an HTTP request over this connection.

	Automatically connects if not already connected. Sets `Host` and
	`Content-Length` headers when not explicitly provided.

	@param method The HTTP method (e.g. `"GET"`, `"POST"`).
	@param path The request path (e.g. `"/api/users"`).
	@param headers Optional table of request headers.
	@param body Optional request body string.
]=]
function HttpConnection.Request(
	self: HttpConnection,
	method: string,
	path: string,
	headers: { [string]: string }?,
	body: string?
)
	-- Auto-connect if not already connected
	if not self._sock then
		self:Connect()
	end

	-- Build header block
	local hdrs: { [string]: string } = {}
	if headers then
		for k, v in headers do
			hdrs[string.lower(k)] = v
		end
	end

	-- Set Host if not provided
	if not hdrs["host"] then
		if self.port == 80 or self.port == 443 then
			hdrs["host"] = self.host
		else
			hdrs["host"] = self.host .. ":" .. tostring(self.port)
		end
	end

	-- Set Content-Length for bodies
	if body and not hdrs["content-length"] and not hdrs["transfer-encoding"] then
		hdrs["content-length"] = tostring(#body)
	end

	-- Default connection header
	if not hdrs["connection"] then
		hdrs["connection"] = "close"
	end

	-- Build request line + headers
	local lines: { string } = {}
	table.insert(lines, method .. " " .. path .. " HTTP/1.1\r\n")
	for name, value in hdrs do
		table.insert(lines, name .. ": " .. value .. "\r\n")
	end
	table.insert(lines, "\r\n")

	local request_str = table.concat(lines)
	local sock = self._sock :: any
	sock:SendAll(strToBuf(request_str))

	-- Send body if present
	if body and #body > 0 then
		sock:SendAll(strToBuf(body))
	end
end

--- Internal: read from socket, respecting leftover from previous over-reads
function HttpConnection._RecvUntil(self: HttpConnection, delim: string): (string, string)
	local accumulated = self._leftover
	self._leftover = ""

	-- Check if the delimiter is already in the leftover
	local pos = string.find(accumulated, delim, 1, true)
	if pos then
		local result = string.sub(accumulated, 1, pos + #delim - 1)
		self._leftover = string.sub(accumulated, pos + #delim)
		return result, self._leftover
	end

	local sock = self._sock :: any
	while true do
		local ok, chunk = pcall(sock.Recv, sock, 8192)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = bufToStr(chunk)
		if #s == 0 then
			break
		end
		accumulated ..= s
		pos = string.find(accumulated, delim, 1, true)
		if pos then
			local result = string.sub(accumulated, 1, pos + #delim - 1)
			self._leftover = string.sub(accumulated, pos + #delim)
			return result, self._leftover
		end
	end
	return accumulated, ""
end

--- Internal: read exactly n bytes, respecting leftover
function HttpConnection._RecvExact(self: HttpConnection, n: number): string
	local accumulated = self._leftover
	self._leftover = ""

	local sock = self._sock :: any
	while #accumulated < n do
		local remaining = n - #accumulated
		local ok, chunk = pcall(sock.Recv, sock, remaining)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = bufToStr(chunk)
		if #s == 0 then
			break
		end
		accumulated ..= s
	end

	if #accumulated > n then
		self._leftover = string.sub(accumulated, n + 1)
		return string.sub(accumulated, 1, n)
	end
	return accumulated
end

--- Internal: read until connection closes, respecting leftover
function HttpConnection._RecvAll(self: HttpConnection): string
	local parts: { string } = {}
	if #self._leftover > 0 then
		table.insert(parts, self._leftover)
		self._leftover = ""
	end

	local sock = self._sock :: any
	while true do
		local ok, chunk = pcall(sock.Recv, sock, 65536)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = bufToStr(chunk)
		if #s == 0 then
			break
		end
		table.insert(parts, s)
	end
	return table.concat(parts)
end

--- Internal: read chunked transfer-encoding body
function HttpConnection._RecvChunked(self: HttpConnection): string
	local parts: { string } = {}

	while true do
		-- Read chunk size line
		local size_line = self:_RecvUntil("\r\n")
		-- Strip the delimiter
		size_line = string.gsub(size_line, "\r\n$", "")
		-- Chunk size may have extensions after a semicolon
		local size_str = string.match(size_line, "^([0-9a-fA-F]+)")
		if not size_str then
			break
		end

		local chunk_size = tonumber(size_str, 16)
		if not chunk_size or chunk_size == 0 then
			-- Terminal chunk - read trailing \r\n
			self:_RecvUntil("\r\n")
			break
		end

		-- Read exactly chunk_size bytes + trailing \r\n
		local data = self:_RecvExact(chunk_size)
		table.insert(parts, data)
		-- Consume trailing \r\n after chunk data
		self:_RecvExact(2)
	end

	return table.concat(parts)
end

function HttpConnection.GetResponse(self: HttpConnection): HttpResponse
	-- Read the status line + all headers (terminated by \r\n\r\n)
	local head_raw = self:_RecvUntil("\r\n\r\n")

	if #head_raw == 0 then
		error("Connection closed before receiving HTTP response")
	end

	-- Split status line from headers
	local status_end = string.find(head_raw, "\r\n", 1, true)
	if not status_end then
		error("Malformed HTTP response (no CRLF found): " .. string.sub(head_raw, 1, 200))
	end
	local status_line = string.sub(head_raw, 1, status_end - 1)
	local headers_raw = string.sub(head_raw, status_end + 2)

	-- Parse status line: "HTTP/1.1 200 OK"
	local httpVersion, status_str, reason = string.match(status_line, "^(HTTP/%d+%.%d+)%s+(%d+)%s*(.*)")
	if not httpVersion then
		error("Malformed HTTP status line: " .. status_line)
	end
	local status_code = tonumber(status_str) :: number

	-- Parse headers
	local headers = parseHeaders(headers_raw)

	-- Read body based on Transfer-Encoding / Content-Length
	local body: string
	local te = headers["transfer-encoding"]
	local cl = headers["content-length"]

	if te and string.find(string.lower(te), "chunked", 1, true) then
		body = self:_RecvChunked()
	elseif cl then
		local content_length = tonumber(cl)
		if content_length and content_length > 0 then
			body = self:_RecvExact(content_length)
		else
			body = ""
		end
	else
		-- No content-length and not chunked - read until close
		-- (for responses that have a body)
		if status_code >= 200 and status_code ~= 204 and status_code ~= 304 then
			body = self:_RecvAll()
		else
			body = ""
		end
	end

	-- If Connection: close, shut down the socket
	local conn_header = headers["connection"]
	if conn_header and string.lower(conn_header) == "close" then
		self:Close()
	end

	return {
		status = status_code,
		reason = (reason or "") :: string,
		headers = headers,
		body = body,
		httpVersion = httpVersion :: string,
	}
end

-- ───────────────────────────────────────────────────────────────────────────
-- Module-level convenience functions
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	Options for one-shot request functions like [[request]], [[get]], and [[post]].
]=]
export type RequestOptions = {
	headers: { [string]: string }?,
	body: string?,
	timeout: number?,
	verifySsl: boolean?,
}

-- ───────────────────────────────────────────────────────────────────────────
-- Reason phrase lookup
-- ───────────────────────────────────────────────────────────────────────────

local _STATUS_REASONS: { [number]: string } = {
	[100] = "Continue",
	[101] = "Switching Protocols",
	[200] = "OK",
	[201] = "Created",
	[202] = "Accepted",
	[204] = "No Content",
	[206] = "Partial Content",
	[301] = "Moved Permanently",
	[302] = "Found",
	[303] = "See Other",
	[304] = "Not Modified",
	[307] = "Temporary Redirect",
	[308] = "Permanent Redirect",
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[408] = "Request Timeout",
	[409] = "Conflict",
	[410] = "Gone",
	[411] = "Length Required",
	[413] = "Payload Too Large",
	[414] = "URI Too Long",
	[415] = "Unsupported Media Type",
	[422] = "Unprocessable Entity",
	[429] = "Too Many Requests",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[502] = "Bad Gateway",
	[503] = "Service Unavailable",
	[504] = "Gateway Timeout",
}

local function _reasonFor(code: number): string
	return _STATUS_REASONS[code] or "Unknown"
end

-- ───────────────────────────────────────────────────────────────────────────
-- ServerRequest  –  represents an incoming HTTP request
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	An incoming HTTP request received by an [[HttpServer]].

	Header names are lowercased for consistent lookup.
]=]
export type ServerRequest = {
	method: string,
	path: string,
	httpVersion: string,
	headers: { [string]: string },
	body: string,
	remoteAddr: string,
	remotePort: number,
}

-- ───────────────────────────────────────────────────────────────────────────
-- ServerResponse  –  writable response for streaming or one-shot replies
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	A writable HTTP response used inside an [[HttpServer]] handler.

	Supports both one-shot replies and streaming (chunked transfer-encoding).

	**One-shot:**
	```luau
	res:Send(200, "Hello!")
	```

	**Streaming:**
	```luau
	res:Status(200):Header("content-type", "text/plain")
	res:Write("chunk 1")
	res:Write("chunk 2")
	res:Finish()
	```
]=]
local ServerResponse = {}
ServerResponse.__index = ServerResponse

type ServerResponseFields = {
	_sock: any, -- the accepted client socket (or SSLSocket)
	_headersSent: boolean,
	_finished: boolean,
	_status: number,
	_reason: string,
	_headers: { [string]: string },
	_chunked: boolean,
}

export type ServerResponse = setmetatable<ServerResponseFields, typeof(ServerResponse)>

function ServerResponse._new(sock: any): ServerResponse
	return setmetatable({
		_sock = sock,
		_headersSent = false,
		_finished = false,
		_status = 200,
		_reason = "OK",
		_headers = {} :: { [string]: string },
		_chunked = false,
	}, ServerResponse)
end

--[=[
	Sets the HTTP status code and optional reason phrase.

	Must be called before [[ServerResponse.Write]] or [[ServerResponse.Finish]].
	Returns `self` for chaining.

	@param code The HTTP status code (e.g. `200`, `404`).
	@param reason Custom reason phrase. Defaults to the standard phrase for the code.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.Status(self: ServerResponse, code: number, reason: string?): ServerResponse
	assert(not self._headersSent, "Cannot set status after headers have been sent")
	self._status = code
	self._reason = reason or _reasonFor(code)
	return self
end

--[=[
	Sets a single response header.

	Must be called before [[ServerResponse.Write]] or [[ServerResponse.Finish]].
	Returns `self` for chaining.

	@param name The header name (case-insensitive).
	@param value The header value.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.Header(self: ServerResponse, name: string, value: string): ServerResponse
	assert(not self._headersSent, "Cannot set headers after headers have been sent")
	self._headers[string.lower(name)] = value
	return self
end

--[=[
	Sets multiple response headers at once.

	Must be called before [[ServerResponse.Write]] or [[ServerResponse.Finish]].
	Returns `self` for chaining.

	@param hdrs A table of header name/value pairs.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.Headers(self: ServerResponse, hdrs: { [string]: string }): ServerResponse
	assert(not self._headersSent, "Cannot set headers after headers have been sent")
	for k, v in hdrs do
		self._headers[string.lower(k)] = v
	end
	return self
end

--- Internal: flush the status line + headers to the socket.
function ServerResponse._SendHead(self: ServerResponse)
	if self._headersSent then
		return
	end
	self._headersSent = true

	-- If no content-length was set, use chunked transfer-encoding so
	-- the caller can stream multiple Write() calls.

	local cl = self._headers["content-length"]
	local te = self._headers["transfer-encoding"]

	if not cl and not te then
		self._headers["transfer-encoding"] = "chunked"
		self._chunked = true
	elseif te and string.find(string.lower(te), "chunked", 1, true) then
		self._chunked = true
	end

	if not self._headers["connection"] then
		self._headers["connection"] = "close"
	end

	local lines: { string } = {}
	table.insert(lines, "HTTP/1.1 " .. tostring(self._status) .. " " .. self._reason :: string .. "\r\n")
	for name, value in self._headers :: { [string]: string } do
		table.insert(lines, name .. ": " .. value .. "\r\n")
	end
	table.insert(lines, "\r\n")

	self._sock:SendAll(strToBuf(table.concat(lines)))
end

--[=[
	Writes a chunk of the response body.

	Sends headers on the first call. Can be called multiple times for
	streaming or long-polling. Uses chunked transfer-encoding when
	no `Content-Length` is set.

	@param data The body chunk to send.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.Write(self: ServerResponse, data: string): ServerResponse
	assert(not self._finished, "Cannot write after response is finished")
	self:_SendHead()

	if #data == 0 then
		return self
	end

	if self._chunked then
		-- Chunked encoding: size in hex + CRLF + data + CRLF
		local chunk = string.format("%x\r\n", #data) .. data .. "\r\n"
		self._sock:SendAll(strToBuf(chunk))
	else
		self._sock:SendAll(strToBuf(data))
	end
	return self
end

--[=[
	Finishes the response.

	Sends the terminating chunk if chunked transfer-encoding is active.
	If `body` is provided, it is a shorthand for
	`Write(body)` followed by `Finish()`.

	@param body Optional final body to send before finishing.
]=]
function ServerResponse.Finish(self: ServerResponse, body: string?)
	if self._finished then
		return
	end

	if body then
		-- If headers haven't been sent yet and no content-length set,
		-- we know the full size so set it to avoid chunked for simple responses.
		if not self._headersSent and not self._headers["content-length"] then
			self._headers["content-length"] = tostring(#body)
		end
		self:Write(body)
	else
		self:_SendHead()
	end

	if self._chunked then
		-- Send terminal chunk
		self._sock:SendAll(strToBuf("0\r\n\r\n"))
	end

	self._finished = true
end

--[=[
	Sends a complete response in one call (status + headers + body).

	Convenience for the common case of a simple, non-streaming reply.

	@param statusCode The HTTP status code.
	@param body The response body string.
	@param hdrs Optional response headers.
]=]
function ServerResponse.Send(self: ServerResponse, statusCode: number, body: string?, hdrs: { [string]: string }?)
	self:Status(statusCode)
	if hdrs then
		self:Headers(hdrs)
	end
	self:Finish(body or "")
end

--[=[
	Sends a JSON response with the `content-type` header set to
	`application/json`.

	@param statusCode The HTTP status code.
	@param data The JSON string to send as the body.
]=]
function ServerResponse.Json(self: ServerResponse, statusCode: number, data: string)
	self:Status(statusCode)
	self:Header("content-type", "application/json")
	self:Finish(data)
end

-- ───────────────────────────────────────────────────────────────────────────
-- HttpServer  –  basic single-threaded HTTP/HTTPS server
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	A single-threaded HTTP (or HTTPS) server.

	Create one with [[createServer]], then call [[HttpServer.Listen]] to
	start accepting connections. Provide an `sslCtx` in the options
	to enable HTTPS.

	```luau
	local server = http.createServer(function(req, res)
	    print(req.method, req.path)
	    res:Send(200, "OK")
	end, { port = 8080 })
	server:Listen()
	```
]=]
local HttpServer = {}
HttpServer.__index = HttpServer

type ServerCallback = (request: ServerRequest, response: ServerResponse) -> ()

type HttpServerFields = {
	_host: string,
	_port: number,
	_backlog: number,
	_clientTimeout: number,
	_callback: ServerCallback,
	_sock: _socket.Socket?,
	_running: boolean,
	-- TLS fields (nil for plain HTTP)
	_sslCtx: any?,
}

export type HttpServer = typeof(setmetatable({} :: HttpServerFields, HttpServer))

--[=[
	Options for creating an [[HttpServer]].
]=]
export type HttpServerOptions = {
	host: string?,
	port: number?,
	backlog: number?,
	clientTimeout: number?, -- Seconds before an idle client connection is dropped. Defaults to 30. Pass a negative value for no timeout.
	sslCtx: _ssl.SslContext?, -- Provide a server-mode SSLContext to enable HTTPS; omit for plain HTTP.
}

--[=[
	Creates a new [[HttpServer]].

	Prefer using [[createServer]] which delegates to this constructor.

	@param callback The request handler invoked for each incoming request.
	@param options Server configuration options.
	@return HttpServer -- The new server (not yet listening).
]=]
function HttpServer.new(callback: ServerCallback, options: HttpServerOptions?): HttpServer
	local opts = options or ({} :: HttpServerOptions)
	return setmetatable(
		{
			_host = opts.host or "0.0.0.0",
			_port = opts.port or 8080,
			_backlog = opts.backlog or 128,
			_clientTimeout = if opts.clientTimeout ~= nil then opts.clientTimeout else 30,
			_callback = callback,
			_sock = nil :: _socket.Socket?,
			_running = false,
			_sslCtx = opts.sslCtx,
		} :: HttpServerFields,
		HttpServer
	)
end

--[=[
	Starts listening for connections and serves requests.

	This call **blocks** until [[HttpServer.Close]] is called or the process
	is interrupted. The optional callback is invoked once the socket is
	bound and ready to accept connections.

	@param callback Called with `(host, port)` when the server is ready.
]=]
function HttpServer.Listen(self: HttpServer, callback: ((host: string, port: number) -> ())?): never
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:SetSockOpt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, true)
	sock:Bind(self._host, self._port)
	sock:Listen(self._backlog)
	self._sock = sock
	self._running = true

	if callback then
		callback(self._host, self._port)
	end

	while self._running do
		local accept_ok, client_or_err, addr, port = pcall(sock.Accept, sock)
		if not accept_ok then
			-- If the error is "interrupted" (Ctrl+C), let it propagate

			if typeof(client_or_err) == "Exception" and client_or_err.type == "interrupt" then
				self:Close()
				error(client_or_err)
			end
			if self._running then
				print("accept error: ", client_or_err)
			end
			continue
		end

		local client_sock: _socket.Socket = client_or_err
		local remoteAddr = addr or "?"
		local remotePort = port or 0

		-- Apply per-client receive timeout so a slow sender can't block the server indefinitely.
		client_sock:SetTimeout(self._clientTimeout)

		-- Optional TLS handshake
		if self._sslCtx then
			local wrap_ok, ssl_sock = pcall(function()
				return self._sslCtx:WrapSocket(client_sock)
			end)
			if not wrap_ok then
				pcall(function()
					client_sock:Close()
				end)
				continue
			end
			client_sock = ssl_sock
		end

		-- Handle the connection in a protected call so one bad request
		-- can't crash the server.
		local ok, err = pcall(function()
			self:_HandleConnection(client_sock, remoteAddr, remotePort)
		end)
		if not ok then
			local msg = tostring(err)
			if string.find(msg, "interrupt", 1, true) then
				pcall(function()
					client_sock:Close()
				end)
				self:Close()
				error(err)
			end
			print("request handler error: " .. msg)
		end

		-- Ensure the socket is always closed
		pcall(function()
			client_sock:Close()
		end)
	end

	-- Unreachable in normal operation but typed as `never` for the loop.
	-- If stop() breaks us out we still clean up.
	self:Close()
	return nil :: never
end

--- Parse an incoming HTTP request from a client socket.
--- Returns nil if the connection was closed before a full request arrived.
function HttpServer._ReadRequest(self: HttpServer, sock: any, remoteAddr: string, remotePort: number): ServerRequest?
	-- Read until we find the end of headers
	local buf = ""
	while true do
		local ok, chunk = pcall(sock.Recv, sock, 8192)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			return nil
		end
		local s = bufToStr(chunk)
		if #s == 0 then
			return nil -- connection closed
		end
		buf ..= s
		if string.find(buf, "\r\n\r\n", 1, true) then
			break
		end
	end

	-- Split head from any body bytes we already received
	local head_end = string.find(buf, "\r\n\r\n", 1, true) :: number
	local head_raw = string.sub(buf, 1, head_end - 1)
	local body_start_data = string.sub(buf, head_end + 4)

	-- Parse request line
	local first_line_end = string.find(head_raw, "\r\n", 1, true)
	local request_line: string
	local headers_raw: string
	if first_line_end then
		request_line = string.sub(head_raw, 1, first_line_end - 1)
		headers_raw = string.sub(head_raw, first_line_end + 2)
	else
		request_line = head_raw
		headers_raw = ""
	end

	local method, path, httpVersion = string.match(request_line, "^(%S+)%s+(%S+)%s+(HTTP/%d+%.%d+)")
	if not method then
		return nil
	end

	local req_headers = parseHeaders(headers_raw)

	-- Read body if Content-Length is present
	local body = body_start_data
	local cl = req_headers["content-length"]
	if cl then
		local content_length = tonumber(cl) or 0
		while #body < content_length do
			local remaining = content_length - #body
			local ok, chunk = pcall(sock.Recv, sock, remaining)
			if not ok then
				if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
					error(chunk)
				end
				break
			end
			local s = bufToStr(chunk)
			if #s == 0 then
				break
			end
			body ..= s
		end
	end

	return {
		method = method :: string,
		path = path :: string,
		httpVersion = (httpVersion or "HTTP/1.1") :: string,
		headers = req_headers,
		body = body,
		remoteAddr = remoteAddr,
		remotePort = remotePort,
	}
end

function HttpServer._HandleConnection(self: HttpServer, client_sock: any, remoteAddr: string, remotePort: number)
	local request = self:_ReadRequest(client_sock, remoteAddr, remotePort)
	if not request then
		return
	end

	local response = ServerResponse._new(client_sock)

	-- Call the user's handler
	self._callback(request, response)

	-- If the handler didn't call finish(), do it now.
	if not response._finished then
		response:Finish()
	end
end

--[=[
	Stops the server by closing the listening socket.

	This unblocks the [[HttpServer.Listen]] call, allowing the server
	loop to exit cleanly.
]=]
function HttpServer.Close(self: HttpServer)
	self._running = false
	if self._sock then
		pcall(function()
			(self._sock :: any):Close()
		end)
		self._sock = nil
	end
end

local http = {}

http.HttpConnection = HttpConnection
http.HttpServer = HttpServer
http.ServerResponse = ServerResponse

--[=[
	Creates and returns a new [[HttpServer]] with the given request handler.

	Call [[HttpServer.Listen]] on the returned server to start accepting
	connections.

	```luau
	local server = http.createServer(function(req, res)
	    print(req.method, req.path)
	    res:Send(200, "Hello, world!")
	end)
	server:Listen(function(host, port)
	    print("Listening on " .. host .. ":" .. tostring(port))
	end)
	```

	@param callback The handler invoked for each incoming request.
	@param options Server configuration options.
	@return HttpServer -- The new server (not yet listening).
]=]
function http.createServer(
	callback: (request: ServerRequest, response: ServerResponse) -> (),
	options: HttpServerOptions?
): HttpServer
	return HttpServer.new(callback, options)
end

--[=[
	Makes a one-shot HTTP request.

	Opens a connection, sends the request, reads the response, and closes
	the connection. For multiple requests to the same host, use
	[[HttpConnection]] directly.

	```luau
	local resp = http.request("POST", "http://example.com/api", {
	    headers = { ["Content-Type"] = "application/json" },
	    body = '{"key": "value"}',
	})
	```

	@param method The HTTP method (e.g. `"GET"`, `"POST"`).
	@param url The full URL including scheme and host.
	@param options Request options (headers, body, timeout, etc.).
	@return HttpResponse -- The parsed response.
]=]
function http.request(method: string, url: string, options: RequestOptions?): HttpResponse
	local parsed_url = parseUrl(url)

	local opts: RequestOptions = options or {}
	local conn = HttpConnection.new(parsed_url.host, parsed_url.port, opts.timeout, parsed_url.scheme, opts.verifySsl)
	local ok, result = pcall(function()
		conn:Request(method, parsed_url.path, opts.headers, opts.body)
		return conn:GetResponse()
	end)
	conn:Close()

	if not ok then
		error(result :: any)
	end
	return result :: HttpResponse
end

--[=[
	Convenience wrapper for a `GET` request.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response.
]=]
function http.get(url: string, options: RequestOptions?): HttpResponse
	return http.request("GET", url, options)
end

--[=[
	Convenience wrapper for a `POST` request.

	@param url The full URL to request.
	@param body The request body string.
	@param options Additional request options.
	@return HttpResponse -- The parsed response.
]=]
function http.post(url: string, body: string?, options: RequestOptions?): HttpResponse
	local opts: RequestOptions = options or {}
	opts.body = body or opts.body
	return http.request("POST", url, opts)
end

--[=[
	Convenience wrapper for a `PUT` request.

	@param url The full URL to request.
	@param body The request body string.
	@param options Additional request options.
	@return HttpResponse -- The parsed response.
]=]
function http.put(url: string, body: string?, options: RequestOptions?): HttpResponse
	local opts: RequestOptions = options or {}
	opts.body = body or opts.body
	return http.request("PUT", url, opts)
end

--[=[
	Convenience wrapper for a `DELETE` request.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response.
]=]
function http.delete(url: string, options: RequestOptions?): HttpResponse
	return http.request("DELETE", url, options)
end

--[=[
	Convenience wrapper for a `HEAD` request.

	Returns headers only - the body will be empty.

	@param url The full URL to request.
	@param options Request options.
	@return HttpResponse -- The parsed response (body is empty).
]=]
function http.head(url: string, options: RequestOptions?): HttpResponse
	return http.request("HEAD", url, options)
end

return http
