--[=[
	RSA asymmetric cryptography.

	Provides key generation, PEM/DER conversion, PKCS#1 v1.5 and OAEP
	encryption/decryption, and PKCS#1 v1.5 signing/verification.

	Keys are represented as PEM strings (the standard `-----BEGIN RSA
	PRIVATE KEY-----` / `-----BEGIN PUBLIC KEY-----` format). Use
	[[private_to_der]] / [[public_to_der]] to convert to raw DER bytes,
	or `@eryx/crypto/pem` to wrap/unwrap arbitrary DER blobs.

	```luau
	local rsa = require("@eryx/crypto/rsa")

	-- Generate a 2048-bit key pair
	local priv = rsa.generateKey(2048)
	local pub  = rsa.getPublicPem(priv)

	-- Encrypt / decrypt with OAEP
	local ct = rsa.encryptOaep(pub,  buffer.fromstring("hello"))
	local pt = rsa.decryptOaep(priv, ct)
	assert(buffer.tostring(pt) == "hello")

	-- Sign / verify
	local sig = rsa.signPkcs1(priv, buffer.fromstring("message"))
	assert(rsa.verifyPkcs1(pub, buffer.fromstring("message"), sig))
	```
]=]

local _rsa = require("@eryx/crypto/_crypto").rsa

local rsa = {}

--[=[
	Generates a new RSA private key and returns it as a PEM string.

	The key includes all parameters needed for both encryption and
	signing. Extract the corresponding public key with [[get_public_pem]].

	```luau
	local priv = rsa.generateKey(2048)
	local pub  = rsa.getPublicPem(priv)
	```

	@param bits Key size in bits. Defaults to 2048. Common values: 2048, 3072, 4096.
	@return string -- PEM-encoded RSA private key.
]=]
function rsa.generateKey(bits: number?): string
	return _rsa.generateKey(bits)
end

--[=[
	Derives the public key from a PEM-encoded RSA private key.

	@param private_pem PEM-encoded RSA private key.
	@return string -- PEM-encoded RSA public key.
]=]
function rsa.getPublicPem(private_pem: string): string
	return _rsa.getPublicPem(private_pem)
end

--[=[
	Encrypts `data` using RSA-PKCS#1 v1.5.

	PKCS#1 v1.5 encryption is widely supported but has known weaknesses
	(ROBOT attack, Bleichenbacher oracle). Prefer [[encrypt_oaep]] for
	new designs.

	Maximum plaintext size: `key_bytes - 11`.

	@param public_pem PEM-encoded RSA public key.
	@param data       Plaintext to encrypt.
	@return buffer -- Ciphertext (same length as the key modulus).
]=]
function rsa.encryptPkcs1(public_pem: string, data: buffer): buffer
	return _rsa.encryptPkcs1(public_pem, data)
end

--[=[
	Decrypts RSA-PKCS#1 v1.5 ciphertext.

	@param private_pem PEM-encoded RSA private key.
	@param data        Ciphertext to decrypt.
	@return buffer -- Plaintext.
]=]
function rsa.decryptPkcs1(private_pem: string, data: buffer): buffer
	return _rsa.decryptPkcs1(private_pem, data)
end

--[=[
	Encrypts `data` using RSA-OAEP.

	OAEP (Optimal Asymmetric Encryption Padding) is the modern, secure
	RSA encryption scheme. Use `"sha256"` (the default) or `"sha1"` for
	the OAEP hash parameter.

	Maximum plaintext size: `key_bytes - 2 * hash_bytes - 2`.
	For a 2048-bit key with SHA-256: 256 - 2×32 - 2 = 190 bytes.

	@param public_pem PEM-encoded RSA public key.
	@param data       Plaintext to encrypt.
	@param hash       Hash for the OAEP mask - `"sha256"` (default) or `"sha1"`.
	@return buffer -- Ciphertext.
]=]
function rsa.encryptOaep(public_pem: string, data: buffer, hash: string?): buffer
	return _rsa.encryptOaep(public_pem, data, hash)
end

--[=[
	Decrypts RSA-OAEP ciphertext.

	@param private_pem PEM-encoded RSA private key.
	@param data        Ciphertext to decrypt.
	@param hash        Hash for the OAEP mask - must match what was used for encryption.
	@return buffer -- Plaintext.
]=]
function rsa.decryptOaep(private_pem: string, data: buffer, hash: string?): buffer
	return _rsa.decryptOaep(private_pem, data, hash)
end

--[=[
	Signs `data` using RSA-PKCS#1 v1.5.

	The data is hashed internally before signing. Supported hash values:
	`"sha256"` (default), `"sha1"`, `"sha384"`, `"sha512"`.

	```luau
	local sig = rsa.signPkcs1(priv, buffer.fromstring("message"))
	assert(rsa.verifyPkcs1(pub, buffer.fromstring("message"), sig))
	```

	@param private_pem PEM-encoded RSA private key.
	@param data        Message to sign.
	@param hash        Hash algorithm - `"sha256"` (default), `"sha1"`, `"sha384"`, `"sha512"`.
	@return buffer -- Signature (same length as the key modulus).
]=]
function rsa.signPkcs1(private_pem: string, data: buffer, hash: string?): buffer
	return _rsa.signPkcs1(private_pem, data, hash)
end

--[=[
	Verifies an RSA-PKCS#1 v1.5 signature.

	Returns `true` if the signature is valid for the given data and
	public key, `false` otherwise.

	@param public_pem PEM-encoded RSA public key.
	@param data       The original message.
	@param signature  Signature to verify.
	@param hash       Hash algorithm - must match what was used for signing.
	@return boolean -- `true` if the signature is valid.
]=]
function rsa.verifyPkcs1(public_pem: string, data: buffer, signature: buffer, hash: string?): boolean
	return _rsa.verifyPkcs1(public_pem, data, signature, hash)
end

--[=[
	Encodes a PEM private key as raw DER bytes.

	DER (Distinguished Encoding Rules) is the binary ASN.1 representation
	that PEM wraps in base64. Use this when a library or protocol requires
	the raw binary form.

	```luau
	local der = rsa.privateToDer(priv)
	local priv2 = rsa.privateFromDer(der)  -- round-trip
	```

	@param private_pem PEM-encoded RSA private key.
	@return buffer -- Raw DER-encoded private key.
]=]
function rsa.privateToDer(private_pem: string): buffer
	return _rsa.privateToDer(private_pem)
end

--[=[
	Encodes a PEM public key as raw DER bytes.

	@param public_pem PEM-encoded RSA public key.
	@return buffer -- Raw DER-encoded public key (SubjectPublicKeyInfo format).
]=]
function rsa.publicToDer(public_pem: string): buffer
	return _rsa.publicToDer(public_pem)
end

--[=[
	Parses a DER-encoded RSA private key and returns it as a PEM string.

	@param der Raw DER-encoded RSA private key.
	@return string -- PEM-encoded RSA private key.
]=]
function rsa.privateFromDer(der: buffer): string
	return _rsa.privateFromDer(der)
end

--[=[
	Parses a DER-encoded RSA public key and returns it as a PEM string.

	@param der Raw DER-encoded RSA public key (SubjectPublicKeyInfo format).
	@return string -- PEM-encoded RSA public key.
]=]
function rsa.publicFromDer(der: buffer): string
	return _rsa.publicFromDer(der)
end

--[=[
	Returns the key size in bits for a PEM-encoded private or public key.

	Useful for validating that a key meets a minimum size requirement
	before use.

	```luau
	local priv = rsa.generateKey(2048)
	assert(rsa.getKeyBits(priv) == 2048)
	assert(rsa.getKeyBits(rsa.getPublicPem(priv)) == 2048)
	```

	@param pem PEM-encoded RSA private or public key.
	@return number -- Key size in bits (e.g. 2048, 3072, 4096).
]=]
function rsa.getKeyBits(pem: string): number
	return _rsa.getKeyBits(pem)
end

return rsa
