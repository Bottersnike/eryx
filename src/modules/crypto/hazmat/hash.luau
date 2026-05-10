--[=[
	Cryptographic hash functions.

	All one-shot functions take a `buffer` and return the raw digest as a
	`buffer`. For incremental hashing, use [[new]] to create a streaming
	hash context.

	```luau
	local hash = require("@eryx/crypto/hazmat/hash")
	local hex = require("@eryx/encoding/hex")

	local ctx = hash.new("sha256")
	ctx:update(buffer.fromstring("hel"))
	ctx:update(buffer.fromstring("lo"))
	print(hex.encode(ctx:final()))
	-- "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	```
]=]

local _h = require("@eryx/crypto/hazmat/_crypto").hash

export type Context = {
	update: (self: Context, data: buffer) -> (),
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
}

local hash = {}

--[=[
	Creates an incremental hash context.

	Supported algorithms currently include `"md5"`, `"sha1"`, `"sha224"`,
	`"sha256"`, `"sha384"`, `"sha512"`, `"sha3_224"`, `"sha3_256"`,
	`"sha3_384"`, and `"sha3_512"`.

	@param algorithm Hash algorithm name.
	@return Context -- Streaming hash context.
]=]
function hash.new(algorithm: string): Context
	return _h.new(algorithm)
end

-- Legacy one-shot hash helpers kept commented out during the
-- streaming API transition.
--[==[
--[=[
	Computes the MD5 digest of `data`.

	MD5 is considered cryptographically broken. Use it only for
	non-security purposes such as checksums or legacy compatibility.

	@param data Input data.
	@return buffer -- 16-byte (128-bit) digest.
]=]
function hash.md5(data: buffer): buffer
	return _h.md5(data)
end

--[=[
	Computes the SHA-1 digest of `data`.

	SHA-1 is deprecated for security-critical uses. Prefer SHA-256 or
	SHA-3 for new designs.

	@param data Input data.
	@return buffer -- 20-byte (160-bit) digest.
]=]
function hash.sha1(data: buffer): buffer
	return _h.sha1(data)
end

--[=[
	Computes the SHA-224 digest of `data`.

	@param data Input data.
	@return buffer -- 28-byte (224-bit) digest.
]=]
function hash.sha224(data: buffer): buffer
	return _h.sha224(data)
end

--[=[
	Computes the SHA-256 digest of `data`.

	The most widely deployed secure hash. Suitable for signatures,
	HMACs, key derivation, and general-purpose integrity checking.

	@param data Input data.
	@return buffer -- 32-byte (256-bit) digest.
]=]
function hash.sha256(data: buffer): buffer
	return _h.sha256(data)
end

--[=[
	Computes the SHA-384 digest of `data`.

	@param data Input data.
	@return buffer -- 48-byte (384-bit) digest.
]=]
function hash.sha384(data: buffer): buffer
	return _h.sha384(data)
end

--[=[
	Computes the SHA-512 digest of `data`.

	Provides 512-bit security strength. Preferred over SHA-256 when
	output size matters less than collision resistance.

	@param data Input data.
	@return buffer -- 64-byte (512-bit) digest.
]=]
function hash.sha512(data: buffer): buffer
	return _h.sha512(data)
end

--[=[
	Computes the SHA3-224 digest of `data`.

	SHA-3 is based on the Keccak sponge construction, an entirely
	different design from SHA-2. Resistant to length-extension attacks.

	@param data Input data.
	@return buffer -- 28-byte (224-bit) digest.
]=]
function hash.sha3_224(data: buffer): buffer
	return _h.sha3_224(data)
end

--[=[
	Computes the SHA3-256 digest of `data`.

	@param data Input data.
	@return buffer -- 32-byte (256-bit) digest.
]=]
function hash.sha3_256(data: buffer): buffer
	return _h.sha3_256(data)
end

--[=[
	Computes the SHA3-384 digest of `data`.

	@param data Input data.
	@return buffer -- 48-byte (384-bit) digest.
]=]
function hash.sha3_384(data: buffer): buffer
	return _h.sha3_384(data)
end

--[=[
	Computes the SHA3-512 digest of `data`.

	@param data Input data.
	@return buffer -- 64-byte (512-bit) digest.
]=]
function hash.sha3_512(data: buffer): buffer
	return _h.sha3_512(data)
end
]==]

return table.freeze(hash)
