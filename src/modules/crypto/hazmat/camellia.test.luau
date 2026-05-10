local test = require("@eryx/test")
local hex = require("@eryx/encoding/hex")
local camellia = require("./camellia")
local pkcs7 = require("./pkcs7")

local suite = test.Suite.new("Camellia")

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
	mode: camellia.Mode,
	operation: camellia.Operation,
	ivOrNonce: buffer,
	chunks: { buffer }
): buffer
	local ctx = camellia.new(key, mode, operation, ivOrNonce)
	local out = {}
	for _, chunk in chunks do
		table.insert(out, ctx:update(chunk))
	end
	table.insert(out, ctx:final())
	return join(out)
end

suite:test("CBC encrypt/decrypt round-trips across chunk boundaries", function()
	local key = hex.decode("0123456789abcdeffedcba9876543210")
	local iv = hex.decode("00112233445566778899aabbccddeeff")
	local plaintext = pkcs7.pad(buffer.fromstring("camellia likes aligned blocks"), 16)

	local ciphertext = crypt(key, "cbc", "encrypt", iv, {
		buffer.fromstring(buffer.tostring(plaintext):sub(1, 16)),
		buffer.fromstring(buffer.tostring(plaintext):sub(17)),
	})

	local recovered = crypt(key, "cbc", "decrypt", iv, {
		buffer.fromstring(buffer.tostring(ciphertext):sub(1, 16)),
		buffer.fromstring(buffer.tostring(ciphertext):sub(17)),
	})

	test.expect(pkcs7.unpad(recovered, 16)):toBe(buffer.fromstring("camellia likes aligned blocks"))
end)

suite:test("CTR matches single-shot chunking semantics", function()
	local key = hex.decode("0123456789abcdeffedcba9876543210")
	local iv = hex.decode("f0e0d0c0b0a090807060504030201000")
	local plaintext = buffer.fromstring("ctr mode can split anywhere")

	local whole = crypt(key, "ctr", "encrypt", iv, { plaintext })
	local split = crypt(key, "ctr", "encrypt", iv, {
		buffer.fromstring("ctr mode "),
		buffer.fromstring("can split "),
		buffer.fromstring("anywhere"),
	})

	test.expect(split):toBe(whole)
	test.expect(crypt(key, "ctr", "decrypt", iv, { split })):toBe(plaintext)
end)

suite:test("GCM supports AAD and tag verification", function()
	local key = hex.decode("0123456789abcdeffedcba9876543210")
	local nonce = hex.decode("000102030405060708090a0b")
	local aad = buffer.fromstring("camellia-header")
	local plaintext = buffer.fromstring("authenticated camellia payload")

	local ok, encOrErr = pcall(function()
		return camellia.new(key, "gcm", "encrypt", nonce)
	end)
	if not ok then
		local err = tostring(encOrErr)
		if string.find(err, "is not available in this OpenSSL build", 1, true) then
			test.skip("Camellia GCM is not available in this OpenSSL build")
		end
		error(encOrErr)
	end

	local enc = encOrErr
	enc:updateAAD(aad)
	local ciphertext = join({
		enc:update(buffer.fromstring("authenticated ")),
		enc:update(buffer.fromstring("camellia payload")),
		enc:final(),
	})
	local tag = enc:getTag()

	local dec = camellia.new(key, "gcm", "decrypt", nonce)
	dec:updateAAD(aad)
	dec:setTag(tag)
	local recovered = join({
		dec:update(buffer.fromstring(buffer.tostring(ciphertext):sub(1, 10))),
		dec:update(buffer.fromstring(buffer.tostring(ciphertext):sub(11))),
		dec:final(),
	})

	test.expect(recovered):toBe(plaintext)
end)

suite:test("CBC rejects non-block-aligned input", function()
	test.expect(function()
		crypt(
			hex.decode("0123456789abcdeffedcba9876543210"),
			"cbc",
			"encrypt",
			hex.decode("00112233445566778899aabbccddeeff"),
			{ buffer.fromstring("abc") }
		)
	end):toError("cipher block size")
end)

return suite
