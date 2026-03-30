local _socket = require("@eryx/_socket")
local _ssl = require("@eryx/_ssl")
local util = require("./util")

--[=[
	A completed HTTP response returned by [[HttpConnection.getResponse]]
	and the convenience request functions.
]=]
export type HttpResponse = {
	status: number,
	reason: string,
	headers: { [string]: string },
	body: string,
	httpVersion: string,
}

--[=[
	A persistent HTTP connection to a single host and port.

	Supports both HTTP and HTTPS. Multiple requests can be sent over
	the same connection when the server supports keep-alive.

	```luau
	local conn = http.HttpConnection.new("example.com", 443, nil, "https")
	conn:request("GET", "/")
	local resp = conn:getResponse()
	print(resp.status, resp.body)
	conn:close()
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
	(or [[HttpConnection.connect]] is called explicitly).

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
function HttpConnection.connect(self: HttpConnection)
	if self._sock then
		return
	end

	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	if self.timeout then
		sock:setTimeout(self.timeout)
	end
	sock:setSockOpt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, true)
	sock:connect(self.host, self.port)

	if self._scheme == "https" then
		-- Wrap the raw TCP socket with TLS
		local ctx = _ssl.createDefaultContext()
		if not self._verifySsl then
			ctx:setVerify(_ssl.VERIFY_NONE)
		end
		local ssock = ctx:wrapSocket(sock, self.host)
		self._sock = ssock
	else
		self._sock = sock
	end
	self._leftover = ""
end

--[=[
	Closes the connection and releases associated resources.

	It is safe to call `close` multiple times.
]=]
function HttpConnection.close(self: HttpConnection)
	if self._sock then
		pcall(function()
			(self._sock :: any):close()
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
function HttpConnection.request(
	self: HttpConnection,
	method: string,
	path: string,
	headers: { [string]: string }?,
	body: string?
)
	-- Auto-connect if not already connected
	if not self._sock then
		self:connect()
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
	sock:sendAll(buffer.fromstring(request_str))

	-- Send body if present
	if body and #body > 0 then
		sock:sendAll(buffer.fromstring(body))
	end
end

--- @private
--- read from socket, respecting leftover from previous over-reads
function HttpConnection._recvUntil(self: HttpConnection, delim: string): (string, string)
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
		local ok, chunk = pcall(sock.recv, sock, 8192)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = buffer.tostring(chunk)
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

--- @private
--- read exactly n bytes, respecting leftover
function HttpConnection._recvExact(self: HttpConnection, n: number): string
	local accumulated = self._leftover
	self._leftover = ""

	local sock = self._sock :: any
	while #accumulated < n do
		local remaining = n - #accumulated
		local ok, chunk = pcall(sock.recv, sock, remaining)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = buffer.tostring(chunk)
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

--- @private
--- read until connection closes, respecting leftover
function HttpConnection._recvAll(self: HttpConnection): string
	local parts: { string } = {}
	if #self._leftover > 0 then
		table.insert(parts, self._leftover)
		self._leftover = ""
	end

	local sock = self._sock :: any
	while true do
		local ok, chunk = pcall(sock.recv, sock, 65536)
		if not ok then
			if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
				error(chunk)
			end
			break
		end
		local s = buffer.tostring(chunk)
		if #s == 0 then
			break
		end
		table.insert(parts, s)
	end
	return table.concat(parts)
end

--- @private
--- read chunked transfer-encoding body
function HttpConnection._recvChunked(self: HttpConnection): string
	local parts: { string } = {}

	while true do
		-- Read chunk size line
		local size_line = self:_recvUntil("\r\n")
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
			self:_recvUntil("\r\n")
			break
		end

		-- Read exactly chunk_size bytes + trailing \r\n
		local data = self:_recvExact(chunk_size)
		table.insert(parts, data)
		-- Consume trailing \r\n after chunk data
		self:_recvExact(2)
	end

	return table.concat(parts)
end

function HttpConnection.getResponse(self: HttpConnection): HttpResponse
	-- Read the status line + all headers (terminated by \r\n\r\n)
	local head_raw = self:_recvUntil("\r\n\r\n")

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
	local headers = util.parseHeaders(headers_raw)

	-- Read body based on Transfer-Encoding / Content-Length
	local body: string
	local te = headers["transfer-encoding"]
	local cl = headers["content-length"]

	if te and string.find(string.lower(te), "chunked", 1, true) then
		body = self:_recvChunked()
	elseif cl then
		local content_length = tonumber(cl)
		if content_length and content_length > 0 then
			body = self:_recvExact(content_length)
		else
			body = ""
		end
	else
		-- No content-length and not chunked - read until close
		-- (for responses that have a body)
		if status_code >= 200 and status_code ~= 204 and status_code ~= 304 then
			body = self:_recvAll()
		else
			body = ""
		end
	end

	-- If Connection: close, shut down the socket
	local conn_header = headers["connection"]
	if conn_header and string.lower(conn_header) == "close" then
		self:close()
	end

	return {
		status = status_code,
		reason = (reason or "") :: string,
		headers = headers,
		body = body,
		httpVersion = httpVersion :: string,
	}
end

return table.freeze(HttpConnection)
