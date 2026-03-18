--[=[
	Z85 (ZeroMQ Base85) encoding utilities.

	Encodes and decodes binary `buffer` data using the Z85 alphabet,
	a compact base-85 representation designed for use in source code
	and XML. Input length must be a multiple of 4 bytes.

	```luau
	local base85 = require("@eryx/encoding/base85")
	local data = buffer.fromstring("\x86\x4f\xd2\x6f")
	print(base85.encode(data)) -- "HelloWorld" (example)
	```

	:::caution
	Z85 requires the input buffer length to be a multiple of **4 bytes**
	for encoding and the string length to be a multiple of **5 characters**
	for decoding. Inputs that don’t meet this constraint will raise an error.
	:::
]=]

local base85 = {}

local Z85_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"

--[=[
	Encodes a buffer into a Z85 string.

	The buffer length **must** be a multiple of 4.

	@param buf The binary data to encode.
	@return string -- The Z85-encoded string.
]=]
function base85.encode(buf: buffer): string
	local len = buffer.len(buf)
	assert(len % 4 == 0, "Z85 requires length multiple of 4")

	local out = table.create(len // 4 * 5)
	local o = 1

	for i = 0, len - 1, 4 do
		local n = bit32.bor(
			bit32.lshift(buffer.readu8(buf, i), 24),
			bit32.lshift(buffer.readu8(buf, i + 1), 16),
			bit32.lshift(buffer.readu8(buf, i + 2), 8),
			buffer.readu8(buf, i + 3)
		)

		for j = 5, 1, -1 do
			local d = n % 85
			n = (n - d) // 85
			out[o + j - 1] = Z85_ALPHABET:sub(d + 1, d + 1)
		end
		o += 5
	end

	return table.concat(out)
end
local Z85_MAP = table.create(256, -1)
do
	for i = 1, #Z85_ALPHABET do
		Z85_MAP[string.byte(Z85_ALPHABET, i)] = i - 1
	end
end

--[=[
	Decodes a Z85 string back into a buffer.

	The string length **must** be a multiple of 5.

	@param str The Z85-encoded string.
	@return buffer -- The decoded binary data.
]=]
function base85.decode(str: string): buffer
	local len = #str
	assert(len % 5 == 0, "Invalid Z85 length")

	local buf = buffer.create(len // 5 * 4)
	local bi = 0

	for i = 1, len, 5 do
		local n = 0
		for j = 0, 4 do
			local v = Z85_MAP[string.byte(str, i + j)]
			assert(v >= 0, "Invalid Z85")
			n = n * 85 + v
		end

		buffer.writeu8(buf, bi, bit32.band(bit32.rshift(n, 24), 0xFF))
		buffer.writeu8(buf, bi + 1, bit32.band(bit32.rshift(n, 16), 0xFF))
		buffer.writeu8(buf, bi + 2, bit32.band(bit32.rshift(n, 8), 0xFF))
		buffer.writeu8(buf, bi + 3, bit32.band(n, 0xFF))
		bi += 4
	end

	return buf
end

return base85
