local test = require("@eryx/test")
local hash = require("@eryx/crypto/hash")
local hex = require("@eryx/encoding/hex")
local suite = test.Suite.new("hash")

local function h(b: buffer): string
	return hex.encode(b)
end

local function buf(s: string): buffer
	return buffer.fromstring(s)
end

suite:Test("md5: output is 16 bytes", function()
	test.expect(buffer.len(hash.md5(buf("")))):ToBe(16)
end)

suite:Test("sha1: output is 20 bytes", function()
	test.expect(buffer.len(hash.sha1(buf("")))):ToBe(20)
end)

suite:Test("sha224: output is 28 bytes", function()
	test.expect(buffer.len(hash.sha224(buf("")))):ToBe(28)
end)

suite:Test("sha256: output is 32 bytes", function()
	test.expect(buffer.len(hash.sha256(buf("")))):ToBe(32)
end)

suite:Test("sha384: output is 48 bytes", function()
	test.expect(buffer.len(hash.sha384(buf("")))):ToBe(48)
end)

suite:Test("sha512: output is 64 bytes", function()
	test.expect(buffer.len(hash.sha512(buf("")))):ToBe(64)
end)

suite:Test("sha3_224: output is 28 bytes", function()
	test.expect(buffer.len(hash.sha3_224(buf("")))):ToBe(28)
end)

suite:Test("sha3_256: output is 32 bytes", function()
	test.expect(buffer.len(hash.sha3_256(buf("")))):ToBe(32)
end)

suite:Test("sha3_384: output is 48 bytes", function()
	test.expect(buffer.len(hash.sha3_384(buf("")))):ToBe(48)
end)

suite:Test("sha3_512: output is 64 bytes", function()
	test.expect(buffer.len(hash.sha3_512(buf("")))):ToBe(64)
end)

-- ── hash: known test vectors ─────────────────────────────────────────────────

-- MD5 vectors (RFC 1321)
suite:Test("md5: empty string", function()
	test.expect(h(hash.md5(buf("")))):ToBe("d41d8cd98f00b204e9800998ecf8427e")
end)

suite:Test("md5: 'abc'", function()
	test.expect(h(hash.md5(buf("abc")))):ToBe("900150983cd24fb0d6963f7d28e17f72")
end)

-- SHA-1 vectors (FIPS 180-4)
suite:Test("sha1: empty string", function()
	test.expect(h(hash.sha1(buf("")))):ToBe("da39a3ee5e6b4b0d3255bfef95601890afd80709")
end)

suite:Test("sha1: 'abc'", function()
	test.expect(h(hash.sha1(buf("abc")))):ToBe("a9993e364706816aba3e25717850c26c9cd0d89d")
end)

-- SHA-256 vectors (FIPS 180-4)
suite:Test("sha256: empty string", function()
	test.expect(h(hash.sha256(buf("")))):ToBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

suite:Test("sha256: 'hello'", function()
	test.expect(h(hash.sha256(buf("hello")))):ToBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
end)

suite:Test("sha256: 'abc'", function()
	test.expect(h(hash.sha256(buf("abc")))):ToBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end)

suite:Test("sha256: 448-bit message", function()
	-- "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
	test.expect(h(hash.sha256(buf("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))))
		:ToBe("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

-- SHA-512 vectors (FIPS 180-4)
suite:Test("sha512: empty string", function()
	test.expect(h(hash.sha512(buf("")))):ToBe(
		"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
	)
end)

suite:Test("sha512: 'abc'", function()
	test.expect(h(hash.sha512(buf("abc")))):ToBe(
		"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
	)
end)

-- SHA3-256 vectors (FIPS 202)
suite:Test("sha3_256: empty string", function()
	test.expect(h(hash.sha3_256(buf("")))):ToBe("a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
end)

suite:Test("sha3_256: 'abc'", function()
	test.expect(h(hash.sha3_256(buf("abc")))):ToBe("3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
end)

-- ── hash: determinism ────────────────────────────────────────────────────────

suite:Test("sha256: same input always same output", function()
	local a = h(hash.sha256(buf("test")))
	local b = h(hash.sha256(buf("test")))
	test.expect(a):ToBe(b)
end)

suite:Test("sha256: different inputs give different hashes", function()
	local a = h(hash.sha256(buf("hello")))
	local b = h(hash.sha256(buf("world")))
	test.expect(a):ToNotBe(b)
end)

suite:Test("sha3_224: 'abc'", function()
	test.expect(h(hash.sha3_224(buf("abc")))):ToBe("e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf")
end)

suite:Test("sha3_384: empty string", function()
	test.expect(h(hash.sha3_384(buf(""))))
		:ToBe("0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004")
end)

suite:Test("sha3_512: empty string", function()
	test.expect(h(hash.sha3_512(buf("")))):ToBe(
		"a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"
	)
end)

return suite
