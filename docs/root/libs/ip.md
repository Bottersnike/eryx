# Working with IP addresses

The IP module has a lot of surface area, so this guide focuses on what to use in day-to-day code.

Use this when you want to:
- parse and validate IP input
- classify addresses (private, loopback, multicast, etc.)
- work with CIDR networks and containment
- convert between IPv4 and IPv6 mapped forms
- model non-prefix ranges and exclusions

For the full method-by-method reference, see [[ip|the API docs]].

## Quick start

```luau
local ip = require("@eryx/ip")

local addr = ip.address("192.168.1.10")
local net = ip.network("192.168.1.0/24")

if addr and net and net:contains(addr) then
    print("address is inside network")
end
```

## Which entry point should I use?

- `ip.address(str, opts?)`
Use this when the input must be a single IP address.

- `ip.network(str, opts?)`
Use this when the input must be CIDR/network notation.

- `ip.interface(str, opts?)`
Use this when you expect `address/prefix` interface strings.

- `ip.parse(str, opts?)`
Use this when input might be an address or network and you can branch on `value.version` and type.

- `ip.isAddress / ip.isNetwork / ip.isIPv4 / ip.isIPv6`
Use these for lightweight validation checks.

## Parsing policy (`strict`, `allowZoneId`)

Parsing accepts optional options:

```luau
local netLoose = ip.network("192.168.1.42/24", { strict = false })
local netStrict = ip.network("192.168.1.42/24", { strict = true })
-- netLoose -> 192.168.1.0/24
-- netStrict -> nil (host bits were set)

local linkLocal = ip.address("fe80::1%eth0", { allowZoneId = true })
```

Rule of thumb:
- Use `strict = true` for config ingestion and infrastructure declarations.
- Use `strict = false` for user-friendly parsing where normalization is acceptable.

## Address objects: when to use them

Address objects are best for:
- classification (`isPrivate`, `isLoopback`, `isGlobal`, etc.)
- ordering/comparison (`==`, `<`, `<=`)
- stepping (`next`, `previous`)
- reverse DNS pointer generation (`reverseUri`)

```luau
local a = ip.address("10.0.0.1")
local b = ip.address("10.0.0.2")

if a and b and a < b then
    print("sorted")
end

local net = a and (a / 24) -- address -> network via / prefix
```

## Network objects: when to use them

Network objects are best for:
- containment and overlap (`contains`, `containsNetwork`, `overlaps`)
- subnet/supernet operations (`subnets`, `supernet`)
- network math (`networkAddress`, `broadcastAddress`, `hostCount`)
- iteration (`hosts`, `addresses`)

```luau
local net = ip.network("10.0.0.0/24")
if net then
    for host in net:hosts() do
        -- lazy iterator
        print(host)
    end
end
```

Important: iterators are lazy, but huge ranges can still run for a very long time. Prefer bounded loops and early exits.

## Interface objects: when to use them

Use interface objects when you care about both host address and attached prefix as a single value.

```luau
local iface = ip.interface("192.168.1.10/255.255.255.0")
if iface then
    print(iface:withPrefixLength()) -- 192.168.1.10/24
    print(iface:withNetmask())      -- 192.168.1.10/255.255.255.0
end
```

## Range objects: set-style IP ranges

Ranges are useful when CIDR alone is not enough (for example exclusions or irregular spans).

Constructors:
- `ip.IPv4Range.new(start, finish)`
- `ip.IPv6Range.new(start, finish)`
- `ip.IPv4Range.fromNetwork(net)`
- `ip.IPv6Range.fromNetwork(net)`

Common operations:
- `contains(...)`
- `exclude(...)`
- `iter()` (and `for x in range do`)
- `toNetworks()` exact CIDR cover (lazy)
- `smallestContainingNetwork()` single enclosing CIDR

```luau
local r = ip.IPv4Range.new("192.168.1.10", "192.168.1.20")
local trimmed = r:exclude("192.168.1.15")

for net in trimmed:toNetworks() do
    print(net)
end
```

Use `toNetworks()` when you need exact coverage. Use `smallestContainingNetwork()` when one broad CIDR is acceptable.

## IPv4/IPv6 interoperability patterns

Useful conversions:
- `IPv4Address:toIPv6Mapped()`
- `IPv4Network:toIPv6Mapped()`
- `IPv6Address:isIPv4Mapped()` / `isIPv4Compatible()`
- `IPv6Address:getEmbeddedIPv4()` / `toIPv4()`

```luau
local mapped = ip.address("::ffff:192.168.1.1")
if mapped and mapped:isIPv4Mapped() then
    local v4 = mapped:toIPv4()
    print(v4)
end
```

## Sorting and summarizing

Use built-ins instead of hand-rolling comparisons:
- `ip.sortIPv4(list)` / `ip.sortIPv6(list)`
- `ip.smallestEnclosingIPv4Network(a, b)`
- `ip.smallestEnclosingIPv6Network(a, b)`
- `IPv4Network.mergeNetworks(list)` / `IPv6Network.mergeNetworks(list)`

These keep family-specific behavior explicit and avoid accidental IPv4/IPv6 mixing.

## Recommended patterns in production code

- Parse once at boundaries, then pass typed objects internally.
- Prefer object methods over re-parsing string forms repeatedly.
- Keep IPv4 and IPv6 flows explicit.
- Use strict parsing for configuration files and policy definitions.
- Treat network/range iteration as potentially large work; keep it lazy and bounded.

## Practical workflow

A good default flow for user input:
1. Validate with `ip.address` or `ip.network`.
2. Normalize using `tostring(...)` for storage/display.
3. Run policy checks (`isPrivate`, `contains`, etc.).
4. Convert only when required (`toIPv6Mapped`, `toIPv4`, `toPacked`, `toInteger`).

This keeps your code predictable, fast, and easy to reason about.
