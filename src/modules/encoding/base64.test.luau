local base64 = require("@eryx/encoding/base64")
local test = require("@eryx/test")
local suite = test.Suite.new("base64")

suite:Test("encode: empty", function()
	test.expect(base64.encode(buffer.fromstring(""))):ToBe("")
end)

suite:Test("encode: 1-byte padding ==", function()
	test.expect(base64.encode(buffer.fromstring("f"))):ToBe("Zg==")
end)

suite:Test("encode: 2-byte padding =", function()
	test.expect(base64.encode(buffer.fromstring("fo"))):ToBe("Zm8=")
end)

suite:Test("encode: 3-byte no padding", function()
	test.expect(base64.encode(buffer.fromstring("foo"))):ToBe("Zm9v")
end)

suite:Test("encode: known string", function()
	test.expect(base64.encode(buffer.fromstring("Hello, world!"))):ToBe("SGVsbG8sIHdvcmxkIQ==")
end)

suite:Test("decode: empty", function()
	test.expect(buffer.tostring(base64.decode(""))):ToBe("")
end)

suite:Test("decode: with padding ==", function()
	test.expect(buffer.tostring(base64.decode("Zg=="))):ToBe("f")
end)

suite:Test("decode: with padding =", function()
	test.expect(buffer.tostring(base64.decode("Zm8="))):ToBe("fo")
end)

suite:Test("decode: no padding", function()
	test.expect(buffer.tostring(base64.decode("Zm9v"))):ToBe("foo")
end)

suite:Test("round-trip: binary data", function()
	local data = "\x00\x01\x02\xfe\xff"
	local encoded = base64.encode(buffer.fromstring(data))
	test.expect(buffer.tostring(base64.decode(encoded))):ToBe(data)
end)

suite:Test("URL-safe alphabet", function()
	-- bytes that produce + and / in standard encoding -> - and _ in URL-safe
	local data = buffer.fromstring("\xfb\xff\xfe")
	local standard = base64.encode(data)
	local urlsafe = base64.encode(data, base64.URL_SAFE_ALPHABET)
	test.expect(standard):ToBe("+//+")
	test.expect(urlsafe):ToBe("-__-")
	test.expect(buffer.tostring(base64.decode(urlsafe, base64.URL_SAFE_ALPHABET))):ToBe(buffer.tostring(data))
end)

return suite
