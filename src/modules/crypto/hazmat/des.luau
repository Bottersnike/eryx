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

	Only CBC mode is defined for DES in this backend, and it operates on
	raw block-aligned data. Use `@eryx/crypto/hazmat/pkcs7` if you need
	PKCS#7 padding.

	```luau
	local des = require("@eryx/crypto/hazmat/des")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.fromstring("123456789012345678901234")
	local iv = buffer.fromstring("12345678")
	local padded = pkcs7.pad(buffer.fromstring("Hello!!"), 8)
	local ct = des.encryptCBC(key, iv, padded)
	local pt = pkcs7.unpad(des.decryptCBC(key, iv, ct), 8)
	```
]=]

local _des = require("@eryx/crypto/hazmat/_crypto").des

local des = {}

--[=[
	Encrypts `data` with 3DES-CBC (no padding).

	The block size is 8 bytes, so the IV must also be 8 bytes. The input
	length must already be a multiple of 8 bytes.

	@param key  Triple-DES key - exactly 24 bytes.
	@param iv   Initialisation vector - 8 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function des.encryptCBC(key: buffer, iv: buffer, data: buffer): buffer
	return _des.cbc_encrypt(key, iv, data)
end

--[=[
	Decrypts 3DES-CBC ciphertext (no padding).

	The input length must be a multiple of 8 bytes.

	@param key  Triple-DES key - exactly 24 bytes.
	@param iv   Initialisation vector - 8 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function des.decryptCBC(key: buffer, iv: buffer, data: buffer): buffer
	return _des.cbc_decrypt(key, iv, data)
end

return des
