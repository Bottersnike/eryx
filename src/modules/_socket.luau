--[=[
	Low-level BSD socket API for Luau.

	This module exposes the platform's native socket interface, providing
	TCP and UDP networking with non-blocking I/O support. All data transfer
	uses Luau `buffer` objects for zero-copy efficiency.

	:::caution
	This is a **low-level** API. For HTTP, prefer using `@eryx/http`,
    which handle framing, TLS, and connection management automatically.
	:::

	```luau
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:Connect("127.0.0.1", 8080)
	sock:SendAll(buffer.fromstring("GET / HTTP/1.0\r\n\r\n"))
	local data = sock:Recv(4096)
	print(buffer.tostring(data))
	sock:Close()
	```
]=]

export type Socket = {
	--[=[
		Binds the socket to a local address and port.

		Must be called before [[Socket.listen]] for server sockets. Use host
		`"0.0.0.0"` or `""` to bind to all interfaces.

		@param host The local address to bind to.
		@param port The port number to bind to.
	]=]
	Bind: (self: Socket, host: string, port: number) -> (),

	--[=[
		Starts listening for incoming connections.

		The socket must have been [[Socket.bind|bound]] first. After calling
		this, use [[Socket.accept]] to accept individual connections.

		@param backlog Maximum number of queued connections.  Defaults to
			a system-defined value (usually 128) when omitted.
	]=]
	Listen: (self: Socket, backlog: number?) -> (),

	--[=[
		Accepts an incoming connection, returning a new socket for
		the client along with the remote address and port.

		:::caution
		This call **blocks** the current thread until a connection arrives
		(unless the socket is set to non-blocking mode via
		[[Socket.setblocking]]).
		:::

		A nil return value indicates a non-blocking operation that would
		have blocked.

		@return Socket -- A new socket connected to the client.
		@return string -- The remote IP address.
		@return number -- The remote port.
	]=]
	Accept: (self: Socket) -> (Socket, string, number) | (self: Socket) -> (nil, nil, nil),

	--[=[
		Opens a connection to a remote host.

		For TCP sockets this performs the full three-way handshake. In
		non-blocking mode the call may return before the connection is
		fully established.

		@param host The remote address to connect to.
		@param port The remote port number.
	]=]
	Connect: (self: Socket, host: string, port: number) -> (),

	--[=[
		Closes the socket, releasing all associated OS resources.

		After closing, no further operations may be performed on this socket.
		It is safe to call `close` multiple times.
	]=]
	Close: (self: Socket) -> (),

	--[=[
		Shuts down one or both halves of the connection without closing the
		socket descriptor.

		Use `SHUT_RD` (0) to stop reads, `SHUT_WR` (1) to stop writes,
		or `SHUT_RDWR` (2) to stop both.

		@param how The shutdown mode - one of `SHUT_RD`, `SHUT_WR`, or `SHUT_RDWR`.
	]=]
	Shutdown: (self: Socket, how: number) -> (),

	--[=[
		Sends data over the socket. Returns the number of bytes actually
		sent, which may be less than the full buffer length.

		For guaranteed delivery of the entire buffer, use [[Socket.sendall]]
		instead.

		A nil return value indicates a non-blocking operation that would
		have blocked.

		@param data The data to send.
		@return number -- Number of bytes sent.
	]=]
	Send: (self: Socket, data: buffer) -> number?,

	--[=[
		Sends all data in the buffer, retrying internally until every byte
		has been transmitted or an error occurs.

		In blocking operation, this function always returns `true`.

		In non-blocking operation, this function returns `false` is the
		operation would have blocked.

		@param data The data to send.
	]=]
	SendAll: (self: Socket, data: buffer) -> boolean,

	--[=[
		Sends data to a specific destination address (UDP).

		Primarily used with `SOCK_DGRAM` sockets. Returns the number of
		bytes actually sent.

		A nil return value indicates a non-blocking operation that would
		have blocked.

		@param data The datagram payload to send.
		@param host The destination address.
		@param port The destination port.
		@return number -- Number of bytes sent.
	]=]
	SendTo: (self: Socket, data: buffer, host: string, port: number) -> number?,

	--[=[
		Receives up to `bufsize` bytes from the socket.

		Returns a buffer containing the received data, which may be shorter
		than `bufsize`. An empty buffer (length 0) typically indicates the
		remote end has closed the connection.

		A nil return value indicates a non-blocking operation that would
		have blocked.

		@param bufsize Maximum number of bytes to receive.
		@return buffer -- The received data.
	]=]
	Recv: (self: Socket, bufsize: number) -> buffer?,

	--[=[
		Receives a datagram of up to `bufsize` bytes along with the
		sender's address (UDP).

		A nil return value indicates a non-blocking operation that would
		have blocked.

		@param bufsize Maximum number of bytes to receive.
		@return buffer -- The received datagram.
		@return string -- The sender's IP address.
		@return number -- The sender's port.
	]=]
	RecvFrom: (self: Socket, bufsize: number) -> (buffer, string, number)
		| (self: Socket, bufsize: number) -> (nil, nil, nil),

	--[=[
		Sets a socket option.

		Common combinations:
		- `SOL_SOCKET, SO_REUSEADDR, true` - allow port reuse
		- `SOL_SOCKET, SO_KEEPALIVE, true` - enable keep-alive
		- `IPPROTO_TCP, TCP_NODELAY, true` - disable Nagle's algorithm

		@param level The protocol level (e.g. `SOL_SOCKET`, `IPPROTO_TCP`).
		@param optname The option identifier.
		@param value The value to set - a number or boolean depending on the option.
	]=]
	SetSockOpt: (self: Socket, level: number, optname: number, value: number | boolean) -> (),

	--[=[
		Gets the current value of a socket option.

		@param level The protocol level (e.g. `SOL_SOCKET`, `IPPROTO_TCP`).
		@param optname The option identifier.
		@return number -- The current option value.
	]=]
	GetSockOpt: (self: Socket, level: number, optname: number) -> number,

	--[=[
		Switches the socket between blocking and non-blocking mode.

		In non-blocking mode, operations like [[Socket.recv]] and
		[[Socket.send]] will raise an error instead of waiting when no
		data is available.

		@param flag `true` for blocking, `false` for non-blocking.
	]=]
	SetBlocking: (self: Socket, flag: boolean) -> (),

	--[=[
		Sets a timeout (in seconds) for blocking socket operations.

		Pass `nil` or `0` to disable the timeout (wait indefinitely).

		@param seconds Timeout duration, or `nil` for no timeout.
	]=]
	SetTimeout: (self: Socket, seconds: number?) -> (),

	--[=[
		Returns the remote address and port of the connected peer.

		@return string -- The remote IP address.
		@return number -- The remote port.
	]=]
	GetPeerName: (self: Socket) -> (string, number),

	--[=[
		Returns the local address and port the socket is bound to.

		@return string -- The local IP address.
		@return number -- The local port.
	]=]
	GetSockName: (self: Socket) -> (string, number),

	--[=[
		Returns the underlying OS file descriptor / handle number for
		this socket. Useful for advanced I/O multiplexing.

		@return number -- The file descriptor.
	]=]
	FileNo: (self: Socket) -> number,
}

--[=[
	Result record from [[getaddrinfo]], representing a single resolved
	address with its protocol metadata.
]=]
export type AddrInfo = {
	family: number,
	type: number,
	proto: number,
	canonname: string,
	addr: string,
	port: number,
}

local _socket = {}

--[=[
	Drives the async I/O scheduler.

	Call this **once per frame**, before [[task.step]], to resume any
	coroutines that are waiting on socket I/O (recv, send, accept, connect).

	```luau
	while running do
		_socket.poll()
		task.step()
	end
	```

	@param timeout How long to wait for I/O readiness, in seconds.
		`0` (default) returns immediately if nothing is ready.
		`-1` blocks until at least one fd is ready.
	@return number -- Number of coroutines that were resumed this call.
]=]
function _socket.poll(timeout: number?): number
	return 0
end

--[=[
	Creates a new socket.

	```luau
	local tcp = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	local udp = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
	```

	@param family Address family - `AF_INET` (IPv4) or `AF_INET6` (IPv6).
	@param type Socket type - `SOCK_STREAM` (TCP) or `SOCK_DGRAM` (UDP).
	@param proto Protocol number, or `nil` to auto-select (usually 0).
	@return Socket -- The newly created socket.
]=]
function _socket.socket(family: number, type: number, proto: number?): Socket
	return nil :: any
end

--[=[
	Resolves a host/service pair into a list of address records suitable
	for creating and connecting sockets.

	```luau
	local results = _socket.getaddrinfo("example.com", 443, _socket.AF_INET, _socket.SOCK_STREAM)
	for _, info in results do
		print(info.addr, info.port)
	end
	```

	@param host Hostname or numeric address, or `nil` for the wildcard address.
	@param service Service name (e.g. `"http"`) or port number.
	@param family Desired address family, or `AF_UNSPEC` to allow any.
	@param type Desired socket type (e.g. `SOCK_STREAM`), or `nil` for any.
	@param proto Desired protocol, or `nil` for any.
	@param flags Bitwise OR of `AI_*` flags (e.g. `AI_PASSIVE`).
	@return {AddrInfo} -- An array of resolved address records.
]=]
function _socket.getAddrInfo(
	host: string?,
	service: (string | number)?,
	family: number?,
	type: number?,
	proto: number?,
	flags: number?
): { AddrInfo }
	return nil :: any
end

--[=[
	Reverse-resolves a numeric address and port into a hostname and
	service name.

	@param host The numeric IP address to look up.
	@param port The port number.
	@param flags Bitwise OR of `NI_*` flags to control name resolution.
	@return string -- The resolved hostname.
	@return string -- The resolved service name.
]=]
function _socket.getNameInfo(host: string, port: number, flags: number?): (string, string)
	return nil :: any
end

--- Converts a 16-bit value from host byte order to network byte order.
function _socket.htons(x: number): number
	return 0
end
--- Converts a 16-bit value from network byte order to host byte order.
function _socket.ntohs(x: number): number
	return 0
end
--- Converts a 32-bit value from host byte order to network byte order.
function _socket.htonl(x: number): number
	return 0
end
--- Converts a 32-bit value from network byte order to host byte order.
function _socket.ntohl(x: number): number
	return 0
end

--- Address families
_socket.AF_UNSPEC = 0 :: number
_socket.AF_INET = 2 :: number
_socket.AF_INET6 = 23 :: number

--- Socket types
_socket.SOCK_STREAM = 1 :: number
_socket.SOCK_DGRAM = 2 :: number
_socket.SOCK_RAW = 3 :: number

--- Protocols
_socket.IPPROTO_TCP = 6 :: number
_socket.IPPROTO_UDP = 17 :: number

--- Socket option levels
_socket.SOL_SOCKET = 65535 :: number
_socket.IPPROTO_IP = 0 :: number
_socket.IPPROTO_IPV6 = 41 :: number

--- Socket options
_socket.SO_REUSEADDR = 4 :: number
_socket.SO_BROADCAST = 32 :: number
_socket.SO_KEEPALIVE = 8 :: number
_socket.SO_RCVBUF = 4098 :: number
_socket.SO_SNDBUF = 4097 :: number
_socket.SO_RCVTIMEO = 4102 :: number
_socket.SO_SNDTIMEO = 4101 :: number
_socket.SO_ERROR = 4103 :: number
_socket.SO_LINGER = 128 :: number

--- TCP options
_socket.TCP_NODELAY = 1 :: number

--- IPv6 options
_socket.IPV6_V6ONLY = 27 :: number

--- Shutdown modes
_socket.SHUT_RD = 0 :: number
_socket.SHUT_WR = 1 :: number
_socket.SHUT_RDWR = 2 :: number

--- getaddrinfo flags
_socket.AI_PASSIVE = 1 :: number
_socket.AI_CANONNAME = 2 :: number
_socket.AI_NUMERICHOST = 4 :: number

--- getnameinfo flags
_socket.NI_NUMERICHOST = 1 :: number
_socket.NI_NUMERICSERV = 2 :: number
_socket.NI_DGRAM = 16 :: number

return _socket
