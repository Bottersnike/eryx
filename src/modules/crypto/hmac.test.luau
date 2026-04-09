local test = require("@eryx/test")
local hmac = require("@eryx/crypto/hmac")

local suite = test.Suite.new("crypto hmac")

suite:test("digest + verify: round-trips", function()
	local key = buffer.fromstring("secret")
	local data = buffer.fromstring("hello")
	local mac = hmac.digest(key, data)

	test.expect(buffer.readstring(mac, 0, 3)):toBe("$m$")
	test.expect(hmac.verify(key, data, mac)):toBe(true)
	test.expect(hmac.verify(buffer.fromstring("wrong"), data, mac)):toBe(false)
	test.expect(hmac.verify(key, buffer.fromstring("goodbye"), mac)):toBe(false)
end)

suite:test("verify: rejects malformed macs", function()
	test.expect(hmac.verify(buffer.fromstring("secret"), buffer.fromstring("hello"), buffer.fromstring("$x$nope")))
		:toBe(false)
	test.expect(hmac.verify(buffer.fromstring("secret"), buffer.fromstring("hello"), buffer.fromstring(""))):toBe(false)
end)

return suite
