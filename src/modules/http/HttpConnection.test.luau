local HttpConnection = require("./HttpConnection")
local test = require("@eryx/test")

local suite = test.Suite.new("http connection")

local function makeFakeSocket(chunks: { string })
	local index = 0
	return {
		sendAll = function(self, _data) end,
		setTimeout = function(self, _timeout) end,
		recv = function(self, _size: number)
			index += 1
			local chunk = chunks[index]
			if chunk == nil then
				return buffer.fromstring("")
			end
			return buffer.fromstring(chunk)
		end,
		close = function() end,
	}
end

local function makeTrackedSocket(chunks: { string })
	local socket = makeFakeSocket(chunks)
	local timeouts = {}
	socket.setTimeout = function(self, timeout)
		table.insert(timeouts, timeout)
	end
	return socket, timeouts
end

suite:test("getResponse: ignores interim 100 Continue responses", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
	})

	local response = conn:getResponse()
	test.expect(response.status):toBe(200)
	test.expect(response.body):toBe("OK")
end)

suite:test("getResponse: HEAD responses never read a body", function()
	local conn = HttpConnection.new("example.com")
	conn._lastRequestMethod = "HEAD"
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: keep-alive\r\n\r\n",
	})

	local response = conn:getResponse()
	test.expect(response.status):toBe(200)
	test.expect(response.body):toBe("")
end)

suite:test("getResponse: chunked responses consume trailer headers fully", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n3\r\nabc\r\n0\r\nX-Trailer: yes\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
	})

	local first = conn:getResponse()
	local second = conn:getResponse()
	test.expect(first.body):toBe("abc")
	test.expect(first.trailers["x-trailer"]):toBe("yes")
	test.expect(second.status):toBe(200)
	test.expect(second.body):toBe("ok")
end)

suite:test("getResponse: rejects conflicting Content-Length values", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\ntest",
	})

	test.expect(function()
		conn:getResponse()
	end):toError("Conflicting Content%-Length")
end)

suite:test("getResponse: rejects Transfer-Encoding with Content-Length", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n",
	})

	test.expect(function()
		conn:getResponse()
	end):toError("Transfer%-Encoding and Content%-Length")
end)

suite:test("getResponseStream: fixed-length responses can be read incrementally and drained", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nabcdefHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
	})

	local stream = conn:getResponseStream()
	test.expect(stream:read(2)):toBe("ab")
	stream:close()

	local response = conn:getResponse()
	test.expect(response.status):toBe(200)
	test.expect(response.body):toBe("ok")
end)

suite:test("getResponseStream: chunked responses can be read incrementally", function()
	local conn = HttpConnection.new("example.com")
	conn._sock = makeFakeSocket({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
	})

	local stream = conn:getResponseStream()
	test.expect(stream:read(2)):toBe("ab")
	test.expect(stream:read(2)):toBe("c")
	test.expect(stream:readAll()):toBe("def")
	test.expect(stream:read(2)):toBe("")

	local response = conn:getResponse()
	test.expect(response.body):toBe("ok")
end)

suite:test("request/getResponse: switches socket timeouts between write and read phases", function()
	local conn = HttpConnection.new("example.com", nil, {
		read = 3,
		write = 7,
	})
	local sock, timeouts = makeTrackedSocket({
		"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
	})
	conn._sock = sock

	conn:request("GET", "/")
	local response = conn:getResponse()

	test.expect(response.body):toBe("ok")
	test.expect(#timeouts):toBe(2)
	test.expect(timeouts[1]):toBe(7)
	test.expect(timeouts[2]):toBe(3)
end)

return suite
