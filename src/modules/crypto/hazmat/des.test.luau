local test = require("@eryx/test")
local des = require("./des")
local pkcs7 = require("./pkcs7")

local suite = test.Suite.new("3DES")

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

local function crypt(key: buffer, operation: des.Operation, iv: buffer, chunks: { buffer }): buffer
	local ctx = des.new(key, "cbc", operation, iv)
	local out = {}
	for _, chunk in chunks do
		table.insert(out, ctx:update(chunk))
	end
	table.insert(out, ctx:final())
	return join(out)
end

suite:test("CBC encrypt/decrypt round-trips across chunk boundaries", function()
	local key = buffer.fromstring("123456789012345678901234")
	local iv = buffer.fromstring("12345678")
	local plaintext = pkcs7.pad(buffer.fromstring("Hello 3DES world"), 8)

	local ciphertext = crypt(key, "encrypt", iv, {
		buffer.fromstring(buffer.tostring(plaintext):sub(1, 8)),
		buffer.fromstring(buffer.tostring(plaintext):sub(9)),
	})

	local recovered = crypt(key, "decrypt", iv, {
		buffer.fromstring(buffer.tostring(ciphertext):sub(1, 8)),
		buffer.fromstring(buffer.tostring(ciphertext):sub(9)),
	})

	test.expect(pkcs7.unpad(recovered, 8)):toBe(buffer.fromstring("Hello 3DES world"))
end)

suite:test("CBC rejects non-block-aligned input", function()
	test.expect(function()
		crypt(
			buffer.fromstring("123456789012345678901234"),
			"encrypt",
			buffer.fromstring("12345678"),
			{ buffer.fromstring("abc") }
		)
	end):toError("cipher block size")
end)

return suite
