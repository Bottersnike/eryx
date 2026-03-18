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

suite:Test("md5: output is 16 bytes", function()
	test.expect(buffer.len(hmac.md5(buf("key"), buf("data")))):ToBe(16)
end)

suite:Test("sha1: output is 20 bytes", function()
	test.expect(buffer.len(hmac.sha1(buf("key"), buf("data")))):ToBe(20)
end)

suite:Test("sha256: output is 32 bytes", function()
	test.expect(buffer.len(hmac.sha256(buf("key"), buf("data")))):ToBe(32)
end)

suite:Test("sha512: output is 64 bytes", function()
	test.expect(buffer.len(hmac.sha512(buf("key"), buf("data")))):ToBe(64)
end)

-- ── hmac: known test vectors (RFC 4231 / NIST) ───────────────────────────────

suite:Test("sha256: RFC 4231 test case 1", function()
	-- key = 0x0b * 20 bytes, data = "Hi There"
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha256(key, data))):ToBe("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
end)

suite:Test("sha256: 'key' / 'The quick brown fox'", function()
	test.expect(h(hmac.sha256(buf("key"), buf("The quick brown fox jumps over the lazy dog"))))
		:ToBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
end)

suite:Test("sha512: RFC 4231 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha512(key, data))):ToBe(
		"87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
	)
end)

suite:Test("sha1: RFC 2202 test case 1", function()
	local key = buffer.fromstring(string.rep("\x0b", 20))
	local data = buf("Hi There")
	test.expect(h(hmac.sha1(key, data))):ToBe("b617318655057264e28bc0b6fb378c8ef146be00")
end)

-- ── hmac: key sensitivity ─────────────────────────────────────────────────────

suite:Test("sha256: different keys produce different MACs", function()
	local data = buf("message")
	local mac1 = h(hmac.sha256(buf("key1"), data))
	local mac2 = h(hmac.sha256(buf("key2"), data))
	test.expect(mac1):ToNotBe(mac2)
end)

suite:Test("sha256: same key different data produce different MACs", function()
	local key = buf("secret")
	local mac1 = h(hmac.sha256(key, buf("msg1")))
	local mac2 = h(hmac.sha256(key, buf("msg2")))
	test.expect(mac1):ToNotBe(mac2)
end)

return suite
