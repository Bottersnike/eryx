# Stdlib Expansion Roadmap

This document proposes new modules that would push the runtime closer to a truly "complete" standard library in the spirit of mature ecosystems like Python, while still respecting Luau's strengths:

- tables already cover a lot of light data-structuring needs
- APIs should prefer simple functional/table-based design over heavy object ceremony
- modules should feel pragmatic, portable, and composable

This is not an audit of current modules. It is a forward-looking roadmap of what to add next.

## Design Principles

- Prefer `path` over a heavy Python-style `pathlib` clone
- Prefer focused modules over giant kitchen-sink utility modules
- Do not duplicate what Luau tables already do well
- Expose both simple and advanced layers where appropriate
- Make runtime capability discovery a first-class feature

---

## Tier 1: Must-Have

These are the highest-value additions for everyday application development.

### `shutil`

Purpose:

- high-level filesystem operations

Suggested API:

```luau
local shutil = require("@eryx/shutil")

shutil.copy("a.txt", "b.txt")
shutil.copytree("src", "dist")
shutil.move("build/output", "release/output")
shutil.rmtree(".cache/tmp")
shutil.mirror("assets", "dist/assets")
```

Likely exports:

- `copy(src, dst, options?)`
- `copytree(src, dst, options?)`
- `move(src, dst, options?)`
- `remove(path)`
- `rmtree(path, options?)`
- `mirror(src, dst, options?)`
- `which(command)`

### `toml`

Purpose:

- modern configuration format support

Suggested API:

```luau
local toml = require("@eryx/toml")

local data = toml.decode([[
title = "App"
[server]
port = 8080
]])

local text = toml.encode({
    title = "App",
    server = { port = 8080 },
})
```

Likely exports:

- `decode(text)`
- `encode(value, options?)`
- `decodeFile(path)`
- `encodeFile(path, value, options?)`

### `url`

Purpose:

- full URL parsing/building, beyond percent-encoding helpers

Suggested API:

```luau
local url = require("@eryx/url")

local u = url.parse("https://example.com:8443/a/b?x=1#frag")
print(u.scheme, u.host, u.port, u.path, u.query, u.fragment)

url.format(u)
url.join("https://example.com/api/", "../v1/users")
url.withQuery("https://example.com", { q = "hello", page = 2 })
```

Likely exports:

- `parse(value)`
- `format(parts)`
- `join(base, relative)`
- `withQuery(value, query)`
- `parseQuery(value)`
- `formatQuery(tbl)`
- `normalize(value, options?)`

### `env`

Purpose:

- typed environment loading

Suggested API:

```luau
local env = require("@eryx/env")

local cfg = env.load({
    PORT = env.number({ default = 8080 }),
    DEBUG = env.boolean({ default = false }),
    DATABASE_URL = env.string({ required = true }),
})
```

Likely exports:

- `load(schema)`
- `string(options?)`
- `number(options?)`
- `boolean(options?)`
- `enum(values, options?)`
- `json(options?)`

### `retry`

Purpose:

- retries, exponential backoff, jitter, deadlines

Suggested API:

```luau
local retry = require("@eryx/retry")

local result = retry.run(function(attempt)
    return flakyCall()
end, {
    attempts = 5,
    backoff = "exponential",
    minDelay = 0.1,
    maxDelay = 2,
    jitter = true,
})
```

Likely exports:

- `run(fn, options?)`
- `forever(fn, options?)`
- `sleep(attempt, options?)`
- predicates/helpers for retryable errors

### `cache`

Purpose:

- in-memory caches and memoization

Suggested API:

```luau
local cache = require("@eryx/cache")

local c = cache.lru({ maxEntries = 1000 })
c:set("a", 1)
c:get("a")

local ttl = cache.ttl({ ttl = 60 })
local memoized = cache.memoize(function(x)
    return expensive(x)
end)
```

Likely exports:

- `lru(options?)`
- `ttl(options?)`
- `memoize(fn, options?)`
- `file(options?)`

Likely cache methods:

- `:get(key)`
- `:set(key, value)`
- `:delete(key)`
- `:clear()`
- `:has(key)`

### `cli`

Purpose:

- terminal UX for tools

Suggested API:

```luau
local cli = require("@eryx/cli")

print(cli.color("hello", "green"))
cli.table({
    { "Name", "Score" },
    { "Ada", 100 },
})

local bar = cli.progress({ total = 100 })
bar:advance(10)
bar:finish()
```

Likely exports:

- `color(text, style)`
- `style(text, options)`
- `table(rows, options?)`
- `progress(options?)`
- `spinner(options?)`
- `prompt(text, options?)`
- `confirm(text, options?)`

### `schema`

Purpose:

- validation/coercion of untrusted or loosely typed input

Suggested API:

```luau
local schema = require("@eryx/schema")

local User = schema.object({
    id = schema.string(),
    age = schema.number({ min = 0 }),
    admin = schema.boolean({ default = false }),
})

local value = User:parse(input)
```

Likely exports:

- `string(options?)`
- `number(options?)`
- `boolean(options?)`
- `array(inner, options?)`
- `object(shape, options?)`
- `union(options)`
- `literal(value)`
- `optional(inner)`
- `nullable(inner)`

## Tier 2: Strong Differentiators

These are less universally urgent, but would make the platform feel rich and unusually capable.

### `archive`

Purpose:

- unified archive handling

Suggested API:

```luau
local archive = require("@eryx/archive")

archive.pack("dist", "dist.tar.gz")
archive.unpack("release.zip", "release/")
archive.list("release.zip")
```

Likely exports:

- `pack(src, dst, options?)`
- `unpack(src, dst, options?)`
- `list(src, options?)`

### `email`

Purpose:

- MIME construction and parsing

Suggested API:

```luau
local email = require("@eryx/email")

local msg = email.message({
    from = "a@example.com",
    to = { "b@example.com" },
    subject = "Hello",
    text = "Plain body",
    html = "<b>Hello</b>",
})

local raw = msg:render()
local parsed = email.parse(raw)
```

Likely exports:

- `message(fields)`
- `parse(raw)`
- `attachment(options)`

### `dns`

Purpose:

- DNS queries and helpers

Suggested API:

```luau
local dns = require("@eryx/dns")

dns.lookup("example.com")
dns.resolve("example.com", "MX")
dns.reverse("8.8.8.8")
```

Likely exports:

- `lookup(host, options?)`
- `resolve(name, rrtype, options?)`
- `reverse(addr, options?)`

### `metrics`

Purpose:

- counters, gauges, histograms, timers

Suggested API:

```luau
local metrics = require("@eryx/metrics")

local requests = metrics.counter("http_requests_total")
requests:inc()

local latency = metrics.histogram("http_latency_seconds")
latency:observe(0.12)
```

Likely exports:

- `counter(name, options?)`
- `gauge(name, options?)`
- `histogram(name, options?)`
- `timer(name, options?)`
- `registry()`

### `trace`

Purpose:

- structured tracing/spans

Suggested API:

```luau
local trace = require("@eryx/trace")

trace.withSpan("request", function(span)
    span:set("path", "/users")
    doWork()
end)
```

Likely exports:

- `span(name, options?)`
- `withSpan(name, fn, options?)`
- `currentSpan()`

### `benchmark`

Purpose:

- microbenchmarking and perf comparisons

Suggested API:

```luau
local benchmark = require("@eryx/benchmark")

benchmark.run("json encode", function()
    json.encode(data)
end)
```

Likely exports:

- `run(name, fn, options?)`
- `compare(cases, options?)`

### `diff`

Purpose:

- textual and structured diffs

Suggested API:

```luau
local diff = require("@eryx/diff")

diff.text("a\nb\n", "a\nc\n")
diff.lines(left, right)
diff.table(oldValue, newValue)
```

### `unicode`

Purpose:

- Unicode normalization and classification

Suggested API:

```luau
local unicode = require("@eryx/unicode")

unicode.normalize("NFC", text)
unicode.isLetter("a")
unicode.graphemes(text)
```

### `text`

Purpose:

- general string/text helpers not covered by core libs

Suggested API:

```luau
local text = require("@eryx/text")

text.slug("Hello World")
text.wrap(longText, 80)
text.indent(text, 4)
text.truncate(text, 120)
```

### `collections`

Purpose:

- data structures tables do not naturally provide well

Suggested API:

```luau
local collections = require("@eryx/collections")

local deque = collections.deque()
deque:pushRight(1)
deque:pushLeft(0)
deque:popLeft()

local counter = collections.counter({ "a", "b", "a" })
print(counter:get("a"))
```

Likely exports:

- `deque()`
- `counter(iterableOrMap?)`
- `priorityQueue(options?)`
- maybe `defaultMap(factory)`

### `enum`

Purpose:

- symbolic constants and flags

Suggested API:

```luau
local enum = require("@eryx/enum")

local Color = enum.new({ "Red", "Green", "Blue" })
print(Color.Red)
```

### `x509`

Purpose:

- high-level certificate parsing/building above ASN.1/PEM

Suggested API:

```luau
local x509 = require("@eryx/x509")

local cert = x509.parsePem(pem)
print(cert.subject, cert.issuer)
```

### `signing`

Purpose:

- signed blobs/messages without exposing low-level crypto choices

Suggested API:

```luau
local signing = require("@eryx/signing")

local token = signing.sign(secret, payload)
local payload = signing.verify(secret, token)
```

### Desktop helpers

Potential modules:

- `clipboard`
- `dialog`
- `notification`
- `watch`

Suggested APIs:

```luau
local clipboard = require("@eryx/clipboard")
clipboard.writeText("hello")
clipboard.readText()

local dialog = require("@eryx/dialog")
dialog.openFile()
dialog.saveFile()
dialog.alert("Done")
```

---

## Tier 3: Ambitious Extras

These are powerful, but either specialized or large in scope.

### Networking and protocols

- `http2`
- `sse`
- `rpc`
- `oauth`
- `smtp`
- `imap`
- `ftp`

Mock API example:

```luau
local rpc = require("@eryx/rpc")

local client = rpc.connect("https://api.example.com/rpc")
client:call("sum", { 1, 2, 3 })
```

### Serialization and config extras

- `msgpack`
- `protobuf`
- `plist`
- `dotenv`

Mock API example:

```luau
local dotenv = require("@eryx/dotenv")
dotenv.load(".env")
```

### Systems and resource introspection

- `resource`
- `system`

Mock API example:

```luau
local system = require("@eryx/system")

system.hostname()
system.cpus()
system.memory()
system.networkInterfaces()
```

### Security extras

- `jwt`
- `ssh`
- `keyring`
- `totp`
- `csrf`

Mock API example:

```luau
local totp = require("@eryx/totp")

local secret = totp.generateSecret()
totp.code(secret)
totp.verify(secret, input)
```

### Parsing and search

- `search`
- `parser`
- `importlib`

Mock API example:

```luau
local search = require("@eryx/search")

search.fuzzy("helo", { "hello", "world" })
```
