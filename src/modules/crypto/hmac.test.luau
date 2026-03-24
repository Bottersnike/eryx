local test = require("@eryx/test")
local hmac = require("@eryx/crypto/hmac")
local hex = require("@eryx/encoding/hex")
local suite = test.Suite.new("hmac")

local function h(b: buffer): string
	return hex.encode(b)
end

local function buf(s: string): buffer
	return buffer.fromstring(s)
end

suite:test("md5: output is 16 bytes", function()
	test.expect(buffer.len(hmac.md5(buf("key"), buf("data")))):toBe(16)
end)

suite:test("sha1: output is 20 bytes", function()
	test.expect(buffer.len(hmac.sha1(buf("key"), buf("data")))):toBe(20)
end)

suite:test("sha256: output is 32 bytes", function()
	test.expect(buffer.len(hmac.sha256(buf("key"), buf("data")))):toBe(32)
end)

suite:test("sha512: output is 64 bytes", function()
	test.expect(buffer.len(hmac.sha512(buf("key"), buf("data")))):toBe(64)
end)

-- ── hmac: known test vectors (RFC 4231 / NIST) ───────────────────────────────

suite:test("sha256: RFC 4231 test case 1", function()
	-- key = 0x0b * 20 bytes, data = "Hi There"
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha256(key, data))):toBe("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
end)

suite:test("sha256: 'key' / 'The quick brown fox'", function()
	test.expect(h(hmac.sha256(buf("key"), buf("The quick brown fox jumps over the lazy dog"))))
		:toBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
end)

suite:test("sha512: RFC 4231 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha512(key, data))):toBe(
		"87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
	)
end)

suite:test("sha1: RFC 2202 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha1(key, data))):toBe("b617318655057264e28bc0b6fb378c8ef146be00")
end)

-- ── hmac: key sensitivity ─────────────────────────────────────────────────────

suite:test("sha256: different keys produce different MACs", function()
	local data = buf("message")
	local mac1 = h(hmac.sha256(buf("key1"), data))
	local mac2 = h(hmac.sha256(buf("key2"), data))
	test.expect(mac1):toNotBe(mac2)
end)

suite:test("sha256: same key different data produce different MACs", function()
	local key = buf("secret")
	local mac1 = h(hmac.sha256(key, buf("msg1")))
	local mac2 = h(hmac.sha256(key, buf("msg2")))
	test.expect(mac1):toNotBe(mac2)
end)

return suite
