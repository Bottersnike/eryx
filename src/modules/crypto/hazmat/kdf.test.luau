local test = require("@eryx/test")
local hex = require("@eryx/encoding/hex")
local kdf = require("./kdf")

local suite = test.Suite.new("KDF")

local function hkdfSha256Case(
	name: string,
	ikmHex: string,
	saltHex: string?,
	infoHex: string?,
	length: number,
	expectedHex: string
)
	suite:test(name, function()
		local ikm = hex.decode(ikmHex)
		local salt = if saltHex == nil then nil else hex.decode(saltHex)
		local info = if infoHex == nil then nil else hex.decode(infoHex)

		test.expect(kdf.hkdf_sha256(ikm, salt, info, length)):toBe(hex.decode(expectedHex))
	end)
end

-- RFC 5869 Appendix A test vectors for HKDF-SHA256.
-- The SHA-1 vectors are intentionally omitted because this API does not
-- currently expose an HKDF-SHA1 variant.
-- https://www.rfc-editor.org/rfc/rfc5869
hkdfSha256Case(
	"rfc5869 a.1 hkdf-sha256 basic",
	"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
	"000102030405060708090a0b0c",
	"f0f1f2f3f4f5f6f7f8f9",
	42,
	"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
)

hkdfSha256Case(
	"rfc5869 a.2 hkdf-sha256 long inputs",
	"000102030405060708090a0b0c0d0e0f"
		.. "101112131415161718191a1b1c1d1e1f"
		.. "202122232425262728292a2b2c2d2e2f"
		.. "303132333435363738393a3b3c3d3e3f"
		.. "404142434445464748494a4b4c4d4e4f",
	"606162636465666768696a6b6c6d6e6f"
		.. "707172737475767778797a7b7c7d7e7f"
		.. "808182838485868788898a8b8c8d8e8f"
		.. "909192939495969798999a9b9c9d9e9f"
		.. "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf",
	"b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
		.. "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
		.. "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
		.. "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
		.. "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
	82,
	"b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
		.. "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
		.. "cc30c58179ec3e87c14c01d5c1f3434f1d87"
)

hkdfSha256Case(
	"rfc5869 a.3 hkdf-sha256 zero-length salt-info",
	"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
	"",
	"",
	42,
	"8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
)

suite:test("nil salt matches RFC zero-salt default", function()
	local ikm = hex.decode("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	local expected = hex.decode("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")

	test.expect(kdf.hkdf_sha256(ikm, nil, nil, 42)):toBe(expected)
end)

suite:test("pbkdf2 sha256 is deterministic", function()
	local password = buffer.fromstring("hunter2")
	local salt = buffer.fromstring("salty")

	local a = kdf.pbkdf2_sha256(password, salt, 1000, 32)
	local b = kdf.pbkdf2_sha256(password, salt, 1000, 32)

	test.expect(a):toBe(b)
end)

suite:test("pbkdf2 sha256 changes with iteration count", function()
	local password = buffer.fromstring("hunter2")
	local salt = buffer.fromstring("salty")

	local a = kdf.pbkdf2_sha256(password, salt, 1000, 32)
	local b = kdf.pbkdf2_sha256(password, salt, 1001, 32)

	test.expect(a):toNotBe(b)
end)

suite:test("pbkdf2 sha512 returns requested length", function()
	local out = kdf.pbkdf2_sha512(buffer.fromstring("hunter2"), buffer.fromstring("salty"), 1000, 48)

	test.expect(buffer.len(out)):toBe(48)
end)

return suite
