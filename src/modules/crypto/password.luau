--[=[
	High-level password hashing and verification.

	This library is the user-facing API for password storage. It hashes
	passwords with Argon2id using sensible defaults and stores them in a
	tagged string format so the scheme can evolve later without guessing.

	The current format is:

	- `"$a$<argon2-phc-string>"`

	where the inner value is the standard Argon2 PHC encoded form
	containing the salt and cost parameters.

	```luau
	local password = require("@eryx/crypto/password")

	local stored = password.hash("hunter2")
	assert(password.verify("hunter2", stored))
	assert(not password.verify("wrong-password", stored))
	```
]=]

local argon2 = require("@eryx/crypto/hazmat/argon2")
local random = require("@eryx/crypto/hazmat/random")

local password = {}

local SALT_LEN = 16
local TIME_COST = 2
local MEMORY_KIB = 16384
local PARALLELISM = 1
local HASH_LEN = 32
local ARGON2ID_TAG = "$a$"

--[=[
	Hashes a plaintext password for storage.

	The result is a tagged string beginning with `"$a$"` followed by an
	Argon2id PHC string. The PHC portion embeds the salt and work-factor
	parameters, so you only need to store the returned string.

	```luau
	local stored = password.hash("correct horse battery staple")
	```

	@param password The plaintext password to hash.
	@return string -- Tagged password hash suitable for database storage.
]=]
function password.hash(password: string): string
	local encoded = argon2.argon2id_hash_encoded(
		buffer.fromstring(password),
		random.bytes(SALT_LEN),
		TIME_COST,
		MEMORY_KIB,
		PARALLELISM,
		HASH_LEN
	)

	return ARGON2ID_TAG .. encoded
end

--[=[
	Verifies a plaintext password against a stored hash.

	The hash must be in this library's tagged format. Returns `true` if the
	password matches, otherwise `false`. Raises an error if the hash uses
	an unsupported tag or is malformed.

	```luau
	if password.verify(inputPassword, storedHash) then
		print("password accepted")
	end
	```

	@param password The plaintext password to test.
	@param hash     The stored tagged hash string returned by [[hash]].
	@return boolean -- `true` if the password matches.
]=]
function password.verify(password: string, hash: string): boolean
	local tag, value = hash:match("^%$([^$]+)%$(.+)$")

	if tag and value then
		if tag == "a" then
			return argon2.verify_encoded(value, buffer.fromstring(password))
		end

		error(`Unsupported password hash algorithm tag "${tag}"`)
	else
		error(`Unsupported password hash type`)
	end
end

return table.freeze(password)
