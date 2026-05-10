--[=[
	ChaCha20 stream cipher and ChaCha20-Poly1305 AEAD.

	ChaCha20 is a fast, secure stream cipher designed by Daniel J.
	Bernstein. It is widely used in TLS 1.3 and WireGuard as an
	alternative to AES when hardware AES acceleration is unavailable.

	- **ChaCha20 (stream)** - symmetric stream cipher; keystream is XOR'd
	  with the plaintext. No authentication; pair with an HMAC if you need
	  it, or use the Poly1305 variant.
	- **ChaCha20-Poly1305** - authenticated encryption (AEAD) combining
	  ChaCha20 with the Poly1305 MAC. This is the recommended variant.

	Key: **32 bytes**. Nonce: **12 bytes**. Counter starts at 0.

	```luau
	local chacha20 = require("@eryx/crypto/hazmat/chacha20")

	local key   = buffer.create(32)  -- 32 zero bytes (use a real key!)
	local nonce = buffer.create(12)  -- 12 zero bytes

	-- Authenticated encryption
	local enc = chacha20.new(key, "poly1305", "encrypt", nonce)
	local ct = enc:update(buffer.fromstring("secret"))
	local tail = enc:final()
	local tag = enc:getTag()

	local dec = chacha20.new(key, "poly1305", "decrypt", nonce)
	dec:setTag(tag)
	local pt = dec:update(ct)
	local ptTail = dec:final()
	```
]=]

local _cc = require("@eryx/crypto/hazmat/_crypto").chacha20

export type Mode = "stream" | "poly1305"
export type Operation = "encrypt" | "decrypt"
export type Context = {
	update: (self: Context, data: buffer) -> buffer,
	updateAAD: (self: Context, aad: buffer) -> (),
	setTag: (self: Context, tag: buffer) -> (),
	getTag: (self: Context) -> buffer,
	final: (self: Context) -> buffer,
	close: (self: Context) -> (),
}

local chacha20 = {}

--[=[
	Creates a streaming ChaCha20 context.

	For `stream`, the nonce must be 12 bytes and the context behaves like a
	raw stream cipher with no authentication.
	For `poly1305`, the nonce must also be 12 bytes and you can use
	[[Context.updateAAD]], [[Context.setTag]], and [[Context.getTag]] for
	AEAD operation.

	@param key 32-byte ChaCha20 key.
	@param mode `"stream"` or `"poly1305"`.
	@param operation `"encrypt"` or `"decrypt"`.
	@param nonce 12-byte nonce.
	@return Context -- Streaming ChaCha20 context.
]=]
function chacha20.new(key: buffer, mode: Mode, operation: Operation, nonce: buffer): Context
	return _cc.new(key, mode, operation, nonce)
end

return table.freeze(chacha20)
