local _socket = require("@eryx/_socket")
local HttpConnection = require("./HttpConnection")
local HttpServer = require("./HttpServer")
local ServerResponse = require("./ServerResponse")
local Session = require("./Session")
local gzip = require("@eryx/compression/gzip")
local json = require("@eryx/data/json")
local multipart = require("./multipart")
local request = require("./request")
local task = require("@eryx/task")
local test = require("@eryx/test")

local suite = test.Suite.new("http request")

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function withServer(
	handler: (
		server: HttpServer.HttpServer,
		req: HttpServer.ServerRequest,
		res: ServerResponse.ServerResponse
	) -> (),
	run: (url: string) -> (),
	options: { [string]: any }?
)
	local port = reservePort()
	local server: HttpServer.HttpServer
	local serverOptions = options and table.clone(options) or ({} :: { [string]: any })
	serverOptions.host = "127.0.0.1"
	serverOptions.port = port
	serverOptions.clientTimeout = 1
	server = HttpServer.new(function(req: HttpServer.ServerRequest, res: ServerResponse.ServerResponse)
		handler(server, req, res)
	end, serverOptions)

	task.spawn(function()
		server:listen()
	end)
	task.wait(0.05)

	local ok, err = pcall(run, `http://127.0.0.1:{port}`)
	server:close()
	task.wait(0.05)
	if not ok then
		error(err)
	end
end

suite:test("request: json option sends JSON bodies and decodes JSON responses", function()
	local receivedBody: string? = nil
	local receivedContentType = nil

	withServer(function(server, req, res)
		receivedBody = req.body
		receivedContentType = req.headers["content-type"]
		res:send(200, json.encode({ ok = true }), {
			["Content-Type"] = "application/json",
		})
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.post(url .. "/json", nil, {
			json = {
				name = "Alice",
			},
		})

		local decoded = request.decodeJsonBody(request.raiseForStatus(response))
		test.expect(decoded.ok):toBeTrue()
	end)

	assert(receivedBody)

	test.expect(receivedContentType):toBe("application/json")
	test.expect(json.decode(receivedBody).name):toBe("Alice")
end)

suite:test("request: multipart option sends multipart bodies and decodes multipart responses", function()
	local receivedMultipart = nil

	withServer(function(server, req, res)
		receivedMultipart = req.multipart
		local responseBody, contentType = multipart.encodeFields({
			{ name = "status", value = "ok" },
			{ name = "artifact", value = "DATA", filename = "report.txt", contentType = "text/plain" },
		})
		res:send(200, responseBody, {
			["Content-Type"] = contentType,
		})
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.post(url .. "/upload", nil, {
			multipart = {
				{ name = "username", value = "alice" },
				{ name = "avatar", value = "PNGDATA", filename = "pic.png", contentType = "image/png" },
			},
		})

		local decoded = request.decodeMultipartBody(request.raiseForStatus(response))
		test.expect(#decoded):toBe(2)
		test.expect(decoded[1].name):toBe("status")
		test.expect(decoded[2].filename):toBe("report.txt")
	end)

	assert(receivedMultipart)
	test.expect(#(receivedMultipart :: { any })):toBe(2)
	test.expect((receivedMultipart :: { any })[1].name):toBe("username")
	test.expect((receivedMultipart :: { any })[2].filename):toBe("pic.png")
end)

suite:test("request: redirects rewritten to GET do not keep stale body headers", function()
	local finalMethod = nil
	local finalBody = nil
	local finalContentLength = nil
	local finalContentType = nil

	withServer(function(server, req, res)
		if req.pathname == "/redirect" then
			res:send(302, "", {
				["Location"] = "/final",
			})
			return
		end

		finalMethod = req.method
		finalBody = req.body
		finalContentLength = req.headers["content-length"]
		finalContentType = req.headers["content-type"]
		res:send(200, "done")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.post(url .. "/redirect", nil, {
			json = {
				ok = true,
			},
		})
		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("done")
	end)

	test.expect(finalMethod):toBe("GET")
	test.expect(finalBody):toBe("")
	test.expect(finalContentLength):toBeNil()
	test.expect(finalContentType):toBeNil()
end)

suite:test("raiseForStatus: errors on HTTP failures", function()
	withServer(function(server, _req, res)
		res:send(500, "boom")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.get(url .. "/fail")
		test.expect(function()
			request.raiseForStatus(response)
		end):toError("HTTP request failed with 500")
	end)
end)

suite:test("request: HEAD responses are returned without reading a body", function()
	withServer(function(server, req, res)
		test.expect(req.method):toBe("HEAD")
		res:header("Content-Length", "4")
		res:finish("body")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.head(url .. "/head")
		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("")
	end)
end)

suite:test("request: expectContinue waits for 100 Continue before sending body", function()
	local receivedBody = nil
	local receivedExpect = nil

	withServer(function(server, req, res)
		receivedBody = req.body
		receivedExpect = req.headers["expect"]
		res:send(200, "ok")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.post(url .. "/continue", nil, {
			json = { message = "hello" },
			expectContinue = true,
		})

		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("ok")
	end)

	assert(receivedBody)
	test.expect(receivedExpect):toBe("100-continue")
	test.expect(json.decode(receivedBody).message):toBe("hello")
end)

suite:test("HttpConnection: keeps a connection alive across multiple requests", function()
	local seen = 0

	withServer(function(server, _req, res)
		seen += 1
		res:send(200, tostring(seen))
		if seen >= 2 then
			task.defer(function()
				server:close()
			end)
		end
	end, function(url)
		local port = tonumber(string.match(url, ":(%d+)$")) :: number
		local conn = HttpConnection.new("127.0.0.1", port)
		conn:request("GET", "/one")
		local first = conn:getResponse()
		conn:request("GET", "/two")
		local second = conn:getResponse()
		conn:close()

		test.expect(first.body):toBe("1")
		test.expect(second.body):toBe("2")
	end)
end)

suite:test("request: one-shot helpers still request connection close", function()
	local receivedConnection = nil

	withServer(function(server, req, res)
		receivedConnection = req.headers["connection"]
		res:send(200, "ok")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.get(url .. "/close")
		test.expect(response.status):toBe(200)
	end)

	test.expect(receivedConnection):toBe("close")
end)

suite:test("request: bodyStream uploads fixed-length request bodies", function()
	local receivedBody = nil
	local receivedContentLength = nil

	withServer(function(server, req, res)
		receivedBody = req.body
		receivedContentLength = req.headers["content-length"]
		res:send(200, "ok")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local index = 0
		local chunks = { "hello ", "world" }
		local response = request.request("POST", url .. "/upload", {
			bodyStream = {
				read = function(self, _size)
					index += 1
					return chunks[index] or ""
				end,
			},
			bodyLength = 11,
		})

		test.expect(response.status):toBe(200)
	end)

	test.expect(receivedBody):toBe("hello world")
	test.expect(receivedContentLength):toBe("11")
end)

suite:test("request: bodyStream uploads chunked request bodies when length is unknown", function()
	local receivedBody = nil
	local receivedTransferEncoding = nil

	withServer(function(server, req, res)
		receivedBody = req.body
		receivedTransferEncoding = req.headers["transfer-encoding"]
		res:send(200, "ok")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local index = 0
		local chunks = { "stream", "ed", " body" }
		local response = request.request("POST", url .. "/upload", {
			bodyStream = {
				read = function(self, _size)
					index += 1
					return chunks[index] or ""
				end,
			},
		})

		test.expect(response.status):toBe(200)
	end)

	test.expect(receivedBody):toBe("streamed body")
	test.expect(receivedTransferEncoding):toBe("chunked")
end)

suite:test("HttpServer: handlers can read request bodies incrementally", function()
	local firstChunk = nil
	local remaining = nil

	withServer(function(server, req, res)
		local stream = req.bodyStream :: any
		firstChunk = stream:read(5)
		remaining = stream:readAll()
		res:send(200, "ok")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local _chunks = { "hello ", "world" }
		local _index = 0
		local response = request.request("POST", url .. "/stream-in", {
			bodyStream = {
				read = function(self, _size)
					_index += 1
					return _chunks[_index] or ""
				end,
			} :: any,
			bodyLength = 11,
		})

		test.expect(response.status):toBe(200)
	end, {
		streamRequestBodies = true,
	})

	test.expect(firstChunk):toBe("hello")
	test.expect(remaining):toBe(" world")
end)

suite:test("request.stream: incrementally decompresses gzip responses", function()
	withServer(function(server, _req, res)
		local body = buffer.tostring(gzip.compress(buffer.fromstring("hello zipped world")))
		res:send(200, body, {
			["Content-Encoding"] = "gzip",
			["Content-Length"] = tostring(#body),
		})
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.stream("GET", url .. "/gzip")
		test.expect(response.headers["content-encoding"]):toBeNil()
		test.expect(response.headers["content-length"]):toBeNil()
		test.expect(response:read(5)):toBe("hello")
		test.expect(response:readAll()):toBe(" zipped world")
	end)
end)

suite:test("request.stream: reads chunked responses incrementally", function()
	withServer(function(server, _req, res)
		res:holdOpen()
		res:status(200)
		res:write("hello")
		task.delay(0.02, function()
			res:finish(" world")
			server:close()
		end)
	end, function(url)
		local response = request.stream("GET", url .. "/stream")
		test.expect(response.status):toBe(200)
		test.expect(response:read(5)):toBe("hello")
		test.expect(response:readAll()):toBe(" world")
	end)
end)

suite:test("ServerResponse: sendStream streams chunked bodies and exposes trailers to clients", function()
	withServer(function(server, _req, res)
		local index = 0
		local chunks = { "hello", " ", "world" }
		res:status(200)
		res:header("Content-Type", "text/plain")
		res:trailer("X-Checksum", "ok")
		res:sendStream({
			read = function(self, _size)
				index += 1
				return chunks[index] or ""
			end,
		})
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local response = request.get(url .. "/streamed")
		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("hello world")
		test.expect(response.trailers["x-checksum"]):toBe("ok")
	end)
end)

suite:test("ServerResponse: holdOpen supports long-poll style responses", function()
	withServer(function(server, _req, res)
		res:holdOpen()
		task.delay(0.05, function()
			res:send(200, "delayed")
			server:close()
		end)
	end, function(url)
		local response = request.get(url .. "/poll")
		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("delayed")
	end)
end)

suite:test("Session: reuses connections across requests", function()
	local remotePorts = {}

	withServer(function(server, req, res)
		table.insert(remotePorts, req.remotePort)
		res:send(200, "ok")
		if #remotePorts >= 2 then
			task.defer(function()
				server:close()
			end)
		end
	end, function(url)
		local session = Session.new()
		local first = session:get(url .. "/one")
		local second = session:get(url .. "/two")
		session:close()

		test.expect(first.status):toBe(200)
		test.expect(second.status):toBe(200)
	end)

	test.expect(#remotePorts):toBe(2)
	test.expect(remotePorts[1]):toBe(remotePorts[2])
end)

suite:test("Session: retries safe requests when a pooled keep-alive connection has gone stale", function()
	local session = Session.new()
	local deadConn = {
		closed = false,
		request = function(self, ...)
			error("Connection closed before receiving HTTP response")
		end,
		close = function(self)
			self.closed = true
		end,
	}
	local freshConn = {
		request = function(self, ...) end,
		getResponse = function(self)
			return {
				status = 200,
				reason = "OK",
				headers = {},
				trailers = {},
				body = "recovered",
				httpVersion = "HTTP/1.1",
			}
		end,
		close = function(self) end,
	}

	local calls = 0
	session._pool["http://example.com:80"] = {
		{
			conn = deadConn :: any,
			lastUsed = 0,
		},
	}
	session._getConnection = function(self, parsedUrl, timeout, verifySsl)
		calls += 1
		if calls == 1 then
			return deadConn :: any
		end
		return freshConn :: any
	end

	local response = session:get("http://example.com/")
	test.expect(response.status):toBe(200)
	test.expect(response.body):toBe("recovered")
	test.expect((deadConn :: any).closed):toBeTrue()
	test.expect(calls):toBe(2)
end)

suite:test("Session: opens a second pooled connection when another streamed response is still active", function()
	local remotePorts = {}

	withServer(function(server, req, res)
		table.insert(remotePorts, req.remotePort)
		if req.pathname == "/one" then
			res:holdOpen()
			res:status(200)
			res:write("busy")
			task.delay(0.05, function()
				res:finish(" stream")
			end)
			return
		end

		res:send(200, "fresh")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local session = Session.new({
			maxConnectionsPerHost = 2,
		})
		local first = session:stream("GET", url .. "/one")
		local second = session:get(url .. "/two")
		first:close()
		session:close()

		test.expect(second.body):toBe("fresh")
	end)

	test.expect(#remotePorts):toBe(2)
	test.expect(remotePorts[1] == remotePorts[2]):toBeFalse()
end)

suite:test("Session: errors when all pooled connections for a host are busy and the limit is reached", function()
	withServer(function(server, req, res)
		if req.pathname == "/one" then
			res:holdOpen()
			res:status(200)
			res:write("busy")
			task.delay(0.05, function()
				res:finish(" stream")
				server:close()
			end)
			return
		end

		res:send(200, "fresh")
	end, function(url)
		local session = Session.new({
			maxConnectionsPerHost = 1,
		})
		local first = session:stream("GET", url .. "/one")
		test.expect(function()
			session:get(url .. "/two")
		end):toError("No available pooled HTTP connections")
		first:close()
		session:close()
	end)
end)

suite:test("Session: evict removes pooled connections for a specific origin", function()
	local session = Session.new()
	local closed = false
	session._pool["http://example.com:80"] = {
		{
			conn = {
				close = function(self)
					closed = true
				end,
			} :: any,
			lastUsed = 0,
		},
	}

	session:evict("http://example.com/path")
	test.expect(closed):toBeTrue()
	test.expect(session._pool["http://example.com:80"]):toBeNil()
end)

suite:test("Session: reused pooled connections adopt the current request timeouts", function()
	local session = Session.new()
	local appliedTimeouts = nil
	local conn = {
		_activeResponseStream = nil,
		setTimeouts = function(self, timeouts)
			appliedTimeouts = timeouts
		end,
		close = function(self) end,
	}

	session._pool["http://example.com:80"] = {
		{
			conn = conn :: any,
			lastUsed = 0,
		},
	}

	local reused = session:_getConnection({
		scheme = "http",
		host = "example.com",
		port = 80,
	}, {
		connect = 1,
		read = 2,
		write = 3,
	}, nil)

	test.expect(reused):toBe(conn)
	test.expect((appliedTimeouts :: any).connect):toBe(1)
	test.expect((appliedTimeouts :: any).read):toBe(2)
	test.expect((appliedTimeouts :: any).write):toBe(3)
end)

suite:test("Session: streamed responses can be closed early and reused", function()
	local remotePorts = {}

	withServer(function(server, req, res)
		table.insert(remotePorts, req.remotePort)
		if req.pathname == "/one" then
			res:send(200, "abcdef")
			return
		end

		res:send(200, "done")
		task.defer(function()
			server:close()
		end)
	end, function(url)
		local session = Session.new()
		local stream = session:stream("GET", url .. "/one")
		test.expect(stream:read(2)):toBe("ab")
		stream:close()

		local second = session:get(url .. "/two")
		session:close()
		test.expect(second.body):toBe("done")
	end)

	test.expect(#remotePorts):toBe(2)
	test.expect(remotePorts[1]):toBe(remotePorts[2])
end)

suite:test("Session: close closes pooled connections", function()
	local port = reservePort()
	local session = Session.new()
	local conn = session:_getConnection({
		scheme = "http",
		host = "127.0.0.1",
		port = port,
		path = "/",
	}, nil, nil)

	test.expect(conn._sock):toBeNil()
	session:close()
	test.expect(next(session._pool)):toBeNil()
end)

return suite
