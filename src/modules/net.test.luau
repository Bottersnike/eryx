local _socket = require("@eryx/_socket")
local net = require("@self/net")
local task = require("@eryx/task")
local test = require("@eryx/test")

local suite = test.Suite.new("net")

local function reservePort(sockType: number, family: number?): number
	local sock = _socket.socket(family or _socket.AF_INET, sockType)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

suite:test("tcp clients can set socket options and use manual accept servers", function()
	local port = reservePort(_socket.SOCK_STREAM)

	task.spawn(function()
		local opts: net.TcpServerOptions = {
			mode = "manual",
			reuseAddress = true,
			nodelay = true,
		}
		local server = net.TcpServer.new("127.0.0.1", port, opts)

		local client = server:accept()
		test.expect(client):toNotBeNil()
		assert(client) -- for types

		local request = buffer.tostring(client:read(1024))
		test.expect(request):toBe("ping")
		client:write("pong")
		client:close()
		server:close()
	end)

	task.wait(0.05)

	local client = net.TcpClient.new("127.0.0.1", port, {
		nodelay = true,
	})
	test.expect(client:getSocketOption(_socket.IPPROTO_TCP, _socket.TCP_NODELAY)):toBeGreaterThan(0)

	client:write("ping")
	local response = client:read(1024)
	test.expect(buffer.tostring(response)):toBe("pong")
	client:close()
end)

suite:test("tcp servers can process clients concurrently in signal mode", function()
	local port = reservePort(_socket.SOCK_STREAM)
	local activeHandlers = 0
	local overlap = false
	local completed = 0
	local server: net.TcpServer

	local opts: net.TcpServerOptions = {
		reuseAddress = true,
		handler = function(client)
			activeHandlers += 1
			if activeHandlers > 1 then
				overlap = true
			end

			local payload = buffer.tostring(client:read(1024))
			task.wait(0.05)
			client:write("ok:" .. payload)
			client:close()

			activeHandlers -= 1
			completed += 1
			if completed == 2 then
				server:close()
			end
		end,
	}
	server = net.TcpServer.new("127.0.0.1", port, opts)

	task.wait(0.05)

	local responses = {}
	for index = 1, 2 do
		task.spawn(function()
			local client = net.TcpClient.new("127.0.0.1", port)
			client:write("client" .. tostring(index))
			responses[index] = buffer.tostring(client:read(1024))
			client:close()
		end)
	end

	task.wait(0.25)

	test.expect(overlap):toBeTrue()
	test.expect(responses[1]):toBe("ok:client1")
	test.expect(responses[2]):toBe("ok:client2")
end)

suite:test("udp client and server round-trip datagrams", function()
	local port = reservePort(_socket.SOCK_DGRAM)
	local opts: net.UdpServerOptions = {
		reuseAddress = true,
	}
	local server = net.UdpServer.new("127.0.0.1", port, opts)
	local client = net.UdpClient.new("127.0.0.1", port)

	client:write("ping")
	local data, host, replyPort = server:receive(1024)

	test.expect(data):toNotBeNil()
	test.expect(host):toBe("127.0.0.1")
	test.expect(replyPort):toBeGreaterThan(0)
	test.expect(buffer.tostring(data :: buffer)):toBe("ping")

	server:writeTo("pong", host :: string, replyPort :: number)
	local response = client:read(1024)

	test.expect(response):toNotBeNil()
	test.expect(buffer.tostring(response :: buffer)):toBe("pong")

	client:close()
	server:close()
end)

suite:test("tcp clients and servers can use IPv6 when the runtime supports it", function()
	local serverOk, serverOrErr = pcall(function()
		local opts: net.TcpServerOptions = {
			family = _socket.AF_INET6,
			mode = "manual",
			ipv6Only = true,
		}
		return net.TcpServer.new("::1", 0, opts)
	end)

	test.skipIf(not serverOk, "IPv6 loopback is not available in this environment")

	local server = serverOrErr :: net.TcpServer
	local host, port = server.host, server.port

	task.spawn(function()
		local client = server:accept()
		test.expect(client):toNotBeNil()
		assert(client) -- for types
		client:write("v6")
		client:close()
		server:close()
	end)

	task.wait(0.05)

	local client = net.TcpClient.new(host, port, {
		family = _socket.AF_INET6,
	})
	local response = client:read(16)
	test.expect(buffer.tostring(response)):toBe("v6")
	client:close()
end)

return suite
