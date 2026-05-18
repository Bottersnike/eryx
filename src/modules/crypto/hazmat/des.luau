--[=[
	Triple-DES (3DES / TDEA) symmetric encryption.

	Only **Triple-DES** is provided; single DES is cryptographically
	broken and omitted intentionally. Keys must be exactly **24 bytes**
	(three independent 8-byte DES keys = 192-bit key material, ~112-bit
	effective security).

	:::warning
	3DES is a legacy cipher. Its 64-bit block size makes it vulnerable to
	birthday attacks (Sweet32) in long sessions. Prefer AES for new designs.
	:::

	Only CBC mode is defined for DES in this backend, and it uses a
	streaming `Context` API over raw block-aligned data. Use
	`@eryx/crypto/hazmat/pkcs7` if you need PKCS#7 padding.

	```luau
	local des = require("@eryx/crypto/hazmat/des")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.fromstring("123456789012345678901234")
	local iv = buffer.fromstring("12345678")
	local padded = pkcs7.pad(buffer.fromstring("Hello!!"), 8)
	local enc = des.new(key, "cbc", "encrypt", iv)
	local ct = enc:update(padded)
	local tail = enc:final()
	local ciphertext = buffer.create(buffer.len(ct) + buffer.len(tail))
	buffer.copy(ciphertext, 0, ct)
	buffer.copy(ciphertext, buffer.len(ct), tail)

	local dec = des.new(key, "cbc", "decrypt", iv)
	local ptChunk = dec:update(ciphertext)
	local ptTail = dec:final()
	local decrypted = buffer.create(buffer.len(ptChunk) + buffer.len(ptTail))
	buffer.copy(decrypted, 0, ptChunk)
	buffer.copy(decrypted, buffer.len(ptChunk), ptTail)

	local pt = pkcs7.unpad(decrypted, 8)
	```
]=]

local _des = require("@eryx/crypto/hazmat/_crypto").des

export type Mode = "cbc"
export type Operation = "encrypt" | "decrypt"
export type Context = setmetatable<{}, { __index: {
	update: (self: Context, data: buffer) -> buffer,
	updateAAD: (self: Context, aad: buffer) -> (),
	setTag: (self: Context, tag: buffer) -> (),
	getTag: (self: Context) -> buffer,
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
} }>

local des = {}

--[=[
	Creates a streaming 3DES-CBC context.

	The block size is 8 bytes, so the IV must also be 8 bytes. Input must
	remain block-aligned because padding is disabled.

	@param key Triple-DES key - exactly 24 bytes.
	@param mode DES mode. Only `"cbc"` is supported.
	@param operation `"encrypt"` or `"decrypt"`.
	@param ivOrNonce 8-byte IV.
	@return Context -- Streaming 3DES context.
]=]
function des.new(key: buffer, mode: Mode, operation: Operation, ivOrNonce: buffer): Context
	return _des.new(key, mode, operation, ivOrNonce)
end

return table.freeze(des)
