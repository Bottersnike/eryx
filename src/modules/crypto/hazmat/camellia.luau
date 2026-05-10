--[=[
	Camellia symmetric encryption.

	Camellia is an ISO/IEC 18033-3 and NESSIE-approved block cipher with
	the same block and key sizes as AES (128/192/256-bit keys, 128-bit
	block). It is a recognised alternative to AES in TLS and IPsec.

	Supports CBC, CTR, and GCM modes. CBC operates on raw block-aligned
	data; use `@eryx/crypto/hazmat/pkcs7` if you need PKCS#7 padding.
	CCM is not defined for Camellia in this backend.

	```luau
	local camellia = require("@eryx/crypto/hazmat/camellia")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.fromstring("0123456789abcdef")
	local iv = buffer.fromstring("0000000000000000")
	local plain = buffer.fromstring("Hello, Camellia!")

	local padded = pkcs7.pad(plain, 16)
	local ct = camellia.encryptCBC(key, iv, padded)
	local pt = pkcs7.unpad(camellia.decryptCBC(key, iv, ct), 16)
	```
]=]

local _cam = require("@eryx/crypto/hazmat/_crypto").camellia

local camellia = {}

--[=[
	Encrypts `data` with Camellia-CBC (no padding).

	The input length must already be a multiple of 16 bytes.

	@param key  Key - 16, 24, or 32 bytes (128/192/256-bit).
	@param iv   Initialisation vector - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function camellia.encryptCBC(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.cbc_encrypt(key, iv, data)
end

--[=[
	Decrypts Camellia-CBC ciphertext (no padding).

	The input length must be a multiple of 16 bytes.

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Initialisation vector - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function camellia.decryptCBC(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.cbc_decrypt(key, iv, data)
end

--[=[
	Encrypts `data` with Camellia-CTR (stream cipher; no padding).

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function camellia.encryptCTR(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.ctr_encrypt(key, iv, data)
end

--[=[
	Decrypts Camellia-CTR ciphertext.

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function camellia.decryptCTR(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.ctr_decrypt(key, iv, data)
end

--[=[
	Encrypts `data` with Camellia-GCM (authenticated encryption).

	Returns ciphertext and authentication tag separately.

	@param key   Key - 16, 24, or 32 bytes.
	@param nonce Nonce - 12 bytes recommended.
	@param data  Plaintext to encrypt.
	@param aad   Additional authenticated data (optional).
	@return buffer -- Ciphertext.
	@return buffer -- 16-byte authentication tag.
]=]
function camellia.encryptGCM(key: buffer, nonce: buffer, data: buffer, aad: buffer?): (buffer, buffer)
	return _cam.gcm_encrypt(key, nonce, data, aad)
end

--[=[
	Decrypts Camellia-GCM ciphertext and verifies the authentication tag.

	Raises an error if the tag does not match.

	@param key   Key - 16, 24, or 32 bytes.
	@param nonce Nonce - must match the value used during encryption.
	@param ct    Ciphertext.
	@param tag   16-byte authentication tag.
	@param aad   Additional authenticated data (must match encryption).
	@return buffer -- Plaintext.
]=]
function camellia.decryptGCM(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _cam.gcm_decrypt(key, nonce, ct, tag, aad)
end

return camellia
