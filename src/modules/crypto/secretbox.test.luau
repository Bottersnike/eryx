local test = require("@eryx/test")
local secretbox = require("@eryx/crypto/secretbox")

local suite = test.Suite.new("secretbox")

suite:test("keygen: returns a 32-byte key", function()
	local key = secretbox.keygen()

	test.expect(buffer.len(key)):toBe(32)
end)

suite:test("seal + open: round-trips with generated key", function()
	local ciphertext, key = secretbox.seal(buffer.fromstring("hello secretbox"))
	local opened = secretbox.open(ciphertext, key)

	test.expect(buffer.tostring(opened)):toBe("hello secretbox")
	test.expect(buffer.len(key)):toBe(32)
	test.expect(buffer.readstring(ciphertext, 0, 3)):toBe("$c$")
	test.expect(buffer.len(ciphertext)):toBeGreaterThan(31)
end)

suite:test("seal: uses the supplied key", function()
	local key = secretbox.keygen()
	local ciphertext, usedKey = secretbox.seal(buffer.fromstring("with explicit key"), key)

	test.expect(buffer.tostring(usedKey)):toBe(buffer.tostring(key))
	test.expect(buffer.tostring(secretbox.open(ciphertext, key))):toBe("with explicit key")
end)

suite:test("open: rejects tampered ciphertext", function()
	local ciphertext, key = secretbox.seal(buffer.fromstring("please dont tamper"))
	local tampered = buffer.create(buffer.len(ciphertext))

	buffer.copy(tampered, 0, ciphertext)
	buffer.writeu8(
		tampered,
		buffer.len(tampered) - 1,
		bit32.bxor(buffer.readu8(tampered, buffer.len(tampered) - 1), 0x01)
	)

	test.expect(function()
		secretbox.open(tampered, key)
	end):toError()
end)

return suite
