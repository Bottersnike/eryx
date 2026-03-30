--[=[
	HTTP/1.1 client and server library.

	Built on top of `@eryx/_socket` and `@eryx/_ssl`, this module provides
	both one-shot convenience functions and lower-level connection and
	server classes for HTTP and HTTPS, with cookie jar and multipart
	form data support.

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

http.HttpServer = require("@self/HttpServer")
http.CookieJar = require("@self/CookieJar")
http.HttpConnection = require("@self/HttpConnection")
http.ServerResponse = require("@self/ServerResponse")
http.request = request.request
http.get = request.get
http.post = request.post
http.put = request.put
http.delete = request.delete
http.head = request.head
http.multipartEncode = multipart.encodeFields

return table.freeze(http)
