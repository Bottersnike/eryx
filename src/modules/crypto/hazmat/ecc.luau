--[=[
	Elliptic-curve cryptography using interoperable named curves.

	Provides named-curve key generation, PEM/DER conversion, ECDSA
	signing/verification, and ECDH shared-secret derivation.

	The initial curve set focuses on standard interoperable curves:
	`secp224r1`, `secp256r1`, `secp384r1`, `secp521r1`, and `secp256k1`.

	```luau
	local ecc = require("@eryx/crypto/hazmat/ecc")

	local alicePriv = ecc.generateKey("secp256r1")
	local alicePub = ecc.getPublicPem(alicePriv)

	local bobPriv = ecc.generateKey("secp256r1")
	local bobPub = ecc.getPublicPem(bobPriv)

	local sig = ecc.sign(alicePriv, buffer.fromstring("hello"))
	assert(ecc.verify(alicePub, buffer.fromstring("hello"), sig))

	local aliceSecret = ecc.derive(alicePriv, bobPub)
	local bobSecret = ecc.derive(bobPriv, alicePub)
	assert(buffer.tostring(aliceSecret) == buffer.tostring(bobSecret))
	```
]=]

local _ecc = require("@eryx/crypto/hazmat/_crypto").ecc

local ecc = {}

--[=[
	Generates a new ECC private key on a named curve and returns it as PEM.

	Supported curve names: `"secp224r1"`, `"secp256r1"` (default),
	`"prime256v1"`, `"secp384r1"`, `"secp521r1"`, and `"secp256k1"`.

	@param curve Curve name. Defaults to `"secp256r1"`.
	@return string -- PEM-encoded ECC private key.
]=]
function ecc.generateKey(curve: string?): string
	return _ecc.generate_key(curve)
end

--[=[
	Derives the public key from a PEM-encoded ECC private key.

	@param private_pem PEM-encoded ECC private key.
	@return string -- PEM-encoded ECC public key.
]=]
function ecc.getPublicPem(private_pem: string): string
	return _ecc.get_public_pem(private_pem)
end

--[=[
	Signs `data` using ECDSA on the private key's curve.

	Supported hash values: `"sha256"` (default), `"sha1"`, `"sha384"`,
	and `"sha512"`.

	@param private_pem PEM-encoded ECC private key.
	@param data Message to sign.
	@param hash Hash algorithm.
	@return buffer -- ASN.1 DER-encoded ECDSA signature.
]=]
function ecc.sign(private_pem: string, data: buffer, hash: string?): buffer
	return _ecc.sign(private_pem, data, hash)
end

--[=[
	Verifies an ECDSA signature.

	@param public_pem PEM-encoded ECC public key.
	@param data Original message.
	@param signature ASN.1 DER-encoded signature.
	@param hash Hash algorithm.
	@return boolean -- `true` if the signature is valid.
]=]
function ecc.verify(public_pem: string, data: buffer, signature: buffer, hash: string?): boolean
	return _ecc.verify(public_pem, data, signature, hash)
end

--[=[
	Derives a shared secret using ECDH.

	Both keys must be on the same curve.

	@param private_pem Your PEM-encoded ECC private key.
	@param peer_public_pem Peer's PEM-encoded ECC public key.
	@return buffer -- Raw shared secret bytes.
]=]
function ecc.derive(private_pem: string, peer_public_pem: string): buffer
	return _ecc.derive(private_pem, peer_public_pem)
end

--[=[
	Encodes a PEM private key as raw DER bytes.

	@param private_pem PEM-encoded ECC private key.
	@return buffer -- Raw DER-encoded private key.
]=]
function ecc.privateToDer(private_pem: string): buffer
	return _ecc.private_to_der(private_pem)
end

--[=[
	Encodes a PEM public key as raw DER bytes.

	@param public_pem PEM-encoded ECC public key.
	@return buffer -- Raw DER-encoded public key.
]=]
function ecc.publicToDer(public_pem: string): buffer
	return _ecc.public_to_der(public_pem)
end

--[=[
	Parses a DER-encoded ECC private key and returns it as PEM.

	@param der Raw DER-encoded ECC private key.
	@return string -- PEM-encoded ECC private key.
]=]
function ecc.privateFromDer(der: buffer): string
	return _ecc.private_from_der(der)
end

--[=[
	Parses a DER-encoded ECC public key and returns it as PEM.

	@param der Raw DER-encoded ECC public key.
	@return string -- PEM-encoded ECC public key.
]=]
function ecc.publicFromDer(der: buffer): string
	return _ecc.public_from_der(der)
end

--[=[
	Returns the key size in bits for a PEM-encoded ECC key.

	@param pem PEM-encoded ECC private or public key.
	@return number -- Curve size in bits.
]=]
function ecc.getKeyBits(pem: string): number
	return _ecc.get_key_bits(pem)
end

--[=[
	Returns the canonical curve name for a PEM-encoded ECC key.

	Known return values currently include `"secp224r1"`, `"secp256r1"`,
	`"secp384r1"`, `"secp521r1"`, `"secp256k1"`, and `"unknown"` if the
	curve is not one of the canonical names recognised by this wrapper.

	@param pem PEM-encoded ECC private or public key.
	@return string -- Canonical curve name.
]=]
function ecc.getCurve(pem: string): string
	return _ecc.get_curve(pem)
end

return table.freeze(ecc)
