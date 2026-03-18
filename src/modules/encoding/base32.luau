--[=[
	Base32 encoding utilities.

	Encodes and decodes binary `buffer` data using the standard Base32
	alphabet (RFC 4648 § 6: `A–Z`, `2–7`). Padding characters are not
	emitted.

	```luau
	local base32 = require("@eryx/encoding/base32")
	local encoded = base32.encode(buffer.fromstring("Hello"))
	print(encoded) -- "JBSWY3DP"
	```
]=]

local base32 = {}

local B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

--[=[
	Encodes a buffer into a Base32 string.

	@param buf The binary data to encode.
	@return string -- The Base32-encoded string.
]=]
function base32.encode(buf: buffer): string
	local len = buffer.len(buf)
	local out = {}

	local bits = 0
	local value = 0

	for i = 0, len - 1 do
		value = bit32.bor(bit32.lshift(value, 8), buffer.readu8(buf, i))
		bits += 8

		while bits >= 5 do
			local index = bit32.band(bit32.rshift(value, (bits - 5)), 31)
			bits -= 5
			out[#out + 1] = B32_ALPHABET:sub(index + 1, index + 1)
		end
	end

	if bits > 0 then
		local index = bit32.band(bit32.lshift(value, (5 - bits)), 31)
		out[#out + 1] = B32_ALPHABET:sub(index + 1, index + 1)
	end

	return table.concat(out)
end

local B32_MAP = table.create(256, -1)
do
	for i = 1, #B32_ALPHABET do
		B32_MAP[string.byte(B32_ALPHABET, i)] = i - 1
	end
end

--[=[
	Decodes a Base32 string back into a buffer.

	Padding characters (`=`) and whitespace are ignored.

	@param str The Base32-encoded string.
	@return buffer -- The decoded binary data.
]=]
function base32.decode(str: string): buffer
	local out = {}
	local bits = 0
	local value = 0

	for i = 1, #str do
		local v = B32_MAP[string.byte(str, i)]
		if v >= 0 then
			value = bit32.bor(bit32.lshift(value, 5), v)
			bits += 5

			if bits >= 8 then
				bits -= 8
				out[#out + 1] = string.char(bit32.band(bit32.rshift(value, bits), 0xFF))
			end
		end
	end

	local buf = buffer.create(#out)
	for i = 1, #out do
		local byte = string.byte(out[i])
		buffer.writeu8(buf, i - 1, byte)
	end

	return buf
end

return base32
