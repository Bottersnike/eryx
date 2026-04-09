local test = require("@eryx/test")
local hash = require("@eryx/crypto/hash")

local suite = test.Suite.new("crypto hash")

suite:test("digest + verify: round-trips", function()
	local data = buffer.fromstring("hello")
	local digest = hash.digest(data)

	test.expect(buffer.readstring(digest, 0, 3)):toBe("$h$")
	test.expect(hash.verify(data, digest)):toBe(true)
	test.expect(hash.verify(buffer.fromstring("goodbye"), digest)):toBe(false)
end)

suite:test("verify: rejects malformed digests", function()
	test.expect(hash.verify(buffer.fromstring("hello"), buffer.fromstring("$x$nope"))):toBe(false)
	test.expect(hash.verify(buffer.fromstring("hello"), buffer.fromstring(""))):toBe(false)
end)

return suite
