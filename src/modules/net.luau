--[=[
	High-level TCP and UDP networking helpers built on top of `@eryx/_socket`.

	This library wraps the low-level BSD-style socket API with friendlier
	client/server classes, socket-option helpers, IPv4/IPv6 family selection,
	and both signal-driven and manual server accept loops.

	## Quick start - TCP client

	```luau
	local net = require("@eryx/net")

	local client = net.TcpClient.new("127.0.0.1", 8080, {
		nodelay = true,
		timeout = 5,
	})

	client:write("Hello, server!")
	local response = client:read(1024)
	print(buffer.tostring(response))
	client:close()
	```

	## Quick start - concurrent TCP server

	```luau
	local net = require("@eryx/net")

	local server = net.TcpServer.new("0.0.0.0", 8080, {
		reuseAddress = true,
		handler = function(client)
			client:write("hello\\n")
			client:close()
		end,
	})
	```

	## Quick start - UDP

	```luau
	local net = require("@eryx/net")

	local server = net.UdpServer.new("127.0.0.1", 9000)
	local client = net.UdpClient.new("127.0.0.1", 9000)

	client:write("ping")
	local data, host, port = server:receive(1024)
	server:writeTo("pong", host, port)

	print(buffer.tostring(data))
	client:close()
	server:close()
	```
]=]

local _socket = require("@eryx/_socket")
local Signal = require("@eryx/signal")
local task = require("@eryx/task")

local net = {}

--[=[
	A single socket option assignment used by the higher-level `net` wrappers.

	Each entry maps directly to one `setsockopt` call on the underlying socket.
]=]
export type SocketOption = {
	--- Protocol level such as `SOL_SOCKET` or `IPPROTO_TCP`.
	level: number,
	--- Option constant such as `SO_REUSEADDR` or `TCP_NODELAY`.
	name: number,
	--- Value to assign to the option.
	value: number | boolean,
}

--[=[
	Common socket configuration shared by TCP and UDP clients and servers.

	All fields are optional. When omitted, the wrapper chooses sensible defaults
	for the socket kind being created.
]=]
export type SocketConfig = {
	--- Address family, typically `AF_INET` or `AF_INET6`.
	family: number?,
	--- Blocking timeout in seconds. Ignored in non-blocking mode.
	timeout: number?,
	--- Whether the wrapper should operate in blocking mode. Defaults to `true`.
	blocking: boolean?,
	--- Extra raw socket options to apply after the socket is created.
	socketOptions: { SocketOption }?,
	--- Enables `SO_REUSEADDR`.
	reuseAddress: boolean?,
	--- Enables `SO_KEEPALIVE`.
	keepAlive: boolean?,
	--- Enables `TCP_NODELAY` for TCP sockets.
	nodelay: boolean?,
	--- Enables `SO_BROADCAST` for UDP broadcast traffic.
	broadcast: boolean?,
	--- Sets `SO_RCVBUF`.
	receiveBufferSize: number?,
	--- Sets `SO_SNDBUF`.
	sendBufferSize: number?,
	--- Sets `IPV6_V6ONLY` on IPv6 sockets.
	ipv6Only: boolean?,
	--- Optional local address to bind before connect.
	localHost: string?,
	--- Optional local port to bind before connect.
	localPort: number?,
}

--[=[
	Options for [[TcpClient.new]] and [[TcpClientNonBlocking.new]].
]=]
export type TcpClientOptions = SocketConfig

--[=[
	Options for [[TcpServer.new]].
]=]
export type TcpServerOptions = SocketConfig & {
	--- Maximum queued connection count passed to `listen`.
	backlog: number?,
	--- `signal` starts a background accept loop; `manual` leaves accepting to the caller.
	mode: "signal" | "manual"?,
	--- Optional convenience handler connected to `onClient`.
	handler: ((client: TcpClient) -> ())?,
}

--[=[
	Options for [[UdpClient.new]].
]=]
export type UdpClientOptions = SocketConfig

--[=[
	Options for [[UdpServer.new]].
]=]
export type UdpServerOptions = SocketConfig & {
	--- `signal` starts a background receive loop; `manual` leaves receiving to the caller.
	mode: "signal" | "manual"?,
	--- Optional convenience handler connected to `onDatagram`.
	handler: ((data: buffer, host: string, port: number) -> ())?,
	--- Datagram buffer size used by the background receive loop.
	packetSize: number?,
}

local function cloneOptions<T>(options: T?): T
	if options == nil then
		return {} :: T
	end
	return table.clone(options :: any) :: T
end

local function dataToBuffer(data: string | buffer): buffer
	if typeof(data) == "string" then
		return buffer.fromstring(data)
	end
	return data
end

local function resolveFamily(host: string?, port: number?, sockType: number, proto: number, family: number?): number
	if family ~= nil then
		return family
	end

	if host == nil or host == "" then
		return _socket.AF_INET
	end

	if string.find(host, ":", 1, true) then
		return _socket.AF_INET6
	end

	local results = _socket.getAddrInfo(host, port, _socket.AF_UNSPEC, sockType, proto)
	if #results > 0 then
		return results[1].family
	end

	return _socket.AF_INET
end

local function applySocketOptions(sock: _socket.Socket, options: SocketConfig?)
	if options == nil then
		return
	end

	if options.reuseAddress ~= nil then
		sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, options.reuseAddress)
	end
	if options.keepAlive ~= nil then
		sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_KEEPALIVE, options.keepAlive)
	end
	if options.nodelay ~= nil then
		sock:setSockOpt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, options.nodelay)
	end
	if options.broadcast ~= nil then
		sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_BROADCAST, options.broadcast)
	end
	if options.receiveBufferSize ~= nil then
		sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, options.receiveBufferSize)
	end
	if options.sendBufferSize ~= nil then
		sock:setSockOpt(_socket.SOL_SOCKET, _socket.SO_SNDBUF, options.sendBufferSize)
	end
	if options.ipv6Only ~= nil then
		sock:setSockOpt(_socket.IPPROTO_IPV6, _socket.IPV6_V6ONLY, options.ipv6Only)
	end
	if options.socketOptions then
		for _, option in options.socketOptions do
			sock:setSockOpt(option.level, option.name, option.value)
		end
	end
end

local function configureSocket(sock: _socket.Socket, options: SocketConfig?)
	if options == nil then
		sock:setBlocking(true)
		return
	end

	applySocketOptions(sock, options)

	if options.blocking == false then
		sock:setBlocking(false)
	else
		sock:setBlocking(true)
		if options.timeout ~= nil then
			sock:setTimeout(options.timeout)
		end
	end
end

local function createConfiguredSocket(
	host: string?,
	port: number?,
	sockType: number,
	proto: number,
	options: SocketConfig?
): (_socket.Socket, number)
	local family = resolveFamily(host, port, sockType, proto, if options then options.family else nil)
	local sock = _socket.socket(family, sockType, proto)
	configureSocket(sock, options)
	return sock, family
end

local function bindIfRequested(sock: _socket.Socket, options: SocketConfig?)
	if options == nil then
		return
	end
	if options.localHost ~= nil or options.localPort ~= nil then
		sock:bind(options.localHost or "", options.localPort or 0)
	end
end

local function setSocketTimeout(sock: _socket.Socket, seconds: number?)
	if seconds == nil then
		sock:setBlocking(true)
		return
	end
	sock:setBlocking(true)
	sock:setTimeout(seconds)
end

local function socketRead(sock: _socket.Socket, bytes: number): buffer
	local ret = sock:recv(bytes)
	assert(ret, "socket would block")
	return ret
end

local function socketReadNonBlocking(sock: _socket.Socket, bytes: number): buffer?
	return sock:recv(bytes)
end

local TcpClient = {}
TcpClient.__index = TcpClient
--[=[
	A blocking TCP client wrapper.

	All read and write operations suspend the current coroutine until the
	operation completes or the configured timeout is hit.
]=]
export type TcpClient = setmetatable<
	{
		--- Underlying connected socket.
		read socket: _socket.Socket,
		--- Remote host this client is connected to.
		read host: string,
		--- Remote port this client is connected to.
		read port: number,
		--- Address family in use, such as `AF_INET` or `AF_INET6`.
		read family: number,
	},
	typeof(TcpClient)
>

--[=[
	Creates and connects a blocking TCP client.

	@param host string -- Remote hostname or numeric address.
	@param port number -- Remote TCP port.
	@param options TcpClientOptions? -- Optional socket configuration.
	@return TcpClient -- A connected blocking TCP client.
	@error Throws if socket creation, optional local bind, or connect fails.
]=]
function TcpClient.new(host: string, port: number, options: TcpClientOptions?): TcpClient
	local sock, family = createConfiguredSocket(host, port, _socket.SOCK_STREAM, _socket.IPPROTO_TCP, options)
	bindIfRequested(sock, options)
	sock:connect(host, port)

	return setmetatable({
		socket = sock,
		host = host,
		port = port,
		family = family,
	}, TcpClient)
end

--[=[
	Wraps an already-connected socket as a [[TcpClient]].

	This is primarily used internally by [[TcpServer.accept]], but can also be
	useful for advanced code that obtains connected sockets elsewhere.

	@param socket _socket.Socket -- Already-connected TCP socket.
	@param host string -- Remote peer address.
	@param port number -- Remote peer port.
	@param family number? -- Address family override.
	@param options TcpClientOptions? -- Optional wrapper configuration to apply.
	@return TcpClient -- Wrapped blocking TCP client.
]=]
function TcpClient._fromConnectedSocket(
	socket: _socket.Socket,
	host: string,
	port: number,
	family: number?,
	options: TcpClientOptions?
): TcpClient
	configureSocket(socket, options)
	return setmetatable({
		socket = socket,
		host = host,
		port = port,
		family = family or resolveFamily(host, port, _socket.SOCK_STREAM, _socket.IPPROTO_TCP, nil),
	}, TcpClient)
end

--[=[
	Sends the provided data to the remote peer.

	@param data string | buffer -- Payload to send.
	@yields Yields until the full payload has been written.
]=]
function TcpClient.write(self: TcpClient, data: string | buffer)
	self.socket:sendAll(dataToBuffer(data))
end

--[=[
	Reads up to `bytes` bytes from the remote peer.

	@param bytes number -- Maximum number of bytes to receive.
	@return buffer -- Received data.
	@yields Yields until data becomes available.
	@error Throws if the remote side has closed the connection.
]=]
function TcpClient.read(self: TcpClient, bytes: number): buffer
	local ret = socketRead(self.socket, bytes)
	if buffer.len(ret) == 0 then
		error("Server closed connection")
	end
	return ret
end

--[=[
	Updates the blocking timeout for future operations on this client.

	Passing `nil` restores blocking mode with no timeout.

	@param seconds number? -- Timeout in seconds, or `nil` for no timeout.
]=]
function TcpClient.setTimeout(self: TcpClient, seconds: number?)
	setSocketTimeout(self.socket, seconds)
end

--[=[
	Sets a socket option on the underlying connection.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant such as `SO_KEEPALIVE`.
	@param value number | boolean -- Value to set.
]=]
function TcpClient.setSocketOption(self: TcpClient, level: number, option: number, value: number | boolean)
	self.socket:setSockOpt(level, option, value)
end

--[=[
	Reads a socket option from the underlying connection.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant to query.
	@return number -- Current option value.
]=]
function TcpClient.getSocketOption(self: TcpClient, level: number, option: number): number
	return self.socket:getSockOpt(level, option)
end

--[=[
	Returns the remote address and port of this connection.

	@return string -- Remote host.
	@return number -- Remote port.
]=]
function TcpClient.getPeerName(self: TcpClient): (string, number)
	return self.socket:getPeerName()
end

--[=[
	Returns the local address and port used by this connection.

	@return string -- Local host.
	@return number -- Local port.
]=]
function TcpClient.getSockName(self: TcpClient): (string, number)
	return self.socket:getSockName()
end

--[=[
	Shuts down one or both halves of the TCP connection.

	@param how number -- One of `_socket.SHUT_RD`, `_socket.SHUT_WR`, or `_socket.SHUT_RDWR`.
]=]
function TcpClient.shutdown(self: TcpClient, how: number)
	self.socket:shutdown(how)
end

--[=[
	Closes the TCP connection.
]=]
function TcpClient.close(self: TcpClient)
	self.socket:close()
end

local TcpClientNonBlocking = {}
TcpClientNonBlocking.__index = TcpClientNonBlocking
--[=[
	A non-blocking TCP client wrapper.

	Read operations return `nil` when no data is available yet, and write
	operations return `false` when the socket would block.
]=]
export type TcpClientNonBlocking = setmetatable<
	{
		--- Underlying connected socket.
		read socket: _socket.Socket,
		--- Remote host this client is connected to.
		read host: string,
		--- Remote port this client is connected to.
		read port: number,
		--- Address family in use, such as `AF_INET` or `AF_INET6`.
		read family: number,
	},
	typeof(TcpClientNonBlocking)
>

--[=[
	Creates and connects a non-blocking TCP client.

	@param host string -- Remote hostname or numeric address.
	@param port number -- Remote TCP port.
	@param options TcpClientOptions? -- Optional socket configuration.
	@return TcpClientNonBlocking -- A connected non-blocking TCP client.
	@error Throws if socket creation, optional local bind, or connect fails.
]=]
function TcpClientNonBlocking.new(host: string, port: number, options: TcpClientOptions?): TcpClientNonBlocking
	local opts = cloneOptions(options);
	(opts :: SocketConfig).blocking = false
	local sock, family = createConfiguredSocket(host, port, _socket.SOCK_STREAM, _socket.IPPROTO_TCP, opts)
	bindIfRequested(sock, opts)
	sock:connect(host, port)

	return setmetatable({
		socket = sock,
		host = host,
		port = port,
		family = family,
	}, TcpClientNonBlocking)
end

--[=[
	Wraps an already-connected socket as a [[TcpClientNonBlocking]].

	@param socket _socket.Socket -- Already-connected TCP socket.
	@param host string -- Remote peer address.
	@param port number -- Remote peer port.
	@param family number? -- Address family override.
	@param options TcpClientOptions? -- Optional wrapper configuration to apply.
	@return TcpClientNonBlocking -- Wrapped non-blocking TCP client.
]=]
function TcpClientNonBlocking._fromConnectedSocket(
	socket: _socket.Socket,
	host: string,
	port: number,
	family: number?,
	options: TcpClientOptions?
): TcpClientNonBlocking
	local opts = cloneOptions(options);
	(opts :: SocketConfig).blocking = false
	configureSocket(socket, opts)
	return setmetatable({
		socket = socket,
		host = host,
		port = port,
		family = family or resolveFamily(host, port, _socket.SOCK_STREAM, _socket.IPPROTO_TCP, nil),
	}, TcpClientNonBlocking)
end

--[=[
	Attempts to send the full payload without blocking.

	@param data string | buffer -- Payload to send.
	@return boolean -- `true` when the payload was fully sent, `false` when the socket would block.
]=]
function TcpClientNonBlocking.write(self: TcpClientNonBlocking, data: string | buffer): boolean
	return self.socket:sendAll(dataToBuffer(data))
end

--[=[
	Attempts to read up to `bytes` bytes without blocking.

	@param bytes number -- Maximum number of bytes to receive.
	@return buffer? -- Received data, or `nil` if the socket would block.
	@error Throws if the remote side has closed the connection.
]=]
function TcpClientNonBlocking.read(self: TcpClientNonBlocking, bytes: number): buffer?
	local ret = socketReadNonBlocking(self.socket, bytes)
	if ret and buffer.len(ret) == 0 then
		error("Server closed connection")
	end
	return ret
end

--[=[
	Sets a socket option on the underlying connection.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant such as `SO_KEEPALIVE`.
	@param value number | boolean -- Value to set.
]=]
function TcpClientNonBlocking.setSocketOption(
	self: TcpClientNonBlocking,
	level: number,
	option: number,
	value: number | boolean
)
	self.socket:setSockOpt(level, option, value)
end

--[=[
	Reads a socket option from the underlying connection.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant to query.
	@return number -- Current option value.
]=]
function TcpClientNonBlocking.getSocketOption(self: TcpClientNonBlocking, level: number, option: number): number
	return self.socket:getSockOpt(level, option)
end

--[=[
	Returns the remote address and port of this connection.

	@return string -- Remote host.
	@return number -- Remote port.
]=]
function TcpClientNonBlocking.getPeerName(self: TcpClientNonBlocking): (string, number)
	return self.socket:getPeerName()
end

--[=[
	Returns the local address and port used by this connection.

	@return string -- Local host.
	@return number -- Local port.
]=]
function TcpClientNonBlocking.getSockName(self: TcpClientNonBlocking): (string, number)
	return self.socket:getSockName()
end

--[=[
	Shuts down one or both halves of the TCP connection.

	@param how number -- One of `_socket.SHUT_RD`, `_socket.SHUT_WR`, or `_socket.SHUT_RDWR`.
]=]
function TcpClientNonBlocking.shutdown(self: TcpClientNonBlocking, how: number)
	self.socket:shutdown(how)
end

--[=[
	Closes the TCP connection.
]=]
function TcpClientNonBlocking.close(self: TcpClientNonBlocking)
	self.socket:close()
end

local TcpServer = {}
TcpServer.__index = TcpServer
type TcpServerFields = {
	--- Underlying listening socket.
	read socket: _socket.Socket,
	--- Fired for each accepted client in `signal` mode.
	read onClient: Signal.Signal<TcpClient>,
	--- Fired when the background accept loop encounters an error.
	read onError: Signal.Signal<any>,
	--- Bound local host.
	read host: string,
	--- Bound local port.
	read port: number,
	-- Address family in use, such as `AF_INET` or `AF_INET6`.
	read family: number,
	_listening: boolean,
	_mode: "signal" | "manual",
	_clientOptions: TcpClientOptions?,
}
--[=[
	A TCP server wrapper.

	In `signal` mode, a background accept loop dispatches each connection
	through [[TcpServer.onClient]]. In `manual` mode, callers explicitly use
	[[TcpServer.accept]] or [[TcpServer.acceptNonBlocking]].
]=]
export type TcpServer = setmetatable<TcpServerFields, typeof(TcpServer)>

local function tcpServerLoop(self: TcpServer)
	task.spawn(function()
		while self._listening do
			local ok, clientOrErr = pcall(function()
				return self:accept()
			end)

			if not ok then
				if not self._listening then
					break
				end
				if not self.onError:fire(clientOrErr) then
					error(clientOrErr)
				end
				continue
			end

			local client = clientOrErr :: TcpClient?
			if client == nil then
				if not self._listening then
					break
				end
				continue
			end

			if not self.onClient:fire(client) then
				client:close()
			end
		end
	end)
end

--[=[
	Creates and starts a TCP server.

	When `options.mode` is `"signal"` or omitted, the server immediately starts
	a background accept loop. When set to `"manual"`, no background loop is
	started and callers should use [[TcpServer.accept]] themselves.

	@param host string -- Local address to bind to.
	@param port number -- Local port to listen on. Use `0` to let the OS choose.
	@param options TcpServerOptions? -- Optional listener configuration.
	@return TcpServer -- A listening TCP server.
	@error Throws if socket creation, bind, or listen fails.
]=]
function TcpServer.new(host: string, port: number, options: TcpServerOptions?): TcpServer
	local serverOptions = cloneOptions(options)

	local sock, family = createConfiguredSocket(host, port, _socket.SOCK_STREAM, _socket.IPPROTO_TCP, serverOptions)
	sock:bind(host, port)
	sock:listen(serverOptions.backlog)

	local boundHost, boundPort = sock:getSockName()
	local this = setmetatable({
		socket = sock,
		onClient = Signal.new() :: Signal.Signal<TcpClient>,
		onError = Signal.new() :: Signal.Signal<any>,
		host = boundHost,
		port = boundPort,
		family = family,
		_listening = true,
		_mode = serverOptions.mode or ("signal" :: "signal"),
		_clientOptions = {
			timeout = serverOptions.timeout,
			keepAlive = serverOptions.keepAlive,
			nodelay = serverOptions.nodelay,
			socketOptions = serverOptions.socketOptions,
		},
	}, TcpServer) :: TcpServer

	if serverOptions.handler then
		this.onClient:connect(serverOptions.handler)
	end

	if this._mode == "signal" then
		tcpServerLoop(this)
	end

	return this
end

--[=[
	Accepts the next incoming connection as a blocking [[TcpClient]].

	In `manual` mode this is typically called by user code. In `signal` mode it
	is used internally by the background accept loop.

	@return TcpClient? -- Accepted client, or `nil` when the listening socket is non-blocking and no client is ready.
	@yields Yields while waiting for a client when the server socket is in blocking mode.
]=]
function TcpServer.accept(self: TcpServer): TcpClient?
	local client, clientHost, clientPort = self.socket:accept()
	if not client then
		return nil
	end
	return TcpClient._fromConnectedSocket(client, clientHost, clientPort, self.family, self._clientOptions)
end

--[=[
	Accepts the next incoming connection as a non-blocking [[TcpClientNonBlocking]].

	@return TcpClientNonBlocking? -- Accepted client, or `nil` when the listening socket is non-blocking and no client is ready.
	@yields Yields while waiting for a client when the server socket is in blocking mode.
]=]
function TcpServer.acceptNonBlocking(self: TcpServer): TcpClientNonBlocking?
	local client, clientHost, clientPort = self.socket:accept()
	if not client then
		return nil
	end
	return TcpClientNonBlocking._fromConnectedSocket(client, clientHost, clientPort, self.family, self._clientOptions)
end

--[=[
	Registers a handler on [[TcpServer.onClient]].

	@param handler (client: TcpClient) -> () -- Callback to run for each accepted client.
	@return Signal.Connection<TcpClient> -- Connection object that can disconnect the handler.
]=]
function TcpServer.handle(self: TcpServer, handler: (client: TcpClient) -> ())
	return self.onClient:connect(handler)
end

--[=[
	Returns the bound local address and port of the listening socket.

	@return string -- Local host.
	@return number -- Local port.
]=]
function TcpServer.getSockName(self: TcpServer): (string, number)
	return self.socket:getSockName()
end

--[=[
	Stops accepting new connections and closes the listening socket.
]=]
function TcpServer.stopListening(self: TcpServer)
	self._listening = false
	self.socket:close()
end

TcpServer.close = TcpServer.stopListening

local UdpClient = {}
UdpClient.__index = UdpClient
--[=[
	A UDP client wrapper.

	Unlike TCP, UDP is datagram-oriented: each send corresponds to one packet
	and reads may return complete datagrams from a connected peer.
]=]
export type UdpClient = setmetatable<
	{
		--- Underlying UDP socket.
		read socket: _socket.Socket,
		--- Default remote host.
		read host: string,
		--- Default remote port.
		read port: number,
		--- Address family in use, such as `AF_INET` or `AF_INET6`.
		read family: number,
	},
	typeof(UdpClient)
>

--[=[
	Creates a UDP socket and connects it to a default remote peer.

	Connected UDP sockets can still use [[UdpClient.writeTo]] to override the
	destination per datagram.

	@param host string -- Default remote hostname or numeric address.
	@param port number -- Default remote UDP port.
	@param options UdpClientOptions? -- Optional socket configuration.
	@return UdpClient -- Connected UDP client wrapper.
	@error Throws if socket creation, optional local bind, or connect fails.
]=]
function UdpClient.new(host: string, port: number, options: UdpClientOptions?): UdpClient
	local sock, family = createConfiguredSocket(host, port, _socket.SOCK_DGRAM, _socket.IPPROTO_UDP, options)
	bindIfRequested(sock, options)
	sock:connect(host, port)

	return setmetatable({
		socket = sock,
		host = host,
		port = port,
		family = family,
	}, UdpClient)
end

--[=[
	Sends one datagram to the connected peer.

	@param data string | buffer -- Datagram payload.
	@return number? -- Number of bytes written, or `nil` if the socket would block.
	@yields Yields while waiting for writability when the socket is in blocking mode.
]=]
function UdpClient.write(self: UdpClient, data: string | buffer): number?
	return self.socket:send(dataToBuffer(data))
end

--[=[
	Sends one datagram to an explicit destination.

	@param data string | buffer -- Datagram payload.
	@param host string -- Destination host.
	@param port number -- Destination port.
	@return number? -- Number of bytes written, or `nil` if the socket would block.
	@yields Yields while waiting for writability when the socket is in blocking mode.
]=]
function UdpClient.writeTo(self: UdpClient, data: string | buffer, host: string, port: number): number?
	return self.socket:sendTo(dataToBuffer(data), host, port)
end

--[=[
	Receives one datagram payload from the connected peer.

	@param bytes number -- Maximum datagram size to receive.
	@return buffer? -- Datagram payload, or `nil` if the socket would block.
	@yields Yields while waiting for data when the socket is in blocking mode.
]=]
function UdpClient.read(self: UdpClient, bytes: number): buffer?
	return self.socket:recv(bytes)
end

--[=[
	Receives one datagram along with its sender address.

	@param bytes number -- Maximum datagram size to receive.
	@return buffer? -- Datagram payload.
	@return string? -- Sender host.
	@return number? -- Sender port.
	@yields Yields while waiting for data when the socket is in blocking mode.
]=]
function UdpClient.readFrom(self: UdpClient, bytes: number): (buffer?, string?, number?)
	return self.socket:recvFrom(bytes)
end

--[=[
	Updates the blocking timeout for future operations on this client.

	Passing `nil` restores blocking mode with no timeout.

	@param seconds number? -- Timeout in seconds, or `nil` for no timeout.
]=]
function UdpClient.setTimeout(self: UdpClient, seconds: number?)
	setSocketTimeout(self.socket, seconds)
end

--[=[
	Sets a socket option on the underlying UDP socket.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant such as `SO_BROADCAST`.
	@param value number | boolean -- Value to set.
]=]
function UdpClient.setSocketOption(self: UdpClient, level: number, option: number, value: number | boolean)
	self.socket:setSockOpt(level, option, value)
end

--[=[
	Reads a socket option from the underlying UDP socket.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant to query.
	@return number -- Current option value.
]=]
function UdpClient.getSocketOption(self: UdpClient, level: number, option: number): number
	return self.socket:getSockOpt(level, option)
end

--[=[
	Returns the default remote peer for this connected UDP socket.

	@return string -- Remote host.
	@return number -- Remote port.
]=]
function UdpClient.getPeerName(self: UdpClient): (string, number)
	return self.socket:getPeerName()
end

--[=[
	Returns the local address and port used by this UDP socket.

	@return string -- Local host.
	@return number -- Local port.
]=]
function UdpClient.getSockName(self: UdpClient): (string, number)
	return self.socket:getSockName()
end

--[=[
	Closes the UDP socket.
]=]
function UdpClient.close(self: UdpClient)
	self.socket:close()
end

local UdpServer = {}
UdpServer.__index = UdpServer
type UdpServerFields = {
	--- Underlying bound UDP socket.
	read socket: _socket.Socket,
	--- Fired with `(data, host, port)` for each received datagram in `signal` mode.
	read onDatagram: Signal.Signal<buffer, string, number>,
	--- Fired when the background receive loop encounters an error.
	read onError: Signal.Signal<any>,
	--- Bound local host.
	read host: string,
	--- Bound local port.
	read port: number,
	--- Address family in use, such as `AF_INET` or `AF_INET6`.
	read family: number,
	_listening: boolean,
	_mode: "signal" | "manual",
	_packetSize: number,
}
--[=[
	A UDP server wrapper.

	In `signal` mode, a background receive loop dispatches datagrams through
	[[UdpServer.onDatagram]]. In `manual` mode, callers explicitly use
	[[UdpServer.receive]].
]=]
export type UdpServer = setmetatable<UdpServerFields, typeof(UdpServer)>

local function udpServerLoop(self: UdpServer)
	task.spawn(function()
		while self._listening do
			local ok, dataOrErr, host, port = pcall(function()
				return self:receive(self._packetSize)
			end)

			if not ok then
				if not self._listening then
					break
				end
				if not self.onError:fire(dataOrErr) then
					error(dataOrErr)
				end
				continue
			end

			if dataOrErr == nil then
				if not self._listening then
					break
				end
				continue
			end

			self.onDatagram:fire(dataOrErr :: buffer, host :: string, port :: number)
		end
	end)
end

--[=[
	Creates and binds a UDP server socket.

	When `options.mode` is `"signal"`, the server immediately starts a
	background receive loop that fires [[UdpServer.onDatagram]].

	@param host string -- Local address to bind to.
	@param port number -- Local UDP port. Use `0` to let the OS choose.
	@param options UdpServerOptions? -- Optional socket configuration.
	@return UdpServer -- Bound UDP server wrapper.
	@error Throws if socket creation or bind fails.
]=]
function UdpServer.new(host: string, port: number, options: UdpServerOptions?): UdpServer
	local opts = cloneOptions(options)
	local sock, family = createConfiguredSocket(host, port, _socket.SOCK_DGRAM, _socket.IPPROTO_UDP, opts)
	sock:bind(host, port)

	local boundHost, boundPort = sock:getSockName()
	local this: UdpServer = setmetatable({
		socket = sock,
		onDatagram = Signal.new() :: Signal.Signal<buffer, string, number>,
		onError = Signal.new() :: Signal.Signal<any>,
		host = boundHost,
		port = boundPort,
		family = family,
		_listening = true,
		_mode = opts.mode or ("manual" :: "manual"),
		_packetSize = opts.packetSize or 65507,
	}, UdpServer)

	if opts.handler then
		this.onDatagram:connect(opts.handler)
	end

	if this._mode == "signal" then
		udpServerLoop(this)
	end

	return this
end

--[=[
	Receives one datagram and its sender address.

	@param bytes number -- Maximum datagram size to receive.
	@return buffer? -- Datagram payload.
	@return string? -- Sender host.
	@return number? -- Sender port.
	@yields Yields while waiting for data when the socket is in blocking mode.
]=]
function UdpServer.receive(self: UdpServer, bytes: number): (buffer?, string?, number?)
	return self.socket:recvFrom(bytes)
end

--[=[
	Sends one datagram to the specified destination.

	@param data string | buffer -- Datagram payload.
	@param host string -- Destination host.
	@param port number -- Destination port.
	@return number? -- Number of bytes written, or `nil` if the socket would block.
	@yields Yields while waiting for writability when the socket is in blocking mode.
]=]
function UdpServer.writeTo(self: UdpServer, data: string | buffer, host: string, port: number): number?
	return self.socket:sendTo(dataToBuffer(data), host, port)
end

--[=[
	Updates the blocking timeout for future operations on this server socket.

	Passing `nil` restores blocking mode with no timeout.

	@param seconds number? -- Timeout in seconds, or `nil` for no timeout.
]=]
function UdpServer.setTimeout(self: UdpServer, seconds: number?)
	setSocketTimeout(self.socket, seconds)
end

--[=[
	Sets a socket option on the underlying UDP socket.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant such as `SO_BROADCAST`.
	@param value number | boolean -- Value to set.
]=]
function UdpServer.setSocketOption(self: UdpServer, level: number, option: number, value: number | boolean)
	self.socket:setSockOpt(level, option, value)
end

--[=[
	Reads a socket option from the underlying UDP socket.

	@param level number -- Protocol level such as `SOL_SOCKET`.
	@param option number -- Option constant to query.
	@return number -- Current option value.
]=]
function UdpServer.getSocketOption(self: UdpServer, level: number, option: number): number
	return self.socket:getSockOpt(level, option)
end

--[=[
	Returns the local address and port of the bound UDP socket.

	@return string -- Local host.
	@return number -- Local port.
]=]
function UdpServer.getSockName(self: UdpServer): (string, number)
	return self.socket:getSockName()
end

--[=[
	Stops the background receive loop, if any, and closes the UDP socket.
]=]
function UdpServer.stopListening(self: UdpServer)
	self._listening = false
	self.socket:close()
end

UdpServer.close = UdpServer.stopListening

net.TcpClient = TcpClient
net.TcpClientNonBlocking = TcpClientNonBlocking
net.TcpServer = TcpServer
net.UdpClient = UdpClient
net.UdpServer = UdpServer

return table.freeze(net)
