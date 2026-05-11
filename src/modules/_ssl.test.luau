local fs = require("@eryx/fs")
local path = require("@eryx/path")
local task = require("@eryx/task")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")
local _socket = require("@eryx/_socket")

local sslOk, sslOrErr = pcall(require, "@eryx/_ssl")
local ssl = if sslOk then sslOrErr else nil

local suite = test.Suite.new("_ssl")

local function requireSsl()
	if ssl == nil then
		test.skip(`TLS backend unavailable: {tostring(sslOrErr)}`)
	end
	return ssl :: any
end

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function makeFixture(isCa: boolean?): { key: string, cert: string, parsed: any }
	local _ssl = requireSsl()
	local key = _ssl.generateKey("rsa", 2048)
	local cert = _ssl.generateSelfSignedCert({
		key = key,
		subject = "CN=localhost,O=Eryx TLS Test",
		days = 30,
		san = { "localhost", "127.0.0.1" },
		isCa = isCa,
	})
	local parsed = _ssl.parseCertificate(cert)
	return { key = key, cert = cert, parsed = parsed }
end

suite:test("generateKey returns PEM for rsa and ec keys", function()
	local _ssl = requireSsl()

	local rsaKey = _ssl.generateKey("rsa", 2048)
	local ecKey = _ssl.generateKey("ec")

	test.expect(rsaKey):toContain("BEGIN PRIVATE KEY")
	test.expect(ecKey):toContain("BEGIN PRIVATE KEY")
	test.expect(rsaKey == ecKey):toBeFalse()
end)

suite:test("generateSelfSignedCert honors isCa and parseCertificate uses camelCase fields", function()
	local fixture = makeFixture(true)
	local parsed = fixture.parsed

	test.expect(parsed.subject):toContain("CN=localhost")
	test.expect(parsed.issuer):toContain("CN=localhost")
	test.expect(parsed.validFrom):toBeType("string")
	test.expect(parsed.validTo):toBeType("string")
	test.expect(parsed.serial):toMatch("^[0-9A-F:]+$")
	test.expect(parsed.version):toBe(3)
	test.expect(parsed.info):toContain("CA:TRUE")
	test.expect(parsed.info):toContain("DNS:localhost")
	test.expect(parsed.info):toContain("127.0.0.1")
end)

suite:test("createServerContextPem accepts generated certificate material", function()
	local _ssl = requireSsl()
	local fixture = makeFixture(false)

	local ctx = _ssl.createServerContextPem(fixture.cert, fixture.key)
	test.expect(ctx):toNotBeNil()
	test.expect(tostring(ctx)):toContain("SSLContext(server")
end)

suite:test("createServerContext loads certificate material from files", function()
	local _ssl = requireSsl()
	local fixture = makeFixture(false)

	tempfile.withTempDir(function(dir)
		local certPath = path.join(dir, "server-cert.pem")
		local keyPath = path.join(dir, "server-key.pem")

		local certFile = fs.openSync(certPath, "w")
		certFile:writeSync(fixture.cert)
		certFile:close()

		local keyFile = fs.openSync(keyPath, "w")
		keyFile:writeSync(fixture.key)
		keyFile:close()

		local ctx = _ssl.createServerContext(certPath, keyPath)
		test.expect(ctx):toNotBeNil()
		test.expect(tostring(ctx)):toContain("SSLContext(server")
	end)
end)

suite:test("setVerify rejects unsupported values", function()
	local _ssl = requireSsl()
	local ctx = _ssl.createDefaultContext()

	test.expect(function()
		ctx:setVerify(1)
	end):toError("invalid verify mode")
end)

suite:test("verified client wrap requires a hostname", function()
	local _ssl = requireSsl()
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	local ctx = _ssl.createDefaultContext()

	test.expect(function()
		ctx:wrapSocket(sock)
	end):toError("require serverHostname")

	sock:close()
end)

suite:test("client and server contexts can complete a local TLS round-trip", function()
	local _ssl = requireSsl()
	local fixture = makeFixture(true)
	local port = reservePort()
	local requestSeen = false

	tempfile.withTempDir(function(dir)
		local caPath = path.join(dir, "ca.pem")
		local caFile = fs.openSync(caPath, "w")
		caFile:writeSync(fixture.cert)
		caFile:close()

		local serverCtx = _ssl.createServerContextPem(fixture.cert, fixture.key)

		task.spawn(function()
			local listener = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
			listener:setSockOpt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, true)
			listener:bind("127.0.0.1", port)
			listener:listen(1)

			local clientSock = select(1, listener:accept())
			local tlsSock = serverCtx:wrapSocket(clientSock)

			local received = buffer.tostring(tlsSock:recv(1024))
			test.expect(received):toBe("ping over tls")
			requestSeen = true

			tlsSock:sendAll("pong over tls")
			tlsSock:close()
			listener:close()
		end)

		task.wait(0.05)

		local clientSock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
		clientSock:connect("127.0.0.1", port)

		local clientCtx = _ssl.createDefaultContext()
		clientCtx:loadVerifyLocations(caPath)
		local tlsSock = clientCtx:wrapSocket(clientSock, "localhost")

		test.expect(tlsSock.closed):toBeFalse()
		tlsSock:sendAll("ping over tls")
		local response = buffer.tostring(tlsSock:recv(1024))

		test.expect(response):toBe("pong over tls")
		test.expect(requestSeen):toBeTrue()

		tlsSock:close()
		test.expect(tlsSock.closed):toBeTrue()
	end)
end)

return suite
