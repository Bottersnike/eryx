--[=[
	HMAC (Hash-based Message Authentication Code).

	Computes an authentication tag over `data` using a secret `key` and the
	chosen hash algorithm. The output length equals the digest size of the
	underlying hash.

	```luau
	local hmac = require("@eryx/crypto/hmac")
	local hex  = require("@eryx/encoding/hex")

	local key = buffer.fromstring("secret")
	local msg = buffer.fromstring("hello")
	print(hex.encode(hmac.sha256(key, msg)))
	```
]=]

local _hm = require("@eryx/crypto/_crypto").hmac

local hmac = {}

--[=[
	Computes HMAC-MD5 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 16-byte MAC.
]=]
function hmac.md5(key: buffer, data: buffer): buffer
	return _hm.md5(key, data)
end

--[=[
	Computes HMAC-SHA1 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 20-byte MAC.
]=]
function hmac.sha1(key: buffer, data: buffer): buffer
	return _hm.sha1(key, data)
end

--[=[
	Computes HMAC-SHA224 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 28-byte MAC.
]=]
function hmac.sha224(key: buffer, data: buffer): buffer
	return _hm.sha224(key, data)
end

--[=[
	Computes HMAC-SHA256 over `data` with `key`.

	The most common HMAC variant. Suitable for API authentication,
	signed cookies, and TOTP/HOTP tokens.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 32-byte MAC.
]=]
function hmac.sha256(key: buffer, data: buffer): buffer
	return _hm.sha256(key, data)
end

--[=[
	Computes HMAC-SHA384 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 48-byte MAC.
]=]
function hmac.sha384(key: buffer, data: buffer): buffer
	return _hm.sha384(key, data)
end

--[=[
	Computes HMAC-SHA512 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 64-byte MAC.
]=]
function hmac.sha512(key: buffer, data: buffer): buffer
	return _hm.sha512(key, data)
end

--[=[
	Computes HMAC-SHA3-224 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 28-byte MAC.
]=]
function hmac.sha3_224(key: buffer, data: buffer): buffer
	return _hm.sha3_224(key, data)
end

--[=[
	Computes HMAC-SHA3-256 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 32-byte MAC.
]=]
function hmac.sha3_256(key: buffer, data: buffer): buffer
	return _hm.sha3_256(key, data)
end

--[=[
	Computes HMAC-SHA3-384 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 48-byte MAC.
]=]
function hmac.sha3_384(key: buffer, data: buffer): buffer
	return _hm.sha3_384(key, data)
end

--[=[
	Computes HMAC-SHA3-512 over `data` with `key`.

	@param key  Secret key (any length).
	@param data Input data.
	@return buffer -- 64-byte MAC.
]=]
function hmac.sha3_512(key: buffer, data: buffer): buffer
	return _hm.sha3_512(key, data)
end

return hmac
