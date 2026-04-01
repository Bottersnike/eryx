local App = require("./App")
local CookieJar = require("./CookieJar")
local ServerSession = require("./ServerSession")
local _socket = require("@eryx/_socket")
local request = require("./request")
local sqlite3 = require("@eryx/sqlite3")
local task = require("@eryx/task")
local test = require("@eryx/test")

local suite = test.Suite.new("http server session")

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function withApp(app: App.App, run: (url: string) -> ())
	local port = reservePort()

	task.spawn(function()
		app:listen(nil, {
			host = "127.0.0.1",
			port = port,
			clientTimeout = 1,
		})
	end)
	task.wait(0.05)

	local ok, err = pcall(run, `http://127.0.0.1:{port}`)
	app:close()
	task.wait(0.05)
	if not ok then
		error(err)
	end
end

suite:test("memory-backed sessions persist across requests", function()
	local app = App.new()
	app:useSessions({
		store = ServerSession.memoryStore(),
		cookieName = "sid",
	})
	app:get("/login", function(ctx)
		ctx.session:set("user", "alice")
		return "ok"
	end)
	app:get("/me", function(ctx)
		return {
			user = ctx.session:get("user"),
		}
	end)

	local jar = CookieJar.new()
	withApp(app, function(url)
		local login = request.get(url .. "/login", { cookies = jar })
		test.expect(login.status):toBe(200)
		local me = request.get(url .. "/me", { cookies = jar })
		local decoded = request.decodeJsonBody(me)
		test.expect(decoded.user):toBe("alice")
	end)
end)

suite:test("custom stores can back sessions", function()
	local saved = {}
	local store = {
		get = function(self, id)
			return saved[id]
		end,
		set = function(self, id, data, expiresAt)
			saved[id] = {
				data = table.clone(data),
				expiresAt = expiresAt,
			}
		end,
		delete = function(self, id)
			saved[id] = nil
		end,
	}

	local app = App.new()
	app:useSessions({
		store = store,
		cookieName = "sid",
	})
	app:get("/set", function(ctx)
		ctx.session:set("ok", true)
		return "ok"
	end)
	app:get("/get", function(ctx)
		return {
			ok = ctx.session:get("ok"),
		}
	end)

	local jar = CookieJar.new()
	withApp(app, function(url)
		request.get(url .. "/set", { cookies = jar })
		local response = request.get(url .. "/get", { cookies = jar })
		local decoded = request.decodeJsonBody(response)
		test.expect(decoded.ok):toBeTrue()
	end)
end)

suite:test("filesystem-backed stores round-trip session records", function()
	local dir = ".cache/http-session-file-store"
	local store = ServerSession.fileStore(dir)
	store:set("abc", { user = "bob" }, 4102444800)
	local record = store:get("abc")
	test.expect(record):toNotBeNil()
	test.expect(record.data.user):toBe("bob")
	store:delete("abc")
end)

suite:test("sqlite-backed stores round-trip session records", function()
	local db = sqlite3.open(":memory:")
	local store = ServerSession.sqliteStore(db)
	store:set("abc", { user = "carol" }, 4102444800)
	local record = store:get("abc")
	test.expect(record):toNotBeNil()
	test.expect(record.data.user):toBe("carol")
	store:delete("abc")
	test.expect(store:get("abc")):toBeNil()
	db:close()
end)

return suite
