local test = require("@eryx/test")
local password = require("@eryx/crypto/password")

local suite = test.Suite.new("password")

suite:test("hash + verify: round-trips with argon2id", function()
	local hash = password.hash("hunter2")

	test.expect(hash:sub(1, 3)):toBe("$a$")
	test.expect(password.verify("hunter2", hash)):toBe(true)
	test.expect(password.verify("wrong-password", hash)):toBe(false)
end)

return suite
