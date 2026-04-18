# HTTP Recipes

This page collects a few copy-paste patterns for common tasks.

## JSON API Client

```luau
local http = require("@eryx/http")

local function getJson(url: string): any
    local response = http.get(url)
    http.raiseForStatus(response)
    return http.decodeJsonBody(response)
end

local profile = getJson("https://api.example.com/profile")
print(profile.name)
```

## Shared Login Session

```luau
local http = require("@eryx/http")

local session = http.Session.new()

local login = session:post("https://example.com/login", nil, {
    form = {
        username = "alice",
        password = "secret",
    },
})
http.raiseForStatus(login)

local dashboard = session:get("https://example.com/dashboard")
print(dashboard.status)

session:close()
```

## Bounded Session Pool

```luau
local http = require("@eryx/http")

local session = http.Session.new({
    idleTimeout = 15,
    maxConnectionsPerHost = 4,
})

local a = session:get("https://api.example.com/a")
local b = session:get("https://api.example.com/b")

session:evict("https://api.example.com/")
session:close()
```

## Download a Large File Incrementally

```luau
local fs = require("@eryx/fs")
local http = require("@eryx/http")

local file = fs.open("download.bin", "w")
local response = http.stream("GET", "https://example.com/large.bin")

while true do
    local chunk = response:read(64 * 1024)
    if chunk == "" then
        break
    end
    file:write(chunk)
end

file:close()
```

## Upload from a Reader

```luau
local fs = require("@eryx/fs")
local http = require("@eryx/http")

local file = fs.open("video.mp4", "r")
local size = file:size()

local response = http.request("PUT", "https://example.com/video", {
    bodyStream = {
        read = function(self, n)
            return file:read(n)
        end,
    },
    bodyLength = size,
    expectContinue = true,
})

file:close()
http.raiseForStatus(response)
```

## Stream an Incoming Upload on the Server

```luau
local http = require("@eryx/http")

local server = http.HttpServer.new(function(req, res)
    local stream = req.bodyStream
    local total = 0

    while true do
        local chunk = stream:read(64 * 1024)
        if chunk == "" then
            break
        end
        total += #chunk
    end

    res:send(200, "received " .. tostring(total) .. " bytes")
end, {
    port = 8080,
    streamRequestBodies = true,
})
```

## Long-Poll Endpoint

```luau
local http = require("@eryx/http")
local task = require("@eryx/task")

local server = http.HttpServer.new(function(req, res)
    res:holdOpen()

    task.delay(10, function()
        res:json(200, '{"ready":true}')
    end)
end, {
    port = 8080,
})
```

## Stream a Generated Response

```luau
local http = require("@eryx/http")

local server = http.HttpServer.new(function(req, res)
    local index = 0
    local chunks = { "hello", " ", "world" }

    res:status(200)
    res:header("content-type", "text/plain")
    res:trailer("x-checksum", "ok")
    res:sendStream({
        read = function(self, size)
            index += 1
            return chunks[index] or ""
        end,
    })
end, {
    port = 8080,
})
```

## Small Routed App

```luau
local http = require("@eryx/http")

local app = http.createApp()

app:get("/", function()
    return "hello"
end)

app:get("/users/:id", function(ctx)
    return {
        id = ctx.params.id,
    }
end)

app:listen(nil, { port = 8080 })
```

## Mount Routes From Another Folder

```luau
-- routes/api/init.luau
local http = require("@eryx/http")

local api = http.createRouter()
api:get("/projects/:id", function(ctx)
    return { id = ctx.params.id }
end)

return api
```

```luau
-- main.luau
local http = require("@eryx/http")
local api = require("./routes/api")

local app = http.createApp()
app:mount("/api", api)
app:listen(nil, { port = 8080 })
```

## Serve Static Files

```luau
local http = require("@eryx/http")

local app = http.createApp()
app:static("/assets", "public", {
    indexFile = "index.html",
})

app:listen(nil, { port = 8080 })
```

## WebSocket Route

```luau
local http = require("@eryx/http")

local app = http.createApp()
app:websocket("/ws", function(ctx, ws)
    while true do
        local msg = ws:receive()
        if msg == nil then
            break
        end
        ws:send("echo:" .. msg.data)
    end
end)

app:listen(nil, { port = 8080 })
```

## Server-Side Sessions

```luau
local http = require("@eryx/http")

local app = http.createApp()
app:useSessions({
    store = http.createMemorySessionStore(),
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

app:listen(nil, { port = 8080 })
```

## Server With Request Limits

```luau
local http = require("@eryx/http")

local server = http.HttpServer.new(function(req, res)
    res:send(200, "ok")
end, {
    port = 8080,
    maxHeaderBytes = 16 * 1024,
    maxBodyBytes = 2 * 1024 * 1024,
    keepAliveTimeout = 5,
    maxRequestsPerConnection = 100,
})
```

## Manual Multipart Construction

```luau
local http = require("@eryx/http")

local body, contentType = http.multipartEncode({
    { name = "title", value = "Quarterly report" },
    { name = "file", value = reportBytes, filename = "report.pdf", contentType = "application/pdf" },
})

local response = http.post("https://example.com/upload", body, {
    headers = {
        ["Content-Type"] = contentType,
    },
})
```

## When in Doubt

Use this rule of thumb:

- reach for `http.get()` and `http.post()` first
- move to `http.Session` when requests become repeated or stateful
- move to `http.stream()` when bodies become large
- move to `http.HttpConnection` only when you truly want transport-level control
