local ServerResponse = require("./ServerResponse")
local _socket = require("@eryx/_socket")
local exception = require("@eryx/exception")
local json = require("@eryx/encoding/json")
local task = require("@eryx/task")
local util = require("./util")
local multipart = require("./multipart")

type QueryTable = { [string]: string | { string } }
type ParsedMultipartField = multipart.ParsedMultipartField
type SslContext = {
	wrapSocket: (self: SslContext, sock: _socket.Socket, serverHostname: string?) -> any,
	loadVerifyLocations: (self: SslContext, cafile: string) -> (),
	setVerify: (self: SslContext, mode: number) -> (),
}
local REQUEST_ERROR_PREFIX = "__http_request_error__:"
local DEFAULT_MAX_HEADER_BYTES = 64 * 1024
local DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024

local RequestBodyStream = {}
RequestBodyStream.__index = RequestBodyStream

type RequestBodyStreamFields = {
	_closed: boolean,
	_sock: any,
	_buffer: string,
	_trailers: { [string]: string }?,
	_mode: "empty" | "length" | "chunked",
	_remaining: number,
	_chunkRemaining: number,
	_totalRead: number,
	_maxBodyBytes: number,
	_onFinish: ((string, { [string]: string }?) -> ())?,
}

export type RequestBodyStream = typeof(setmetatable({} :: RequestBodyStreamFields, RequestBodyStream))

--[=[
	An incoming HTTP request received by an [[HttpServer]].

	Header names are lowercased for consistent lookup.
]=]
export type ServerRequest = {
	method: string,
	path: string,
	pathname: string,
	queryString: string,
	query: QueryTable,
	httpVersion: string,
	headers: { [string]: string },
	trailers: { [string]: string },
	contentType: string?,
	body: string,
	form: QueryTable?,
	multipart: { ParsedMultipartField }?,
	--- Available when `streamRequestBodies = true`.
	bodyStream: RequestBodyStream?,
	remoteAddr: string,
	remotePort: number,
	--- Reads and buffers the full body on demand.
	readBody: (self: ServerRequest) -> string,
	--- Decodes URL-encoded form data on demand.
	readForm: (self: ServerRequest) -> QueryTable?,
	--- Decodes multipart form-data on demand.
	readMultipart: (self: ServerRequest) -> { ParsedMultipartField }?,
	--- Decodes JSON request bodies on demand.
	readJson: (self: ServerRequest) -> any?,
}

--[=[
	A single-threaded HTTP (or HTTPS) server.

	Create one with [[createServer]], then call [[HttpServer.listen]] to
	start accepting connections. Provide an `sslCtx` in the options
	to enable HTTPS.

	```luau
	local server = http.createServer(function(req, res)
	    print(req.method, req.path)
	    res:send(200, "OK")
	end, { port = 8080 })
	server:listen()
	```
]=]
local HttpServer = {}
HttpServer.__index = HttpServer

local ServerRequestMethods = {}
local ServerRequestMetatable = {
	__index = function(self, key)
		local method = (ServerRequestMethods :: any)[key]
		if method ~= nil then
			return method
		end
		if key == "bodyStream" then
			return rawget(self, "_bodyStream")
		end
		return nil
	end,
}

type ServerCallback = (request: ServerRequest, response: ServerResponse.ServerResponse) -> ()

type HttpServerFields = {
	_host: string,
	_port: number,
	_backlog: number,
	_clientTimeout: number,
	_keepAliveTimeout: number,
	_maxRequestsPerConnection: number?,
	_maxHeaderBytes: number,
	_maxBodyBytes: number,
	_streamRequestBodies: boolean,
	_callback: ServerCallback,
	_sock: _socket.Socket?,
	_running: boolean,
	-- TLS fields (nil for plain HTTP)
	_sslCtx: SslContext?,
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
	keepAliveTimeout: number?,
	maxRequestsPerConnection: number?,
	maxHeaderBytes: number?,
	maxBodyBytes: number?,
	--- When true, request bodies are exposed through `req.bodyStream`
	--- instead of being buffered eagerly.
	streamRequestBodies: boolean?,
	sslCtx: SslContext?, -- Provide a server-mode SSLContext to enable HTTPS; omit for plain HTTP.
}

--[=[
	Creates a new [[HttpServer]] with the given request handler.

	Call [[HttpServer.listen]] on the returned server to start accepting
	connections.

	```luau
	local server = http.createServer(function(req, res)
	    print(req.method, req.path)
	    res:send(200, "Hello, world!")
	end)
	server:listen(function(host, port)
	    print("Listening on " .. host .. ":" .. tostring(port))
	end)
	```

	@param callback The handler invoked for each incoming request.
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
			_keepAliveTimeout = if opts.keepAliveTimeout ~= nil then opts.keepAliveTimeout else 5,
			_maxRequestsPerConnection = opts.maxRequestsPerConnection,
			_maxHeaderBytes = opts.maxHeaderBytes or DEFAULT_MAX_HEADER_BYTES,
			_maxBodyBytes = opts.maxBodyBytes or DEFAULT_MAX_BODY_BYTES,
			_streamRequestBodies = if opts.streamRequestBodies == true then true else false,
			_callback = callback,
			_sock = nil :: _socket.Socket?,
			_running = false,
			_sslCtx = opts.sslCtx,
		} :: HttpServerFields,
		HttpServer
	)
end

local function requestError(status: number, message: string): never
	error(`{REQUEST_ERROR_PREFIX}{status}:{message}`, 0)
end

function RequestBodyStream._finish(self: RequestBodyStream)
	if self._closed then
		return
	end
	self._closed = true
	local onFinish = self._onFinish
	self._onFinish = nil
	if onFinish ~= nil then
		onFinish(self._buffer, self._trailers)
	end
end

function RequestBodyStream._recvChunk(self: RequestBodyStream): string
	local emptyReads = 0
	while true do
		local ok, chunk = pcall(self._sock.recv, self._sock, 8192)
		if not ok then
			local isInterrupt = exception.isInterrupt
			if isInterrupt ~= nil and isInterrupt(chunk) then
				error(chunk)
			end
			emptyReads += 1
			if emptyReads >= 8 then
				requestError(400, "Failed while reading request body")
			end
			task.wait()
			continue
		end
		if chunk ~= nil then
			local s = buffer.tostring(chunk)
			if #s > 0 then
				return s
			end
		end

		emptyReads += 1
		if emptyReads >= 8 then
			requestError(400, "Unexpected EOF while reading request body")
		end
		task.wait()
	end
end

function RequestBodyStream._recvUntil(self: RequestBodyStream, delim: string): string
	while true do
		local pos = string.find(self._buffer, delim, 1, true)
		if pos then
			local result = string.sub(self._buffer, 1, pos + #delim - 1)
			self._buffer = string.sub(self._buffer, pos + #delim)
			return result
		end
		self._buffer ..= self:_recvChunk()
		if (self._totalRead + #self._buffer) > self._maxBodyBytes then
			requestError(413, "Request body too large")
		end
	end
end

function RequestBodyStream._recvExact(self: RequestBodyStream, n: number): string
	while #self._buffer < n do
		self._buffer ..= self:_recvChunk()
		if (self._totalRead + #self._buffer) > self._maxBodyBytes then
			requestError(413, "Request body too large")
		end
	end
	local result = string.sub(self._buffer, 1, n)
	self._buffer = string.sub(self._buffer, n + 1)
	return result
end

function RequestBodyStream._readChunkHeader(self: RequestBodyStream)
	local sizeLine = self:_recvUntil("\r\n")
	sizeLine = string.gsub(sizeLine, "\r\n$", "")
	local sizeText = string.match(sizeLine, "^([0-9a-fA-F]+)")
	if sizeText == nil then
		requestError(400, "Malformed chunk size")
	end
	local chunkSize = tonumber(sizeText, 16)
	if chunkSize == nil then
		requestError(400, "Malformed chunk size")
	end
	if chunkSize == 0 then
		local trailerLines = {}
		while true do
			local trailerLine = self:_recvUntil("\r\n")
			if trailerLine == "\r\n" then
				break
			end
			table.insert(trailerLines, trailerLine)
		end
		if #trailerLines > 0 then
			self._trailers = util.parseHeaders(table.concat(trailerLines))
		end
		self:_finish()
		return
	end
	self._chunkRemaining = chunkSize
end

--[=[
	Reads a chunk from a streamed request body.

	In streamed request-body mode, handlers receive `req.bodyStream`, which
	exposes `read`, `readAll`, and `close` for incremental upload
	processing.

	@param count Maximum number of bytes to read. Defaults to `65536`.
	@return string? -- The next body chunk, or `nil` when the stream ends.
]=]
function RequestBodyStream.read(self: RequestBodyStream, count: number?): string?
	if self._closed then
		return nil
	end

	local limit = count or 65536
	if limit <= 0 then
		return ""
	end

	if self._mode == "empty" then
		self:_finish()
		return nil
	end

	if self._mode == "length" then
		if self._remaining <= 0 then
			self:_finish()
			return nil
		end

		local toRead = math.min(limit, self._remaining)
		local chunk = self:_recvExact(toRead)
		self._remaining -= #chunk
		self._totalRead += #chunk
		if self._remaining <= 0 then
			self:_finish()
		end
		return chunk
	end

	if self._chunkRemaining <= 0 then
		self:_readChunkHeader()
		if self._closed then
			return nil
		end
	end

	local toRead = math.min(limit, self._chunkRemaining)
	local chunk = self:_recvExact(toRead)
	self._chunkRemaining -= #chunk
	self._totalRead += #chunk
	if self._totalRead > self._maxBodyBytes then
		requestError(413, "Request body too large")
	end
	if self._chunkRemaining == 0 then
		local lineEnd = self:_recvExact(2)
		if lineEnd ~= "\r\n" then
			requestError(400, "Malformed chunk terminator")
		end
	end
	return chunk
end

--[=[
	Reads the rest of a streamed request body into a string.

	@return string -- The remaining request body.
]=]
function RequestBodyStream.readAll(self: RequestBodyStream): string
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

--[=[
	Consumes and closes a streamed request body.

	This is useful when a handler wants to abandon the body early but still
	allow the connection to be reused safely.
]=]
function RequestBodyStream.close(self: RequestBodyStream)
	if self._closed then
		return
	end
	while self:read() ~= nil do
	end
end

local function decodeRequestError(err: any): (number?, string?)
	local message = if typeof(err) == "Exception" then (err :: any).message else tostring(err)
	if string.sub(message, 1, #REQUEST_ERROR_PREFIX) ~= REQUEST_ERROR_PREFIX then
		return nil, nil
	end

	local payload = string.sub(message, #REQUEST_ERROR_PREFIX + 1)
	local colon = string.find(payload, ":", 1, true)
	if not colon then
		return nil, nil
	end

	local status = tonumber(string.sub(payload, 1, colon - 1))
	if status == nil then
		return nil, nil
	end
	return status, string.sub(payload, colon + 1)
end

--[=[
	Reads and buffers the full request body on demand.

	In default buffered mode this simply returns `req.body`. When streamed
	request-body mode is enabled, this drains `req.bodyStream` and caches
	the result.

	@return string -- The full request body.
]=]
function ServerRequestMethods.readBody(self: ServerRequest): string
	local cached = rawget(self, "_body")
	if cached ~= nil then
		return cached
	end

	local stream = rawget(self, "_bodyStream")
	local body = if stream ~= nil then (stream :: RequestBodyStream):readAll() else ""
	rawset(self, "_body", body)
	return body
end

--[=[
	Decodes a request body as `application/x-www-form-urlencoded`.

	In streamed request-body mode this reads the full body on demand.

	@return QueryTable? -- The decoded form fields, or `nil` when the
	request is not URL-encoded.
]=]
function ServerRequestMethods.readForm(self: ServerRequest): QueryTable?
	local cached = rawget(self, "_form")
	if cached ~= nil then
		return cached
	end
	if self.contentType ~= "application/x-www-form-urlencoded" then
		return nil
	end

	local form = util.decodeForm(self:readBody())
	rawset(self, "_form", form)
	return form
end

--[=[
	Decodes a request body as `multipart/form-data`.

	In streamed request-body mode this reads the full body on demand.

	@return { ParsedMultipartField }? -- Parsed multipart fields, or `nil`
	when the request is not multipart form-data.
]=]
function ServerRequestMethods.readMultipart(self: ServerRequest): { ParsedMultipartField }?
	local cached = rawget(self, "_multipart")
	if cached ~= nil then
		return cached
	end
	if self.contentType ~= "multipart/form-data" then
		return nil
	end

	local boundary = rawget(self, "_multipartBoundary")
	if boundary == nil or boundary == "" then
		return nil
	end

	local parsed = multipart.parse(self:readBody(), boundary)
	rawset(self, "_multipart", parsed)
	return parsed
end

--[=[
	Decodes a request body as JSON.

	In streamed request-body mode this reads the full body on demand.

	@return any? -- The decoded JSON value, or `nil` when the request does
	not declare a JSON content type.
]=]
function ServerRequestMethods.readJson(self: ServerRequest): any?
	if not util.isJsonContentType(self.headers["content-type"]) then
		return nil
	end
	return json.decode(self:readBody())
end

--[=[
	Starts listening for connections and serves requests.

	This call **blocks** until [[HttpServer.close]] is called or the process
	is interrupted. The optional callback is invoked once the socket is
	bound and ready to accept connections.

	@param callback Called with `(host, port)` when the server is ready.
]=]
function HttpServer.listen(self: HttpServer, callback: ((host: string, port: number) -> ())?): never
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, true)
	sock:bind(self._host, self._port)
	sock:listen(self._backlog)
	self._sock = sock
	self._running = true

	if callback then
		callback(self._host, self._port)
	end

	while self._running do
		local accept_ok, client_or_err, addr, port = pcall(function()
			return sock.accept(sock)
		end)
		if not accept_ok then
			-- If the error is "interrupted" (Ctrl+C), let it propagate
			if exception.isInterrupt(client_or_err) then
				self:close()
				error(client_or_err)
			end
			if self._running then
				print("accept error: ", client_or_err)
			end
			continue
		end

		task.spawn(function()
			local client_sock: _socket.Socket = client_or_err
			local remoteAddr = addr or "?"
			local remotePort = port or 0

			-- Apply per-client receive timeout so a slow sender can't block the server indefinitely.
			client_sock:setTimeout(self._clientTimeout)

			-- Optional TLS handshake
			if self._sslCtx then
				local wrap_ok, ssl_sock = pcall(function()
					return self._sslCtx:wrapSocket(client_sock)
				end)
				if not wrap_ok then
					pcall(function()
						client_sock:close()
					end)
					return
				end
				client_sock = ssl_sock
			end

			-- Handle the connection in a protected call so one bad request
			-- can't crash the server.
			local ok, err = pcall(function()
				return self:_handleConnection(client_sock, remoteAddr, remotePort)
			end)
			local upgraded: boolean
			if not ok then
				local msg = tostring(err)
				if string.find(msg, "interrupt", 1, true) then
					pcall(function()
						client_sock:close()
					end)
					self:close()
					error(err)
				end
				print("request handler error: " .. exception.format(err))
				upgraded = false
			else
				upgraded = err
			end

			-- Ensure the socket is always closed, unless the connection was
			-- upgraded (e.g. to WebSocket) - the new owner manages the socket.
			if not upgraded then
				pcall(function()
					client_sock:close()
				end)
			end
		end)
	end

	-- Unreachable in normal operation but typed as `never` for the loop.
	-- If stop() breaks us out we still clean up.
	self:close()
	return nil :: never
end

--- Parse an incoming HTTP request from a client socket.
--- Returns nil if the connection was closed before a full request arrived.
---
--- In the default mode, request bodies are buffered eagerly and exposed
--- through `req.body`, `req.form`, and `req.multipart`. When
--- `streamRequestBodies = true`, requests instead expose `req.bodyStream`
--- along with `req:readBody()`, `req:readForm()`, `req:readMultipart()`,
--- and `req:readJson()` for on-demand buffering/decoding. Chunked
--- request trailers are exposed on `req.trailers` once the body has
--- been fully consumed.
function HttpServer._readRequest(
	self: HttpServer,
	sock: any,
	remoteAddr: string,
	remotePort: number,
	initialBuffer: string?
): (ServerRequest?, string)
	-- Read until we find the end of headers
	local buf = initialBuffer or ""
	while true do
		if string.find(buf, "\r\n\r\n", 1, true) then
			break
		end
		local ok, chunk = pcall(sock.recv, sock, 8192)
		if not ok then
			if exception.isInterrupt(chunk) then
				error(chunk)
			end
			return nil, buf
		end
		if not chunk then
			return nil, buf -- connection closed
		end
		local s = buffer.tostring(chunk)
		if #s == 0 then
			return nil, buf -- connection closed
		end
		buf ..= s
		if #buf > self._maxHeaderBytes then
			requestError(431, "Request headers too large")
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

	local req_headers = util.parseHeaders(headers_raw)
	local target = util.parseRequestTarget(path :: string)

	if httpVersion == "HTTP/1.1" and req_headers["host"] == nil then
		requestError(400, "Missing required Host header")
	end

	local transferEncoding = req_headers["transfer-encoding"]
	local contentLengthHeader = req_headers["content-length"]
	if transferEncoding and contentLengthHeader then
		requestError(400, "Requests must not send both Transfer-Encoding and Content-Length")
	end
	local transferEncodings = util.parseTransferEncoding(transferEncoding)
	local content_length: number? = nil
	if contentLengthHeader then
		local ok, parsedOrErr = pcall(util.parseContentLength, contentLengthHeader)
		if not ok then
			requestError(400, parsedOrErr)
		end
		content_length = parsedOrErr :: number?
	end
	if #transferEncodings > 0 and transferEncodings[#transferEncodings] ~= "chunked" then
		requestError(501, "Unsupported Transfer-Encoding")
	end

	local expectHeader = req_headers["expect"]
	if expectHeader then
		if string.lower(util.trim(expectHeader)) == "100-continue" then
			if (content_length ~= nil and content_length > 0) or #transferEncodings > 0 then
				sock:sendAll(buffer.fromstring("HTTP/1.1 100 Continue\r\n\r\n"))
			end
		else
			requestError(417, "Unsupported Expect header")
		end
	end

	local parsedContentType = util.parseContentType(req_headers["content-type"])
	local nextBuffered = body_start_data
	local bodyStream: RequestBodyStream?
	local request

	if not self._streamRequestBodies then
		local buffered = body_start_data
		local function recvChunk(): string
			local ok, chunk = pcall(sock.recv, sock, 8192)
			if not ok then
				if exception.isInterrupt(chunk) then
					error(chunk)
				end
				requestError(400, "Failed while reading request body")
			end
			local s = buffer.tostring(chunk)
			if #s == 0 then
				requestError(400, "Unexpected EOF while reading request body")
			end
			return s
		end

		local function recvUntil(delim: string): string
			while true do
				local pos = string.find(buffered, delim, 1, true)
				if pos then
					local result = string.sub(buffered, 1, pos + #delim - 1)
					buffered = string.sub(buffered, pos + #delim)
					return result
				end
				buffered ..= recvChunk()
				if #buffered > self._maxBodyBytes then
					requestError(413, "Request body too large")
				end
			end
		end

		local function recvExact(n: number): string
			while #buffered < n do
				buffered ..= recvChunk()
				if #buffered > self._maxBodyBytes then
					requestError(413, "Request body too large")
				end
			end
			local result = string.sub(buffered, 1, n)
			buffered = string.sub(buffered, n + 1)
			return result
		end

		local function readChunkedBody(): (string, { [string]: string })
			local parts = {}
			local total = 0
			local trailers = {}

			while true do
				local size_line = recvUntil("\r\n")
				size_line = string.gsub(size_line, "\r\n$", "")
				local size_str = string.match(size_line, "^([0-9a-fA-F]+)")
				if not size_str then
					requestError(400, "Malformed chunk size")
				end

				local chunk_size = tonumber(size_str, 16)
				if chunk_size == nil then
					requestError(400, "Malformed chunk size")
				end
				if chunk_size == 0 then
					local trailerLines = {}
					while true do
						local trailerLine = recvUntil("\r\n")
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

				total += chunk_size
				if total > self._maxBodyBytes then
					requestError(413, "Request body too large")
				end

				table.insert(parts, recvExact(chunk_size))
				local line_end = recvExact(2)
				if line_end ~= "\r\n" then
					requestError(400, "Malformed chunk terminator")
				end
			end

			return table.concat(parts), trailers
		end

		local body = buffered
		local trailers = {}
		if #transferEncodings > 0 then
			body, trailers = readChunkedBody()
		elseif content_length ~= nil then
			buffered = ""
			if content_length > self._maxBodyBytes then
				requestError(413, "Request body too large")
			end
			while #body < content_length do
				local remaining = content_length - #body
				local ok, chunk = pcall(sock.recv, sock, remaining)
				if not ok then
					if exception.isInterrupt(chunk) then
						error(chunk)
					end
					break
				end
				local s = buffer.tostring(chunk)
				if #s == 0 then
					break
				end
				body ..= s
			end
			if #body > content_length then
				buffered = string.sub(body, content_length + 1)
				body = string.sub(body, 1, content_length)
			end
		else
			buffered = body
			body = ""
		end

		local parsedForm = nil :: QueryTable?
		local parsedMultipart = nil :: { ParsedMultipartField }?
		if parsedContentType.mediaType == "application/x-www-form-urlencoded" then
			parsedForm = util.decodeForm(body)
		elseif parsedContentType.mediaType == "multipart/form-data" then
			local boundary = parsedContentType.params.boundary
			if boundary and boundary ~= "" then
				parsedMultipart = multipart.parse(body, boundary)
			end
		end

		return {
			method = method :: string,
			path = path :: string,
			pathname = target.path,
			queryString = target.queryString,
			query = target.query,
			httpVersion = (httpVersion or "HTTP/1.1") :: string,
			headers = req_headers,
			trailers = trailers,
			contentType = parsedContentType.mediaType,
			body = body,
			form = parsedForm,
			multipart = parsedMultipart,
			bodyStream = nil,
			remoteAddr = remoteAddr,
			remotePort = remotePort,
			readBody = function(selfReq)
				return selfReq.body
			end,
			readForm = function(selfReq)
				return selfReq.form
			end,
			readMultipart = function(selfReq)
				return selfReq.multipart
			end,
			readJson = function(selfReq)
				if not util.isJsonContentType(selfReq.headers["content-type"]) then
					return nil
				end
				return json.decode(selfReq.body)
			end,
		},
			buffered
	end

	if #transferEncodings > 0 then
		bodyStream = setmetatable({
			_closed = false,
			_sock = sock,
			_buffer = body_start_data,
			_trailers = nil,
			_mode = "chunked",
			_remaining = 0,
			_chunkRemaining = 0,
			_totalRead = 0,
			_maxBodyBytes = self._maxBodyBytes,
			_onFinish = function(remaining, trailers)
				nextBuffered = remaining
				request.trailers = trailers or {}
			end,
		}, RequestBodyStream)
		nextBuffered = ""
	elseif content_length ~= nil and content_length > 0 then
		if content_length > self._maxBodyBytes then
			requestError(413, "Request body too large")
		end
		bodyStream = setmetatable({
			_closed = false,
			_sock = sock,
			_buffer = body_start_data,
			_trailers = nil,
			_mode = "length",
			_remaining = content_length,
			_chunkRemaining = 0,
			_totalRead = 0,
			_maxBodyBytes = self._maxBodyBytes,
			_onFinish = function(remaining, trailers)
				nextBuffered = remaining
				request.trailers = trailers or {}
			end,
		}, RequestBodyStream)
		nextBuffered = ""
	elseif content_length ~= nil or #body_start_data == 0 then
		bodyStream = nil
	else
		nextBuffered = body_start_data
	end

	request = setmetatable({
		method = method :: string,
		path = path :: string,
		pathname = target.path,
		queryString = target.queryString,
		query = target.query,
		httpVersion = (httpVersion or "HTTP/1.1") :: string,
		headers = req_headers,
		trailers = {},
		contentType = parsedContentType.mediaType,
		remoteAddr = remoteAddr,
		remotePort = remotePort,
		body = nil,
		form = nil,
		multipart = nil,
		_body = if bodyStream == nil then "" else nil,
		_form = nil,
		_multipart = nil,
		_bodyStream = bodyStream,
		_multipartBoundary = parsedContentType.params.boundary,
	}, ServerRequestMetatable)

	return request :: any, nextBuffered
end

--[=[
	Handles one accepted client connection.

	This may serve multiple requests over the same socket when keep-alive
	is in use. Unread streamed request bodies are drained automatically
	before reusing the connection.

	@param client_sock The accepted client socket.
	@param remoteAddr The peer IP address.
	@param remotePort The peer port.
	@return boolean -- `true` when the connection was upgraded and the
	socket ownership has been transferred elsewhere.
]=]
function HttpServer._handleConnection(
	self: HttpServer,
	client_sock: any,
	remoteAddr: string,
	remotePort: number
): boolean
	local buffered = ""
	local requestsServed = 0
	while true do
		if requestsServed == 0 then
			client_sock:setTimeout(self._clientTimeout)
		else
			client_sock:setTimeout(self._keepAliveTimeout)
		end

		local ok, requestOrErr, nextBuffered = pcall(function()
			return self:_readRequest(client_sock, remoteAddr, remotePort, buffered)
		end)
		if not ok then
			local status, message = decodeRequestError(requestOrErr)
			if status ~= nil then
				local response = ServerResponse._new(client_sock)
				response:send(status, message, {
					["Content-Type"] = "text/plain; charset=utf-8",
				})
				return false
			end
			error(requestOrErr)
		end

		local request = requestOrErr :: ServerRequest?
		if not request then
			return false
		end
		buffered = nextBuffered :: string
		requestsServed += 1

		local response = ServerResponse._new(client_sock, request.method, request.httpVersion, request.headers)

		-- Call the user's handler
		self._callback(request, response)

		if not response._finished then
			if response._holdOpen then
				while not response._finished and not response._upgraded do
					task.wait(0.01)
				end
			else
				response:finish()
			end
		end

		if response._upgraded then
			return true
		end

		if self._maxRequestsPerConnection ~= nil and requestsServed >= (self._maxRequestsPerConnection :: number) then
			response._keepAlive = false
		end

		if response:wantsKeepAlive() then
			local bodyStream = rawget(request :: any, "_bodyStream")
			if bodyStream ~= nil and not (bodyStream :: RequestBodyStream)._closed then
				local ok, err = pcall(function()
					(bodyStream :: RequestBodyStream):close()
				end)
				if not ok then
					local status = decodeRequestError(err)
					if status ~= nil then
						return false
					end
					error(err)
				end
				buffered = rawget(bodyStream, "_buffer") or buffered
			end
		end

		if not response:wantsKeepAlive() then
			return false
		end
	end
end

--[=[
	Stops the server by closing the listening socket.

	This unblocks the [[HttpServer.listen]] call, allowing the server
	loop to exit cleanly.
]=]
function HttpServer.close(self: HttpServer)
	self._running = false
	if self._sock then
		pcall(function()
			(self._sock :: any):close()
		end)
		self._sock = nil
	end
end

return table.freeze(HttpServer)
