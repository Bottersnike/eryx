--[=[
	ChaCha20 stream cipher and ChaCha20-Poly1305 AEAD.

	ChaCha20 is a fast, secure stream cipher designed by Daniel J.
	Bernstein. It is widely used in TLS 1.3 and WireGuard as an
	alternative to AES when hardware AES acceleration is unavailable.

	- **ChaCha20 (stream)** - symmetric stream cipher; keystream is XOR'd
	  with the plaintext. No authentication; pair with an HMAC if you need
	  it, or use the Poly1305 variant.
	- **ChaCha20-Poly1305** - authenticated encryption (AEAD) combining
	  ChaCha20 with the Poly1305 MAC. This is the recommended variant.

	Key: **32 bytes**. Nonce: **12 bytes**. Counter starts at 0.

	```luau
	local chacha20 = require("@eryx/crypto/chacha20")

	local key   = buffer.create(32)  -- 32 zero bytes (use a real key!)
	local nonce = buffer.create(12)  -- 12 zero bytes

	-- Authenticated encryption
	local ct, tag = chacha20.poly1305_encrypt(key, nonce, buffer.fromstring("secret"))
	local pt = chacha20.poly1305_decrypt(key, nonce, ct, tag)
	```
]=]

local _cc = require("@eryx/crypto/_crypto").chacha20

local chacha20 = {}

--[=[
	Encrypts `data` with ChaCha20 (unauthenticated stream cipher).

	The output is the same length as the input. A given (key, nonce) pair
	must never be reused; generate a fresh random nonce per message.

	For authenticated encryption, use [[poly1305_encrypt]] instead.

	@param key   32-byte ChaCha20 key.
	@param nonce 12-byte nonce.
	@param data  Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as input).
]=]
function chacha20.encrypt(key: buffer, nonce: buffer, data: buffer): buffer
	return _cc.encrypt(key, nonce, data)
end

--[=[
	Decrypts ChaCha20 ciphertext (unauthenticated).

	ChaCha20 decryption is identical to encryption; this function is
	provided for API symmetry.

	@param key   32-byte ChaCha20 key.
	@param nonce 12-byte nonce.
	@param data  Ciphertext to decrypt.
	@return buffer -- Plaintext (same length as input).
]=]
function chacha20.decrypt(key: buffer, nonce: buffer, data: buffer): buffer
	return _cc.decrypt(key, nonce, data)
end

--[=[
	Encrypts `data` with ChaCha20-Poly1305 (authenticated encryption).

	Returns the ciphertext and a 16-byte Poly1305 authentication tag
	separately. The tag covers the ciphertext and any additional
	authenticated data (`aad`).

	This is the recommended variant when you need both confidentiality
	and integrity.

	```luau
	local ct, tag = chacha20.poly1305_encrypt(key, nonce, plain, aad)
	local pt = chacha20.poly1305_decrypt(key, nonce, ct, tag, aad)
	```

	@param key   32-byte ChaCha20 key.
	@param nonce 12-byte nonce.
	@param data  Plaintext to encrypt.
	@param aad   Additional authenticated data (not encrypted).
	@return buffer -- Ciphertext.
	@return buffer -- 16-byte Poly1305 authentication tag.
]=]
function chacha20.poly1305_encrypt(key: buffer, nonce: buffer, data: buffer, aad: buffer?): (buffer, buffer)
	return _cc.poly1305_encrypt(key, nonce, data, aad)
end

--[=[
	Decrypts ChaCha20-Poly1305 ciphertext and verifies the tag.

	Raises an error if the authentication tag does not match (data
	has been tampered with, or wrong key/nonce/aad was used).

	@param key   32-byte ChaCha20 key.
	@param nonce 12-byte nonce - must match the value used during encryption.
	@param ct    Ciphertext.
	@param tag   16-byte Poly1305 authentication tag.
	@param aad   Additional authenticated data (must match encryption).
	@return buffer -- Plaintext.
]=]
function chacha20.poly1305_decrypt(key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?): buffer
	return _cc.poly1305_decrypt(key, nonce, ct, tag, aad)
end

return chacha20
