local test = require("@eryx/test")
local argon2 = require("@eryx/crypto/hazmat/argon2")
local hex = require("@eryx/encoding/hex")

local suite = test.Suite.new("argon2")

local function buf(s: string): buffer
	return buffer.fromstring(s)
end

local function h(b: buffer): string
	return hex.encode(b)
end

suite:test("argon2id_hash_raw: returns requested length", function()
	local out = argon2.argon2id_hash_raw(buf("password"), buf("12345678"), 2, 32, 1, 32)
	test.expect(buffer.len(out)):toBe(32)
end)

suite:test("argon2 variants: produce distinct raw outputs", function()
	local pwd = buf("password")
	local salt = buf("12345678")

	local d = h(argon2.argon2d_hash_raw(pwd, salt, 2, 32, 1, 32))
	local i = h(argon2.argon2i_hash_raw(pwd, salt, 2, 32, 1, 32))
	local id = h(argon2.argon2id_hash_raw(pwd, salt, 2, 32, 1, 32))

	test.expect(d):toNotBe(i)
	test.expect(i):toNotBe(id)
	test.expect(d):toNotBe(id)
end)

suite:test("argon2id_hash_encoded + verify_encoded: round-trips", function()
	local encoded = argon2.argon2id_hash_encoded(buf("password"), buf("12345678"), 2, 32, 1, 32)

	test.expect(encoded:sub(1, 10)):toBe("$argon2id$")
	test.expect(argon2.verify_encoded(encoded, buf("password"))):toBe(true)
	test.expect(argon2.verify_encoded(encoded, buf("wrong-password"))):toBe(false)
end)

suite:test("encoded_len: provides enough room for encoded hashes", function()
	local encoded = argon2.argon2i_hash_encoded(buf("password"), buf("12345678"), 2, 32, 1, 16)
	local predicted = argon2.encoded_len(2, 32, 1, 8, 16, "argon2i")

	test.expect(#encoded):toBeLessThan(predicted)
end)

return suite
