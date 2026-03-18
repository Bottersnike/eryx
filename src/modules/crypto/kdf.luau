--[=[
	Key Derivation Functions (KDF).

	Derives cryptographically strong keys from input key material (IKM)
	or passwords. Two families are provided:

	- **HKDF** (RFC 5869) - extract-and-expand KDF built on HMAC.
	  Best for deriving multiple keys from a single high-entropy secret
	  (e.g. a Diffie-Hellman shared secret).
	- **PBKDF2** (RFC 8018) - password-based KDF using iterated HMAC.
	  Best for deriving keys from human-chosen passwords. Use at least
	  600,000 iterations (NIST 2023 guidance).

	```luau
	local kdf = require("@eryx/crypto/kdf")
	local hex = require("@eryx/encoding/hex")

	-- Derive a 32-byte AES key from a shared secret
	local ikm  = buffer.fromstring("shared-secret")
	local salt = buffer.fromstring("random-salt")
	local info = buffer.fromstring("aes-256-key")
	local key  = kdf.hkdf_sha256(ikm, salt, info, 32)

	-- Derive a key from a password
	local dkey = kdf.pbkdf2_sha256(
	    buffer.fromstring("hunter2"),
	    buffer.fromstring("random-salt"),
	    600000, 32
	)
	```
]=]

local _kdf = require("@eryx/crypto/_crypto").kdf

local kdf = {}

--[=[
	Derives `length` bytes of key material using HKDF-SHA256.

	HKDF first extracts a pseudorandom key from `ikm` and `salt`, then
	expands it using `info` as context. Pass `nil` for `salt` to use the
	default all-zeros salt; pass `nil` for `info` if no context is needed.

	@param ikm    Input key material (the initial secret).
	@param salt   Optional random salt (recommended; improves extraction).
	@param info   Optional context string to bind the output to a purpose.
	@param length Number of bytes to derive (must not exceed 255 × 32 = 8160).
	@return buffer -- Derived key material of the requested length.
]=]
function kdf.hkdf_sha256(ikm: buffer, salt: buffer?, info: buffer?, length: number): buffer
	return _kdf.hkdf_sha256(ikm, salt, info, length)
end

--[=[
	Derives `length` bytes of key material using HKDF-SHA512.

	Same semantics as [[hkdf_sha256]] but uses SHA-512 internally, raising
	the maximum output to 255 × 64 = 16320 bytes.

	@param ikm    Input key material.
	@param salt   Optional random salt.
	@param info   Optional context string.
	@param length Number of bytes to derive (max 16320).
	@return buffer -- Derived key material.
]=]
function kdf.hkdf_sha512(ikm: buffer, salt: buffer?, info: buffer?, length: number): buffer
	return _kdf.hkdf_sha512(ikm, salt, info, length)
end

--[=[
	Derives `length` bytes from a password using PBKDF2-HMAC-SHA256.

	PBKDF2 applies the HMAC in `iterations` rounds, deliberately slowing
	down brute-force attacks. Use a unique random salt per password and
	enough iterations to make the computation take ~100 ms on your
	hardware (NIST SP 800-132 recommends ≥ 600,000 iterations with SHA-256
	as of 2023).

	@param password   The password to derive from (as a buffer).
	@param salt       A unique random salt (at least 16 bytes recommended).
	@param iterations Iteration count - higher is slower but more secure.
	@param length     Number of output bytes to derive.
	@return buffer -- Derived key material.
]=]
function kdf.pbkdf2_sha256(password: buffer, salt: buffer, iterations: number, length: number): buffer
	return _kdf.pbkdf2_sha256(password, salt, iterations, length)
end

--[=[
	Derives `length` bytes from a password using PBKDF2-HMAC-SHA512.

	Same semantics as [[pbkdf2_sha256]] but uses SHA-512. Equivalent
	iteration counts are roughly half those of SHA-256 variants for the
	same wall-clock time budget, since each round does more work.

	@param password   The password to derive from.
	@param salt       A unique random salt.
	@param iterations Iteration count.
	@param length     Number of output bytes to derive.
	@return buffer -- Derived key material.
]=]
function kdf.pbkdf2_sha512(password: buffer, salt: buffer, iterations: number, length: number): buffer
	return _kdf.pbkdf2_sha512(password, salt, iterations, length)
end

return kdf
