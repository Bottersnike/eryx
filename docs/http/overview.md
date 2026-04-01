# HTTP in Eryx

[[http|@eryx/http]] is Eryx's HTTP/1.1 client and server library. It is designed to cover the common "just make a request" workflow, but it also scales down into lower-level transport control when you need connection reuse, streaming, long-polling, or protocol-aware server behavior.

At a high level, the module gives you five layers:

1. One-shot client helpers like `http.get()` and `http.post()`.
2. Pooled client sessions with `http.Session`.
3. Low-level persistent transports with `http.HttpConnection`.
4. An HTTP server with `http.HttpServer`.
5. A higher-level routed app layer with `http.App`.

## The Quickest Start

```luau
local http = require("@eryx/http")

local response = http.get("https://httpbin.org/json")
http.raiseForStatus(response)

local data = http.decodeJsonBody(response)
print(data.slideshow.title)
```

That is the "requests-style" path: make a request, get a buffered response, decode it, move on.

## What the Module Handles for You

The client side already covers a lot of HTTP behavior that you normally only notice when it breaks:

- Redirect handling.
- Cookie jars.
- Gzip, deflate, and Brotli response decompression.
- `Expect: 100-continue`.
- `HEAD` responses with no body reads.
- Chunked transfer decoding and trailers.
- Multipart and URL-encoded form helpers.
- Keep-alive connections and pooled sessions.
- Session retry on stale keep-alive reuse for safe requests.
- Incremental streamed request and response bodies.
- Per-phase connect, read, and write timeout control.

The server side also handles a meaningful amount of protocol detail:

- HTTP/1.1 `Host` validation.
- Chunked request bodies.
- Parsed query strings, forms, and multipart bodies.
- Optional streamed request-body handling for large uploads.
- Automatic `100 Continue` replies when appropriate.
- Keep-alive connection loops.
- Header and body size limits.
- Correct body suppression for `HEAD`, `1xx`, `204`, and `304`.

## Which API Should I Use?

Use `http.get()`, `http.post()`, and `http.request()` when:

- you are making one request at a time
- buffering the full response body is fine
- you do not need connection reuse

Use `http.stream()` when:

- the response body may be large
- you want to process chunks incrementally
- you still want the convenience one-shot client surface

Use `http.Session` when:

- you are talking to the same host repeatedly
- you want pooled keep-alive connections
- you want one cookie jar shared across many requests
- you want streaming and reuse together

Use `http.HttpConnection` when:

- you need direct control over a single persistent connection
- you are implementing a custom higher-level client flow
- you want to manually coordinate requests and streamed responses

Use `http.HttpServer` when:

- you are serving HTTP or HTTPS directly
- you want parsed request bodies and lower-level response control
- you need long-poll or chunked response streaming

Use `http.App` when:

- you want Flask/FastAPI-style routing and middleware
- you want groups, mounted sub-apps, or named routes
- you want static-file serving without manually reading files
- you want app-level WebSocket routes or server-side sessions

## Suggested Reading Order

- [[Client Requests|./client]] for everyday client usage.
- [[Sessions and Streaming|./sessions-and-streaming]] for reuse and large bodies.
- [[Server|./server]] for serving requests.
- [[App|./app]] for higher-level routed servers.
- [[Forms and Multipart|./forms-and-multipart]] for structured request and response bodies.
- [[Recipes|./recipes]] for copy-paste patterns.
