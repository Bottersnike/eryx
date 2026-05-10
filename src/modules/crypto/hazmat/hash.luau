--[=[
	Cryptographic hash functions.

	Use [[new]] to create a streaming hash context.

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

return table.freeze(hash)
