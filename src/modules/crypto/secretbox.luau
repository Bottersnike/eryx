--[=[
	High-level symmetric authenticated encryption.

	This module provides a simple "secretbox"-style API built on
	ChaCha20-Poly1305. It is intended as the user-facing way to encrypt a
	message with a shared secret key without manually managing nonces or
	separate authentication tags.

	The serialized ciphertext format is:

	- `algorithm || nonce || ciphertext || tag`

	The current algorithm marker is:

	- `"$c$"` for ChaCha20-Poly1305

	```luau
	local secretbox = require("@eryx/crypto/secretbox")

	local ciphertext, key = secretbox.seal(buffer.fromstring("hello"))
	local opened = secretbox.open(ciphertext, key)

	assert(buffer.tostring(opened) == "hello")
	```
]=]

local chacha20 = require("@eryx/crypto/hazmat/chacha20")
local random = require("@eryx/crypto/hazmat/random")

local secretbox = {}

local KEY_LEN = 32
local NONCE_LEN = 12
local TAG_LEN = 16
local CIPHERTEXT_TAG = "$c$"

local function concat(buffers: { buffer }): buffer
	local totalLen = 0

	for _, part in buffers do
		totalLen += buffer.len(part)
	end

	local out = buffer.create(totalLen)
	local offset = 0

	for _, part in buffers do
		buffer.copy(out, offset, part)
		offset += buffer.len(part)
	end

	return out
end

local function parseCiphertext(data: buffer): (buffer, buffer, buffer)
	local dataLen = buffer.len(data)
	local tagLen = #CIPHERTEXT_TAG
	local minimumLen = tagLen + NONCE_LEN + TAG_LEN

	if dataLen < minimumLen then
		error("secretbox ciphertext is truncated")
	end

	if buffer.readstring(data, 0, tagLen) ~= CIPHERTEXT_TAG then
		error("unsupported secretbox ciphertext type")
	end

	local nonce = buffer.create(NONCE_LEN)
	local tag = buffer.create(TAG_LEN)
	local ciphertextLen = dataLen - minimumLen
	local ciphertext = buffer.create(ciphertextLen)

	buffer.copy(nonce, 0, data, tagLen, NONCE_LEN)
	buffer.copy(ciphertext, 0, data, tagLen + NONCE_LEN, ciphertextLen)
	buffer.copy(tag, 0, data, tagLen + NONCE_LEN + ciphertextLen, TAG_LEN)

	return nonce, ciphertext, tag
end

--[=[
	Generates a fresh 32-byte secretbox key.

	This key is suitable for use with [[seal]] and [[open]]. Treat it as a
	shared secret and store or transmit it securely.

	```luau
	local key = secretbox.keygen()
	```

	@return buffer -- 32 random bytes.
]=]
function secretbox.keygen(): buffer
	return random.bytes(KEY_LEN)
end

--[=[
	Encrypts and authenticates a message.

	If `key` is omitted, a fresh random key is generated and returned as
	the second result. The first result is a self-contained ciphertext
	buffer containing the algorithm tag, nonce, ciphertext, and Poly1305
	tag.

	```luau
	local ciphertext, key = secretbox.seal(buffer.fromstring("top secret"))
	```

	@param message The plaintext message to encrypt.
	@param key     Optional 32-byte symmetric key. If omitted, one is generated.
	@return buffer -- Serialized ciphertext in `algorithm || nonce || ciphertext || tag` form.
	@return buffer -- The key used for encryption.
]=]
function secretbox.seal(message: buffer, key: buffer?): (buffer, buffer)
	local boxKey = key or secretbox.keygen()
	local nonce = random.bytes(NONCE_LEN)
	local ctx = chacha20.new(boxKey, "poly1305", "encrypt", nonce)
	local ciphertext = concat({
		ctx:update(message),
		ctx:final(),
	})
	local tag = ctx:getTag()

	return concat({
		buffer.fromstring(CIPHERTEXT_TAG),
		nonce,
		ciphertext,
		tag,
	}), boxKey
end

--[=[
	Decrypts and verifies a serialized secretbox ciphertext.

	Raises an error if the algorithm tag is unsupported, the ciphertext is
	truncated, or authentication fails.

	```luau
	local message = secretbox.open(ciphertext, key)
	```

	@param ciphertext A buffer previously returned by [[seal]].
	@param key        The 32-byte secret key used to encrypt it.
	@return buffer -- Decrypted plaintext.
]=]
function secretbox.open(ciphertext: buffer, key: buffer): buffer
	local nonce, body, tag = parseCiphertext(ciphertext)
	local ctx = chacha20.new(key, "poly1305", "decrypt", nonce)
	ctx:setTag(tag)
	return concat({
		ctx:update(body),
		ctx:final(),
	})
end

return table.freeze(secretbox)
