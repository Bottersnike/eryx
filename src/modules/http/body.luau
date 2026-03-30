local gzip = require("@eryx/compression/gzip")
local zlib = require("@eryx/compression/zlib")

local body = {}

--- Decompresses an HTTP response body based on the Content-Encoding header.
function body.decompress(body: string, encoding: string?): string
	if not encoding or #body == 0 then
		return body
	end
	local enc = string.lower(encoding)
	if enc == "gzip" or enc == "x-gzip" then
		return buffer.tostring(gzip.decompress(buffer.fromstring(body)))
	elseif enc == "deflate" then
		-- RFC 7230: "deflate" can be raw deflate or zlib-wrapped.
		-- Try zlib first, fall back to raw deflate.
		local ok, result = pcall(zlib.decompress, buffer.fromstring(body))
		if ok then
			return buffer.tostring(result)
		end
		return buffer.tostring(zlib.decompressRaw(buffer.fromstring(body), zlib.RAW_WBITS))
	end
	return body
end

return table.freeze(body)
