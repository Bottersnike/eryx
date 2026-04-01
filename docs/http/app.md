# HTTP App

`http.App` is the higher-level server layer built on top of `http.HttpServer`. It is the better fit when you want Flask- or FastAPI-style routing, middleware, grouped endpoints, mounted sub-apps, named routes, and static files.

## Quick Start

```luau
local http = require("@eryx/http")

local app = http.createApp()

app:get("/", function()
    return "hello from the app layer"
end)

app:get("/users/:id", function(ctx)
    return {
        id = ctx.params.id,
        page = ctx.query.page,
    }
end, {
    name = "users.show",
})

app:listen(nil, {
    host = "127.0.0.1",
    port = 8080,
})
```

Handlers can:

- return a string for a plain-text response
- return a table for an automatic JSON response
- return `status, body, headers`
- call `ctx:text(...)`, `ctx:html(...)`, `ctx:jsonResponse(...)`, or `ctx:redirect(...)`
- read request cookies from `ctx.cookies` or `ctx:cookie(name)`
- write response cookies with `ctx:setCookie(...)` and `ctx:clearCookie(...)`
- stream files with `ctx:sendFile(...)`
- drop down to `ctx.response` for full low-level control

## Middleware

Middleware receives `(ctx, next)` and wraps the rest of the pipeline.

```luau
app:use(function(ctx, next)
    local started = os.clock()
    ctx.response:header("x-powered-by", "eryx")

    local result = next()

    print(ctx.request.method, ctx.originalPath, os.clock() - started)
    return result
end)
```

Middleware order is onion-style:

1. Parent app middleware
2. Group or mounted child middleware
3. Route-local middleware
4. Route handler
5. Route-local post-processing
6. Child post-processing
7. Parent post-processing

## Route-Local Middleware

Use `options.middleware` when behavior only belongs to one endpoint or a small set of endpoints.

```luau
local requireAuth = function(ctx, next)
    if ctx.request.headers["authorization"] == nil then
        return {
            status = 401,
            json = { error = "missing auth" },
        }
    end
    return next()
end

app:get("/private", function(ctx)
    return { ok = true }
end, {
    middleware = { requireAuth },
})
```

This is a good fit for:

- auth checks
- per-route rate limiting
- endpoint-specific validation gates
- instrumentation that should not apply globally

## Groups and Mounted Routers

Use `group()` when you want a prefixed child router in the same file:

```luau
local api = app:group("/api")

api:use(function(ctx, next)
    ctx.response:header("x-api", "1")
    return next()
end)

api:get("/users/:id", function(ctx)
    return { id = ctx.params.id }
end)
```

Use `mount()` when the child app lives somewhere else:

```luau
-- routes/api/init.luau
local http = require("@eryx/http")

local api = http.createRouter()
api:get("/users/:id", function(ctx)
    return { id = ctx.params.id }
end, {
    name = "api.users.show",
})

return api
```

```luau
-- main.luau
local http = require("@eryx/http")
local api = require("./routes/api")

local app = http.createApp()
app:mount("/api", api)
```

Mounted routes expose extra context:

| Field | Meaning |
| ---- | ---- |
| `ctx.mountPath` | Mount prefix such as `"/api"` |
| `ctx.pathWithinMount` | Path relative to the child app |
| `ctx.originalPath` | Original incoming request pathname |

## Named Routes and URL Generation

Name routes with `options.name`, then generate URLs with `urlFor()`.

```luau
app:get("/users/:id", showUser, {
    name = "users.show",
})

local url = app:urlFor("users.show", {
    id = "alice smith",
}, {
    page = 2,
})

print(url) -- /users/alice%20smith?page=2
```

This also works across mounted apps as long as the route name is unique.

## Error Handling

`error(status, handler)` replaces framework-generated status responses such as `404` and `405`.

```luau
app:error(404, function(ctx)
    return {
        status = 404,
        json = {
            message = "not found",
            path = ctx.originalPath,
        },
    }
end)
```

`onError(handler)` catches uncaught route or middleware exceptions:

```luau
app:onError(function(ctx, err)
    return {
        status = 500,
        json = {
            error = tostring(err),
            path = ctx.originalPath,
        },
    }
end)
```

## Static Files

Use `static()` to expose a directory under a URL prefix:

```luau
app:static("/assets", "public", {
    indexFile = "index.html",
    headers = {
        ["cache-control"] = "public, max-age=3600",
    },
})
```

Static mounts:

- only serve `GET`/`HEAD`
- infer `content-type` from the file extension
- reject path traversal attempts
- can optionally fall through to later routes

For one-off file responses inside a normal handler, use `ctx:sendFile(...)`:

```luau
app:get("/download", function(ctx)
    ctx:sendFile("build/report.pdf", {
        filename = "report.pdf",
    })
end)
```

## WebSockets

Use `app:websocket()` to register a route that upgrades through `@eryx/websocket`.

```luau
app:websocket("/ws", function(ctx, ws)
    while true do
        local msg = ws:receive()
        if msg == nil then
            break
        end
        ws:send("echo:" .. msg.data)
    end
end, {
    websocket = {
        compress = true,
        heartbeat = 30,
    },
})
```

If a normal HTTP request hits a WebSocket route without a valid upgrade, the app returns `426 Upgrade Required`.

## Cookies

The app layer exposes parsed request cookies and helpers for `Set-Cookie`.

```luau
app:get("/profile", function(ctx)
    local sessionId = ctx:cookie("session")
    if sessionId == nil then
        return { status = 401, json = { error = "missing session" } }
    end

    ctx:setCookie("last_seen", "now", {
        path = "/",
        httpOnly = true,
        sameSite = "Lax",
    })

    return { sessionId = sessionId }
end)
```

To clear a cookie:

```luau
app:get("/logout", function(ctx)
    ctx:clearCookie("session", {
        path = "/",
        httpOnly = true,
    })
    return "ok"
end)
```

## Server-Side Sessions

`app:useSessions(...)` adds `ctx.session` backed by a pluggable store.

```luau
local http = require("@eryx/http")

local app = http.createApp()
app:useSessions({
    store = http.createMemorySessionStore(),
    cookieName = "sid",
    ttl = 7 * 24 * 60 * 60,
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
```

Available store options:

- `http.createMemorySessionStore()`
- `http.createFileSessionStore(directory)`
- `http.createSqliteSessionStore(pathOrDb, tableName?)`
- a custom store implementing `get(id)`, `set(id, data, expiresAt)`, and `delete(id)`

Useful session methods:

- `ctx.session:get(key)`
- `ctx.session:set(key, value)`
- `ctx.session:delete(key)`
- `ctx.session:clear()`
- `ctx.session:regenerate()`
- `ctx.session:destroy()`

## When To Use `App` vs `HttpServer`

Use `http.App` when:

- you want routing and middleware
- your application is endpoint-oriented
- you want grouped APIs and mounted modules

Use `http.HttpServer` directly when:

- you need total control over request handling
- you want streaming or protocol work without a framework layer
- you are building a custom server abstraction
