--[=[
	Type facade for the optional native crypto backend.

	This module keeps the typed hazmat crypto surface available to Luau
	callers. In builds without cryptography support,
	`require("@eryx/crypto/hazmat/_crypto")` fails immediately with a
	clear capability error.
]=]

export type HashContext = {
	update: (self: HashContext, data: buffer) -> (),
	final: (self: HashContext) -> buffer,
	close: (self: HashContext) -> (),
}

export type HashLib = {
	new: (algorithm: string) -> HashContext,
}

export type HmacContext = {
	update: (self: HmacContext, data: buffer) -> (),
	final: (self: HmacContext) -> buffer,
	close: (self: HmacContext) -> (),
}

export type HmacLib = {
	new: (algorithm: string, key: buffer) -> HmacContext,
}

export type AesContext = {
	update: (self: AesContext, data: buffer) -> buffer,
	updateAAD: (self: AesContext, aad: buffer) -> (),
	setTag: (self: AesContext, tag: buffer) -> (),
	getTag: (self: AesContext) -> buffer,
	final: (self: AesContext) -> buffer,
	close: (self: AesContext) -> (),
}

-- Symmetric cipher: key, iv, data -> ciphertext (hazmat surface is raw/unpadded)
export type AesLib = {
	new: (key: buffer, mode: string, operation: "encrypt" | "decrypt", iv_or_nonce: buffer?) -> AesContext,
	ccm_encrypt: (key: buffer, nonce: buffer, data: buffer, aad: buffer?, tag_len: number?) -> (buffer, buffer),
	ccm_decrypt: (key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?) -> buffer,
}

export type CamelliaLib = {
	new: (key: buffer, mode: string, operation: "encrypt" | "decrypt", iv_or_nonce: buffer?) -> AesContext,
}

-- 3DES only; key must be 24 bytes
export type DesLib = {
	new: (key: buffer, mode: string, operation: "encrypt" | "decrypt", iv_or_nonce: buffer?) -> AesContext,
}

export type ChaCha20Lib = {
	new: (key: buffer, mode: string, operation: "encrypt" | "decrypt", nonce: buffer) -> AesContext,
}

export type KdfLib = {
	hkdf_sha256: (ikm: buffer, salt: buffer?, info: buffer?, length: number) -> buffer,
	hkdf_sha512: (ikm: buffer, salt: buffer?, info: buffer?, length: number) -> buffer,
	pbkdf2_sha256: (password: buffer, salt: buffer, iterations: number, length: number) -> buffer,
	pbkdf2_sha512: (password: buffer, salt: buffer, iterations: number, length: number) -> buffer,
}

export type RsaLib = {
	generate_key: (bits: number?) -> string,
	get_public_pem: (private_pem: string) -> string,
	encrypt_pkcs1: (public_pem: string, data: buffer) -> buffer,
	decrypt_pkcs1: (private_pem: string, data: buffer) -> buffer,
	encrypt_oaep: (public_pem: string, data: buffer, hash: string?) -> buffer,
	decrypt_oaep: (private_pem: string, data: buffer, hash: string?) -> buffer,
	sign_pkcs1: (private_pem: string, data: buffer, hash: string?) -> buffer,
	verify_pkcs1: (public_pem: string, data: buffer, signature: buffer, hash: string?) -> boolean,
	sign_pss: (private_pem: string, data: buffer, hash: string?) -> buffer,
	verify_pss: (public_pem: string, data: buffer, signature: buffer, hash: string?) -> boolean,
	private_to_der: (private_pem: string) -> buffer,
	public_to_der: (public_pem: string) -> buffer,
	private_from_der: (der: buffer) -> string,
	public_from_der: (der: buffer) -> string,
	get_key_bits: (pem: string) -> number,
}

export type EccLib = {
	generate_key: (curve: string?) -> string,
	get_public_pem: (private_pem: string) -> string,
	sign: (private_pem: string, data: buffer, hash: string?) -> buffer,
	verify: (public_pem: string, data: buffer, signature: buffer, hash: string?) -> boolean,
	derive: (private_pem: string, peer_public_pem: string) -> buffer,
	private_to_der: (private_pem: string) -> buffer,
	public_to_der: (public_pem: string) -> buffer,
	private_from_der: (der: buffer) -> string,
	public_from_der: (der: buffer) -> string,
	get_key_bits: (pem: string) -> number,
	get_curve: (pem: string) -> string,
}

export type RandomLib = {
	randint: (n: number) -> number,
	choice: (tbl: { any }) -> any,
	bits: (n: number) -> number,
	bytes: (n: number) -> buffer,
	hex: (n: number) -> string,
}

local capability = require("@eryx/capability")
local _crypto = {}
_crypto.hash = {} :: HashLib
_crypto.hmac = {} :: HmacLib
_crypto.aes = {} :: AesLib
_crypto.camellia = {} :: CamelliaLib
_crypto.des = {} :: DesLib
_crypto.chacha20 = {} :: ChaCha20Lib
_crypto.kdf = {} :: KdfLib
_crypto.ecc = {} :: EccLib
_crypto.rsa = {} :: RsaLib
_crypto.random = {} :: RandomLib

return capability.require(
	"@eryx/crypto/hazmat/_native",
	"Native cryptography support",
	"Enable cryptography support to use @eryx/crypto/hazmat/_crypto."
) :: typeof(_crypto)
