-- Type stub for the _crypto native DLL.
-- The DLL takes precedence at runtime; this file exists for IDE type support.

export type HashLib = {
	md5: (data: buffer) -> buffer,
	sha1: (data: buffer) -> buffer,
	sha224: (data: buffer) -> buffer,
	sha256: (data: buffer) -> buffer,
	sha384: (data: buffer) -> buffer,
	sha512: (data: buffer) -> buffer,
	sha3_224: (data: buffer) -> buffer,
	sha3_256: (data: buffer) -> buffer,
	sha3_384: (data: buffer) -> buffer,
	sha3_512: (data: buffer) -> buffer,
}

export type HmacLib = {
	md5: (key: buffer, data: buffer) -> buffer,
	sha1: (key: buffer, data: buffer) -> buffer,
	sha224: (key: buffer, data: buffer) -> buffer,
	sha256: (key: buffer, data: buffer) -> buffer,
	sha384: (key: buffer, data: buffer) -> buffer,
	sha512: (key: buffer, data: buffer) -> buffer,
	sha3_224: (key: buffer, data: buffer) -> buffer,
	sha3_256: (key: buffer, data: buffer) -> buffer,
	sha3_384: (key: buffer, data: buffer) -> buffer,
	sha3_512: (key: buffer, data: buffer) -> buffer,
}

-- Symmetric cipher: key, iv, data -> ciphertext (CBC uses PKCS7 padding)
export type CipherLib = {
	ecb_encrypt: (key: buffer, data: buffer) -> buffer,
	ecb_decrypt: (key: buffer, data: buffer) -> buffer,
	cbc_encrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	cbc_decrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	ctr_encrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	ctr_decrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	gcm_encrypt: (key: buffer, nonce: buffer, data: buffer, aad: buffer?) -> (buffer, buffer),
	gcm_decrypt: (key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?) -> buffer,
	ccm_encrypt: (key: buffer, nonce: buffer, data: buffer, aad: buffer?) -> (buffer, buffer),
	ccm_decrypt: (key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?) -> buffer,
}

export type CamelliaLib = {
	cbc_encrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	cbc_decrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	ctr_encrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	ctr_decrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	gcm_encrypt: (key: buffer, nonce: buffer, data: buffer, aad: buffer?) -> (buffer, buffer),
	gcm_decrypt: (key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?) -> buffer,
}

-- 3DES only; key must be 24 bytes
export type DesLib = {
	cbc_encrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
	cbc_decrypt: (key: buffer, iv: buffer, data: buffer) -> buffer,
}

export type ChaCha20Lib = {
	encrypt: (key: buffer, nonce: buffer, data: buffer) -> buffer,
	decrypt: (key: buffer, nonce: buffer, data: buffer) -> buffer,
	poly1305_encrypt: (key: buffer, nonce: buffer, data: buffer, aad: buffer?) -> (buffer, buffer),
	poly1305_decrypt: (key: buffer, nonce: buffer, ct: buffer, tag: buffer, aad: buffer?) -> buffer,
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
	private_to_der: (private_pem: string) -> buffer,
	public_to_der: (public_pem: string) -> buffer,
	private_from_der: (der: buffer) -> string,
	public_from_der: (der: buffer) -> string,
	get_key_bits: (pem: string) -> number,
}

local _crypto = {}
_crypto.hash     = {} :: HashLib
_crypto.hmac     = {} :: HmacLib
_crypto.aes      = {} :: CipherLib
_crypto.camellia = {} :: CamelliaLib
_crypto.des      = {} :: DesLib
_crypto.chacha20 = {} :: ChaCha20Lib
_crypto.kdf      = {} :: KdfLib
_crypto.rsa      = {} :: RsaLib

return _crypto
