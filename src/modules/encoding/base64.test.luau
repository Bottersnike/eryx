local base64 = require("@eryx/encoding/base64")
local test = require("@eryx/test")
local suite = test.Suite.new("base64")

suite:test("encode: empty", function()
	test.expect(base64.encode(buffer.fromstring(""))):toBe("")
end)

suite:test("encode: 1-byte padding ==", function()
	test.expect(base64.encode(buffer.fromstring("f"))):toBe("Zg==")
end)

suite:test("encode: 2-byte padding =", function()
	test.expect(base64.encode(buffer.fromstring("fo"))):toBe("Zm8=")
end)

suite:test("encode: 3-byte no padding", function()
	test.expect(base64.encode(buffer.fromstring("foo"))):toBe("Zm9v")
end)

suite:test("encode: known string", function()
	test.expect(base64.encode(buffer.fromstring("Hello, world!"))):toBe("SGVsbG8sIHdvcmxkIQ==")
end)

suite:test("decode: empty", function()
	test.expect(buffer.tostring(base64.decode(""))):toBe("")
end)

suite:test("decode: with padding ==", function()
	test.expect(buffer.tostring(base64.decode("Zg=="))):toBe("f")
end)

suite:test("decode: with padding =", function()
	test.expect(buffer.tostring(base64.decode("Zm8="))):toBe("fo")
end)

suite:test("decode: no padding", function()
	test.expect(buffer.tostring(base64.decode("Zm9v"))):toBe("foo")
end)

suite:test("round-trip: binary data", function()
	local data = "\x00\x01\x02\xfe\xff"
	local encoded = base64.encode(buffer.fromstring(data))
	test.expect(buffer.tostring(base64.decode(encoded))):toBe(data)
end)

suite:test("URL-safe alphabet", function()
	-- bytes that produce + and / in standard encoding -> - and _ in URL-safe
	local data = buffer.fromstring("\xfb\xff\xfe")
	local standard = base64.encode(data)
	local urlsafe = base64.encode(data, base64.URL_SAFE_ALPHABET)
	test.expect(standard):toBe("+//+")
	test.expect(urlsafe):toBe("-__-")
	test.expect(buffer.tostring(base64.decode(urlsafe, base64.URL_SAFE_ALPHABET))):toBe(buffer.tostring(data))
end)

return suite
