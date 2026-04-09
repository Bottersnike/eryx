--[=[
	Argon2 password hashing.

	Provides the three Argon2 variants:

	- **Argon2d**: data-dependent memory access. Fast, but not suitable
	  for password hashing in side-channel-sensitive environments.
	- **Argon2i**: data-independent memory access. Safer against side
	  channels, but typically slower.
	- **Argon2id**: hybrid mode combining the best properties of Argon2i
	  and Argon2d. This is generally the preferred default for password
	  hashing.

	Each variant is available in two forms:

	- `*_hash_raw`: returns the raw derived bytes as a `buffer`
	- `*_hash_encoded`: returns the PHC string form such as
	  `"$argon2id$v=19$m=65536,t=3,p=4$..."`

	The encoded form is the one you usually want to store in a database,
	since it embeds the variant and cost parameters. Use
	[[verify_encoded]] to check a password against one of those strings.

	```luau
	local argon2 = require("@eryx/crypto/hazmat/argon2")
	local random = require("@eryx/crypto/hazmat/random")

	local password = buffer.fromstring("hunter2")
	local salt = random.bytes(16)

	local encoded = argon2.argon2id_hash_encoded(password, salt, 3, 65536, 1, 32)
	assert(argon2.verify_encoded(encoded, password))
	```
]=]

-- Type stub for the native Argon2 module.
-- The DLL takes precedence at runtime; this file exists for IDE type support.

export type Version = number --- 0x10 | 0x13

local argon2 = {}

--[=[
	Hashes a password with Argon2d and returns the raw hash bytes.

	Argon2d uses data-dependent memory access, making it a poor default
	for password hashing on shared hardware, but it can be useful for
	specialised proof-of-work or side-channel-free environments.

	@param password    Password or secret to hash.
	@param salt        Unique salt. Argon2 requires at least 8 bytes; 16+
	                    bytes is a sensible default.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return buffer -- Raw hash output.
]=]
function argon2.argon2d_hash_raw(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): buffer
	return nil :: any
end

--[=[
	Hashes a password with Argon2i and returns the raw hash bytes.

	Argon2i uses data-independent memory access and is safer in the
	presence of timing/cache-observation attacks, but it is usually not
	the first choice now that Argon2id exists.

	@param password    Password or secret to hash.
	@param salt        Unique salt.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return buffer -- Raw hash output.
]=]
function argon2.argon2i_hash_raw(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): buffer
	return nil :: any
end

--[=[
	Hashes a password with Argon2id and returns the raw hash bytes.

	Argon2id is the recommended general-purpose Argon2 mode for password
	hashing.

	@param password    Password or secret to hash.
	@param salt        Unique salt.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return buffer -- Raw hash output.
]=]
function argon2.argon2id_hash_raw(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): buffer
	return nil :: any
end

--[=[
	Hashes a password with Argon2d and returns the PHC encoded string.

	This is the storage-friendly string form containing the variant,
	version, cost parameters, salt, and hash.

	@param password    Password or secret to hash.
	@param salt        Unique salt.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return string -- Encoded Argon2 hash string.
]=]
function argon2.argon2d_hash_encoded(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): string
	return nil :: any
end

--[=[
	Hashes a password with Argon2i and returns the PHC encoded string.

	@param password    Password or secret to hash.
	@param salt        Unique salt.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return string -- Encoded Argon2 hash string.
]=]
function argon2.argon2i_hash_encoded(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): string
	return nil :: any
end

--[=[
	Hashes a password with Argon2id and returns the PHC encoded string.

	This is the usual API you want for password storage.

	@param password    Password or secret to hash.
	@param salt        Unique salt.
	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads to request.
	@param hash_len    Desired raw output length in bytes.
	@param version     Argon2 version. Defaults to [[VERSION_NUMBER]].
	@return string -- Encoded Argon2 hash string.
]=]
function argon2.argon2id_hash_encoded(
	password: buffer,
	salt: buffer,
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	hash_len: number,
	version: Version?
): string
	return nil :: any
end

--[=[
	Verifies a password against an encoded Argon2 hash string.

	The variant is inferred from the encoded PHC prefix, so the same
	function works for Argon2d, Argon2i, and Argon2id encoded hashes.

	@param encoded  Encoded PHC hash string.
	@param password Password to test.
	@return boolean -- `true` if the password matches.
]=]
function argon2.verify_encoded(encoded: string, password: buffer): boolean
	return nil :: any
end

--[=[
	Returns the maximum encoded string length for the given parameters.

	This can be useful when pre-allocating storage or validating size
	limits before calling one of the `*_hash_encoded` functions.

	@param time_cost   Number of passes over memory.
	@param memory_kib  Memory cost in KiB.
	@param parallelism Number of lanes/threads.
	@param salt_len    Salt length in bytes.
	@param hash_len    Raw hash length in bytes.
	@param variant     One of `"argon2d"`, `"argon2i"`, or `"argon2id"`.
	@return number -- Maximum encoded string length including the trailing
	                  NUL used by the underlying C API.
]=]
function argon2.encoded_len(
	time_cost: number,
	memory_kib: number,
	parallelism: number,
	salt_len: number,
	hash_len: number,
	variant: "argon2d" | "argon2i" | "argon2id"
): number
	return nil :: any
end

--[=[
	Argon2 version 1.0 (`0x10`).

	This is mostly useful for interoperability with old hashes.
]=]
argon2.VERSION_10 = 0x10

--[=[
	Argon2 version 1.3 (`0x13`), the modern version used in most contexts.
]=]
argon2.VERSION_13 = 0x13

--[=[
	The default Argon2 version used by this module.
]=]
argon2.VERSION_NUMBER = 0x13

return table.freeze(argon2)
