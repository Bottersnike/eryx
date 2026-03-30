local ServerResponse = require("./ServerResponse")
local _socket = require("@eryx/_socket")
local _ssl = require("@eryx/_ssl")
local exception = require("@eryx/exception")
local task = require("@eryx/task")
local util = require("./util")

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
	server:kisten()
	```
]=]
local HttpServer = {}
HttpServer.__index = HttpServer

type ServerCallback = (request: ServerRequest, response: ServerResponse.ServerResponse) -> ()

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
				print("request handler error: " .. msg)
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
function HttpServer._readRequest(self: HttpServer, sock: any, remoteAddr: string, remotePort: number): ServerRequest?
	-- Read until we find the end of headers
	local buf = ""
	while true do
		local ok, chunk = pcall(sock.recv, sock, 8192)
		if not ok then
			if exception.isInterrupt(chunk) then
				error(chunk)
			end
			return nil
		end
		local s = buffer.tostring(chunk)
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

	local req_headers = util.parseHeaders(headers_raw)

	-- Read body if Content-Length is present
	local body = body_start_data
	local cl = req_headers["content-length"]
	if cl then
		local content_length = tonumber(cl) or 0
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

function HttpServer._handleConnection(
	self: HttpServer,
	client_sock: any,
	remoteAddr: string,
	remotePort: number
): boolean
	local request = self:_readRequest(client_sock, remoteAddr, remotePort)
	if not request then
		return false
	end

	local response = ServerResponse._new(client_sock)

	-- Call the user's handler
	self._callback(request, response)

	-- If the handler didn't call finish(), do it now.
	if not response._finished then
		response:finish()
	end

	-- Return whether the connection was upgraded (e.g. to WebSocket).
	-- When true, the caller must NOT close the socket.
	return response._upgraded
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
