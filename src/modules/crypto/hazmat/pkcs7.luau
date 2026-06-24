--[=[
	PKCS#7 padding helpers for block ciphers.

	This library is intended to pair with the raw block-cipher APIs in
	`@eryx/crypto/hazmat/*`. It pads arbitrary-length data up to a block
	boundary and validates/removes PKCS#7 padding explicitly.

	```luau
	local aes = require("@eryx/crypto/hazmat/aes")
	local pkcs7 = require("@eryx/crypto/hazmat/pkcs7")

	local key = buffer.create(16)
	local iv = buffer.create(16)
	local padded = pkcs7.pad(buffer.fromstring("hello"), 16)
	local encrypt = aes.new(key, "cbc", "encrypt", iv)
	local ct = buffer.concat({ encrypt:update(padded), encrypt:final() })
	local decrypt = aes.new(key, "cbc", "decrypt", iv)
	local pt = pkcs7.unpad(buffer.concat({ decrypt:update(ct), decrypt:final() }), 16)
	```
]=]

local pkcs7 = {}

local rshift = bit32.rshift
local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor

-- Constant-time helpers operating on byte-sized values. They avoid
-- data-dependent branches so that padding validation does not leak *which*
-- byte mismatched or *how many* padding bytes were scanned through timing.

-- Returns 1 if `x` is zero, else 0. `x - 1` borrows into bit 31 only when
-- `x == 0` (after the uint32 wrap), giving a branch-free zero test.
local function ctIsZero(x: number): number
	return rshift(band(x - 1, 0xFFFFFFFF), 31)
end

-- Returns 1 if `a < b`, else 0, for `a`/`b` in 0..255. When `a < b`, `a - b`
-- is negative and wraps with bit 31 set.
local function ctLt(a: number, b: number): number
	return rshift(band(a - b, 0xFFFFFFFF), 31)
end

local function checkBlockSize(blockSize: number): number
	if blockSize % 1 ~= 0 then
		error("blockSize must be an integer", 2)
	end
	if blockSize < 1 or blockSize > 255 then
		error("blockSize must be between 1 and 255", 2)
	end
	return blockSize
end

--[=[
	Appends PKCS#7 padding to `data`.

	If the input is already aligned, a full block of padding is added.

	@param data Raw input bytes.
	@param blockSize Block size in bytes, typically 8 or 16.
	@return buffer -- New buffer containing the padded data.
]=]
function pkcs7.pad(data: buffer, blockSize: number): buffer
	local size = checkBlockSize(blockSize)
	local dataLen = buffer.len(data)
	local padLen = size - (dataLen % size)
	if padLen == 0 then
		padLen = size
	end

	local out = buffer.create(dataLen + padLen)
	buffer.copy(out, 0, data)
	for i = 0, padLen - 1 do
		buffer.writeu8(out, dataLen + i, padLen)
	end
	return out
end

--[=[
	Validates and removes PKCS#7 padding from `data`.

	The input length must be non-zero and a multiple of `blockSize`.

	Padding validation runs in constant time with respect to the buffer
	*contents*: every candidate padding byte is examined regardless of the
	encoded length, and a single generic error is raised on any failure, so an
	attacker cannot learn which byte was wrong from timing or error text. Note
	that this does not remove the padding oracle entirely — a caller can still
	observe success versus failure, and the returned length reveals `padLen`.
	To defend against padding-oracle attacks, pair this with authenticated
	encryption (see `@eryx/crypto/secretbox`) or verify a MAC before unpadding.

	@param data Padded input bytes.
	@param blockSize Block size in bytes, typically 8 or 16.
	@return buffer -- New buffer containing the unpadded data.
]=]
function pkcs7.unpad(data: buffer, blockSize: number): buffer
	local size = checkBlockSize(blockSize)
	local dataLen = buffer.len(data)
	-- Length-based checks may short-circuit: the buffer length is public and
	-- not a secret the padding oracle could exploit.
	if dataLen == 0 then
		error("pkcs7 data must not be empty", 2)
	end
	if dataLen % size ~= 0 then
		error("pkcs7 data length must be a multiple of blockSize", 2)
	end

	local padLen = buffer.readu8(data, dataLen - 1)

	-- `bad` accumulates every reason the padding is invalid without branching.
	-- padLen must be in 1..size.
	local bad = bor(ctIsZero(padLen), ctLt(size, padLen))

	-- Examine the trailing `size` bytes unconditionally. Each byte that falls
	-- within the padding region (j < padLen) must equal padLen; iterating the
	-- full block keeps the running time independent of the padding length.
	for j = 0, size - 1 do
		local b = buffer.readu8(data, dataLen - 1 - j)
		local within = ctLt(j, padLen)
		local eq = ctIsZero(bxor(b, padLen))
		bad = bor(bad, band(within, bxor(eq, 1)))
	end

	if bad ~= 0 then
		error("invalid PKCS#7 padding", 2)
	end

	local outLen = dataLen - padLen
	local out = buffer.create(outLen)
	if outLen > 0 then
		buffer.copy(out, 0, data, 0, outLen)
	end
	return out
end

return table.freeze(pkcs7)
