local test = require("@eryx/test")
local hex = require("@eryx/encoding/hex")
local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

local suite = test.Suite.new("PKCS7")

suite:test("pad adds a full block when input is already aligned", function()
	local data = buffer.fromstring("YELLOW SUBMARINE")
	local out = pkcs7.pad(data, 16)

	test.expect(out):toBe(hex.decode("59454c4c4f57205355424d4152494e4510101010101010101010101010101010"))
end)

suite:test("pad and unpad round-trip short input", function()
	local data = buffer.fromstring("ICE ICE BABY")
	local padded = pkcs7.pad(data, 16)

	test.expect(buffer.len(padded)):toBe(16)
	test.expect(pkcs7.unpad(padded, 16)):toBe(data)
end)

suite:test("unpad rejects malformed padding", function()
	test.expect(function()
		pkcs7.unpad(hex.decode("49434520494345204241425905050504"), 16)
	end):toError("invalid PKCS#7 padding")
end)

suite:test("unpad rejects a zero padding length", function()
	test.expect(function()
		pkcs7.unpad(hex.decode("49434520494345204241425959595900"), 16)
	end):toError("invalid PKCS#7 padding")
end)

suite:test("unpad rejects a padding length greater than the block size", function()
	-- Final byte 0x11 (17) exceeds the 16-byte block size.
	test.expect(function()
		pkcs7.unpad(hex.decode("49434520494345204241425959595911"), 16)
	end):toError("invalid PKCS#7 padding")
end)

suite:test("unpad accepts a full block of padding", function()
	local block = hex.decode("10101010101010101010101010101010")
	test.expect(buffer.len(pkcs7.unpad(block, 16))):toBe(0)
end)

suite:test("unpad rejects non-block-aligned input", function()
	test.expect(function()
		pkcs7.unpad(buffer.fromstring("abc"), 16)
	end):toError("multiple of blockSize")
end)

return suite
