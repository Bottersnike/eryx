# Forms and Multipart

HTTP applications spend a lot of time exchanging structured bodies. The `@eryx/http` library includes helpers for the most common formats on both the client and server sides.

## URL-Encoded Forms

### Sending

```luau
local http = require("@eryx/http")

local response = http.post("https://example.com/login", nil, {
    form = {
        username = "alice",
        password = "secret",
    },
})
```

This automatically:

- encodes the body as `application/x-www-form-urlencoded`
- sets `content-type` if you did not already supply one

### Receiving on the Server

Incoming URL-encoded forms are parsed for you:

```luau
local server = http.HttpServer.new(function(req, res)
    local form = req.form or {}
    local username = form.username

    res:send(200, "hello " .. tostring(username))
end)
```

You can also decode a buffered response body manually:

```luau
local response = http.get("https://example.com/form-endpoint")
local form = http.decodeFormBody(response)
```

## Query Strings

The same encoding rules are often useful outside of bodies.

```luau
local http = require("@eryx/http")

local query = http.parseQuery("tag=a&tag=b&page=2")
print(query.page)
```

On the server, query parsing is already reflected on `req.query`.

## Multipart Form Data

### Sending Multipart Bodies

Use `multipart = { ... }` when you want to send mixed fields and files.

```luau
local response = http.post("https://example.com/upload", nil, {
    multipart = {
        { name = "username", value = "alice" },
        {
            name = "avatar",
            value = imageBytes,
            filename = "avatar.png",
            contentType = "image/png",
        },
    },
})
```

The multipart body and boundary header are generated automatically.

### Manual Multipart Encoding

If you want to build the body yourself, use `http.multipartEncode(...)`:

```luau
local body, contentType = http.multipartEncode({
    { name = "file", value = fileData, filename = "report.txt" },
})
```

### Receiving Multipart on the Server

Incoming multipart requests are parsed into `req.multipart`:

```luau
local server = http.HttpServer.new(function(req, res)
    for _, field in req.multipart or {} do
        print(field.name, field.filename, field.contentType)
    end

    res:send(200, "ok")
end)
```

### Decoding Multipart Responses

If a server returns a multipart response, you can decode it explicitly:

```luau
local response = http.get("https://example.com/bundle")
local parts = http.decodeMultipartBody(response)
```

You can also decode raw multipart bodies with `http.multipartDecode(body, boundary)`.

## JSON

JSON is simple enough that it is easy to forget it is also part of the "structured body" story.

### Sending JSON

```luau
local response = http.post("https://example.com/api", nil, {
    json = {
        ok = true,
        count = 3,
    },
})
```

### Receiving JSON

```luau
local response = http.get("https://example.com/api")
local data = http.decodeJsonBody(response)
```

On the server, buffered requests can read JSON directly from `req.body`, and streamed request-body mode can decode it on demand:

```luau
local server = http.HttpServer.new(function(req, res)
    local data = req:readJson()
    res:send(200, tostring(data.ok))
end, {
    streamRequestBodies = true,
})
```

## Lower-Level Helpers

The library also exposes lower-level helpers directly:

- `http.formEncode(table)`
- `http.formDecode(string)`
- `http.parseQuery(string)`
- `http.multipartEncode(fields)`
- `http.multipartDecode(body, boundary)`

These are useful when you need the encoding tools without making an HTTP request at the same time.
