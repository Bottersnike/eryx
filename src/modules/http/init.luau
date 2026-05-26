--[=[
	HTTP/1.1 client and server library.

	Built on top of `@eryx/_socket` and `@eryx/_ssl`, this library provides
	both one-shot convenience functions and lower-level connection and
	server classes for HTTP and HTTPS, with cookie jars, pooled sessions,
	streaming request and response bodies, multipart/form helpers, and
	HTTP/1.1 trailer support.

	**Client - one-shot request:**
	```luau
	local http = require("@eryx/http")

	local response = http.get("http://example.com/")
	print(response.status, response.reason)
	print(response.body)
	```

	**Client - persistent connection:**
	```luau
	local conn = http.HttpConnection.new("example.com", 80)
	conn:request("GET", "/")
	local resp = conn:getResponse()
	conn:close()
	```

	**Cookies:**
	```luau
	local jar = http.CookieJar.new()
	http.get("http://example.com/login", { cookies = jar })
	-- jar stores Set-Cookie headers; subsequent requests send them back
	http.get("http://example.com/dashboard", { cookies = jar })
	```

	**Multipart form upload:**
	```luau
	local body, contentType = http.multipart({
	    { name = "field", value = "text" },
	    { name = "file", value = data, filename = "pic.png" },
	})
	http.post("http://example.com/upload", body, {
	    headers = { ["Content-Type"] = contentType },
	})
	```

	**Session with connection reuse:**
	```luau
	local session = http.Session.new({
	    connectTimeout = 2,
	    readTimeout = 10,
	    maxConnectionsPerHost = 4,
	})
	local resp = session:get("https://example.com/api")
	session:close()
	```

	**Server:**
	```luau
	local server = http.HttpServer.new(function(req, res)
	    res:send(200, "Hello, world!")
	end, { port = 8080 })
	server:listen(function(host, port)
	    print("Listening on " .. host .. ":" .. tostring(port))
	end)
	```

	**HTTPS Server:**
	```luau
	local ssl  = require("@eryx/_ssl")
	local ctx  = ssl.create_server_context("cert.pem", "key.pem")
	local server = http.HttpServer.new(handler, { port = 443, sslCtx = ctx })
	server:listen()
	```
]=]

local http = {}

local request = require("@self/request")
local multipart = require("@self/multipart")
local util = require("@self/util")

http.HttpServer = require("@self/HttpServer")
http.App = require("@self/App")
http.Router = http.App
http.ServerSession = require("@self/ServerSession")
http.CookieJar = require("@self/CookieJar")
http.HttpConnection = require("@self/HttpConnection")
http.Session = require("@self/Session")
http.ServerResponse = require("@self/ServerResponse")
http.createApp = function(options)
	return http.App.new(options)
end
http.createRouter = http.createApp
http.createMemorySessionStore = function()
	return http.ServerSession.memoryStore()
end
http.createFileSessionStore = function(directory)
	return http.ServerSession.fileStore(directory)
end
http.createSqliteSessionStore = function(database, tableName)
	return http.ServerSession.sqliteStore(database, tableName)
end
http.request = request.request
http.stream = request.stream
http.get = request.get
http.post = request.post
http.put = request.put
http.delete = request.delete
http.head = request.head
http.raiseForStatus = request.raiseForStatus
http.decodeJsonBody = request.decodeJsonBody
http.decodeFormBody = request.decodeFormBody
http.decodeMultipartBody = request.decodeMultipartBody
http.parseQuery = util.decodeForm
http.formEncode = util.encodeForm
http.formDecode = util.decodeForm
http.multipartEncode = multipart.encodeFields
http.multipartDecode = multipart.parse

return table.freeze(http)
