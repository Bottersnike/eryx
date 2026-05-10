local test = require("@eryx/test")
local hex = require("@eryx/encoding/hex")
local chacha20 = require("./chacha20")

local suite = test.Suite.new("ChaCha20")

local function join(parts: { buffer }): buffer
	local total = 0
	for _, part in parts do
		total += buffer.len(part)
	end

	local out = buffer.create(total)
	local offset = 0
	for _, part in parts do
		buffer.copy(out, offset, part)
		offset += buffer.len(part)
	end
	return out
end

local function crypt(
	key: buffer,
	mode: chacha20.Mode,
	operation: chacha20.Operation,
	nonce: buffer,
	chunks: { buffer },
	aad: buffer?
): (buffer, buffer?)
	local ctx = chacha20.new(key, mode, operation, nonce)
	if aad ~= nil then
		ctx:updateAAD(aad)
	end

	local out = {}
	for _, chunk in chunks do
		table.insert(out, ctx:update(chunk))
	end
	table.insert(out, ctx:final())

	if mode == "poly1305" and operation == "encrypt" then
		return join(out), ctx:getTag()
	end

	return join(out), nil
end

local function decryptPoly1305(key: buffer, nonce: buffer, ciphertext: buffer, tag: buffer, aad: buffer?): buffer
	local ctx = chacha20.new(key, "poly1305", "decrypt", nonce)
	if aad ~= nil then
		ctx:updateAAD(aad)
	end
	ctx:setTag(tag)
	return join({
		ctx:update(ciphertext),
		ctx:final(),
	})
end

local function oldNonceToIetfNonce(nonce64Hex: string): buffer
	return hex.decode("00000000" .. nonce64Hex)
end

local function zeroes(length: number): buffer
	return buffer.create(length)
end

local function keystreamCase(name: string, keyHex: string, nonce64Hex: string, keystreamHex: string)
	suite:test(name, function()
		local key = hex.decode(keyHex)
		local nonce = oldNonceToIetfNonce(nonce64Hex)
		local plaintext = zeroes(#keystreamHex // 2)

		local ciphertext = crypt(key, "stream", "encrypt", nonce, { plaintext })
		test.expect(ciphertext):toBe(hex.decode(keystreamHex))
	end)
end

local function oneTimePoly1305KeyCase(name: string, keyHex: string, nonceHex: string, expectedHex: string)
	suite:test(name, function()
		local key = hex.decode(keyHex)
		local nonce = hex.decode(nonceHex)
		local plaintext = zeroes(#expectedHex // 2)

		local ciphertext = crypt(key, "stream", "encrypt", nonce, { plaintext })
		test.expect(ciphertext):toBe(hex.decode(expectedHex))
	end)
end

keystreamCase(
	"draft-agl vec 1",
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0000000000000000",
	"76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586"
)

keystreamCase(
	"draft-agl vec 2",
	"0000000000000000000000000000000000000000000000000000000000000001",
	"0000000000000000",
	"4540f05a9f1fb296d7736e7b208e3c96eb4fe1834688d2604f450952ed432d41bbe2a0b6ea7566d2a5d1e7e20d42af2c53d792b1c43fea817e9ad275ae546963"
)

keystreamCase(
	"draft-agl vec 3",
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0000000000000001",
	"de9cba7bf3d69ef5e786dc63973f653a0b49e015adbff7134fcb7df137821031e85a050278a7084527214f73efc7fa5b5277062eb7a0433e445f41e3"
)

keystreamCase(
	"draft-agl vec 4",
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000",
	"ef3fdfd6c61578fbf5cf35bd3dd33b8009631634d21e42ac33960bd138e50d32111e4caf237ee53ca8ad6426194a88545ddc497a0b466e7d6bbdb0041b2f586b"
)

keystreamCase(
	"draft-agl vec 5",
	"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
	"0001020304050607",
	"f798a189f195e66982105ffb640bb7757f579da31602fc93ec01ac56f85ac3c134a4547b733b46413042c9440049176905d3be59ea1c53f15916155c2be8241a38008b9a26bc35941e2444177c8ade6689de95264986d95889fb60e84629c9bd9a5acb1cc118be563eb9b3a4a472f82e09a7e778492b562ef7130e88dfe031c79db9d4f7c7a899151b9a475032b63fc385245fe054e3dd5a97a5f576fe064025d3ce042c566ab2c507b138db853e3d6959660996546cc9c4a6eafdc777c040d70eaf46f76dad3979e5c5360c3317166a1c894c94a371876a94df7628fe4eaaf2ccb27d5aaae0ad7ad0f9d4b6ad3b54098746d4524d38407a6deb3ab78fab78c9"
)

oneTimePoly1305KeyCase(
	"rfc8439 a.4 poly1305 keygen vec 1",
	"0000000000000000000000000000000000000000000000000000000000000000",
	"000000000000000000000000",
	"76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7"
)

oneTimePoly1305KeyCase(
	"rfc8439 a.4 poly1305 keygen vec 2",
	"0000000000000000000000000000000000000000000000000000000000000001",
	"000000000000000000000002",
	"ecfa254f845f647473d3cb140da9e87606cb33066c447b87bc2666dde3fbb739"
)

oneTimePoly1305KeyCase(
	"rfc8439 a.4 poly1305 keygen vec 3",
	"1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0",
	"000000000000000000000002",
	"965e3bc6f9ec7ed9560808f4d229f94b137ff275ca9b3fcbdd59deaad23310ae"
)

suite:test("stream encrypt/decrypt round-trip", function()
	local key = hex.decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	local nonce = hex.decode("000000000001020304050607")
	local plaintext = buffer.fromstring("hello from chacha20")

	local ciphertext = crypt(key, "stream", "encrypt", nonce, { plaintext })
	test.expect(ciphertext):toNotBe(plaintext)
	test.expect(crypt(key, "stream", "decrypt", nonce, { ciphertext })):toBe(plaintext, nil)
end)

suite:test("stream mode supports split updates", function()
	local key = hex.decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	local nonce = hex.decode("000000000001020304050607")
	local plaintext = buffer.fromstring("split me across chunks")

	local whole = crypt(key, "stream", "encrypt", nonce, { plaintext })
	local split = crypt(key, "stream", "encrypt", nonce, {
		buffer.fromstring("split me "),
		buffer.fromstring("across "),
		buffer.fromstring("chunks"),
	})

	test.expect(split):toBe(whole)
end)

suite:test("rfc8439 2.8.2 aead encrypt", function()
	local key = hex.decode("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	local nonce = hex.decode("070000004041424344454647")
	local plaintext = buffer.fromstring(
		"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
	)
	local aad = hex.decode("50515253c0c1c2c3c4c5c6c7")
	local expectedCiphertext = hex.decode(
		"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
			.. "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
			.. "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
			.. "3ff4def08e4b7a9de576d26586cec64b6116"
	)
	local expectedTag = hex.decode("1ae10b594f09e26a7e902ecbd0600691")

	local ciphertext, tag = crypt(key, "poly1305", "encrypt", nonce, { plaintext }, aad)

	test.expect(ciphertext):toBe(expectedCiphertext)
	test.expect(tag):toBe(expectedTag)
end)

suite:test("rfc8439 a.5 aead decrypt", function()
	local key = hex.decode("1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0")
	local nonce = hex.decode("000000000102030405060708")
	local aad = hex.decode("f33388860000000000004e91")
	local ciphertext = hex.decode(
		"64a0861575861af460f062c79be643bd5e805cfd345cf389f108670ac76c8cb2"
			.. "4c6cfc18755d43eea09ee94e382d26b0bdb7b73c321b0100d4f03b7f355894cf"
			.. "332f830e710b97ce98c8a84abd0b948114ad176e008d33bd60f982b1ff37c855"
			.. "9797a06ef4f0ef61c186324e2b3506383606907b6a7c02b0f9f6157b53c867e4"
			.. "b9166c767b804d46a59b5216cde7a4e99040c5a40433225ee282a1b0a06c523e"
			.. "af4534d7f83fa1155b0047718cbc546a0d072b04b3564eea1b422273f548271a"
			.. "0bb2316053fa76991955ebd63159434ecebb4e466dae5a1073a6727627097a10"
			.. "49e617d91d361094fa68f0ff77987130305beaba2eda04df997b714d6c6f2c29"
			.. "a6ad5cb4022b02709b"
	)
	local tag = hex.decode("eead9d67890cbb22392336fea1851f38")
	local expectedPlaintext = buffer.fromstring(
		"Internet-Drafts are draft documents valid for a maximum of six months and may be updated, replaced, or obsoleted by other documents at any time. It is inappropriate to use Internet-Drafts as reference material or to cite them other than as /“work in progress./”"
	)

	test.expect(decryptPoly1305(key, nonce, ciphertext, tag, aad)):toBe(expectedPlaintext)
end)

suite:test("poly1305 supports chunked updates and AAD", function()
	local key = hex.decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	local nonce = hex.decode("000000000001020304050607")
	local aad = buffer.fromstring("header")
	local plaintext = buffer.fromstring("authenticated chunks")

	local ciphertext, tag = crypt(key, "poly1305", "encrypt", nonce, {
		buffer.fromstring("authenticated "),
		buffer.fromstring("chunks"),
	}, aad)

	test.expect(decryptPoly1305(key, nonce, ciphertext, tag :: buffer, aad)):toBe(plaintext)
end)

return suite
