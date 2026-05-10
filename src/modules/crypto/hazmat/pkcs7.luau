--[=[
	PKCS#7 padding helpers for block ciphers.

	This module is intended to pair with the raw block-cipher APIs in
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

	@param data Padded input bytes.
	@param blockSize Block size in bytes, typically 8 or 16.
	@return buffer -- New buffer containing the unpadded data.
]=]
function pkcs7.unpad(data: buffer, blockSize: number): buffer
	local size = checkBlockSize(blockSize)
	local dataLen = buffer.len(data)
	if dataLen == 0 then
		error("pkcs7 data must not be empty", 2)
	end
	if dataLen % size ~= 0 then
		error("pkcs7 data length must be a multiple of blockSize", 2)
	end

	local padLen = buffer.readu8(data, dataLen - 1)
	if padLen < 1 or padLen > size then
		error("invalid PKCS#7 padding length", 2)
	end

	for i = 0, padLen - 1 do
		if buffer.readu8(data, dataLen - 1 - i) ~= padLen then
			error("invalid PKCS#7 padding bytes", 2)
		end
	end

	local out = buffer.create(dataLen - padLen)
	if dataLen > padLen then
		buffer.copy(out, 0, data, 0, dataLen - padLen)
	end
	return out
end

return table.freeze(pkcs7)
