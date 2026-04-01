local HttpServer = require("./HttpServer")
local multipart = require("./multipart")
local test = require("@eryx/test")

local suite = test.Suite.new("http server")

local function makeFakeSocket(chunks: { string })
	local index = 0
	return {
		recv = function(self, _size: number)
			index += 1
			local chunk = chunks[index]
			if chunk == nil then
				return buffer.fromstring("")
			end
			return buffer.fromstring(chunk)
		end,
	}
end

suite:test("readRequest: parses query strings and urlencoded forms", function()
	local server = HttpServer.new(function() end)
	local sock = makeFakeSocket({
		"POST /submit?tag=a&tag=b HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 17\r\n\r\nname=Jane+Doe&x=1",
	})

	local request = server:_readRequest(sock, "127.0.0.1", 1234)
	test.expect(request):toNotBeNil()
	test.expect((request :: HttpServer.ServerRequest).pathname):toBe("/submit")
	test.expect((request :: HttpServer.ServerRequest).query.tag[1]):toBe("a")
	test.expect((request :: HttpServer.ServerRequest).query.tag[2]):toBe("b")
	test.expect((request :: HttpServer.ServerRequest).form.name):toBe("Jane Doe")
	test.expect((request :: HttpServer.ServerRequest).form.x):toBe("1")
end)

suite:test("readRequest: parses multipart form-data bodies", function()
	local body, contentType = multipart.encodeFields({
		{ name = "username", value = "alice" },
		{ name = "avatar", value = "PNGDATA", filename = "pic.png", contentType = "image/png" },
	})
	local requestHead = table.concat({
		"POST /upload HTTP/1.1\r\n",
		"Host: example.com\r\n",
		"Content-Type: ",
		contentType,
		"\r\n",
		"Content-Length: ",
		tostring(#body),
		"\r\n",
		"\r\n",
	})
	local server = HttpServer.new(function() end)
	local sock = makeFakeSocket({ requestHead .. body })

	local request = server:_readRequest(sock, "127.0.0.1", 4321)
	test.expect(request):toNotBeNil()
	test.expect(#((request :: HttpServer.ServerRequest).multipart :: { any })):toBe(2)
	test.expect(((request :: HttpServer.ServerRequest).multipart :: { any })[1].name):toBe("username")
	test.expect(((request :: HttpServer.ServerRequest).multipart :: { any })[2].filename):toBe("pic.png")
end)

suite:test("readRequest: parses chunked request bodies", function()
	local server = HttpServer.new(function() end)
	local sock = makeFakeSocket({
		"POST /chunked HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Body-Hash: done\r\n\r\n",
	})

	local request = server:_readRequest(sock, "127.0.0.1", 5555)
	test.expect(request):toNotBeNil()
	test.expect((request :: HttpServer.ServerRequest).body):toBe("Wikipedia")
	test.expect((request :: HttpServer.ServerRequest).trailers["x-body-hash"]):toBe("done")
end)

suite:test("readRequest: exposes fixed-length bodies as a stream", function()
	local server = HttpServer.new(function() end, {
		streamRequestBodies = true,
	})
	local sock = makeFakeSocket({
		"POST /stream HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello worldGET /next HTTP/1.1\r\nHost: example.com\r\n\r\n",
	})

	local request, buffered = server:_readRequest(sock, "127.0.0.1", 2222)
	test.expect(request):toNotBeNil()
	test.expect(buffered):toBe("")

	local stream = (request :: HttpServer.ServerRequest).bodyStream
	test.expect(stream):toNotBeNil()
	test.expect((stream :: any):read(5)):toBe("hello")
	test.expect((stream :: any):readAll()):toBe(" world")
end)

suite:test("readRequest: exposes chunked bodies as a stream", function()
	local server = HttpServer.new(function() end, {
		streamRequestBodies = true,
	})
	local sock = makeFakeSocket({
		"POST /chunked HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trace: abc123\r\n\r\nGET /next HTTP/1.1\r\nHost: example.com\r\n\r\n",
	})

	local request, buffered = server:_readRequest(sock, "127.0.0.1", 3333)
	test.expect(request):toNotBeNil()
	test.expect(buffered):toBe("")

	local stream = (request :: HttpServer.ServerRequest).bodyStream
	test.expect(stream):toNotBeNil()
	test.expect((stream :: any):read(4)):toBe("Wiki")
	test.expect((stream :: any):readAll()):toBe("pedia")
	test.expect((request :: HttpServer.ServerRequest).trailers["x-trace"]):toBe("abc123")
end)

suite:test("readRequest: lazily decodes forms from streamed bodies", function()
	local server = HttpServer.new(function() end, {
		streamRequestBodies = true,
	})
	local sock = makeFakeSocket({
		"POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 17\r\n\r\nname=Jane+Doe&x=1",
	})

	local request = server:_readRequest(sock, "127.0.0.1", 1234)
	test.expect(request):toNotBeNil()
	local form = (request :: HttpServer.ServerRequest):readForm()
	test.expect((form :: any).name):toBe("Jane Doe")
	test.expect((request :: HttpServer.ServerRequest):readBody()):toBe("name=Jane+Doe&x=1")
end)

suite:test("readRequest: lazily decodes JSON request bodies", function()
	local server = HttpServer.new(function() end, {
		streamRequestBodies = true,
	})
	local sock = makeFakeSocket({
		'POST /json HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{"name":"emma"}',
	})

	local request = server:_readRequest(sock, "127.0.0.1", 1234)
	test.expect(request):toNotBeNil()
	local decoded = (request :: HttpServer.ServerRequest):readJson()
	test.expect((decoded :: any).name):toBe("emma")
end)

suite:test("readRequest: rejects HTTP/1.1 requests without Host", function()
	local server = HttpServer.new(function() end)
	local sock = makeFakeSocket({
		"GET / HTTP/1.1\r\nUser-Agent: test\r\n\r\n",
	})

	test.expect(function()
		server:_readRequest(sock, "127.0.0.1", 5555)
	end):toError("Missing required Host header")
end)

suite:test("handleConnection: returns 431 for oversized headers", function()
	local server = HttpServer.new(function() end, {
		maxHeaderBytes = 32,
	})
	local sent = {}
	local sock = {
		recv = function(self, _size: number)
			return buffer.fromstring(
				"GET / HTTP/1.1\r\nHost: example.com\r\nX-Large: abcdefghijklmnopqrstuvwxyz\r\n\r\n"
			)
		end,
		setTimeout = function() end,
		sendAll = function(self, data: buffer)
			table.insert(sent, buffer.tostring(data))
			return true
		end,
		close = function() end,
	}

	local upgraded = server:_handleConnection(sock, "127.0.0.1", 5555)
	test.expect(upgraded):toBeFalse()
	test.expect(table.concat(sent)):toContain("431")
end)

suite:test("readRequest: rejects conflicting Content-Length values", function()
	local server = HttpServer.new(function() end)
	local sock = makeFakeSocket({
		"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nbody",
	})

	test.expect(function()
		server:_readRequest(sock, "127.0.0.1", 5555)
	end):toError("Conflicting Content%-Length")
end)

suite:test("handleConnection: returns 417 for unsupported Expect headers", function()
	local server = HttpServer.new(function() end)
	local sent = {}
	local sock = {
		recv = function(self, _size: number)
			return buffer.fromstring(
				"POST / HTTP/1.1\r\nHost: example.com\r\nExpect: something-else\r\nContent-Length: 4\r\n\r\nbody"
			)
		end,
		setTimeout = function() end,
		sendAll = function(self, data: buffer)
			table.insert(sent, buffer.tostring(data))
			return true
		end,
		close = function() end,
	}

	local upgraded = server:_handleConnection(sock, "127.0.0.1", 5555)
	test.expect(upgraded):toBeFalse()
	test.expect(table.concat(sent)):toContain("417")
end)

suite:test("handleConnection: drains unread request streams before reusing keep-alive sockets", function()
	local server: HttpServer.HttpServer
	local seen = {}
	server = HttpServer.new(function(req, res)
		table.insert(seen, req.pathname)
		if req.pathname == "/one" then
			local stream = req.bodyStream :: any
			test.expect(stream:read(3)):toBe("abc")
			res:send(200, "first")
			return
		end

		test.expect(req:readBody()):toBe("")
		res:send(200, "second")
	end, {
		streamRequestBodies = true,
	})

	local sent = {}
	local sock = makeFakeSocket({
		"POST /one HTTP/1.1\r\nHost: example.com\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nabcdefGET /two HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n",
	})
	sock.setTimeout = function() end
	sock.sendAll = function(self, data: buffer)
		table.insert(sent, buffer.tostring(data))
		return true
	end
	sock.close = function() end

	local upgraded = server:_handleConnection(sock, "127.0.0.1", 5555)
	test.expect(upgraded):toBeFalse()
	test.expect(#seen):toBe(2)
	test.expect(seen[1]):toBe("/one")
	test.expect(seen[2]):toBe("/two")
	test.expect(table.concat(sent)):toContain("first")
	test.expect(table.concat(sent)):toContain("second")
end)

return suite
