local _socket = require("@eryx/_socket")
local base64 = require("@eryx/encoding/base64")
local hash = require("@eryx/crypto/hazmat/hash")
local hex = require("@eryx/encoding/hex")
local task = require("@eryx/task")
local test = require("@eryx/test")
local websocket = require("@self/websocket")

local suite = test.Suite.new("websocket")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function digest(algorithm: string, data: buffer): buffer
	local ctx = hash.new(algorithm)
	ctx:update(data)
	return ctx:final()
end

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function computeAccept(key: string): (string, string)
	key = string.match(key, "^%s*(.-)%s*$") :: string
	local input = key .. WS_GUID
	local sha1 = digest("sha1", buffer.fromstring(input))
	return base64.encode(sha1), hex.encode(sha1)
end

local function readHeaders(sock: any): string
	local request = ""
	while not string.find(request, "\r\n\r\n", 1, true) do
		local chunk = sock:recv(4096)
		request ..= buffer.tostring(chunk)
	end
	return request
end

local function serveHandshakeOnce(builder: (request: string) -> string)
	local port = reservePort()
	local server = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	server:bind("127.0.0.1", port)
	server:listen(1)

	task.spawn(function()
		local client = server:accept()
		assert(client)
		client:setTimeout(1)
		local request = readHeaders(client)
		local response = builder(request)
		client:sendAll(buffer.fromstring(response))
		client:close()
		server:close()
	end)

	task.wait(0.05)
	return port
end

local function makeSocketFromBytes(bytes: string)
	local state = {
		buffer = bytes,
		sent = {} :: { string },
		closed = false,
	}

	return {
		recv = function(self, n: number)
			if #state.buffer == 0 then
				return buffer.create(0)
			end
			local chunk = string.sub(state.buffer, 1, n)
			state.buffer = string.sub(state.buffer, n + 1)
			return buffer.fromstring(chunk)
		end,
		sendAll = function(self, data: buffer)
			table.insert(state.sent, buffer.tostring(data))
			return true
		end,
		close = function(self)
			state.closed = true
		end,
		_state = state,
	}
end

local function maskPayload(payload: string, maskKey: string): string
	local out = table.create(#payload)
	for i = 1, #payload do
		local payloadByte = string.byte(payload, i)
		local maskByte = string.byte(maskKey, ((i - 1) % 4) + 1)
		out[i] = string.char(bit32.bxor(payloadByte, maskByte))
	end
	return table.concat(out)
end

local function makeFrame(
	opcode: number,
	payload: string,
	options: {
		fin: boolean?,
		masked: boolean?,
		rsv1: boolean?,
		rsv2: boolean?,
		rsv3: boolean?,
		maskKey: string?,
	}?
): string
	local opts = options or {}
	local fin = if opts.fin == nil then true else opts.fin
	local masked = if opts.masked == true then true else false
	local rsv1 = if opts.rsv1 == true then 0x40 else 0
	local rsv2 = if opts.rsv2 == true then 0x20 else 0
	local rsv3 = if opts.rsv3 == true then 0x10 else 0
	local firstByte = (if fin then 0x80 else 0) + rsv1 + rsv2 + rsv3 + opcode
	local secondByte = (if masked then 0x80 else 0) + #payload
	local parts = {
		string.char(firstByte, secondByte),
	}

	if masked then
		local maskKey = opts.maskKey or "\x01\x02\x03\x04"
		table.insert(parts, maskKey)
		table.insert(parts, maskPayload(payload, maskKey))
	else
		table.insert(parts, payload)
	end

	return table.concat(parts)
end

-- RFC 6455 Section 4.2.2, page 7 - the canonical test vector
suite:test("accept: RFC 6455 test vector", function()
	local accept, sha1hex = computeAccept("dGhlIHNhbXBsZSBub25jZQ==")
	test.expect(sha1hex):toBe("b37a4f2cc0624f1690f64606cf385945b2bec4ea")
	test.expect(accept):toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

suite:test("accept: key with whitespace trimmed", function()
	local accept = computeAccept("  dGhlIHNhbXBsZSBub25jZQ==  ")
	test.expect(accept):toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

suite:test("connect rejects responses without Upgrade websocket", function()
	local port = serveHandshakeOnce(function(request)
		local key = string.match(request, "Sec%-WebSocket%-Key:%s*([^\r\n]+)")
		local accept = computeAccept(key :: string)
		return table.concat({
			"HTTP/1.1 101 Switching Protocols\r\n",
			"Connection: Upgrade\r\n",
			"Sec-WebSocket-Accept: " .. accept .. "\r\n",
			"\r\n",
		})
	end)

	test.expect(function()
		websocket.connect(`ws://127.0.0.1:{port}/chat`)
	end):toError("invalid Upgrade header")
end)

suite:test("connect rejects responses without Connection Upgrade", function()
	local port = serveHandshakeOnce(function(request)
		local key = string.match(request, "Sec%-WebSocket%-Key:%s*([^\r\n]+)")
		local accept = computeAccept(key :: string)
		return table.concat({
			"HTTP/1.1 101 Switching Protocols\r\n",
			"Upgrade: websocket\r\n",
			"Connection: keep-alive\r\n",
			"Sec-WebSocket-Accept: " .. accept .. "\r\n",
			"\r\n",
		})
	end)

	test.expect(function()
		websocket.connect(`ws://127.0.0.1:{port}/chat`)
	end):toError("invalid Connection header")
end)

suite:test("connect rejects unsolicited subprotocol selection", function()
	local port = serveHandshakeOnce(function(request)
		local key = string.match(request, "Sec%-WebSocket%-Key:%s*([^\r\n]+)")
		local accept = computeAccept(key :: string)
		return table.concat({
			"HTTP/1.1 101 Switching Protocols\r\n",
			"Upgrade: websocket\r\n",
			"Connection: Upgrade\r\n",
			"Sec-WebSocket-Accept: " .. accept .. "\r\n",
			"Sec-WebSocket-Protocol: chat\r\n",
			"\r\n",
		})
	end)

	test.expect(function()
		websocket.connect(`ws://127.0.0.1:{port}/chat`, {
			subprotocols = { "superchat" },
		})
	end):toError("unsupported subprotocol")
end)

suite:test("upgrade rejects non-GET requests", function()
	local sent = {}
	local fakeResponse = {
		_sock = {
			sendAll = function(self, data: buffer)
				table.insert(sent, buffer.tostring(data))
			end,
		},
		_headersSent = false,
		_finished = false,
		_upgraded = false,
	}

	local ws = websocket.upgrade({
		method = "POST",
		headers = {
			upgrade = "websocket",
			connection = "Upgrade",
			["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==",
			["sec-websocket-version"] = "13",
		},
	}, fakeResponse, nil)

	test.expect(ws):toBeNil()
	test.expect(#sent):toBe(0)
end)

suite:test("upgrade rejects subprotocols not offered by the client", function()
	local sent = {}
	local fakeResponse = {
		_sock = {
			sendAll = function(self, data: buffer)
				table.insert(sent, buffer.tostring(data))
			end,
		},
		_headersSent = false,
		_finished = false,
		_upgraded = false,
	}

	local ws = websocket.upgrade(
		{
			method = "GET",
			headers = {
				upgrade = "websocket",
				connection = "keep-alive, Upgrade",
				["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==",
				["sec-websocket-version"] = "13",
				["sec-websocket-protocol"] = "chat, superchat",
			},
		},
		fakeResponse,
		{
			subprotocol = "video",
		}
	)

	test.expect(ws):toBeNil()
	test.expect(#sent):toBe(0)
end)

suite:test("receive rejects unmasked client frames on the server side", function()
	local sock = makeSocketFromBytes(makeFrame(websocket.TEXT, "hi"))
	local ws = websocket.WebSocket._new(sock, false, nil, nil)
	local message = ws:receive()

	test.expect(message):toBeNil()
	test.expect(sock._state.closed):toBeTrue()
	test.expect(sock._state.sent[1]):toNotBeNil()
end)

suite:test("receive rejects masked server frames on the client side", function()
	local sock = makeSocketFromBytes(makeFrame(websocket.TEXT, "hi", {
		masked = true,
		maskKey = "\x11\x22\x33\x44",
	}))
	local ws = websocket.WebSocket._new(sock, true, nil, nil)
	local message = ws:receive()

	test.expect(message):toBeNil()
	test.expect(sock._state.closed):toBeTrue()
	test.expect(sock._state.sent[1]):toNotBeNil()
end)

suite:test("receive rejects fragmented control frames", function()
	local sock = makeSocketFromBytes(makeFrame(websocket.PING, "", {
		fin = false,
	}))
	local ws = websocket.WebSocket._new(sock, true, nil, nil)
	local message = ws:receive()

	test.expect(message):toBeNil()
	test.expect(sock._state.closed):toBeTrue()
end)

suite:test("receive rejects reserved bits without negotiated extensions", function()
	local sock = makeSocketFromBytes(makeFrame(websocket.TEXT, "", {
		rsv2 = true,
	}))
	local ws = websocket.WebSocket._new(sock, true, nil, nil)
	local message = ws:receive()

	test.expect(message):toBeNil()
	test.expect(sock._state.closed):toBeTrue()
end)

return suite
