# Client Requests

For most scripts, the top-level functions on [[@eryx/http]] are the right place to start.

## Basic Requests

```luau
local http = require("@eryx/http")

local response = http.get("https://example.com/")
print(response.status, response.reason)
print(response.body)
```

The one-shot helpers open a connection, send the request, read the response, and close the connection again.

Buffered responses expose:

- `status`
- `reason`
- `headers`
- `trailers`
- `body`
- `httpVersion`

Available helpers:

- `http.request(method, url, options)`
- `http.get(url, options)`
- `http.post(url, body?, options)`
- `http.put(url, body?, options)`
- `http.delete(url, options)`
- `http.head(url, options)`

## Request Options

`http.request()` accepts a single options table. The most commonly used fields are:

| Option | Purpose |
| ---- | ---- |
| `headers` | Extra request headers |
| `query` | Query string parameters appended to the URL |
| `body` | Raw request body string |
| `form` | URL-encoded request body |
| `json` | JSON-encoded request body |
| `multipart` | Multipart form-data body |
| `bodyStream` | Incremental upload source |
| `bodyLength` | Required when a streamed body has a known fixed size |
| `cookies` | Shared cookie jar |
| `timeout` | One timeout applied to connect, read, and write |
| `connectTimeout` | Timeout used while opening the connection |
| `readTimeout` | Timeout used while waiting for response bytes |
| `writeTimeout` | Timeout used while sending the request |
| `verifySsl` | Enable or disable TLS certificate verification |
| `maxRedirects` | Redirect limit |
| `decompress` | Automatic response decompression |
| `expectContinue` | Send `Expect: 100-continue` |

Only one body source should be supplied at a time. For example, `body` and `json` should not both be set.

If you set both `timeout` and a more specific timeout like `readTimeout`, the specific value wins for that phase.

## Timeout Control

For many scripts, one timeout is enough:

```luau
local response = http.get("https://example.com/api", {
    timeout = 5,
})
```

When you need more control, you can split the phases:

```luau
local response = http.get("https://example.com/report", {
    connectTimeout = 2,
    writeTimeout = 5,
    readTimeout = 30,
})
```

That pattern is useful when:

- the server should accept connections quickly
- uploads should fail fast if the socket stalls
- the response itself may legitimately take longer, like a report, long-poll, or streamed download

## JSON Requests

```luau
local http = require("@eryx/http")

local response = http.post("https://api.example.com/items", nil, {
    json = {
        name = "widget",
        enabled = true,
    },
})

http.raiseForStatus(response)
local item = http.decodeJsonBody(response)
print(item.id)
```

When `json = ...` is used, the request body is encoded automatically and `content-type: application/json` is set if you did not provide your own.

## Query Strings

```luau
local response = http.get("https://example.com/search", {
    query = {
        q = "eryx",
        page = 2,
        exact = true,
    },
})
```

The `query` table is encoded onto the URL for you.

## Forms

```luau
local response = http.post("https://example.com/login", nil, {
    form = {
        username = "alice",
        password = "secret",
    },
})
```

This produces an `application/x-www-form-urlencoded` body automatically.

## Redirects and Errors

Buffered request helpers follow redirects by default. If you want failures to turn into exceptions, use `http.raiseForStatus()`:

```luau
local response = http.get("https://example.com/missing")
http.raiseForStatus(response)
```

This raises for `4xx` and `5xx` responses.

## Cookies

```luau
local http = require("@eryx/http")
local jar = http.CookieJar.new()

http.get("https://example.com/login", {
    cookies = jar,
})

local response = http.get("https://example.com/dashboard", {
    cookies = jar,
})
```

When a cookie jar is present:

- matching cookies are attached to outgoing requests
- `Set-Cookie` headers from responses are stored back into the jar

## Automatic Decompression

Buffered request helpers automatically advertise and decode:

- `gzip`
- `deflate`
- `br`

Set `decompress = false` if you want the raw compressed bytes instead.

## Response Trailers

If a chunked response includes trailer headers, they are exposed on `response.trailers` after the body has been read:

```luau
local response = http.get("https://example.com/export")
print(response.trailers["x-checksum"])
```

## HEAD Requests

`http.head()` returns the response headers without reading a response body, even if the server includes a misleading `Content-Length`.

```luau
local response = http.head("https://example.com/file.zip")
print(response.headers["content-length"])
```

If you are moving beyond simple request-response flows, continue with [[Sessions and Streaming]].
