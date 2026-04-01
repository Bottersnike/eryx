local _socket = require("@eryx/_socket")
local App = require("./App")
local request = require("./request")
local task = require("@eryx/task")
local test = require("@eryx/test")
local websocket = require("@eryx/websocket")

local suite = test.Suite.new("http app")

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function withApp(app: App.App, run: (url: string, app: App.App) -> ())
	local port = reservePort()

	task.spawn(function()
		app:listen(nil, {
			host = "127.0.0.1",
			port = port,
			clientTimeout = 1,
		})
	end)
	task.wait(0.05)

	local ok, err = pcall(run, `http://127.0.0.1:{port}`, app)
	app:close()
	task.wait(0.05)
	if not ok then
		error(err)
	end
end

suite:test("route params and query are exposed on context", function()
	local app = App.new()
	app:get("/users/:id", function(ctx)
		return {
			id = ctx.params.id,
			page = ctx.query.page,
		}
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/users/alice?page=2")
		local decoded = request.decodeJsonBody(response)
		test.expect(decoded.id):toBe("alice")
		test.expect(decoded.page):toBe("2")
	end)
end)

suite:test("middleware can decorate the request and route responses", function()
	local app = App.new()
	app:use(function(ctx, next)
		ctx.state.authenticated = true
		ctx.response:header("x-middleware", "set")
		return next()
	end)
	app:get("/dashboard", function(ctx)
		return 201, {
			ok = ctx.state.authenticated,
		}
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/dashboard")
		local decoded = request.decodeJsonBody(response)
		test.expect(response.status):toBe(201)
		test.expect(response.headers["x-middleware"]):toBe("set")
		test.expect(decoded.ok):toBeTrue()
	end)
end)

suite:test("context helper methods can send redirects and custom bodies", function()
	local app = App.new()
	app:get("/go", function(ctx)
		ctx:redirect("/target", 307)
	end)
	app:get("/created", function(ctx)
		return {
			status = 201,
			text = "created",
			headers = {
				["x-test"] = "yes",
			},
		}
	end)

	withApp(app, function(url, runningApp)
		local redirected = request.get(url .. "/go", {
			maxRedirects = 0,
		})
		test.expect(redirected.status):toBe(307)
		test.expect(redirected.headers["location"]):toBe("/target")

		local created = request.get(url .. "/created")
		test.expect(created.status):toBe(201)
		test.expect(created.headers["x-test"]):toBe("yes")
		test.expect(created.body):toBe("created")

		runningApp:close()
	end)
end)

suite:test("missing routes return 404 and method mismatches return 405 with allow", function()
	local app = App.new()
	app:get("/items/:id", function(ctx)
		return ctx.params.id
	end)

	withApp(app, function(url)
		local missing = request.get(url .. "/missing")
		test.expect(missing.status):toBe(404)
		test.expect(missing.body):toBe("Not Found")

		local wrongMethod = request.post(url .. "/items/42")
		test.expect(wrongMethod.status):toBe(405)
		test.expect(wrongMethod.headers["allow"]):toContain("GET")
		test.expect(wrongMethod.headers["allow"]):toContain("HEAD")
	end)
end)

suite:test("HEAD requests fall back to GET routes", function()
	local app = App.new()
	app:get("/health", function()
		return "healthy"
	end)

	withApp(app, function(url)
		local response = request.head(url .. "/health")
		test.expect(response.status):toBe(200)
		test.expect(response.body):toBe("")
	end)
end)

suite:test("sub-apps can be mounted at a URL prefix", function()
	local api = App.new()
	api:get("/users/:id", function(ctx)
		return {
			id = ctx.params.id,
			mountPath = ctx.mountPath,
			pathWithinMount = ctx.pathWithinMount,
			originalPath = ctx.originalPath,
		}
	end)

	local app = App.new()
	app:mount("/api", api)

	withApp(app, function(url)
		local response = request.get(url .. "/api/users/alice")
		local decoded = request.decodeJsonBody(response)
		test.expect(decoded.id):toBe("alice")
		test.expect(decoded.mountPath):toBe("/api")
		test.expect(decoded.pathWithinMount):toBe("/users/alice")
		test.expect(decoded.originalPath):toBe("/api/users/alice")
	end)
end)

suite:test("mounted apps compose parent and child middleware", function()
	local child = App.new()
	child:use(function(ctx, next)
		ctx.state.steps = ctx.state.steps or {}
		table.insert(ctx.state.steps, "child-before")
		local result = next()
		table.insert(ctx.state.steps, "child-after")
		return result
	end)
	child:get("/info", function(ctx)
		table.insert(ctx.state.steps, "handler")
		return {
			steps = ctx.state.steps,
		}
	end)

	local app = App.new()
	app:use(function(ctx, next)
		ctx.state.steps = { "parent-before" }
		local result = next()
		table.insert(ctx.state.steps, "parent-after")
		return result
	end)
	app:mount("/api", child)

	withApp(app, function(url)
		local response = request.get(url .. "/api/info")
		local decoded = request.decodeJsonBody(response)
		test.expect(decoded.steps[1]):toBe("parent-before")
		test.expect(decoded.steps[2]):toBe("child-before")
		test.expect(decoded.steps[3]):toBe("handler")
		test.expect(decoded.steps[4]):toBe("child-after")
		test.expect(decoded.steps[5]):toBe("parent-after")
	end)
end)

suite:test("status handlers can customize 404 and 405 responses", function()
	local app = App.new()
	app:get("/only-get", function()
		return "ok"
	end)
	app:error(404, function(ctx)
		return {
			status = 404,
			json = {
				status = ctx.errorStatus,
				message = "missing",
			},
		}
	end)
	app:error(405, function(ctx)
		return {
			status = 405,
			json = {
				status = ctx.errorStatus,
				allowed = ctx.errorData.allowedMethods,
			},
		}
	end)

	withApp(app, function(url)
		local missing = request.get(url .. "/missing")
		local missingJson = request.decodeJsonBody(missing)
		test.expect(missing.status):toBe(404)
		test.expect(missingJson.status):toBe(404)
		test.expect(missingJson.message):toBe("missing")

		local wrongMethod = request.post(url .. "/only-get")
		local wrongMethodJson = request.decodeJsonBody(wrongMethod)
		test.expect(wrongMethod.status):toBe(405)
		test.expect(wrongMethodJson.status):toBe(405)
		test.expect(wrongMethodJson.allowed[1]):toBe("GET")
	end)
end)

suite:test("exception handlers can recover from uncaught route errors", function()
	local app = App.new()
	app:onError(function(ctx, err)
		return {
			status = 500,
			json = {
				path = ctx.originalPath,
				message = tostring(err),
			},
		}
	end)
	app:get("/boom", function()
		error("kaboom")
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/boom")
		local decoded = request.decodeJsonBody(response)
		test.expect(response.status):toBe(500)
		test.expect(decoded.path):toBe("/boom")
		test.expect(decoded.message):toContain("kaboom")
	end)
end)

suite:test("group creates a prefixed child router with local middleware", function()
	local app = App.new()
	local api = app:group("/api")
	api:use(function(ctx, next)
		ctx.response:header("x-group", "api")
		return next()
	end)
	api:get("/users/:id", function(ctx)
		return {
			id = ctx.params.id,
			mountPath = ctx.mountPath,
		}
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/api/users/bob")
		local decoded = request.decodeJsonBody(response)
		test.expect(response.headers["x-group"]):toBe("api")
		test.expect(decoded.id):toBe("bob")
		test.expect(decoded.mountPath):toBe("/api")
	end)
end)

suite:test("urlFor builds paths for named routes across mounted apps", function()
	local api = App.new()
	api:get("/users/:id", function()
		return "ok"
	end, {
		name = "api.user.show",
	})

	local app = App.new()
	app:get("/health", function()
		return "ok"
	end, {
		name = "health",
	})
	app:mount("/api", api)

	test.expect(app:urlFor("health")):toBe("/health")
	test.expect(app:urlFor("api.user.show", {
		id = "alice bob",
	}, {
		page = 2,
	})):toBe("/api/users/alice%20bob?page=2")
end)

suite:test("static mounts serve files with content types", function()
	local app = App.new()
	app:static("/assets", "src/modules/http/testdata/static", {
		indexFile = "index.html",
		headers = {
			["cache-control"] = "public, max-age=60",
		},
	})

	withApp(app, function(url)
		local js = request.get(url .. "/assets/app.js")
		test.expect(js.status):toBe(200)
		test.expect(js.headers["content-type"]):toContain("application/javascript")
		test.expect(js.headers["cache-control"]):toBe("public, max-age=60")
		test.expect(js.body):toContain("hello static")

		local index = request.get(url .. "/assets")
		test.expect(index.status):toBe(200)
		test.expect(index.headers["content-type"]):toContain("text/html")
		test.expect(index.body):toContain("static home")

		local missing = request.get(url .. "/assets/missing.txt")
		test.expect(missing.status):toBe(404)
	end)
end)

suite:test("route-local middleware only applies to that route and runs inside app middleware", function()
	local app = App.new()
	app:use(function(ctx, next)
		ctx.state.steps = { "app-before" }
		local result = next()
		table.insert(ctx.state.steps, "app-after")
		return result
	end)

	local authMiddleware = function(ctx, next)
		table.insert(ctx.state.steps, "route-before")
		ctx.response:header("x-route-middleware", "yes")
		local result = next()
		table.insert(ctx.state.steps, "route-after")
		return result
	end

	app:get("/private", function(ctx)
		table.insert(ctx.state.steps, "handler")
		return {
			steps = ctx.state.steps,
		}
	end, {
		middleware = { authMiddleware },
	})

	app:get("/public", function(ctx)
		table.insert(ctx.state.steps, "public-handler")
		return {
			steps = ctx.state.steps,
		}
	end)

	withApp(app, function(url)
		local privateResponse = request.get(url .. "/private")
		local privateDecoded = request.decodeJsonBody(privateResponse)
		test.expect(privateResponse.headers["x-route-middleware"]):toBe("yes")
		test.expect(privateDecoded.steps[1]):toBe("app-before")
		test.expect(privateDecoded.steps[2]):toBe("route-before")
		test.expect(privateDecoded.steps[3]):toBe("handler")
		test.expect(privateDecoded.steps[4]):toBe("route-after")
		test.expect(privateDecoded.steps[5]):toBe("app-after")

		local publicResponse = request.get(url .. "/public")
		local publicDecoded = request.decodeJsonBody(publicResponse)
		test.expect(publicResponse.headers["x-route-middleware"]):toBeNil()
		test.expect(publicDecoded.steps[1]):toBe("app-before")
		test.expect(publicDecoded.steps[2]):toBe("public-handler")
		test.expect(publicDecoded.steps[3]):toBe("app-after")
	end)
end)

suite:test("context exposes request cookies and can set response cookies", function()
	local app = App.new()
	app:get("/cookies", function(ctx)
		ctx:setCookie("session", "abc123", {
			path = "/",
			httpOnly = true,
			sameSite = "Lax",
		})
		ctx:setCookie("theme", "dark", {
			path = "/",
			maxAge = 60,
		})
		return {
			token = ctx:cookie("token"),
			all = ctx.cookies,
		}
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/cookies", {
			headers = {
				["Cookie"] = "token=secret; theme=light",
			},
		})
		local decoded = request.decodeJsonBody(response)
		test.expect(decoded.token):toBe("secret")
		test.expect(decoded.all.theme):toBe("light")

		local setCookie = response.headers["set-cookie"]
		test.expect(setCookie):toContain("session=abc123")
		test.expect(setCookie):toContain("HttpOnly")
		test.expect(setCookie):toContain("SameSite=Lax")
		test.expect(setCookie):toContain("theme=dark")
		test.expect(setCookie):toContain("Max-Age=60")
	end)
end)

suite:test("clearCookie appends an expired cookie header", function()
	local app = App.new()
	app:get("/logout", function(ctx)
		ctx:clearCookie("session", {
			path = "/",
			httpOnly = true,
		})
		return "ok"
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/logout")
		local setCookie = response.headers["set-cookie"]
		test.expect(setCookie):toContain("session=")
		test.expect(setCookie):toContain("Max-Age=0")
		test.expect(setCookie):toContain("Expires=")
		test.expect(setCookie):toContain("Path=/")
		test.expect(setCookie):toContain("HttpOnly")
	end)
end)

suite:test("sendFile streams a file response with inferred content type", function()
	local app = App.new()
	app:get("/download", function(ctx)
		ctx:sendFile("src/modules/http/testdata/static/app.js")
	end)

	withApp(app, function(url)
		local response = request.get(url .. "/download")
		test.expect(response.status):toBe(200)
		test.expect(response.headers["content-type"]):toContain("application/javascript")
		test.expect(response.body):toContain("hello static")
	end)
end)

suite:test("websocket routes upgrade and handle messages", function()
	local app = App.new()
	app:websocket("/ws", function(ctx, ws)
		local msg = ws:receive()
		if msg ~= nil then
			ws:send("echo:" .. msg.data)
		end
		ws:close()
	end)

	withApp(app, function(url)
		local wsUrl = string.gsub(url, "^http://", "ws://") .. "/ws"
		local ws = websocket.connect(wsUrl)
		ws:send("hello")
		local msg = ws:receive()
		test.expect(msg):toNotBeNil()
		test.expect(msg.data):toBe("echo:hello")
		ws:close()

		local notUpgrade = request.get(url .. "/ws")
		test.expect(notUpgrade.status):toBe(426)
		test.expect(notUpgrade.headers["upgrade"]):toBe("websocket")
	end)
end)

return suite
