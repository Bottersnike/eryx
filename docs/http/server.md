# HTTP Server

`http.HttpServer` lets you serve HTTP or HTTPS directly from Luau.

If you want higher-level routing, middleware, named routes, groups, or mounted sub-apps, start with [[App|./app]] instead and treat `HttpServer` as the low-level escape hatch.

## Minimal Server

```luau
local http = require("@eryx/http")

local server = http.HttpServer.new(function(req, res)
    res:send(200, "Hello, world!\n", {
        ["Content-Type"] = "text/plain; charset=utf-8",
    })
end, {
    host = "127.0.0.1",
    port = 8080,
})

server:listen(function(host, port)
    print("Listening on " .. host .. ":" .. tostring(port))
end)
```

`listen()` blocks until the server is closed or interrupted.

## Request Shape

Incoming requests give you a parsed table with the most useful HTTP pieces already broken out:

```luau
local server = http.HttpServer.new(function(req, res)
    print(req.method)
    print(req.path)
    print(req.pathname)
    print(req.query.page)
    print(req.headers["user-agent"])

    res:send(200, "ok")
end)
```

Important request fields include:

| Field | Meaning |
| ---- | ---- |
| `method` | Request method such as `GET` or `POST` |
| `path` | Original request target |
| `pathname` | Path without the query string |
| `queryString` | Raw query part after `?` |
| `query` | Parsed query parameters |
| `httpVersion` | Usually `HTTP/1.1` |
| `headers` | Lowercased request headers |
| `trailers` | Trailer headers from chunked request bodies |
| `contentType` | Parsed media type from `content-type` |
| `body` | Buffered request body |
| `form` | Parsed URL-encoded form body when present |
| `multipart` | Parsed multipart body when present |
| `remoteAddr` | Peer IP address |
| `remotePort` | Peer port |

## Responses

The simplest response path is `res:send()`:

```luau
res:send(200, "Hello!")
```

You can also build a response step by step:

```luau
res
    :status(201)
    :header("content-type", "application/json")
    :finish('{"ok":true}')
```

Available response methods include:

- `:status(code, reason?)`
- `:header(name, value)`
- `:headers(table)`
- `:write(data)`
- `:finish(body?)`
- `:send(statusCode, body?, headers?)`
- `:sendStream(bodyStream, contentLength?)`
- `:json(statusCode, jsonString)`
- `:holdOpen()`
- `:trailer(name, value)`
- `:trailers(table)`

## Streaming Responses

If you do not provide `Content-Length`, the server will automatically use chunked transfer encoding for normal body-bearing responses.

```luau
res:status(200):header("content-type", "text/plain")
res:write("chunk 1\n")
res:write("chunk 2\n")
res:finish()
```

If you already have an incremental body reader, `sendStream()` lets you stream it directly:

```luau
res:status(200)
res:header("content-type", "text/plain")
res:sendStream({
    read = function(self, size)
        return nextChunkOrNil()
    end,
})
```

The stream object only needs a `read(size?)` method that returns a string chunk or `nil` at end-of-stream.

## Trailers

Chunked request bodies and chunked response bodies can now carry trailer headers.

Incoming request trailers are exposed on `req.trailers`. Outgoing response trailers can be queued before the response starts:

```luau
res:status(200)
res:trailer("x-checksum", checksum)
res:sendStream(myStream)
```

Trailers are only sent on chunked body-bearing responses.

## Long-Poll and Delayed Responses

By default, the server finishes a response automatically when your handler returns. If you want to answer later, call `holdOpen()` first.

```luau
local task = require("@eryx/task")

local server = http.HttpServer.new(function(req, res)
    res:holdOpen()

    task.delay(5, function()
        res:send(200, "event available")
    end)
end)
```

This is the building block for:

- long-poll endpoints
- delayed notifications
- server-side coordination across tasks

## Keep-Alive and Lifecycle Controls

The server can reuse connections across multiple requests automatically.

Useful constructor options:

| Option | Meaning |
| ---- | ---- |
| `host` | Bind address |
| `port` | Bind port |
| `backlog` | Listen backlog |
| `clientTimeout` | Timeout for the first request on a socket |
| `keepAliveTimeout` | Timeout between keep-alive requests |
| `maxRequestsPerConnection` | Cap requests served on one socket |
| `maxHeaderBytes` | Header size limit |
| `maxBodyBytes` | Body size limit |
| `streamRequestBodies` | Expose request bodies as a stream instead of prebuffering them |
| `sslCtx` | TLS context for HTTPS |

These are especially useful for production-style servers, where unbounded connections and bodies become operational problems very quickly.

## Streamed Request Bodies

By default, the server buffers request bodies and populates `req.body`, `req.form`, and `req.multipart` directly.

If you want to process large uploads incrementally, enable streamed request bodies:

```luau
local server = http.HttpServer.new(function(req, res)
    local stream = req.bodyStream
    local total = 0

    while true do
        local chunk = stream:read(64 * 1024)
        if chunk == nil then
            break
        end
        total += #chunk
    end

    res:send(200, tostring(total))
end, {
    port = 8080,
    streamRequestBodies = true,
})
```

In streamed mode:

- `req.bodyStream` is available
- `req:readBody()` buffers the full body on demand
- `req:readForm()` decodes URL-encoded form data on demand
- `req:readMultipart()` decodes multipart form data on demand
- `req:readJson()` decodes JSON bodies on demand
- `req.trailers` is populated after a chunked body has been fully consumed

This mode is a better fit for large uploads, hashing, proxying, and other incremental handlers.

## HTTPS

Pass an SSL context to serve HTTPS:

```luau
local http = require("@eryx/http")
local ssl = require("@eryx/_ssl")

local ctx = ssl.create_server_context("cert.pem", "key.pem")

local server = http.HttpServer.new(function(req, res)
    res:send(200, "secure")
end, {
    port = 8443,
    sslCtx = ctx,
})
```

## Protocol Behavior the Server Enforces

The server already handles several important HTTP/1.1 rules for you:

- missing `Host` on HTTP/1.1 requests is rejected
- `Transfer-Encoding` and `Content-Length` cannot be combined
- chunked request bodies are supported
- unsupported `Expect` values are rejected with `417`
- `100 Continue` is sent automatically when appropriate
- oversized headers and bodies are rejected
- response bodies are suppressed when the protocol requires that

For structured request bodies, continue with [[Forms and Multipart|./forms-and-multipart]].
