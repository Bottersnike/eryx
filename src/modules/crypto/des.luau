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

	Only CBC mode is defined for DES in PSA Crypto.

	```luau
	local des = require("@eryx/crypto/des")

	-- Key MUST be exactly 24 bytes.
	local key = buffer.fromstring("123456789012345678901234")
	local iv  = buffer.fromstring("12345678")  -- 8 bytes
	local ct  = des.cbc_encrypt(key, iv, buffer.fromstring("Hello!!"))
	local pt  = des.cbc_decrypt(key, iv, ct)
	```
]=]

local _des = require("@eryx/crypto/_crypto").des

local des = {}

--[=[
	Encrypts `data` with 3DES-CBC (PKCS#7 padding).

	The block size is 8 bytes, so the IV must also be 8 bytes. PKCS#7
	padding is applied automatically, rounding the output up to the
	next 8-byte boundary.

	@param key  Triple-DES key - exactly 24 bytes.
	@param iv   Initialisation vector - 8 bytes.
	@param data Plaintext to encrypt.
	@return buffer -- Ciphertext.
]=]
function des.cbc_encrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _des.cbc_encrypt(key, iv, data)
end

--[=[
	Decrypts 3DES-CBC ciphertext (strips PKCS#7 padding).

	@param key  Triple-DES key - exactly 24 bytes.
	@param iv   Initialisation vector - 8 bytes.
	@param data Ciphertext to decrypt.
	@return buffer -- Plaintext.
]=]
function des.cbc_decrypt(key: buffer, iv: buffer, data: buffer): buffer
	return _des.cbc_decrypt(key, iv, data)
end

return des
