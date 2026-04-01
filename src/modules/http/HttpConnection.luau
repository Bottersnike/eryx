local _socket = require("@eryx/_socket")
local _ssl = require("@eryx/_ssl")
local util = require("./util")

--[=[
	A completed HTTP response returned by [[HttpConnection.getResponse]]
	and the convenience request functions.

	When a chunked response includes trailer headers, they are exposed on
	`trailers` after the body has been fully consumed.
]=]
export type HttpResponse = {
	status: number,
	reason: string,
	headers: { [string]: string },
	trailers: { [string]: string },
	body: string,
	httpVersion: string,
}

type HttpResponseInternal = HttpResponse

--[=[
	Per-phase timeout settings for an [[HttpConnection]].

	Use this when you want different limits for establishing the
	connection, sending request bytes, and waiting for response bytes.
]=]
export type TimeoutOptions = {
	connect: number?,
	read: number?,
	write: number?,
}

local HttpResponseStream = {}
HttpResponseStream.__index = HttpResponseStream

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
	_timeouts: TimeoutOptions,
	_scheme: string,
	_verifySsl: boolean,
	_sock: any?, -- _socket.Socket or _ssl.SSLSocket (same send/sendall/recv/close interface)
	_leftover: string,
	_lastRequestMethod: string?,
	_prefetchedResponse: HttpResponseInternal?,
	_activeResponseStream: HttpResponseStream?,
	_appliedTimeout: number?,
}

export type HttpConnection = typeof(setmetatable({} :: HttpConnectionFields, HttpConnection))

type HttpResponseStreamFields = {
	status: number,
	reason: string,
	headers: { [string]: string },
	trailers: { [string]: string },
	httpVersion: string,
	_connection: HttpConnection?,
	_closed: boolean,
	_mode: "buffer" | "length" | "chunked" | "close",
	_keepAlive: boolean,
	_closeConnectionOnFinish: boolean,
	_remaining: number,
	_chunkRemaining: number,
	_buffer: string,
	_bufferOffset: number,
}

export type HttpResponseStream = typeof(setmetatable({} :: HttpResponseStreamFields, HttpResponseStream))

export type UploadBodyStream = {
	read: (self: UploadBodyStream, size: number?) -> string?,
	close: ((self: UploadBodyStream) -> ())?,
}

--[=[
	Creates a new [[HttpConnection]] to the given host.

	The connection is not established until the first request is sent
	(or [[HttpConnection.connect]] is called explicitly).

	@param host The remote hostname or IP address.
	@param port The remote port number. Defaults to 80 for HTTP, 443 for HTTPS.
	@param timeout Either one timeout in seconds for every phase, or a
		table with `connect`, `read`, and `write` timeouts.
	@param scheme `"http"` (default) or `"https"`.
	@param verifySsl Whether to verify the server's TLS certificate. Defaults to `true`.
	@return HttpConnection -- A new connection object.
]=]
function HttpConnection.new(
	host: string,
	port: number?,
	timeout: (number | TimeoutOptions)?,
	scheme: string?,
	verifySsl: boolean?
): HttpConnection
	local s = scheme or "http"
	local self = setmetatable(
		{
			host = host,
			port = port or (if s == "https" then 443 else 80),
			_timeouts = if typeof(timeout) == "number"
				then {
					connect = timeout :: number,
					read = timeout :: number,
					write = timeout :: number,
				}
				elseif timeout ~= nil then table.clone(timeout :: TimeoutOptions)
				else {},
			_scheme = s,
			_verifySsl = if verifySsl == nil then true else verifySsl,
			_sock = nil :: any?,
			_leftover = "",
			_lastRequestMethod = nil,
			_prefetchedResponse = nil,
			_activeResponseStream = nil,
			_appliedTimeout = nil,
		} :: HttpConnectionFields,
		HttpConnection
	)
	return self
end

local function normalizeTimeouts(timeout: (number | TimeoutOptions)?): TimeoutOptions
	if typeof(timeout) == "number" then
		local value = timeout :: number
		return {
			connect = value,
			read = value,
			write = value,
		}
	end
	if timeout == nil then
		return {}
	end
	return table.clone(timeout :: TimeoutOptions)
end

function HttpConnection._applyTimeout(self: HttpConnection, phase: "connect" | "read" | "write")
	local sock = self._sock
	if sock == nil then
		return
	end

	local timeout = self._timeouts[phase]
	if self._appliedTimeout == timeout then
		return
	end

	sock:setTimeout(timeout)
	self._appliedTimeout = timeout
end

--[=[
	Updates the per-phase timeouts used by this connection.

	You may pass a single number to apply the same timeout to connect,
	read, and write phases, or a table with explicit `connect`, `read`,
	and `write` values. Passing `nil` clears the timeout configuration.

	@param timeout New timeout settings in seconds.
]=]
function HttpConnection.setTimeouts(self: HttpConnection, timeout: (number | TimeoutOptions)?)
	self._timeouts = normalizeTimeouts(timeout)
	if self._sock ~= nil then
		self._appliedTimeout = nil
	end
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
	sock:setTimeout(self._timeouts.connect)
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
	self._appliedTimeout = self._timeouts.connect
	self._leftover = ""
end

--[=[
	Closes the connection and releases associated resources.

	It is safe to call `close` multiple times.
]=]
function HttpConnection.close(self: HttpConnection)
	if self._activeResponseStream then
		self._activeResponseStream._closed = true
		self._activeResponseStream._connection = nil
		self._activeResponseStream = nil
	end
	if self._sock then
		pcall(function()
			(self._sock :: any):close()
		end)
		self._sock = nil
		self._leftover = ""
		self._prefetchedResponse = nil
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
	@param expectContinue When true, waits for `100 Continue` before
		sending a non-empty request body.
	@param bodyStream Optional incremental request-body reader.
	@param bodyLength Optional exact byte size for `bodyStream`.
]=]
function HttpConnection.request(
	self: HttpConnection,
	method: string,
	path: string,
	headers: { [string]: string }?,
	body: string?,
	expectContinue: boolean?,
	bodyStream: UploadBodyStream?,
	bodyLength: number?
)
	if self._activeResponseStream ~= nil and not self._activeResponseStream._closed then
		error("Cannot send a new request while a response stream is still open")
	end

	-- Auto-connect if not already connected
	if not self._sock then
		self:connect()
	end
	self._lastRequestMethod = string.upper(method)

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

	if body ~= nil and bodyStream ~= nil then
		error("Cannot send both a string body and a streaming body")
	end

	-- Set framing headers for request bodies
	if body then
		if not hdrs["content-length"] and not hdrs["transfer-encoding"] then
			hdrs["content-length"] = tostring(#body)
		end
	elseif bodyStream then
		if not hdrs["content-length"] and not hdrs["transfer-encoding"] then
			if bodyLength ~= nil then
				hdrs["content-length"] = tostring(bodyLength)
			else
				hdrs["transfer-encoding"] = "chunked"
			end
		end
	end

	-- Default connection header
	if not hdrs["connection"] then
		hdrs["connection"] = "keep-alive"
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
	self:_applyTimeout("write")
	sock:sendAll(buffer.fromstring(request_str))

	local function sendChunk(data: string)
		if #data == 0 then
			return
		end
		local chunk = string.format("%x\r\n", #data) .. data .. "\r\n"
		self:_applyTimeout("write")
		sock:sendAll(buffer.fromstring(chunk))
	end

	local function sendRequestBody()
		local transferEncoding = hdrs["transfer-encoding"]
		local useChunked = transferEncoding ~= nil
			and util.parseTransferEncoding(transferEncoding)[#util.parseTransferEncoding(transferEncoding)]
				== "chunked"

		if body ~= nil then
			if useChunked then
				sendChunk(body)
				self:_applyTimeout("write")
				sock:sendAll(buffer.fromstring("0\r\n\r\n"))
			elseif #body > 0 then
				self:_applyTimeout("write")
				sock:sendAll(buffer.fromstring(body))
			end
			return
		end

		if bodyStream == nil then
			return
		end

		local expectedLength = util.parseContentLength(hdrs["content-length"])
		local sentLength = 0
		while true do
			local chunk = bodyStream:read(65536)
			if chunk == nil then
				break
			end
			if #chunk == 0 then
				continue
			end

			sentLength += #chunk
			if expectedLength ~= nil and sentLength > expectedLength then
				error("Streaming body produced more bytes than Content-Length")
			end

			if useChunked then
				sendChunk(chunk)
			else
				self:_applyTimeout("write")
				sock:sendAll(buffer.fromstring(chunk))
			end
		end

		if expectedLength ~= nil and sentLength ~= expectedLength then
			error("Streaming body ended before reaching Content-Length")
		end

		if useChunked then
			self:_applyTimeout("write")
			sock:sendAll(buffer.fromstring("0\r\n\r\n"))
		end
	end

	if expectContinue and ((body and #body > 0) or bodyStream ~= nil) then
		while true do
			local response = self:_readResponse(false)
			if response.status == 100 then
				sendRequestBody()
				return
			elseif response.status >= 100 and response.status < 200 then
				continue
			end

			self._prefetchedResponse = response
			return
		end
	end

	sendRequestBody()
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
		self:_applyTimeout("read")
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
		self:_applyTimeout("read")
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
		self:_applyTimeout("read")
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
--- read up to n bytes, respecting leftover
function HttpConnection._recvSome(self: HttpConnection, n: number): string
	if n <= 0 then
		return ""
	end

	if #self._leftover > 0 then
		local take = math.min(n, #self._leftover)
		local result = string.sub(self._leftover, 1, take)
		self._leftover = string.sub(self._leftover, take + 1)
		return result
	end

	local sock = self._sock :: any
	self:_applyTimeout("read")
	local ok, chunk = pcall(sock.recv, sock, n)
	if not ok then
		if typeof(chunk) == "Exception" and chunk.type == "interrupt" then
			error(chunk)
		end
		return ""
	end
	return buffer.tostring(chunk)
end

local function responseMustNotHaveBody(statusCode: number, requestMethod: string?): boolean
	if requestMethod == "HEAD" then
		return true
	end
	if (statusCode >= 100 and statusCode < 200 and statusCode ~= 101) or statusCode == 204 or statusCode == 304 then
		return true
	end
	return false
end

local function parseResponseHead(headRaw: string): (string, number, string, { [string]: string })
	local status_end = string.find(headRaw, "\r\n", 1, true)
	if not status_end then
		error("Malformed HTTP response (no CRLF found): " .. string.sub(headRaw, 1, 200))
	end
	local status_line = string.sub(headRaw, 1, status_end - 1)
	local headers_raw = string.sub(headRaw, status_end + 2)

	local httpVersion, status_str, reason = string.match(status_line, "^(HTTP/%d+%.%d+)%s+(%d+)%s*(.*)")
	if not httpVersion then
		error("Malformed HTTP status line: " .. status_line)
	end

	return httpVersion :: string,
		tonumber(status_str) :: number,
		(reason or "") :: string,
		util.parseHeaders(headers_raw)
end

local function responseKeepsConnectionAlive(
	httpVersion: string,
	connectionHeader: string?,
	bodyDelimitedByClose: boolean
): boolean
	if bodyDelimitedByClose then
		return false
	end
	if httpVersion == "HTTP/1.0" then
		return util.headerHasToken(connectionHeader, "keep-alive")
	end
	return not util.headerHasToken(connectionHeader, "close")
end

local function createBufferedResponseStream(
	response: {
		status: number,
		reason: string,
		headers: { [string]: string },
		httpVersion: string,
	},
	body: string
): HttpResponseStream
	return setmetatable({
		status = response.status,
		reason = response.reason,
		headers = response.headers,
		trailers = response.trailers,
		httpVersion = response.httpVersion,
		_connection = nil,
		_closed = false,
		_mode = "buffer",
		_keepAlive = false,
		_closeConnectionOnFinish = false,
		_remaining = #body,
		_chunkRemaining = 0,
		_buffer = body,
		_bufferOffset = 1,
	}, HttpResponseStream)
end

--- @private
--- read chunked transfer-encoding body
function HttpConnection._recvChunked(self: HttpConnection): (string, { [string]: string })
	local parts: { string } = {}
	local trailers = {}

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
			local trailerLines = {}
			while true do
				local trailerLine = self:_recvUntil("\r\n")
				if trailerLine == "\r\n" then
					break
				end
				table.insert(trailerLines, trailerLine)
			end
			if #trailerLines > 0 then
				trailers = util.parseHeaders(table.concat(trailerLines))
			end
			break
		end

		-- Read exactly chunk_size bytes + trailing \r\n
		local data = self:_recvExact(chunk_size)
		table.insert(parts, data)
		-- Consume trailing \r\n after chunk data
		self:_recvExact(2)
	end

	return table.concat(parts), trailers
end

function HttpResponseStream._finalize(self: HttpResponseStream)
	if self._closed then
		return
	end

	self._closed = true
	local connection = self._connection
	self._connection = nil
	if connection and connection._activeResponseStream == self then
		connection._activeResponseStream = nil
	end

	if connection ~= nil and (self._closeConnectionOnFinish or not self._keepAlive) then
		connection:close()
	end
end

function HttpResponseStream._readChunkHeader(self: HttpResponseStream)
	local connection = self._connection
	if connection == nil then
		return
	end

	local sizeLine = connection:_recvUntil("\r\n")
	sizeLine = string.gsub(sizeLine, "\r\n$", "")
	local sizeText = string.match(sizeLine, "^([0-9a-fA-F]+)")
	if not sizeText then
		error("Malformed chunk size")
	end

	local chunkSize = tonumber(sizeText, 16)
	if chunkSize == nil then
		error("Malformed chunk size")
	end
	if chunkSize == 0 then
		local trailerLines = {}
		while true do
			local trailerLine = connection:_recvUntil("\r\n")
			if trailerLine == "\r\n" then
				break
			end
			table.insert(trailerLines, trailerLine)
		end
		if #trailerLines > 0 then
			self.trailers = util.parseHeaders(table.concat(trailerLines))
		end
		self:_finalize()
		return
	end

	self._chunkRemaining = chunkSize
end

function HttpResponseStream.read(self: HttpResponseStream, count: number?): string?
	if self._closed then
		return nil
	end

	local limit = count or 65536
	if limit <= 0 then
		return ""
	end

	if self._mode == "buffer" then
		if self._bufferOffset > #self._buffer then
			self._closed = true
			return nil
		end

		local finish = math.min(#self._buffer, self._bufferOffset + limit - 1)
		local chunk = string.sub(self._buffer, self._bufferOffset, finish)
		self._bufferOffset = finish + 1
		self._remaining -= #chunk
		if self._bufferOffset > #self._buffer then
			self._closed = true
		end
		return chunk
	end

	if self._mode == "length" then
		if self._remaining <= 0 then
			self:_finalize()
			return nil
		end

		local connection = self._connection :: HttpConnection
		local toRead = math.min(limit, self._remaining)
		local chunk = connection:_recvExact(toRead)
		if #chunk == 0 then
			self:_finalize()
			return nil
		end

		self._remaining -= #chunk
		if self._remaining <= 0 then
			self:_finalize()
		end
		return chunk
	end

	if self._mode == "chunked" then
		if self._chunkRemaining <= 0 then
			self:_readChunkHeader()
			if self._closed then
				return nil
			end
		end

		local connection = self._connection :: HttpConnection
		local toRead = math.min(limit, self._chunkRemaining)
		local chunk = connection:_recvExact(toRead)
		if #chunk == 0 then
			self:_finalize()
			return nil
		end

		self._chunkRemaining -= #chunk
		if self._chunkRemaining == 0 then
			local terminator = connection:_recvExact(2)
			if terminator ~= "\r\n" then
				error("Malformed chunk terminator")
			end
		end
		return chunk
	end

	local connection = self._connection :: HttpConnection
	local chunk = connection:_recvSome(limit)
	if #chunk == 0 then
		self:_finalize()
		return nil
	end
	return chunk
end

function HttpResponseStream.readAll(self: HttpResponseStream): string
	local parts = {}
	while true do
		local chunk = self:read()
		if chunk == nil then
			break
		end
		table.insert(parts, chunk)
	end
	return table.concat(parts)
end

function HttpResponseStream.close(self: HttpResponseStream)
	if self._closed then
		return
	end

	if self._mode == "close" then
		self:_finalize()
		return
	end

	while self:read() ~= nil do
	end
end

function HttpConnection._openResponse(self: HttpConnection, skipInformational: boolean): HttpResponseStream
	local httpVersion: string
	local status_code: number
	local reason: string
	local headers: { [string]: string }

	while true do
		local head_raw = self:_recvUntil("\r\n\r\n")
		if #head_raw == 0 then
			error("Connection closed before receiving HTTP response")
		end

		httpVersion, status_code, reason, headers = parseResponseHead(head_raw)
		if not skipInformational or not (status_code >= 100 and status_code < 200 and status_code ~= 101) then
			break
		end
	end

	local te = headers["transfer-encoding"]
	local cl = headers["content-length"]
	local encodings = util.parseTransferEncoding(te)
	local content_length = util.parseContentLength(cl)
	if #encodings > 0 and content_length ~= nil then
		error("HTTP response must not include both Transfer-Encoding and Content-Length")
	end

	local body: string
	local bodyDelimitedByClose = false
	if responseMustNotHaveBody(status_code, self._lastRequestMethod) then
		return createBufferedResponseStream({
			status = status_code,
			reason = reason,
			headers = headers,
			trailers = {},
			httpVersion = httpVersion,
		}, "")
	elseif #encodings > 0 then
		if encodings[#encodings] ~= "chunked" then
			error("Unsupported Transfer-Encoding in HTTP response")
		end
		local keepAlive = responseKeepsConnectionAlive(httpVersion, headers["connection"], false)
		local stream = setmetatable({
			status = status_code,
			reason = reason,
			headers = headers,
			httpVersion = httpVersion,
			_connection = self,
			_closed = false,
			_mode = "chunked",
			_keepAlive = keepAlive,
			_closeConnectionOnFinish = false,
			_remaining = 0,
			_chunkRemaining = 0,
			_buffer = "",
			_bufferOffset = 1,
		}, HttpResponseStream)
		self._activeResponseStream = stream
		return stream
	elseif content_length ~= nil then
		if content_length > 0 then
			local keepAlive = responseKeepsConnectionAlive(httpVersion, headers["connection"], false)
			local stream = setmetatable({
				status = status_code,
				reason = reason,
				headers = headers,
				trailers = {},
				httpVersion = httpVersion,
				_connection = self,
				_closed = false,
				_mode = "length",
				_keepAlive = keepAlive,
				_closeConnectionOnFinish = false,
				_remaining = content_length,
				_chunkRemaining = 0,
				_buffer = "",
				_bufferOffset = 1,
			}, HttpResponseStream)
			self._activeResponseStream = stream
			return stream
		end
		return createBufferedResponseStream({
			status = status_code,
			reason = reason,
			headers = headers,
			trailers = {},
			httpVersion = httpVersion,
		}, "")
	else
		if status_code >= 200 and status_code ~= 204 and status_code ~= 304 then
			bodyDelimitedByClose = true
		else
			return createBufferedResponseStream({
				status = status_code,
				reason = reason,
				headers = headers,
				httpVersion = httpVersion,
			}, "")
		end
	end

	local keepAlive = responseKeepsConnectionAlive(httpVersion, headers["connection"], bodyDelimitedByClose)
	local stream = setmetatable({
		status = status_code,
		reason = reason,
		headers = headers,
		httpVersion = httpVersion,
		_connection = self,
		_closed = false,
		_mode = "close",
		_keepAlive = keepAlive,
		_closeConnectionOnFinish = false,
		_remaining = 0,
		_chunkRemaining = 0,
		_buffer = "",
		_bufferOffset = 1,
	}, HttpResponseStream)
	self._activeResponseStream = stream
	return stream
end

function HttpConnection._readResponse(self: HttpConnection, skipInformational: boolean): HttpResponseInternal
	local stream = self:_openResponse(skipInformational)
	local body = stream:readAll()
	return {
		status = stream.status,
		reason = stream.reason,
		headers = stream.headers,
		trailers = stream.trailers,
		body = body,
		httpVersion = stream.httpVersion,
	}
end

function HttpConnection.getResponse(self: HttpConnection): HttpResponse
	if self._prefetchedResponse ~= nil then
		local response = self._prefetchedResponse
		self._prefetchedResponse = nil
		return response
	end
	return self:_readResponse(true)
end

function HttpConnection.getResponseStream(self: HttpConnection): HttpResponseStream
	if self._prefetchedResponse ~= nil then
		local response = self._prefetchedResponse
		self._prefetchedResponse = nil
		return createBufferedResponseStream(response, response.body)
	end
	return self:_openResponse(true)
end

return table.freeze(HttpConnection)
