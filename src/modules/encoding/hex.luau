--[=[
	Hexadecimal encoding utilities.

	Encodes binary `buffer` data into lowercase hexadecimal strings and
	decodes hex strings back into buffers. Both uppercase and lowercase
	hex digits are accepted when decoding.

	```luau
	local hex = require("@eryx/encoding/hex")
	local encoded = hex.encode(buffer.fromstring("\xff\x0a"))
	print(encoded) -- "ff0a"
	```
]=]

local hex = {}

local HEX_ALPHABET = "0123456789abcdef"

--[=[
	Encodes a buffer into a lowercase hexadecimal string.

	@param buf The binary data to encode.
	@return string -- The hex-encoded string (always lowercase).
]=]
function hex.encode(buf: buffer | string): string
	local data: buffer = if type(buf) == "string" then buffer.fromstring(buf) else buf
	local len = buffer.len(data)
	local out = table.create(len * 2)

	local o = 1
	for i = 0, len - 1 do
		local b = buffer.readu8(data, i)
		out[o] = HEX_ALPHABET:sub(bit32.rshift(b, 4) + 1, bit32.rshift(b, 4) + 1)
		o += 1
		out[o] = HEX_ALPHABET:sub(bit32.band(b, 15) + 1, bit32.band(b, 15) + 1)
		o += 1
	end

	return table.concat(out)
end

--- Reverse mapping pre-computed for efficiency
local HEX_MAP = table.create(256, -1)
do
	for i = 0, 9 do
		HEX_MAP[string.byte(tostring(i))] = i
	end
	for i = 0, 5 do
		HEX_MAP[string.byte(string.char(97 + i))] = 10 + i -- a-f
		HEX_MAP[string.byte(string.char(65 + i))] = 10 + i -- A-F
	end
end

--[=[
	Decodes a hexadecimal string back into a buffer.

	Accepts both uppercase (`A–F`) and lowercase (`a–f`) hex digits.
	The input string length must be even.

	@param str The hex-encoded string.
	@return buffer -- The decoded binary data.
]=]
function hex.decode(str: string): buffer
	local len = #str
	assert(len % 2 == 0, "Invalid hex length")

	local buf = buffer.create(len // 2)

	local bi = 0
	for i = 1, len, 2 do
		local hi = HEX_MAP[string.byte(str, i)]
		local lo = HEX_MAP[string.byte(str, i + 1)]
		assert(hi >= 0 and lo >= 0, "Invalid hex")

		buffer.writeu8(buf, bi, bit32.bor(bit32.lshift(hi, 4), lo))
		bi += 1
	end

	return buf
end

return hex
