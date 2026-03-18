--[=[
	AES (Advanced Encryption Standard) symmetric encryption.

	Supports 128-, 192-, and 256-bit keys (determined by key length).
	Three operation modes are provided:

	- **CBC** – Cipher Block Chaining with PKCS#7 padding. Requires an
	  IV; do not reuse (key, IV) pairs.
	- **CTR** – Counter mode. Turns AES into a stream cipher; no padding.
	  The IV is the initial counter block (16 bytes).
	- **GCM** – Galois/Counter Mode. Authenticated encryption (AEAD).
	  Returns ciphertext and a 16-byte authentication tag separately.
	- **CCM** – Counter with CBC-MAC. Another AEAD mode; nonce must be
	  7–13 bytes.

	```luau
	local aes = require("@eryx/crypto/aes")

	local key   = buffer.fromstring("0123456789abcdef")  -- 16-byte AES-128
	local iv    = buffer.fromstring("0000000000000000")
	local plain = buffer.fromstring("Hello, AES!")

	local ct = aes.cbc_encrypt(key, iv, plain)
	local pt = aes.cbc_decrypt(key, iv, ct)
	assert(buffer.tostring(pt) == "Hello, AES!")
	```
]=]

local _aes = require("@eryx/crypto/_crypto").aes

local aes = {}

--[=[
	Encrypts `data` with AES-CBC (PKCS#7 padding).

	The same (key, IV) pair must never be reused. Generate a random IV
	per message and transmit it alongside the ciphertext.

	@param key  AES key - 16, 24, or 32 bytes (128/192/256-bit).
	@param iv   Initialisation vector - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (length rounded up to a 16-byte block boundary).
]=]
function aes.cbc_encrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _aes.cbc_encrypt(key, iv, data)
end

--[=[
	Decrypts AES-CBC ciphertext (strips PKCS#7 padding).

	@param key  AES key - 16, 24, or 32 bytes.
	@param iv   Initialisation vector - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext.
]=]
function aes.cbc_decrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _aes.cbc_decrypt(key, iv, data)
end

--[=[
	Encrypts `data` with AES-CTR (stream cipher; no padding).

	CTR mode is length-preserving. The `iv` parameter is the 16-byte
	counter block (typically a random nonce). A (key, IV) pair must
	never be reused.

	@param key  AES key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function aes.ctr_encrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _aes.ctr_encrypt(key, iv, data)
end

--[=[
	Decrypts AES-CTR ciphertext.

	CTR decryption is identical to encryption; this function is provided
	for API symmetry.

	@param key  AES key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function aes.ctr_decrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _aes.ctr_decrypt(key, iv, data)
end

--[=[
	Encrypts `data` with AES-GCM, returning the ciphertext and
	authentication tag separately.

	GCM provides authenticated encryption: the tag covers both the
	ciphertext and any additional authenticated data (`aad`). A
	(key, nonce) pair must never be reused; 12-byte random nonces are
	standard.

	```luau
	local ct, tag = aes.gcm_encrypt(key, nonce, plain, aad)
	local pt = aes.gcm_decrypt(key, nonce, ct, tag, aad)
	```

	@param key   AES key - 16, 24, or 32 bytes.
	@param nonce Nonce - 12 bytes recommended.
	@param data  Plaintext to encrypt.
	@param aad   Additional authenticated data (not encrypted, but covered by tag).
	@return buffer -- Ciphertext.
	@return buffer -- 16-byte authentication tag.
]=]
function aes.gcm_encrypt(key: buffer, nonce: buffer, data: buffer, aad: buffer?): (buffer, buffer)
	return _aes.gcm_encrypt(key, nonce, data, aad)
end

--[=[
	Decrypts AES-GCM ciphertext and verifies the authentication tag.

	Raises an error if the tag does not match (i.e. the data has been
	tampered with or the wrong key/nonce/aad was supplied).

	@param key   AES key - 16, 24, or 32 bytes.
	@param nonce Nonce - must match the value used during encryption.
	@param ct    Ciphertext.
	@param tag   16-byte authentication tag.
	@param aad   Additional authenticated data (must match encryption).
	@return buffer -- Plaintext.
]=]
function aes.gcm_decrypt(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _aes.gcm_decrypt(key, nonce, ct, tag, aad)
end

--[=[
	Encrypts `data` with AES-CCM, returning the ciphertext and
	authentication tag separately.

	CCM is an AEAD mode similar to GCM but based on CBC-MAC. The nonce
	must be 7–13 bytes; shorter nonces allow larger messages.

	@param key   AES key - 16, 24, or 32 bytes.
	@param nonce Nonce - 7 to 13 bytes.
	@param data  Plaintext to encrypt.
	@param aad   Additional authenticated data.
	@return buffer -- Ciphertext.
	@return buffer -- Authentication tag.
]=]
function aes.ccm_encrypt(key: buffer, nonce: buffer, data: buffer, aad: buffer?): (buffer, buffer)
	return _aes.ccm_encrypt(key, nonce, data, aad)
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
function aes.ccm_decrypt(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _aes.ccm_decrypt(key, nonce, ct, tag, aad)
end

--[=[
	Encrypts `data` with AES-ECB (PKCS#7 padding).
	@param key  AES key - 16, 24, or 32 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (length rounded up to a 16-byte block boundary).
]=]
function aes.ecb_encrypt(key: buffer, data: buffer): buffer
	return _aes.ecb_encrypt(key, data)
end

--[=[
	Decrypts AES-ECB ciphertext (strips PKCS#7 padding).
	@param key  AES key - 16, 24, or 32 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext.
]=]
function aes.ecb_decrypt(key: buffer, data: buffer): buffer
	return _aes.ecb_decrypt(key, data)
end

return aes
