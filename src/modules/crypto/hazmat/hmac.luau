--[=[
	HMAC (Hash-based Message Authentication Code).

	Computes an authentication tag over streamed data using a secret `key`
	and the chosen hash algorithm. The output length equals the digest size
	of the underlying hash.

	```luau
	local hmac = require("@eryx/crypto/hazmat/hmac")
	local hex  = require("@eryx/encoding/hex")

	local key = buffer.fromstring("secret")
	local ctx = hmac.new("sha256", key)
	ctx:update(buffer.fromstring("hello"))
	print(hex.encode(ctx:final()))
	```
]=]

local _hm = require("@eryx/crypto/hazmat/_crypto").hmac

export type Context = {
	update: (self: Context, data: buffer) -> (),
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
}

local hmac = {}

--[=[
	Creates a streaming HMAC context.

	Supported algorithms currently include `"md5"`, `"sha1"`, `"sha224"`,
	`"sha256"`, `"sha384"`, `"sha512"`, `"sha3_224"`, `"sha3_256"`,
	`"sha3_384"`, and `"sha3_512"`.

	@param algorithm Hash algorithm name.
	@param key Secret key (any length).
	@return Context -- Streaming HMAC context.
]=]
function hmac.new(algorithm: string, key: buffer): Context
	return _hm.new(algorithm, key)
end

return table.freeze(hmac)
