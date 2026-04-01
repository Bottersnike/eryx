--[=[
	A writable HTTP response used inside an [[HttpServer]] handler.

	Supports both one-shot replies and streaming (chunked transfer-encoding).
	Trailers can also be attached to chunked responses.

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

	**Stream from a reader:**
	```luau
	res:status(200)
	res:trailer("x-checksum", "ok")
	res:sendStream(myReader)
	```
]=]

local util = require("./util")

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
	[417] = "Expectation Failed",
	[422] = "Unprocessable Entity",
	[429] = "Too Many Requests",
	[431] = "Request Header Fields Too Large",
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

export type ResponseBodyStream = {
	read: (self: ResponseBodyStream, size: number?) -> string?,
	close: ((self: ResponseBodyStream) -> ())?,
}

type ServerResponseFields = {
	_sock: any, -- the accepted client socket (or SSLSocket)
	_headersSent: boolean,
	_finished: boolean,
	_upgraded: boolean, -- true when the connection has been upgraded (e.g. WebSocket); prevents socket cleanup
	_status: number,
	_reason: string,
	_headers: { [string]: string },
	_chunked: boolean,
	_requestMethod: string?,
	_requestHttpVersion: string?,
	_keepAlive: boolean,
	_holdOpen: boolean,
	_trailers: { [string]: string },
}

export type ServerResponse = setmetatable<ServerResponseFields, typeof(ServerResponse)>

local function statusDisallowsBody(status: number): boolean
	return (status >= 100 and status < 200) or status == 204 or status == 304
end

local function responseSuppressesBody(self: ServerResponse): boolean
	return self._requestMethod == "HEAD" or statusDisallowsBody(self._status)
end

local function defaultKeepAlive(requestHttpVersion: string?, connectionHeader: string?): boolean
	if requestHttpVersion == "HTTP/1.0" then
		return util.headerHasToken(connectionHeader, "keep-alive")
	end
	return not util.headerHasToken(connectionHeader, "close")
end

function ServerResponse._new(
	sock: any,
	requestMethod: string?,
	requestHttpVersion: string?,
	requestHeaders: { [string]: string }?
): ServerResponse
	return setmetatable({
		_sock = sock,
		_headersSent = false,
		_finished = false,
		_upgraded = false,
		_status = 200,
		_reason = "OK",
		_headers = {} :: { [string]: string },
		_chunked = false,
		_requestMethod = requestMethod,
		_requestHttpVersion = requestHttpVersion,
		_keepAlive = defaultKeepAlive(requestHttpVersion, if requestHeaders then requestHeaders["connection"] else nil),
		_holdOpen = false,
		_trailers = {},
	}, ServerResponse)
end

function ServerResponse.holdOpen(self: ServerResponse): ServerResponse
	self._holdOpen = true
	return self
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

--[=[
	Queues a trailer header to be sent after a chunked response body.

	Trailers are only sent for chunked, body-bearing responses. The
	response automatically advertises the trailer names in the `Trailer`
	header.

	@param name The trailer header name.
	@param value The trailer value.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.trailer(self: ServerResponse, name: string, value: string): ServerResponse
	assert(not self._headersSent, "Cannot set trailers after headers have been sent")
	assert(not responseSuppressesBody(self), "Cannot send trailers for a bodyless response")
	self._trailers[string.lower(name)] = value
	return self
end

--[=[
	Queues multiple trailer headers to be sent after a chunked response.

	@param hdrs Trailer name/value pairs.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.trailers(self: ServerResponse, hdrs: { [string]: string }): ServerResponse
	assert(not self._headersSent, "Cannot set trailers after headers have been sent")
	for name, value in hdrs do
		self:trailer(name, value)
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
	local hasTrailers = next(self._trailers) ~= nil

	if responseSuppressesBody(self) then
		self._headers["transfer-encoding"] = nil :: any
		self._chunked = false
		self._trailers = {}
	elseif hasTrailers then
		if cl then
			error("Cannot send trailers on a Content-Length response")
		end
		self._headers["transfer-encoding"] = "chunked"
		self._chunked = true
	elseif not cl and not te then
		self._headers["transfer-encoding"] = "chunked"
		self._chunked = true
	elseif te and string.find(string.lower(te), "chunked", 1, true) then
		self._chunked = true
	end

	local connectionHeader = self._headers["connection"]
	if connectionHeader ~= nil then
		if util.headerHasToken(connectionHeader, "close") then
			self._keepAlive = false
		elseif util.headerHasToken(connectionHeader, "keep-alive") then
			self._keepAlive = true
		end
	elseif self._keepAlive then
		self._headers["connection"] = "keep-alive"
	else
		self._headers["connection"] = "close"
	end

	if self._chunked and next(self._trailers) ~= nil and self._headers["trailer"] == nil then
		local names = {}
		for name in self._trailers do
			table.insert(names, name)
		end
		table.sort(names)
		self._headers["trailer"] = table.concat(names, ", ")
	end

	local lines: { string } = {}
	table.insert(lines, "HTTP/1.1 " .. tostring(self._status) .. " " .. self._reason :: string .. "\r\n")
	for name, value in self._headers :: { [string]: string } do
		if name == "set-cookie" and string.find(value, "\n", 1, true) ~= nil then
			for item in string.gmatch(value, "([^\n]+)") do
				table.insert(lines, name .. ": " .. item .. "\r\n")
			end
		else
			table.insert(lines, name .. ": " .. value .. "\r\n")
		end
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

	if #data == 0 or responseSuppressesBody(self) then
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
		if self._requestMethod == "HEAD" and not self._headersSent and not self._headers["content-length"] then
			self._headers["content-length"] = tostring(#body)
		elseif not responseSuppressesBody(self) and not self._headersSent and not self._headers["content-length"] then
			self._headers["content-length"] = tostring(#body)
		end
		self:write(body)
	else
		self:_sendHead()
	end

	if self._chunked then
		local trailerLines = { "0\r\n" }
		for name, value in self._trailers do
			table.insert(trailerLines, name .. ": " .. value .. "\r\n")
		end
		table.insert(trailerLines, "\r\n")
		self._sock:sendAll(buffer.fromstring(table.concat(trailerLines)))
	end

	self._finished = true
end

--[=[
	Streams a response body from an incremental reader.

	This is useful for large downloads, generated content, or proxy-style
	handlers where buffering the entire body first would be wasteful.

	If `contentLength` is omitted, the response uses chunked transfer
	encoding automatically.

	@param bodyStream The incremental body source.
	@param contentLength Optional exact body size in bytes.
	@return ServerResponse -- Self, for method chaining.
]=]
function ServerResponse.sendStream(
	self: ServerResponse,
	bodyStream: ResponseBodyStream,
	contentLength: number?
): ServerResponse
	assert(not self._finished, "Cannot stream after response is finished")
	if contentLength ~= nil and self._headers["content-length"] == nil then
		self._headers["content-length"] = tostring(contentLength)
	end

	local ok, err = pcall(function()
		while true do
			local chunk = bodyStream:read(65536)
			if chunk == nil then
				break
			end
			if #chunk > 0 then
				self:write(chunk)
			end
		end
	end)

	if bodyStream.close ~= nil then
		pcall(function()
			(bodyStream.close :: any)(bodyStream)
		end)
	end

	if not ok then
		error(err :: any)
	end

	self:finish()
	return self
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

function ServerResponse.wantsKeepAlive(self: ServerResponse): boolean
	return self._keepAlive and self._upgraded == false and self._finished == true
end

return table.freeze(ServerResponse)
