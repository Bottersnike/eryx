--[=[
	WebSocket client and server library (RFC 6455).

	**Client - connect to a WebSocket server:**
	```luau
	local websocket = require("@eryx/websocket")

	local ws = websocket.connect("ws://localhost:8080/chat")
	ws:send("hello")

	local msg = ws:receive()
	if msg then
		print(msg.data)
	end

	ws:close()
	```

	**Client - secure WebSocket (wss://):**
	```luau
	local ws = websocket.connect("wss://echo.example.com/ws")
	```

	**Client - with compression and heartbeat:**
	```luau
	local ws = websocket.connect("wss://echo.example.com/ws", {
	    compress = true,       -- negotiate permessage-deflate
	    heartbeat = 30,        -- send a ping every 30 seconds
	})
	```

	**Server - upgrade inside an HTTP handler:**
	```luau
	local http = require("@eryx/http")
	local websocket = require("@eryx/websocket")

	local server = http.createServer(function(req, res)
	    if req.path == "/ws" then
	        local ws = websocket.upgrade(req, res, { compress = true })
	        while true do
	            local msg = ws:receive()
	            if not msg then break end
	            ws:send("echo: " .. msg.data)
	        end
	        return
	    end
	    res:send(200, "Hello!")
	end)
	server:listen()
	```

	The server upgrade works with both HTTP and HTTPS servers - TLS is
	already handled by the HTTP server before the request arrives, so the
	upgraded WebSocket transparently inherits the encrypted transport.
]=]

local _socket = require("@eryx/_socket")
local _ssl = require("@eryx/_ssl")
local hash = require("@eryx/crypto/hash")
local random = require("@eryx/crypto/random")
local base64 = require("@eryx/encoding/base64")
local http = require("@eryx/http")
local zlib = require("@eryx/compression/zlib")
local task = require("@eryx/task")

-- ───────────────────────────────────────────────────────────────────────────
-- Constants
-- ───────────────────────────────────────────────────────────────────────────

--- @interface Opcode
--- WebSocket frame opcodes (RFC 6455 §5.2).
--- .CONTINUATION number -- 0x0 - Continuation frame
--- .TEXT          number -- 0x1 - UTF-8 text frame
--- .BINARY        number -- 0x2 - Binary frame
--- .CLOSE         number -- 0x8 - Connection close
--- .PING          number -- 0x9 - Ping
--- .PONG          number -- 0xA - Pong

local CONTINUATION = 0x0
local TEXT = 0x1
local BINARY = 0x2
local CLOSE = 0x8
local PING = 0x9
local PONG = 0xA

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- permessage-deflate: the 4-byte trailer that zlib appends for SYNC flush,
-- which must be stripped before sending and re-appended before decompressing.
local DEFLATE_TAIL = "\x00\x00\xff\xff"

-- ───────────────────────────────────────────────────────────────────────────
-- Helpers
-- ───────────────────────────────────────────────────────────────────────────

local function strToBuf(s: string): buffer
	return buffer.fromstring(s)
end

local function bufToStr(b: buffer): string
	return buffer.tostring(b)
end

--- Read exactly `n` bytes from a socket. Returns the concatenated string,
--- or nil if the connection closed before all bytes arrived.
local function recvExact(sock: any, n: number): string?
	local parts: { string } = {}
	local total = 0
	while total < n do
		local ok, chunk = pcall(sock.recv, sock, n - total)
		if not ok then
			return nil
		end
		if not chunk or buffer.len(chunk) == 0 then
			return nil
		end
		local s = bufToStr(chunk)
		table.insert(parts, s)
		total += #s
	end
	return table.concat(parts)
end

--- Send all data over a socket.
local function sendAll(sock: any, data: string)
	sock:sendAll(strToBuf(data))
end

--- Generate a random 16-byte base64-encoded WebSocket key.
local function generateKey(): string
	return base64.encode(random.bytes(16))
end

--- Compute the `Sec-WebSocket-Accept` value for a given key.
local function computeAccept(key: string): string
	-- Trim any whitespace from the key (RFC 7230 OWS).
	key = string.match(key, "^%s*(.-)%s*$") :: string
	local input = key .. WS_GUID
	local sha1 = hash.sha1(strToBuf(input))
	local accept = base64.encode(sha1)
	return accept
end

--- XOR-mask (or unmask) `data` with a 4-byte `maskKey`.
local function applyMask(data: buffer, maskKey: buffer): buffer
	local len = buffer.len(data)
	local result = buffer.create(len)
	for i = 0, len - 1 do
		buffer.writeu8(result, i, bit32.bxor(buffer.readu8(data, i), buffer.readu8(maskKey, i % 4)))
	end
	return result
end

-- ───────────────────────────────────────────────────────────────────────────
-- Frame encoding / decoding
-- ───────────────────────────────────────────────────────────────────────────

--- Encode a single WebSocket frame and return it as a string ready to send.
--- rsv1 sets the RSV1 bit (used by permessage-deflate to indicate compression).
local function encodeFrame(fin: boolean, opcode: number, payload: buffer, mask: boolean, rsv1: boolean?): string
	local payloadLen = buffer.len(payload)

	-- Determine extended-length header size.
	local extBytes = 0
	if payloadLen > 125 then
		extBytes = if payloadLen <= 0xFFFF then 2 else 8
	end

	local headerSize = 2 + extBytes + (if mask then 4 else 0)
	local header = buffer.create(headerSize)
	local off = 0

	-- Byte 0: FIN | RSV1 | RSV2(0) | RSV3(0) | opcode
	local byte0 = bit32.bor(if fin then 0x80 else 0, opcode)
	if rsv1 then
		byte0 = bit32.bor(byte0, 0x40)
	end
	buffer.writeu8(header, off, byte0)
	off += 1

	-- Byte 1: MASK | payload length
	local maskBit = if mask then 0x80 else 0
	if payloadLen <= 125 then
		buffer.writeu8(header, off, bit32.bor(maskBit, payloadLen))
		off += 1
	elseif payloadLen <= 0xFFFF then
		buffer.writeu8(header, off, bit32.bor(maskBit, 126))
		off += 1
		-- 16-bit big-endian
		buffer.writeu8(header, off, bit32.rshift(payloadLen, 8))
		buffer.writeu8(header, off + 1, bit32.band(payloadLen, 0xFF))
		off += 2
	else
		buffer.writeu8(header, off, bit32.bor(maskBit, 127))
		off += 1
		-- 64-bit big-endian (upper 32 bits are always 0 for us)
		buffer.writeu8(header, off, 0)
		buffer.writeu8(header, off + 1, 0)
		buffer.writeu8(header, off + 2, 0)
		buffer.writeu8(header, off + 3, 0)
		buffer.writeu8(header, off + 4, bit32.band(bit32.rshift(payloadLen, 24), 0xFF))
		buffer.writeu8(header, off + 5, bit32.band(bit32.rshift(payloadLen, 16), 0xFF))
		buffer.writeu8(header, off + 6, bit32.band(bit32.rshift(payloadLen, 8), 0xFF))
		buffer.writeu8(header, off + 7, bit32.band(payloadLen, 0xFF))
		off += 8
	end

	-- Masking key (client frames only)
	local maskKey: buffer?
	if mask then
		maskKey = random.bytes(4)
		buffer.copy(header, off, maskKey :: buffer)
		off += 4
	end

	-- Assemble: header .. (masked) payload
	if mask and maskKey then
		return bufToStr(header) .. bufToStr(applyMask(payload, maskKey :: buffer))
	end
	return bufToStr(header) .. bufToStr(payload)
end

--- Internal frame representation.
type Frame = {
	fin: boolean,
	rsv1: boolean,
	opcode: number,
	payload: buffer,
}

--- Read and decode one WebSocket frame from a socket.
--- Returns nil when the connection is closed or unreadable.
local function readFrame(sock: any): Frame?
	local hdr = recvExact(sock, 2)
	if not hdr then
		return nil
	end

	local byte0 = string.byte(hdr, 1)
	local byte1 = string.byte(hdr, 2)

	local fin = bit32.band(byte0, 0x80) ~= 0
	local rsv1 = bit32.band(byte0, 0x40) ~= 0
	local opcode = bit32.band(byte0, 0x0F)
	local masked = bit32.band(byte1, 0x80) ~= 0
	local payloadLen: number = bit32.band(byte1, 0x7F)

	-- Extended payload length
	if payloadLen == 126 then
		local ext = recvExact(sock, 2)
		if not ext then
			return nil
		end
		payloadLen = string.byte(ext, 1) * 256 + string.byte(ext, 2)
	elseif payloadLen == 127 then
		local ext = recvExact(sock, 8)
		if not ext then
			return nil
		end
		-- Only lower 32 bits are practical
		payloadLen = string.byte(ext, 5) * 16777216
			+ string.byte(ext, 6) * 65536
			+ string.byte(ext, 7) * 256
			+ string.byte(ext, 8)
	end

	-- Masking key
	local maskKey: buffer?
	if masked then
		local mk = recvExact(sock, 4)
		if not mk then
			return nil
		end
		maskKey = strToBuf(mk)
	end

	-- Payload
	local payload: buffer
	if payloadLen > 0 then
		local data = recvExact(sock, payloadLen)
		if not data then
			return nil
		end
		payload = strToBuf(data)
		if masked and maskKey then
			payload = applyMask(payload, maskKey :: buffer)
		end
	else
		payload = buffer.create(0)
	end

	return {
		fin = fin,
		rsv1 = rsv1,
		opcode = opcode,
		payload = payload,
	}
end

-- ───────────────────────────────────────────────────────────────────────────
-- permessage-deflate (RFC 7692)
-- ───────────────────────────────────────────────────────────────────────────

--- Holds the deflate/inflate streams and negotiated parameters for a
--- single WebSocket connection's permessage-deflate state.
type DeflateState = {
	deflater: any, -- zlib.Deflate stream (raw, -15 window bits)
	inflater: any, -- zlib.Inflate stream (raw, -15 window bits)
	noClientTakeover: boolean,
	noServerTakeover: boolean,
	isClient: boolean,
}

--- Create a new DeflateState after successful negotiation.
local function createDeflateState(isClient: boolean, noClientTakeover: boolean, noServerTakeover: boolean): DeflateState
	return {
		deflater = zlib.createDeflate(zlib.DEFAULT_COMPRESSION, zlib.RAW_WBITS),
		inflater = zlib.createInflate(zlib.RAW_WBITS),
		noClientTakeover = noClientTakeover,
		noServerTakeover = noServerTakeover,
		isClient = isClient,
	}
end

--- Compress a message payload using permessage-deflate.
--- Returns the compressed payload (with trailing 0x00 0x00 0xff 0xff stripped).
local function deflatePayload(state: DeflateState, payload: buffer): buffer
	-- Compress with SYNC_FLUSH to get a complete deflate block.
	local compressed = bufToStr(state.deflater:write(payload, zlib.FLUSH_SYNC))

	-- Per RFC 7692 §7.2.1: strip the trailing 0x00 0x00 0xff 0xff.
	if string.sub(compressed, -4) == DEFLATE_TAIL then
		compressed = string.sub(compressed, 1, -5)
	end

	-- If context takeover is disabled for our sending side, reset the deflater.
	local noTakeover = if state.isClient then state.noClientTakeover else state.noServerTakeover
	if noTakeover then
		state.deflater:close()
		state.deflater = zlib.createDeflate(zlib.DEFAULT_COMPRESSION, zlib.RAW_WBITS)
	end

	return strToBuf(compressed)
end

--- Decompress a message payload using permessage-deflate.
--- Re-appends the trailing 0x00 0x00 0xff 0xff before inflating.
local function inflatePayload(state: DeflateState, payload: buffer): buffer
	-- Per RFC 7692 §7.2.2: re-append the stripped trailer.
	local input = bufToStr(payload) .. DEFLATE_TAIL
	local decompressed, _ = state.inflater:write(strToBuf(input))

	-- If context takeover is disabled for the receiving side, reset the inflater.
	local noTakeover = if state.isClient then state.noServerTakeover else state.noClientTakeover
	if noTakeover then
		state.inflater:close()
		state.inflater = zlib.createInflate(zlib.RAW_WBITS)
	end

	return decompressed
end

--- Parse the Sec-WebSocket-Extensions header value to extract
--- permessage-deflate parameters. Returns nil if not present.
local function parseDeflateParams(extHeader: string?): {
	noClientTakeover: boolean,
	noServerTakeover: boolean,
}?
	if not extHeader then
		return nil
	end

	-- Find permessage-deflate among possibly multiple extensions.
	for ext in string.gmatch(extHeader :: string, "[^,]+") do
		local trimmed = string.match(ext, "^%s*(.-)%s*$") :: string
		if string.find(trimmed, "^permessage%-deflate") then
			local noClientTakeover = string.find(trimmed, "client_no_context_takeover") ~= nil
			local noServerTakeover = string.find(trimmed, "server_no_context_takeover") ~= nil
			return {
				noClientTakeover = noClientTakeover,
				noServerTakeover = noServerTakeover,
			}
		end
	end

	return nil
end

-- ───────────────────────────────────────────────────────────────────────────
-- WebSocket class
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	A WebSocket connection.

	Obtained from [[connect]] (client) or [[upgrade]] (server).
	Provides methods to send and receive messages, send pings, and
	perform the close handshake.
]=]
local WebSocket = {}
WebSocket.__index = WebSocket

type WebSocketFields = {
	_sock: any,
	_isClient: boolean,
	_closed: boolean,
	_closeSent: boolean,
	_closeReceived: boolean,
	_deflate: DeflateState?,
	_heartbeatThread: thread?,
}

export type WebSocket = typeof(setmetatable({} :: WebSocketFields, WebSocket))

function WebSocket._new(sock: any, isClient: boolean, deflate: DeflateState?, heartbeatInterval: number?): WebSocket
	local ws = setmetatable(
		{
			_sock = sock,
			_isClient = isClient,
			_closed = false,
			_closeSent = false,
			_closeReceived = false,
			_deflate = deflate,
			_heartbeatThread = nil :: thread?,
		} :: WebSocketFields,
		WebSocket
	)

	-- Start heartbeat if requested.
	if heartbeatInterval and heartbeatInterval > 0 then
		ws._heartbeatThread = task.spawn(function()
			while not ws._closed do
				task.wait(heartbeatInterval)
				if ws._closed then
					break
				end
				pcall(WebSocket.ping, ws)
			end
		end)
	end

	return ws
end

--[=[
	A message returned by [[WebSocket.receive]].

	@interface Message
	.data string -- The payload. For text frames this is a UTF-8 string; for binary frames it contains raw bytes.
	.binary boolean -- `true` when the message was sent as a binary frame.
]=]
export type Message = {
	data: string,
	binary: boolean,
}

--[=[
	Sends a text or binary message.

	If `permessage-deflate` was negotiated, the message is automatically
	compressed before sending.

	@param data The payload to send. Strings are sent as-is; buffers are
	            converted with `buffer.tostring`.
	@param binary When `true`, sends a binary frame (opcode 0x2) instead
	              of a text frame (opcode 0x1). Defaults to `false`.
]=]
function WebSocket.send(self: WebSocket, data: string | buffer, binary: boolean?)
	if self._closed then
		error("WebSocket is closed")
	end

	local opcode = if binary then BINARY else TEXT
	local payload: buffer
	if typeof(data) == "string" then
		payload = strToBuf(data)
	else
		payload = data
	end

	-- Compress if permessage-deflate is active.
	local rsv1 = false
	if self._deflate and buffer.len(payload) > 0 then
		payload = deflatePayload(self._deflate, payload)
		rsv1 = true
	end

	sendAll(self._sock, encodeFrame(true, opcode, payload, self._isClient, rsv1))
end

--[=[
	Sends a Ping control frame.

	@param data Optional payload (≤ 125 bytes).
]=]
function WebSocket.ping(self: WebSocket, data: (string | buffer)?)
	if self._closed then
		return
	end
	local payload: buffer
	if data then
		payload = if typeof(data) == "string" then strToBuf(data) else data
	else
		payload = buffer.create(0)
	end
	sendAll(self._sock, encodeFrame(true, PING, payload, self._isClient))
end

--[=[
	Sends a Pong control frame.

	@param data Optional payload (≤ 125 bytes). Typically the same data
	            received in the corresponding Ping.
]=]
function WebSocket.pong(self: WebSocket, data: (string | buffer)?)
	if self._closed then
		return
	end
	local payload: buffer
	if data then
		payload = if typeof(data) == "string" then strToBuf(data) else data
	else
		payload = buffer.create(0)
	end
	sendAll(self._sock, encodeFrame(true, PONG, payload, self._isClient))
end

--[=[
	Blocks until a complete data message arrives, or the connection closes.

	Handles fragmented messages, automatically responds to Ping frames
	with Pong, and performs the close handshake when a close frame is
	received. If `permessage-deflate` was negotiated, compressed messages
	(RSV1 set) are automatically decompressed.

	@return Message? -- The received message, or `nil` when the connection
	                    has been closed.
]=]
function WebSocket.receive(self: WebSocket): Message?
	if self._closed then
		return nil
	end

	local fragments: { buffer } = {}
	local messageOpcode: number? = nil
	local messageCompressed = false

	while true do
		local frame = readFrame(self._sock)
		if not frame then
			self._closed = true
			return nil
		end

		-- Control frames (opcode ≥ 0x8) may arrive between data fragments.
		if frame.opcode >= 0x8 then
			if frame.opcode == CLOSE then
				self._closeReceived = true
				if not self._closeSent then
					-- Echo the close frame back.
					pcall(sendAll, self._sock, encodeFrame(true, CLOSE, frame.payload, self._isClient))
					self._closeSent = true
				end
				self._closed = true
				pcall(self._sock.close, self._sock)
				return nil
			elseif frame.opcode == PING then
				pcall(sendAll, self._sock, encodeFrame(true, PONG, frame.payload, self._isClient))
				continue
			elseif frame.opcode == PONG then
				-- Unsolicited pong - ignore.
				continue
			end
		end

		-- Data frame
		if frame.opcode ~= CONTINUATION then
			messageOpcode = frame.opcode
			messageCompressed = frame.rsv1
			fragments = { frame.payload }
		else
			table.insert(fragments, frame.payload)
		end

		if frame.fin then
			if messageOpcode == nil then
				-- Orphan continuation with FIN - ignore.
				continue
			end

			-- Reassemble fragments.
			local totalLen = 0
			for _, frag in fragments do
				totalLen += buffer.len(frag)
			end
			local result = buffer.create(totalLen)
			local off = 0
			for _, frag in fragments do
				buffer.copy(result, off, frag)
				off += buffer.len(frag)
			end

			-- Decompress if RSV1 is set and permessage-deflate is active.
			if messageCompressed and self._deflate then
				result = inflatePayload(self._deflate, result)
			end

			return {
				data = bufToStr(result),
				binary = messageOpcode == BINARY,
			}
		end
	end
end

--[=[
	Initiates the WebSocket close handshake.

	Sends a close frame, waits for the server's close reply (if not
	already received), then shuts down the underlying socket. Also
	cancels any active heartbeat.

	@param code Optional status code (e.g. `1000` for normal closure).
	@param reason Optional human-readable close reason.
]=]
function WebSocket.close(self: WebSocket, code: number?, reason: string?)
	if self._closeSent then
		return
	end
	self._closeSent = true

	-- Stop the heartbeat.
	if self._heartbeatThread then
		pcall(task.cancel, self._heartbeatThread)
		self._heartbeatThread = nil
	end

	-- Build the close frame payload.
	local payload: buffer
	if code then
		local reasonBuf = if reason then strToBuf(reason) else buffer.create(0)
		payload = buffer.create(2 + buffer.len(reasonBuf))
		-- Status code is 16-bit big-endian.
		buffer.writeu8(payload, 0, bit32.rshift(code, 8))
		buffer.writeu8(payload, 1, bit32.band(code, 0xFF))
		if buffer.len(reasonBuf) > 0 then
			buffer.copy(payload, 2, reasonBuf)
		end
	else
		payload = buffer.create(0)
	end

	pcall(sendAll, self._sock, encodeFrame(true, CLOSE, payload, self._isClient))

	-- Wait for the peer's close response (with a safety limit).
	if not self._closeReceived then
		pcall(function()
			for _ = 1, 100 do
				local f = readFrame(self._sock)
				if not f then
					break
				end
				if f.opcode == CLOSE then
					self._closeReceived = true
					break
				end
			end
		end)
	end

	self._closed = true
	pcall(self._sock.close, self._sock)

	-- Clean up compression state.
	if self._deflate then
		pcall(self._deflate.deflater.close, self._deflate.deflater)
		pcall(self._deflate.inflater.close, self._deflate.inflater)
		self._deflate = nil
	end
end

-- ───────────────────────────────────────────────────────────────────────────
-- URL parsing
-- ───────────────────────────────────────────────────────────────────────────

--- Parse a `ws://` or `wss://` URL into its components.
local function parseWsUrl(url: string): { scheme: string, host: string, port: number, path: string }
	local scheme, rest = string.match(url, "^(wss?)://(.+)$")
	if not scheme or not rest then
		error("Invalid WebSocket URL: " .. url)
	end

	local host: string?
	local port: number?
	local path: string?

	-- IPv6 literal: [::1]:port/path
	local ipv6, after = string.match(rest :: string, "^%[([^%]]+)%](.*)$")
	if ipv6 then
		host = ipv6
		local p, pathPart = string.match(after :: string, "^:(%d+)(.*)$")
		if p then
			port = tonumber(p)
			path = pathPart
		else
			path = after
		end
	else
		-- host:port/path  or  host/path
		local h, p, pathPart = string.match(rest :: string, "^([^:/%?]+):(%d+)(.*)$")
		if h then
			host = h
			port = tonumber(p)
			path = pathPart
		else
			local h2, pathPart2 = string.match(rest :: string, "^([^:/%?]+)(.*)$")
			host = h2
			path = pathPart2
		end
	end

	if not host then
		error("Invalid WebSocket URL: " .. url)
	end

	return {
		scheme = scheme :: string,
		host = host :: string,
		port = (port or (if scheme == "wss" then 443 else 80)) :: number,
		path = (if not path or path == "" then "/" else path) :: string,
	}
end

-- ───────────────────────────────────────────────────────────────────────────
-- Client connect
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	Options for [[connect]].

	@interface ConnectOptions
	.headers { [string]: string }? -- Extra headers to include in the upgrade request.
	.timeout number? -- Socket timeout in seconds.
	.subprotocols { string }? -- Requested sub-protocols (`Sec-WebSocket-Protocol`).
	.compress boolean? -- When `true`, negotiates `permessage-deflate` compression (RFC 7692).
	.heartbeat number? -- Interval in seconds between automatic ping frames. `nil` or `0` disables.
]=]
export type ConnectOptions = {
	headers: { [string]: string }?,
	timeout: number?,
	subprotocols: { string }?,
	compress: boolean?,
	heartbeat: number?,
}

--[=[
	Opens a WebSocket connection to the given URL.

	Supports `ws://` (plain) and `wss://` (TLS) schemes. Performs the
	HTTP upgrade handshake and returns a connected [[WebSocket]].

	When `compress` is `true`, the client offers `permessage-deflate`
	and enables compression if the server accepts.

	```luau
	local ws = websocket.connect("ws://localhost:8080/chat", {
	    compress = true,
	    heartbeat = 30,
	})
	```

	@param url The WebSocket URL to connect to.
	@param options Optional connection settings.
	@return WebSocket -- The connected WebSocket.
	@error Throws if the handshake fails or the server rejects the upgrade.
]=]
local function connect(url: string, options: ConnectOptions?): WebSocket
	local parsed = parseWsUrl(url)
	local opts = options or {} :: ConnectOptions

	-- TCP connect
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:connect(parsed.host, parsed.port)
	sock:setBlocking(true)

	if opts.timeout then
		sock:setTimeout(opts.timeout)
	end

	-- TLS for wss://
	local connSock: any = sock
	if parsed.scheme == "wss" then
		local ctx = _ssl.createDefaultContext()
		connSock = ctx:wrapSocket(sock, parsed.host)
	end

	-- Build the upgrade request
	local key = generateKey()

	local hostHeader = parsed.host
	if (parsed.scheme == "ws" and parsed.port ~= 80) or (parsed.scheme == "wss" and parsed.port ~= 443) then
		hostHeader ..= ":" .. tostring(parsed.port)
	end

	local lines: { string } = {
		"GET " .. parsed.path .. " HTTP/1.1\r\n",
		"Host: " .. hostHeader .. "\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Key: " .. key .. "\r\n",
		"Sec-WebSocket-Version: 13\r\n",
	}

	-- Offer permessage-deflate if compression is requested.
	if opts.compress then
		table.insert(lines, "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n")
	end

	if opts.subprotocols and #opts.subprotocols > 0 then
		table.insert(lines, "Sec-WebSocket-Protocol: " .. table.concat(opts.subprotocols, ", ") .. "\r\n")
	end

	if opts.headers then
		for name, value in opts.headers do
			table.insert(lines, name .. ": " .. value .. "\r\n")
		end
	end

	table.insert(lines, "\r\n")
	sendAll(connSock, table.concat(lines))

	-- Read the server's HTTP response (up to end of headers).
	local responseBuf = ""
	while not string.find(responseBuf, "\r\n\r\n", 1, true) do
		local ok, chunk = pcall(connSock.recv, connSock, 4096)
		if not ok then
			pcall(connSock.close, connSock)
			error("WebSocket handshake failed: connection error")
		end
		local s = bufToStr(chunk)
		if #s == 0 then
			pcall(connSock.close, connSock)
			error("WebSocket handshake failed: connection closed")
		end
		responseBuf ..= s
	end

	-- Validate status line
	local statusLine = string.match(responseBuf, "^(.-)\r\n")
	if not statusLine then
		pcall(connSock.close, connSock)
		error("WebSocket handshake failed: invalid response")
	end

	local _, statusCode = string.match(statusLine :: string, "^(HTTP/%d+%.%d+)%s+(%d+)")
	if not statusCode or statusCode ~= "101" then
		pcall(connSock.close, connSock)
		error("WebSocket handshake failed: expected status 101, got " .. tostring(statusCode))
	end

	-- Verify Sec-WebSocket-Accept
	local expectedAccept = computeAccept(key)
	local actualAccept = string.match(responseBuf, "[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)")
	if not actualAccept then
		pcall(connSock.close, connSock)
		error("WebSocket handshake failed: missing Sec-WebSocket-Accept header")
	end
	actualAccept = string.match(actualAccept :: string, "^%s*(.-)%s*$") -- trim

	if actualAccept ~= expectedAccept then
		pcall(connSock.close, connSock)
		error("WebSocket handshake failed: Sec-WebSocket-Accept mismatch")
	end

	-- Check if server accepted permessage-deflate.
	local deflate: DeflateState? = nil
	if opts.compress then
		local extHeader = string.match(responseBuf, "[Ss]ec%-[Ww]eb[Ss]ocket%-[Ee]xtensions:%s*([^\r\n]+)")
		local params = parseDeflateParams(extHeader)
		if params then
			deflate = createDeflateState(true, params.noClientTakeover, params.noServerTakeover)
		end
	end

	return WebSocket._new(connSock, true, deflate, opts.heartbeat)
end

-- ───────────────────────────────────────────────────────────────────────────
-- Server upgrade
-- ───────────────────────────────────────────────────────────────────────────

--[=[
	Options for [[upgrade]].

	@interface UpgradeOptions
	.subprotocol string? -- The sub-protocol to select. Sent back in `Sec-WebSocket-Protocol`.
	.compress boolean? -- When `true`, accepts `permessage-deflate` if the client offered it.
	.heartbeat number? -- Interval in seconds between automatic ping frames. `nil` or `0` disables.
]=]
export type UpgradeOptions = {
	subprotocol: string?,
	compress: boolean?,
	heartbeat: number?,
}

--[=[
	Attempts to upgrade an HTTP connection to a WebSocket inside an
	[[HttpServer]] handler.

	Returns `nil` if the request is not a valid WebSocket upgrade (wrong
	or missing headers), so you can use a simple `if` check. When the
	request *is* valid, sends the `101 Switching Protocols` response and
	returns a [[WebSocket]] that owns the underlying socket. The HTTP
	server will **not** close the socket after the handler returns.

	When `compress` is `true` and the client offered `permessage-deflate`,
	the server accepts and enables compression for the connection.

	```luau
	http.createServer(function(req, res)
	    local ws = websocket.upgrade(req, res, { compress = true })
	    if ws then
	        -- WebSocket connection established
	        ws:send("hello")
	    else
	        -- Normal HTTP request
	        res:send(200, "Not a WebSocket request.")
	    end
	end)
	```

	Works transparently with HTTPS servers - TLS is handled before the
	upgrade request reaches the handler.

	@param request The incoming [[ServerRequest]] from the HTTP handler.
	@param response The [[ServerResponse]] from the HTTP handler.
	@param options Optional upgrade settings (e.g. sub-protocol selection).
	@return WebSocket? -- The upgraded WebSocket, or `nil` if the request is not a WebSocket upgrade.
]=]
local function upgrade(request: http.ServerRequest, response: http.ServerResponse, options: UpgradeOptions?): WebSocket?
	local opts = options or {} :: UpgradeOptions

	-- Validate required upgrade headers - return nil for non-upgrade requests.
	local upgradeHeader = request.headers["upgrade"]
	if not upgradeHeader or string.lower(upgradeHeader) ~= "websocket" then
		return nil
	end

	local connection = request.headers["connection"]
	if not connection or not string.find(string.lower(connection), "upgrade", 1, true) then
		return nil
	end

	local key = request.headers["sec-websocket-key"]
	if not key then
		return nil
	end

	local version = request.headers["sec-websocket-version"]
	if version ~= "13" then
		return nil
	end

	-- Compute accept value and build the 101 response.
	local accept = computeAccept(key)

	-- Check if the client offered permessage-deflate and we want to accept it.
	local deflate: DeflateState? = nil
	local deflateResponseExt: string? = nil
	if opts.compress then
		local clientExts = request.headers["sec-websocket-extensions"]
		local params = parseDeflateParams(clientExts)
		if params then
			deflate = createDeflateState(false, params.noClientTakeover, params.noServerTakeover)

			-- Build the response extension header, echoing relevant parameters.
			local parts = { "permessage-deflate" }
			if params.noClientTakeover then
				table.insert(parts, "client_no_context_takeover")
			end
			if params.noServerTakeover then
				table.insert(parts, "server_no_context_takeover")
			end
			deflateResponseExt = table.concat(parts, "; ")
		end
	end

	local responseLines: { string } = {
		"HTTP/1.1 101 Switching Protocols\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Accept: " .. accept .. "\r\n",
	}

	if deflateResponseExt then
		table.insert(responseLines, "Sec-WebSocket-Extensions: " .. deflateResponseExt .. "\r\n")
	end

	if opts.subprotocol then
		table.insert(responseLines, "Sec-WebSocket-Protocol: " .. opts.subprotocol .. "\r\n")
	end

	table.insert(responseLines, "\r\n")

	-- Send the 101 directly on the raw socket.
	local sock: _socket.Socket = response._sock
	sendAll(sock, table.concat(responseLines))

	-- Clear the HTTP server's per-client timeout - WebSocket connections
	-- are long-lived and should block indefinitely waiting for frames.
	pcall(function()
		if sock.setTimeout then
			sock:setTimeout(nil)
		end
	end)

	-- Mark the response as finished and upgraded so the HTTP server
	-- does not send additional data or close the socket.
	response._headersSent = true
	response._finished = true
	(response :: any)._upgraded = true

	return WebSocket._new(sock, false, deflate, opts.heartbeat)
end

-- ───────────────────────────────────────────────────────────────────────────
-- Module
-- ───────────────────────────────────────────────────────────────────────────

local websocket = {}

websocket.WebSocket = WebSocket
websocket.connect = connect
websocket.upgrade = upgrade

-- Expose opcodes for advanced usage.
websocket.CONTINUATION = CONTINUATION
websocket.TEXT = TEXT
websocket.BINARY = BINARY
websocket.CLOSE = CLOSE
websocket.PING = PING
websocket.PONG = PONG

return table.freeze(websocket)
