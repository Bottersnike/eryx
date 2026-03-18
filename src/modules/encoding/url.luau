--[=[
	URL percent-encoding utilities.

	Encodes and decodes strings using percent-encoding as defined by
	RFC 3986. Unreserved characters (`A–Z`, `a–z`, `0–9`, `-`, `_`, `.`, `~`)
	are left untouched; all others are replaced with `%XX` hex sequences.

	```luau
	local url = require("@eryx/encoding/url")
	print(url.encode("hello world", true))  -- "hello+world"
	print(url.encode("hello world", false)) -- "hello%20world"
	```
]=]

local url = {}

--[=[
	Percent-encodes a string.

	When `spaceIsPlus` is `true`, spaces are encoded as `+` (common in
	`application/x-www-form-urlencoded` form data). Otherwise spaces are
	encoded as `%20`.

	@param str The string to encode.
	@param spaceIsPlus Whether to encode spaces as `+`.
	@return string -- The percent-encoded string.
]=]
function url.encode(str: string, spaceIsPlus: boolean): string
	str = (str:gsub("[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))

	if spaceIsPlus then
		str = str:gsub("%%20", "+")
	end

	return str
end

--[=[
	Decodes a percent-encoded string.

	When `plusIsSpace` is `true`, `+` characters are decoded as spaces
	(matching `application/x-www-form-urlencoded` form data).

	@param str The percent-encoded string.
	@param plusIsSpace Whether to decode `+` as a space.
	@return string -- The decoded string.
]=]
function url.decode(str: string, plusIsSpace: boolean): string
	if plusIsSpace then
		str = str:gsub("%+", " ")
	end
	return (str:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

return url
