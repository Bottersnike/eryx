--[=[
	Camellia symmetric encryption.

	Camellia is an ISO/IEC 18033-3 and NESSIE-approved block cipher with
	the same block and key sizes as AES (128/192/256-bit keys, 128-bit
	block). It is a recognised alternative to AES in TLS and IPsec.

	Supports CBC, CTR, and GCM modes - see `@eryx/crypto/aes` for
	mode descriptions. CCM is not defined for Camellia in PSA Crypto.

	```luau
	local camellia = require("@eryx/crypto/camellia")

	local key   = buffer.fromstring("0123456789abcdef")  -- 16-byte / 128-bit
	local iv    = buffer.fromstring("0000000000000000")
	local plain = buffer.fromstring("Hello, Camellia!")

	local ct = camellia.cbc_encrypt(key, iv, plain)
	local pt = camellia.cbc_decrypt(key, iv, ct)
	```
]=]

local _cam = require("@eryx/crypto/_crypto").camellia

local camellia = {}

--[=[
	Encrypts `data` with Camellia-CBC (PKCS#7 padding).

	@param key  Key - 16, 24, or 32 bytes (128/192/256-bit).
	@param iv   Initialisation vector - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext.
]=]
function camellia.cbc_encrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.cbc_encrypt(key, iv, data)
end

--[=[
	Decrypts Camellia-CBC ciphertext (strips PKCS#7 padding).

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Initialisation vector - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext.
]=]
function camellia.cbc_decrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.cbc_decrypt(key, iv, data)
end

--[=[
	Encrypts `data` with Camellia-CTR (stream cipher; no padding).

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function camellia.ctr_encrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _cam.ctr_encrypt(key, iv, data)
end

--[=[
	Decrypts Camellia-CTR ciphertext.

	@param key  Key - 16, 24, or 32 bytes.
	@param iv   Counter/nonce block - 16 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function camellia.ctr_decrypt(key: buffer, iv: buffer, data: buffer): buffer
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
function camellia.gcm_encrypt(key: buffer, nonce: buffer, data: buffer, aad: buffer?): (buffer, buffer)
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
function camellia.gcm_decrypt(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _cam.gcm_decrypt(key, nonce, ct, tag, aad)
end

return camellia
