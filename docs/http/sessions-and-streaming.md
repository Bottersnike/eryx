# Sessions and Streaming

The next step up from one-shot helpers is to keep connections alive and stop buffering everything.

## Sessions

`http.Session` keeps a pool of reusable connections keyed by scheme, host, and port. It also carries a shared cookie jar by default.

```luau
local http = require("@eryx/http")

local session = http.Session.new({
    timeout = 10,
    readTimeout = 30,
    idleTimeout = 30,
    maxConnectionsPerHost = 4,
})

local a = session:get("https://api.example.com/profile")
local b = session:get("https://api.example.com/preferences")

session:close()
```

Use a session when:

- you are sending many requests to the same host
- you want connection reuse
- you want one shared cookie jar
- you want to mix buffered and streaming requests on the same client

## Session Pool Controls

Sessions are now bounded per origin rather than implicitly acting like a single reusable socket.

Useful options:

| Option | Meaning |
| ---- | ---- |
| `timeout` | Default timeout applied to connect, read, and write |
| `connectTimeout` | Default timeout while opening pooled sockets |
| `readTimeout` | Default timeout while waiting for response bytes |
| `writeTimeout` | Default timeout while sending request bytes |
| `idleTimeout` | Close idle pooled connections after this many seconds |
| `maxConnectionsPerHost` | Maximum pooled connections per scheme/host/port |

If every pooled connection for one origin is currently busy with an active streamed response and the limit is reached, the next request to that same origin will fail instead of reusing an unsafe socket.

Per-request timeout overrides still apply even when a session reuses an existing keep-alive socket. A reused pooled connection adopts the current request's timeout settings before it is used again.

## Stale Keep-Alive Recovery

Some servers close keep-alive sockets quietly while the client still thinks they are reusable. For safe requests like `GET`, `HEAD`, and `OPTIONS`, sessions now retry once on a fresh connection when that stale-reuse failure is detected before any response is received.

That means this common failure mode:

- request one succeeds
- server silently closes the socket
- request two tries to reuse it

is handled automatically for safe requests.

## Session Methods

The session mirrors the top-level client API:

- `session:request(method, url, options)`
- `session:get(url, options)`
- `session:post(url, body?, options)`
- `session:put(url, body?, options)`
- `session:delete(url, options)`
- `session:head(url, options)`
- `session:stream(method, url, options)`
- `session:close()`
- `session:evict(url?)`

`session:evict()` lets you explicitly discard pooled connections:

```luau
session:evict("https://api.example.com/")
```

Pass no argument to evict everything, which is equivalent to `session:close()`.

## Streaming Responses

Use `http.stream()` or `session:stream()` when you want incremental response reads.

```luau
local http = require("@eryx/http")

local response = http.stream("GET", "https://example.com/large-file")

while true do
    local chunk = response:read(64 * 1024)
    if chunk == nil then
        break
    end

    print("received", #chunk, "bytes")
end
```

A streamed response object exposes:

- `status`
- `reason`
- `headers`
- `trailers`
- `httpVersion`
- `:read(size?)`
- `:readAll()`
- `:close()`

## Important Streaming Rule

A streamed response owns the underlying connection until it is fully consumed or explicitly closed.

That means you should always do one of these:

1. Read until `:read()` returns `nil`.
2. Call `:readAll()`.
3. Call `:close()` when you are done early.

This matters most with sessions. If you abandon a streamed response halfway through and never close it, that connection cannot safely be reused.

## Streamed Decompression

Streaming requests still support automatic decompression when `decompress` is left enabled. Gzip, deflate, and Brotli responses are decoded incrementally before you see the chunks.

```luau
local response = http.stream("GET", "https://example.com/logs.gz")

while true do
    local chunk = response:read(4096)
    if chunk == nil then
        break
    end

    -- chunk is already decompressed text
end
```

If you want the raw compressed bytes, set `decompress = false`.

## Streaming Uploads

For large uploads, pass `bodyStream` instead of `body`.

```luau
local index = 0
local chunks = { "hello ", "streamed ", "world" }

local response = http.request("POST", "https://example.com/upload", {
    bodyStream = {
        read = function(self, size)
            index += 1
            return chunks[index]
        end,
    },
    bodyLength = 20,
})
```

If `bodyLength` is set, the client sends a fixed `Content-Length`.

If `bodyLength` is omitted, the client automatically falls back to chunked request framing:

```luau
local response = http.request("POST", "https://example.com/upload", {
    bodyStream = myReader,
})
```

The reader only needs a `read(size?)` method that returns:

- a string chunk when more bytes are available
- `nil` when the stream has ended

## Expect: 100-continue

For large uploads, `expectContinue = true` lets the server approve the request before the full body is sent.

```luau
local response = http.request("POST", "https://example.com/upload", {
    bodyStream = myReader,
    bodyLength = totalBytes,
    expectContinue = true,
})
```

This is especially useful when:

- authentication may fail
- the body is expensive to generate
- the body is very large

## When to Use HttpConnection Directly

`http.HttpConnection` is still useful when you want very explicit transport control.

```luau
local http = require("@eryx/http")

local conn = http.HttpConnection.new("example.com", 443, 10, "https")
conn:request("GET", "/stream")

local response = conn:getResponseStream()
print(response:read(128))
response:close()

conn:close()
```

Most applications should prefer `http.Session` unless they specifically want one manually managed connection.
