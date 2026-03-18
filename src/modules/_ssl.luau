--[=[
	TLS/SSL support for Luau, powered by Mbed TLS.

	Provides encrypted communication over sockets using TLS 1.2+. Includes
	both client and server context creation, certificate generation, and
	certificate parsing utilities.

	:::tip
	For most use cases, prefer `@eryx/http` which handles TLS automatically.
	Use `_ssl` directly when you need fine-grained control over TLS
	settings or are building a custom protocol.
	:::

	```luau
	local _socket = require("@eryx/_socket")
	local _ssl    = require("@eryx/_ssl")

	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:Connect("example.com", 443)

	local ctx  = _ssl.createDefaultContext()
	local ssock = ctx:WrapSocket(sock, "example.com")
	ssock:SendAll(buffer.fromstring("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"))
	local data = ssock:Recv(4096)
	print(buffer.tostring(data))
	ssock:Close()
	```
]=]

--[=[
	A TLS context that holds configuration (trusted CAs, verification
	mode) and can wrap raw sockets into encrypted [[SslSocket]] connections.
]=]
export type SslContext = {
	--[=[
		Wraps an existing connected [[_socket.Socket]] into a TLS connection.

		The `SslSocket` takes ownership of the underlying file descriptor.
		For client connections, pass `serverHostname` to enable SNI
		(Server Name Indication) and certificate hostname verification.

		@param sock A connected `_socket.Socket`.
		@param serverHostname Hostname for SNI and certificate verification.
		@return SslSocket -- The wrapped TLS socket.
	]=]
	WrapSocket: (self: SslContext, sock: any, serverHostname: string?) -> SslSocket,

	--[=[
		Loads a PEM-encoded CA certificate file for server certificate
		verification.

		Call this to trust a custom CA instead of (or in addition to) the
		system certificate store.

		@param cafile Path to a PEM file containing one or more CA certificates.
	]=]
	LoadVerifyLocations: (self: SslContext, cafile: string) -> (),

	--[=[
		Sets the certificate verification mode.

		Use `_ssl.VERIFY_REQUIRED` (the default for contexts created with
		[[createDefaultContext]]) to require a valid, trusted server
		certificate. Use `_ssl.VERIFY_NONE` to skip verification
		(not recommended for production).

		@param mode Verification mode - `VERIFY_NONE` or `VERIFY_REQUIRED`.
	]=]
	SetVerify: (self: SslContext, mode: number) -> (),
}

--[=[
	An encrypted socket wrapping an underlying TCP connection.

	Provides the same `send`/`recv`/`close` interface as [[_socket.Socket]],
	but all data is transparently encrypted and decrypted via TLS.
]=]
export type SslSocket = {
	--[=[
		Sends data over the encrypted connection. Returns the number of
		bytes actually written, which may be less than the full buffer.

		@param data The data to send.
		@return number -- Number of bytes sent.
	]=]
	send: (self: SslSocket, data: buffer) -> number,

	--[=[
		Sends all data in the buffer, retrying internally until every byte
		has been transmitted or an error occurs.

		@param data The data to send.
	]=]
	sendall: (self: SslSocket, data: buffer) -> (),

	--[=[
		Receives up to `bufsize` bytes from the encrypted connection.

		Returns a buffer containing the received data. An empty buffer
		(length 0) indicates the remote end has closed the connection.

		@param bufsize Maximum number of bytes to receive.
		@return buffer -- The received data.
	]=]
	recv: (self: SslSocket, bufsize: number) -> buffer,

	--[=[
		Performs a TLS shutdown and closes the underlying socket, releasing
		all associated resources.
	]=]
	close: (self: SslSocket) -> (),

	--[=[
		Returns the remote address and port of the connected peer.

		@return string -- The remote IP address.
		@return number -- The remote port.
	]=]
	getpeername: (self: SslSocket) -> (string, number),

	--[=[
		Returns the local address and port the socket is bound to.

		@return string -- The local IP address.
		@return number -- The local port.
	]=]
	getsockname: (self: SslSocket) -> (string, number),

	--[=[
		Returns the underlying OS file descriptor number for
		the socket. Useful for advanced I/O multiplexing.

		@return number -- The file descriptor.
	]=]
	fileno: (self: SslSocket) -> number,
}

--[=[
	Structured information about an X.509 certificate, as returned by
	[[parseCertificate]].
]=]
export type CertificateInfo = {
	subject: string,
	issuer: string,
	validFrom: string,
	validTo: string,
	serial: string,
	version: number,
	info: string,
}

local _ssl = {}

--[=[
	Creates a new [[SslContext]] with sensible defaults for **client** mode.

	The context is preconfigured with system CA certificates and requires
	TLS 1.2 or later. Server certificate verification is enabled by default.

	```luau
	local ctx = _ssl.createDefaultContext()
	local ssock = ctx:WrapSocket(sock, "example.com")
	```

	@return SslContext -- A client-mode TLS context.
]=]
function _ssl.createDefaultContext(): SslContext
	return nil :: any
end

--[=[
	Creates a new [[SslContext]] configured for **server** mode by loading
	a certificate chain and private key from PEM files on disk.

	@param certfile Path to the PEM certificate chain file.
	@param keyfile Path to the PEM private key file.
	@param password Passphrase for encrypted private keys.
	@return SslContext -- A server-mode TLS context.
]=]
function _ssl.createServerContext(certfile: string, keyfile: string, password: string?): SslContext
	return nil :: any
end

--[=[
	Creates a new [[SslContext]] configured for **server** mode from PEM
	strings rather than files. Useful when certificates are generated
	at runtime or stored in memory.

	@param certPem PEM-encoded certificate chain string.
	@param keyPem PEM-encoded private key string.
	@param password Passphrase for encrypted private keys.
	@return SslContext -- A server-mode TLS context.
]=]
function _ssl.createServerContextPem(certPem: string, keyPem: string, password: string?): SslContext
	return nil :: any
end

--[=[
	Convenience function that creates a default client context and wraps
	a socket in a single call.

	Equivalent to:
	```luau
	local ctx = _ssl.createDefaultContext()
	local ssock = ctx:WrapSocket(sock, hostname)
	```

	@param sock A connected `_socket.Socket`.
	@param hostname Hostname for SNI and certificate verification.
	@return SslSocket -- The wrapped TLS socket.
]=]
function _ssl.wrapSocket(sock: any, hostname: string?): SslSocket
	return nil :: any
end

--[=[
	Generates a new private key and returns it as a PEM string.

	```luau
	local rsa_key = _ssl.generateKey("rsa", 4096)
	local ec_key  = _ssl.generateKey("ec")
	```

	@param type Key type - `"rsa"` (default) or `"ec"` (secp256r1).
	@param bits Key size in bits. Defaults to 2048 for RSA, 256 for EC.
	@return string -- PEM-encoded private key.
]=]
function _ssl.generateKey(type: ("rsa" | "ec")?, bits: number?): string
	return nil :: any
end

--[=[
	Generates a self-signed X.509 certificate and returns it as a PEM string.

	```luau
	local key  = _ssl.generateKey()
	local cert = _ssl.generateSelfSignedCert({
	    key     = key,
	    subject = "CN=localhost,O=Dev",
	    days    = 365,
	    san     = { "localhost", "127.0.0.1" },
	})
	```

	@param options Certificate generation options.
	@return string -- PEM-encoded certificate.
]=]
function _ssl.generateSelfSignedCert(options: {
	key: string,
	subject: string?,
	days: number?,
	san: { string }?,
	isCa: boolean?,
}): string
	return nil :: any
end

--[=[
	Parses a PEM-encoded certificate string and returns structured
	information about it.

	```luau
	local info = _ssl.parseCertificate(certPem)
	print(info.subject, info.validFrom, info.validTo)
	```

	@param pem PEM-encoded certificate string.
	@return CertificateInfo -- Parsed certificate fields.
]=]
function _ssl.parseCertificate(pem: string): CertificateInfo
	return nil :: any
end

--- Verification mode constants
_ssl.VERIFY_NONE     = 0 :: number
_ssl.VERIFY_REQUIRED = 2 :: number

_ssl.SslContext = {} :: SslContext

return _ssl

