--[=[
	TCP networking module providing blocking and non-blocking clients, and a
	blocking TCP server. Built on top of the low-level `@eryx/_socket` module.

	## Quick start — client

	```luau
	local net = require("@eryx/net")

	local client = net.TcpClient.new("127.0.0.1", 8080)
	client:Write("Hello, server!")
	local response = client:Read(1024)
	print(buffer.tostring(response))
	client:Close()
	```

	## Quick start — server

	```luau
	local net = require("@eryx/net")

	local server = net.TcpServer.new("0.0.0.0", 8080)
	server.onClient:Connect(function(client)
		local data = client:Read(1024)
		client:Write("Echo: " .. buffer.tostring(data))
		client:Close()
	end)
	```
]=]

local _socket = require("@eryx/_socket")
local Signal = require("@eryx/signal")
local task = require("@eryx/task")

local net = {}

--[=[
	A blocking TCP client. All read/write operations will block the current
	coroutine until they complete. Best suited for simple request/response
	protocols or use within dedicated `task.spawn` coroutines.
]=]
local TcpClient = {}
TcpClient.__index = TcpClient
export type TcpClient = setmetatable<{
	read socket: _socket.Socket,
	read host: string,
	read port: number,
}, typeof(TcpClient)>

--[=[
	Creates a new blocking TCP client and connects to the given host and port.

	@param host string -- The hostname or IP address to connect to.
	@param port number -- The port number to connect to.
	@return TcpClient -- A connected blocking TCP client.
	@error Throws if the connection fails.

	```luau
	local client = TcpClient.new("127.0.0.1", 3000)
	```
]=]
function TcpClient.new(host: string, port: number): TcpClient
	local this = {}

	this.socket = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	this.socket:Connect(host, port)
	this.host = host
	this.port = port

	this.socket:SetBlocking(true)

	return setmetatable(this, TcpClient)
end

--[=[
	Creates a TcpClient from an already-connected socket. Used internally by
	TcpServer to wrap accepted connections.

	@param socket _socket.Socket -- An already-connected socket.
	@param host string -- The remote host address.
	@param port number -- The remote port number.
	@return TcpClient
]=]
function TcpClient._fromConnectedSocket(socket: _socket.Socket, host: string, port: number): TcpClient
	local this = {}

	this.socket = socket
	this.host = host
	this.port = port

	this.socket:SetBlocking(true)

	return setmetatable(this, TcpClient)
end

--[=[
	Sends data to the remote peer. Blocks until all data has been sent.

	@param data string | buffer -- The data to send. Strings are converted to buffers automatically.

	```luau
	client:Write("GET / HTTP/1.0\r\n\r\n")
	client:Write(buffer.fromstring("binary data"))
	```
]=]
function TcpClient.Write(self: TcpClient, data: string | buffer)
	if typeof(data) == "string" then
		self.socket:SendAll(buffer.fromstring(data))
	else
		self.socket:SendAll(data)
	end
end

--[=[
	Reads up to the specified number of bytes from the remote peer. Blocks
	until data is available.

	@param bytes number -- Maximum number of bytes to read.
	@return buffer -- The received data.
	@error Throws if the server closed the connection.

	```luau
	local data = client:Read(4096)
	print(buffer.tostring(data))
	```
]=]
function TcpClient.Read(self: TcpClient, bytes: number): buffer
	local ret: buffer? = self.socket:Recv(bytes)
	assert(ret) -- We're in blocking mode
	if buffer.len(ret) == 0 then
		error("Server closed connection")
	end
	return ret
end

--- Closes the connection and releases the underlying socket.
function TcpClient.Close(self: TcpClient): ()
	self.socket:Close()
end

--[=[
	A non-blocking TCP client. Read and write operations return immediately —
	`Read` returns `nil` if no data is available, and `Write` returns `false`
	if the data could not be sent. Useful for polling-style I/O or integration
	with event loops.
]=]
local TcpClientNonBlocking = {}
TcpClientNonBlocking.__index = TcpClientNonBlocking
export type TcpClientNonBlocking = setmetatable<{
	read socket: _socket.Socket,
	read host: string,
	read port: number,
}, typeof(TcpClientNonBlocking)>

--[=[
	Creates a new non-blocking TCP client and connects to the given host and port.

	@param host string -- The hostname or IP address to connect to.
	@param port number -- The port number to connect to.
	@return TcpClientNonBlocking -- A connected non-blocking TCP client.
	@error Throws if the connection fails.

	```luau
	local client = TcpClientNonBlocking.new("127.0.0.1", 3000)
	```
]=]
function TcpClientNonBlocking.new(host: string, port: number): TcpClientNonBlocking
	local this = {}

	this.socket = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	this.socket:Connect(host, port)
	this.host = host
	this.port = port

	this.socket:SetBlocking(false)

	return setmetatable(this, TcpClientNonBlocking)
end

--[=[
	Creates a TcpClientNonBlocking from an already-connected socket. Used
	internally to wrap accepted connections in non-blocking mode.

	@param socket _socket.Socket -- An already-connected socket.
	@param host string -- The remote host address.
	@param port number -- The remote port number.
	@return TcpClientNonBlocking
]=]
function TcpClientNonBlocking._fromConnectedSocket(
	socket: _socket.Socket,
	host: string,
	port: number
): TcpClientNonBlocking
	local this = {}

	this.socket = socket
	this.host = host
	this.port = port

	this.socket:SetBlocking(false)

	return setmetatable(this, TcpClientNonBlocking)
end

--[=[
	Attempts to send data to the remote peer without blocking.

	@param data string | buffer -- The data to send. Strings are converted to buffers automatically.
	@return boolean -- `true` if all data was sent, `false` if the socket would block.
]=]
function TcpClientNonBlocking.Write(self: TcpClientNonBlocking, data: string | buffer): boolean
	if typeof(data) == "string" then
		return self.socket:sendall(buffer.fromstring(data))
	else
		return self.socket:sendall(data)
	end
end

--[=[
	Attempts to read up to the specified number of bytes without blocking.

	@param bytes number -- Maximum number of bytes to read.
	@return buffer? -- The received data, or `nil` if no data is available yet.
	@error Throws if the server closed the connection.

	```luau
	local data = client:Read(1024)
	if data then
		print("Got:", buffer.tostring(data))
	end
	```
]=]
function TcpClientNonBlocking.Read(self: TcpClientNonBlocking, bytes: number): buffer?
	local ret = self.socket:recv(bytes)
	if not ret then
		return nil
	end
	if buffer.len(ret) == 0 then
		error("Server closed connection")
	end
	return ret
end

--[=[
	Closes the connection and releases the underlying socket.
]=]
function TcpClientNonBlocking.Close(self: TcpClientNonBlocking): ()
	self.socket:close()
end

--[=[
	A blocking TCP server that listens for incoming connections. New clients are
	dispatched via the `onClient` signal. The accept loop runs in a separate
	coroutine via `task.spawn`.

	If no handler is connected to `onClient` when a client connects, the
	connection is closed immediately.

	```luau
	local server = TcpServer.new("0.0.0.0", 8080)

	server.onClient:Connect(function(client)
		local request = client:Read(4096)
		client:Write("HTTP/1.0 200 OK\r\n\r\nHello!")
		client:Close()
	end)

	-- Later, to shut down:
	server:StopListening()
	```
]=]
local TcpServer = {}
TcpServer.__index = TcpServer
export type TcpServer = setmetatable<{
	read socket: _socket.Socket,
	read onClient: Signal.Signal<TcpClient>,
	read host: string,
	read port: number,
	_listening: boolean,
}, typeof(TcpServer)>

--[=[
	Creates a new TCP server, binds to the given host and port, and begins
	accepting connections in a background coroutine.

	@param host string -- The address to bind to (e.g. `"0.0.0.0"` for all interfaces).
	@param port number -- The port to listen on.
	@param backlog number? -- Maximum number of queued connections (optional, OS default if nil).
	@return TcpServer -- A listening TCP server.
	@error Throws if binding or listening fails.

	```luau
	local server = TcpServer.new("127.0.0.1", 9000, 128)
	```
]=]
function TcpServer.new(host: string, port: number, backlog: number?): TcpServer
	local this = {}

	this.socket = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	this.onClient = Signal.new()
	this.host = host
	this.port = port

	this.socket:SetBlocking(true)
	this.socket:Bind(host, port)
	this.socket:Listen(backlog)

	this._listening = true

	task.spawn(function()
		while this._listening do
			local ok, client, clientHost, clientPort = pcall(this.socket.Accept :: any, this.socket)
			if not ok then
				-- Odds are our error is because we stopped listening
				if not this._listening then
					break
				end
				-- Otherwise re-raise
				error(client)
			end
			if not (client and clientHost and clientPort) then
				if not this._listening then
					break
				end
				error("socket.accept returned nil values")
			end
			-- We're always blocking
			assert(client and clientHost and clientPort)

			if not this.onClient:Fire(TcpClient._fromConnectedSocket(client, clientHost, clientPort)) then
				-- If there wasn't anyone to handle this connection, close it straight away!
				(client :: _socket.Socket):Close()
			end
		end
	end)

	return setmetatable(this, TcpServer)
end

--- Stops the server from accepting new connections. Closes the listening
--- socket, which causes the background accept loop to exit cleanly.
function TcpServer.StopListening(self: TcpServer)
	self._listening = false
	self.socket:Close()
end

net.TcpClient = TcpClient
net.TcpClientNonBlocking = TcpClientNonBlocking
net.TcpServer = TcpServer

return net
