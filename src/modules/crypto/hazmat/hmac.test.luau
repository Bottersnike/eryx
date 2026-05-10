local test = require("@eryx/test")
local hmac = require("@eryx/crypto/hazmat/hmac")
local hex = require("@eryx/encoding/hex")

local suite = test.Suite.new("hmac")

local function h(b: buffer): string
	return hex.encode(b)
end

local function buf(s: string): buffer
	return buffer.fromstring(s)
end

local function mac(algorithm: string, key: buffer, chunks: { buffer }): buffer
	local ctx = hmac.new(algorithm, key)
	for _, chunk in chunks do
		ctx:update(chunk)
	end
	return ctx:final()
end

suite:test("md5: output is 16 bytes", function()
	test.expect(buffer.len(mac("md5", buf("key"), { buf("data") }))):toBe(16)
end)

suite:test("sha1: output is 20 bytes", function()
	test.expect(buffer.len(mac("sha1", buf("key"), { buf("data") }))):toBe(20)
end)

suite:test("sha256: output is 32 bytes", function()
	test.expect(buffer.len(mac("sha256", buf("key"), { buf("data") }))):toBe(32)
end)

suite:test("sha512: output is 64 bytes", function()
	test.expect(buffer.len(mac("sha512", buf("key"), { buf("data") }))):toBe(64)
end)

suite:test("streaming sha256 matches split updates", function()
	local key = buf("secret")
	test.expect(mac("sha256", key, { buf("hel"), buf("lo") })):toBe(mac("sha256", key, { buf("hello") }))
end)

suite:test("sha256: RFC 4231 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(mac("sha256", key, { data })))
		:toBe("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
end)

suite:test("sha256: 'key' / 'The quick brown fox'", function()
	test.expect(h(mac("sha256", buf("key"), { buf("The quick brown fox jumps over the lazy dog") })))
		:toBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
end)

suite:test("sha512: RFC 4231 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(mac("sha512", key, { data }))):toBe(
		"87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
	)
end)

suite:test("sha1: RFC 2202 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(mac("sha1", key, { data }))):toBe("b617318655057264e28bc0b6fb378c8ef146be00")
end)

suite:test("sha256: different keys produce different MACs", function()
	local data = buf("message")
	local mac1 = h(mac("sha256", buf("key1"), { data }))
	local mac2 = h(mac("sha256", buf("key2"), { data }))
	test.expect(mac1):toNotBe(mac2)
end)

suite:test("sha256: same key different data produce different MACs", function()
	local key = buf("secret")
	local mac1 = h(mac("sha256", key, { buf("msg1") }))
	local mac2 = h(mac("sha256", key, { buf("msg2") }))
	test.expect(mac1):toNotBe(mac2)
end)

return suite
