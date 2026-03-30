--[=[
	A writable HTTP response used inside an [[HttpServer]] handler.

	Supports both one-shot replies and streaming (chunked transfer-encoding).

	**One-shot:**
	```luau
	res:send(200, "Hello!")
	```

	**Streaming:**
	```luau
	res:status(200):header("content-type", "text/plain")
	res:write("chunk 1")
	res:write("chunk 2")
	res:finish()
	```
]=]

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

local ServerResponse = {}
ServerResponse.__index = ServerResponse

type ServerResponseFields = {
	_sock: any, -- the accepted client socket (or SSLSocket)
	_headersSent: boolean,
	_finished: boolean,
	_upgraded: boolean, -- true when the connection has been upgraded (e.g. WebSocket); prevents socket cleanup
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
		_upgraded = false,
		_status = 200,
		_reason = "OK",
		_headers = {} :: { [string]: string },
		_chunked = false,
	}, ServerResponse)
end

--[=[
	Sets the HTTP status code and optional reason phrase.

	Must be called before [[ServerResponse.write]] or [[ServerResponse.finish]].
	Returns `self` for chaining.

	@param code The HTTP status code (e.g. `200`, `404`).
	@param reason Custom reason phrase. Defaults to the standard phrase for the code.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.status(self: ServerResponse, code: number, reason: string?): ServerResponse
	assert(not self._headersSent, "Cannot set status after headers have been sent")
	self._status = code
	self._reason = reason or _reasonFor(code)
	return self
end

--[=[
	Sets a single response header.

	Must be called before [[ServerResponse.write]] or [[ServerResponse.finish]].
	Returns `self` for chaining.

	@param name The header name (case-insensitive).
	@param value The header value.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.header(self: ServerResponse, name: string, value: string): ServerResponse
	assert(not self._headersSent, "Cannot set headers after headers have been sent")
	self._headers[string.lower(name)] = value
	return self
end

--[=[
	Sets multiple response headers at once.

	Must be called before [[ServerResponse.write]] or [[ServerResponse.finish]].
	Returns `self` for chaining.

	@param hdrs A table of header name/value pairs.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.headers(self: ServerResponse, hdrs: { [string]: string }): ServerResponse
	assert(not self._headersSent, "Cannot set headers after headers have been sent")
	for k, v in hdrs do
		self._headers[string.lower(k)] = v
	end
	return self
end

--- @private
--- flush the status line + headers to the socket.
function ServerResponse._sendHead(self: ServerResponse)
	if self._headersSent then
		return
	end
	self._headersSent = true

	-- If no content-length was set, use chunked transfer-encoding so
	-- the caller can stream multiple write() calls.

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

	self._sock:sendAll(buffer.fromstring(table.concat(lines)))
end

--[=[
	Writes a chunk of the response body.

	Sends headers on the first call. Can be called multiple times for
	streaming or long-polling. Uses chunked transfer-encoding when
	no `Content-Length` is set.

	@param data The body chunk to send.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.write(self: ServerResponse, data: string): ServerResponse
	assert(not self._finished, "Cannot write after response is finished")
	self:_sendHead()

	if #data == 0 then
		return self
	end

	if self._chunked then
		-- Chunked encoding: size in hex + CRLF + data + CRLF
		local chunk = string.format("%x\r\n", #data) .. data .. "\r\n"
		self._sock:sendAll(buffer.fromstring(chunk))
	else
		self._sock:sendAll(buffer.fromstring(data))
	end
	return self
end

--[=[
	Finishes the response.

	Sends the terminating chunk if chunked transfer-encoding is active.
	If `body` is provided, it is a shorthand for
	`write(body)` followed by `finish()`.

	@param body Optional final body to send before finishing.
]=]
function ServerResponse.finish(self: ServerResponse, body: string?)
	if self._finished then
		return
	end

	if body then
		-- If headers haven't been sent yet and no content-length set,
		-- we know the full size so set it to avoid chunked for simple responses.
		if not self._headersSent and not self._headers["content-length"] then
			self._headers["content-length"] = tostring(#body)
		end
		self:write(body)
	else
		self:_sendHead()
	end

	if self._chunked then
		-- Send terminal chunk
		self._sock:sendAll(buffer.fromstring("0\r\n\r\n"))
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
function ServerResponse.send(self: ServerResponse, statusCode: number, body: string?, hdrs: { [string]: string }?)
	self:status(statusCode)
	if hdrs then
		self:headers(hdrs)
	end
	self:finish(body or "")
end

--[=[
	Sends a JSON response with the `content-type` header set to
	`application/json`.

	@param statusCode The HTTP status code.
	@param data The JSON string to send as the body.
]=]
function ServerResponse.json(self: ServerResponse, statusCode: number, data: string)
	self:status(statusCode)
	self:header("content-type", "application/json")
	self:finish(data)
end

return table.freeze(ServerResponse)
