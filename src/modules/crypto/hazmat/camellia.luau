--[=[
	Camellia symmetric encryption.

	Camellia is an ISO/IEC 18033-3 and NESSIE-approved block cipher with
	the same block and key sizes as AES (128/192/256-bit keys, 128-bit
	block). It is a recognised alternative to AES in TLS and IPsec.

	Supports CBC, CTR, and GCM modes through a streaming `Context` API.
	CBC operates on raw block-aligned data; use
	`@eryx/crypto/hazmat/pkcs7` if you need PKCS#7 padding. CCM is not
	defined for Camellia in this backend.

	```luau
	local camellia = require("@eryx/crypto/hazmat/camellia")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.fromstring("0123456789abcdef")
	local iv = buffer.fromstring("0000000000000000")
	local plain = buffer.fromstring("Hello, Camellia!")

	local padded = pkcs7.pad(plain, 16)
	local enc = camellia.new(key, "cbc", "encrypt", iv)
	local ct = enc:update(padded)
	local tail = enc:final()
	local ciphertext = buffer.create(buffer.len(ct) + buffer.len(tail))
	buffer.copy(ciphertext, 0, ct)
	buffer.copy(ciphertext, buffer.len(ct), tail)

	local dec = camellia.new(key, "cbc", "decrypt", iv)
	local ptChunk = dec:update(ciphertext)
	local ptTail = dec:final()
	local decrypted = buffer.create(buffer.len(ptChunk) + buffer.len(ptTail))
	buffer.copy(decrypted, 0, ptChunk)
	buffer.copy(decrypted, buffer.len(ptChunk), ptTail)

	local pt = pkcs7.unpad(decrypted, 16)
	```
]=]

local _cam = require("@eryx/crypto/hazmat/_crypto").camellia

export type Mode = "cbc" | "ctr" | "gcm"
export type Operation = "encrypt" | "decrypt"
export type Context = {
	update: (self: Context, data: buffer) -> buffer,
	updateAAD: (self: Context, aad: buffer) -> (),
	setTag: (self: Context, tag: buffer) -> (),
	getTag: (self: Context) -> buffer,
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
}

local camellia = {}

--[=[
	Creates a streaming Camellia context.

	For `cbc`, pass a 16-byte IV and ensure input is block-aligned.
	For `ctr`, pass a 16-byte counter block.
	For `gcm`, pass the nonce and use [[Context.updateAAD]],
	[[Context.setTag]], and [[Context.getTag]] as needed.

	@param key Camellia key - 16, 24, or 32 bytes.
	@param mode Camellia mode.
	@param operation `"encrypt"` or `"decrypt"`.
	@param ivOrNonce IV / counter block / nonce depending on mode.
	@return Context -- Streaming Camellia context.
]=]
function camellia.new(key: buffer, mode: Mode, operation: Operation, ivOrNonce: buffer?): Context
	return _cam.new(key, mode, operation, ivOrNonce)
end

return table.freeze(camellia)
