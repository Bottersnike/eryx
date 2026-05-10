--[=[
	AES (Advanced Encryption Standard) symmetric encryption.

	Supports 128-, 192-, and 256-bit keys (determined by key length).
	Six operation modes are provided:

	- **ECB**: raw block encryption. No padding; input must be a multiple
	  of 16 bytes.
	- **CBC**: Cipher Block Chaining on raw block-aligned data. Requires
	  an IV; do not reuse (key, IV) pairs. Use
	  `@eryx/crypto/hazmat/pkcs7` if you need PKCS#7 padding.
	- **CTR**: Counter mode. Turns AES into a stream cipher; no padding.
	  The IV is the initial counter block (16 bytes).
	- **CFB128**: Cipher Feedback mode with 128-bit feedback. A
	  self-synchronising stream-like mode using a 16-byte IV. No padding.
	- **OFB**: Output Feedback mode. A synchronous stream-like mode using
	  a 16-byte IV. No padding.
	- **GCM**: Galois/Counter Mode. Authenticated encryption (AEAD).
	  Returns ciphertext and a 16-byte authentication tag separately.
	- **CCM**: available as explicit one-shot helpers only because it
	  needs the total message length up front.

	```luau
	local aes = require("@eryx/crypto/hazmat/aes")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.fromstring("0123456789abcdef")
	local iv = buffer.fromstring("0000000000000000")
	local plain = buffer.fromstring("Hello, AES!")

	local padded = pkcs7.pad(plain, 16)
	local enc = aes.new(key, "cbc", "encrypt", iv)
	local ct = enc:update(padded)
	local tail = enc:final()
	local ciphertext = buffer.create(buffer.len(ct) + buffer.len(tail))
	buffer.copy(ciphertext, 0, ct)
	buffer.copy(ciphertext, buffer.len(ct), tail)

	local dec = aes.new(key, "cbc", "decrypt", iv)
	local pt = dec:update(ciphertext)
	local ptTail = dec:final()
	local decrypted = buffer.create(buffer.len(pt) + buffer.len(ptTail))
	buffer.copy(decrypted, 0, pt)
	buffer.copy(decrypted, buffer.len(pt), ptTail)

	local unpadded = pkcs7.unpad(decrypted, 16)
	assert(buffer.tostring(unpadded) == "Hello, AES!")
	```
]=]

local _aes = require("@eryx/crypto/hazmat/_crypto").aes

export type Mode = "ecb" | "cbc" | "ctr" | "cfb128" | "ofb" | "gcm"
export type Operation = "encrypt" | "decrypt"
export type Context = {
	update: (self: Context, data: buffer) -> buffer,
	updateAAD: (self: Context, aad: buffer) -> (),
	setTag: (self: Context, tag: buffer) -> (),
	getTag: (self: Context) -> buffer,
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
}

local aes = {}

--[=[
	Creates a streaming AES context.

	This is the stateful hazmat API for incremental encryption or
	decryption. Use `mode` to choose the AES mode and `operation` to
	choose whether the context encrypts or decrypts.

	For `ecb`, do not pass `ivOrNonce`.
	For `cbc`, `ctr`, `cfb128`, and `ofb`, pass a 16-byte IV/counter block.
	For `gcm`, pass the nonce and use [[Context.updateAAD]], [[Context.setTag]],
	and [[Context.getTag]] as needed.

	CCM is intentionally not part of the streaming constructor. Use
	[[aes.encryptCCM]] / [[aes.decryptCCM]] instead.

	@param key AES key - 16, 24, or 32 bytes.
	@param mode AES mode.
	@param operation `"encrypt"` or `"decrypt"`.
	@param ivOrNonce IV / counter block / nonce depending on mode.
	@return Context -- Streaming AES context.
]=]
function aes.new(key: buffer, mode: Mode, operation: Operation, ivOrNonce: buffer?): Context
	return _aes.new(key, mode, operation, ivOrNonce)
end

--[=[
	Encrypts `data` with AES-CCM, returning the ciphertext and
	authentication tag separately.

	CCM is an AEAD mode similar to GCM but based on CBC-MAC. The nonce
	must be 7-13 bytes; shorter nonces allow larger messages.

	@param key   AES key - 16, 24, or 32 bytes.
	@param nonce Nonce - 7 to 13 bytes.
	@param data  Plaintext to encrypt.
	@param aad   Additional authenticated data.
	@param tagLen Optional authentication tag length in bytes (4, 6, 8, 10, 12, 14, or 16).
	@return buffer -- Ciphertext.
	@return buffer -- Authentication tag.
]=]
function aes.encryptCCM(key: buffer, nonce: buffer, data: buffer, aad: buffer?, tagLen: number?): (buffer, buffer)
	return _aes.ccm_encrypt(key, nonce, data, aad, tagLen)
end

--[=[
	Decrypts AES-CCM ciphertext and verifies the authentication tag.

	Raises an error if the tag does not match.

	@param key   AES key - 16, 24, or 32 bytes.
	@param nonce Nonce - must match the value used during encryption.
	@param ct    Ciphertext.
	@param tag   Authentication tag.
	@param aad   Additional authenticated data (must match encryption).
	@return buffer -- Plaintext.
]=]
function aes.decryptCCM(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _aes.ccm_decrypt(key, nonce, ct, tag, aad)
end

return aes
