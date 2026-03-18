--[=[
	Base64 encoding utilities.

	Encodes binary `buffer` data into the standard Base64 alphabet
	(RFC 4648). A custom alphabet may be supplied for URL-safe or
	other variants.

	```luau
	local base64 = require("@eryx/base64")
	local encoded = base64.encode(buffer.fromstring("Hello, world!"))
	print(encoded) -- "SGVsbG8sIHdvcmxkIQ=="
	```
]=]

local base64 = {}

--- The standard Base64 alphabet (RFC 4648 §4).
base64.STANDARD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
--- The URL-safe Base64 alphabet (RFC 4648 §5), using `-` and `_` instead of `+` and `/`.
base64.URL_SAFE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
--- The IMAP mailbox Base64 alphabet (RFC 3501), using `,` instead of `/`.
base64.IMAP_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,/"

--[=[
	Encodes a buffer into a Base64 string.

	Uses the standard Base64 alphabet by default. Pass a custom 64-character
	alphabet string to use a different encoding (e.g. URL-safe Base64 with
	`"-_"` instead of `"+/"`).

	@param data The binary data to encode.
	@param alphabet A custom 64-character alphabet string.
	@return string -- The Base64-encoded string.
]=]
function base64.encode(data: buffer, alphabet: string?): string
	local alphabet_ = alphabet or base64.STANDARD_ALPHABET
	local len = buffer.len(data)
	local out = table.create(math.ceil(len / 3) * 4)

	local i = 0
	local o = 1

	while i < len do
		local b1 = buffer.readu8(data, i)
		i += 1
		local b2 = i < len and buffer.readu8(data, i) or nil
		i += 1
		local b3 = i < len and buffer.readu8(data, i) or nil
		i += 1

		local n = bit32.bor(bit32.lshift(b1, 16), bit32.lshift((b2 or 0), 8), (b3 or 0))

		local c1 = bit32.band(bit32.rshift(n, 18), 63)
		local c2 = bit32.band(bit32.rshift(n, 12), 63)
		local c3 = bit32.band(bit32.rshift(n, 6), 63)
		local c4 = bit32.band(n, 63)

		out[o] = alphabet_:sub(c1 + 1, c1 + 1)
		o += 1
		out[o] = alphabet_:sub(c2 + 1, c2 + 1)
		o += 1

		if b2 then
			out[o] = alphabet_:sub(c3 + 1, c3 + 1)
		else
			out[o] = "="
		end
		o += 1

		if b3 then
			out[o] = alphabet_:sub(c4 + 1, c4 + 1)
		else
			out[o] = "="
		end
		o += 1
	end

	return table.concat(out)
end

--[=[
	Decodes a Base64 string back into a buffer.

	Uses the standard Base64 alphabet by default. Pass the same custom
	alphabet that was used for encoding to decode URL-safe or other
	variants.

	@param str The Base64-encoded string.
	@param alphabet A custom 64-character alphabet string.
	@return buffer -- The decoded binary data.
]=]
function base64.decode(str: string, alphabet: string?): buffer
	local alphabet_ = alphabet or base64.STANDARD_ALPHABET

	local len = #str
	if len % 4 ~= 0 then
		error("Invalid base64 length")
	end

	-- Prepare reverse-mapping for given alphabet
	local b64Index = table.create(256, -1)
	do
		for i = 1, #alphabet_ do
			b64Index[string.byte(alphabet_, i)] = i - 1
		end
		b64Index[string.byte("=")] = -2 -- padding marker
	end

	-- Maximum output size
	local outLen = (len / 4) * 3

	-- Adjust for padding
	if str:sub(-1) == "=" then
		outLen -= 1
	end
	if str:sub(-2, -2) == "=" then
		outLen -= 1
	end

	local buf = buffer.create(outLen)

	local si = 1
	local bi = 0

	while si <= len do
		local c1 = b64Index[string.byte(str, si)]
		si += 1
		local c2 = b64Index[string.byte(str, si)]
		si += 1
		local c3 = b64Index[string.byte(str, si)]
		si += 1
		local c4 = b64Index[string.byte(str, si)]
		si += 1

		if c1 < 0 or c2 < 0 then
			error("Invalid base64 character")
		end

		local n = bit32.bor(bit32.lshift(c1, 18), bit32.lshift(c2, 12))
		local b1 = bit32.band(bit32.rshift(n, 16), 0xFF)
		buffer.writeu8(buf, bi, b1)
		bi += 1

		if c3 ~= -2 then
			if c3 < 0 then
				error("Invalid base64 character")
			end
			n = bit32.bor(n, bit32.lshift(c3, 6))

			local b2 = bit32.band(bit32.rshift(n, 8), 0xFF)
			buffer.writeu8(buf, bi, b2)
			bi += 1

			if c4 ~= -2 then
				if c4 < 0 then
					error("Invalid base64 character")
				end
				n = bit32.bor(n, c4)

				local b3 = bit32.band(n, 0xFF)
				buffer.writeu8(buf, bi, b3)
				bi += 1
			end
		end
	end

	return buf
end

return base64
