local brotli = require("@eryx/compression/brotli")
local gzip = require("@eryx/compression/gzip")
local zlib = require("@eryx/compression/zlib")

local body = {}

--[=[
	An incremental HTTP content decoder returned by
	[[body.createDecoder]].
]=]
export type StreamDecoder = {
	write: (self: StreamDecoder, data: string) -> string,
	close: (self: StreamDecoder) -> (),
}

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decompressOne(data: string, encoding: string): string
	local enc = string.lower(trim(encoding))
	if enc == "" or enc == "identity" then
		return data
	elseif enc == "gzip" or enc == "x-gzip" then
		return buffer.tostring(gzip.decompress(buffer.fromstring(data)))
	elseif enc == "deflate" then
		-- RFC 7230: "deflate" can be raw deflate or zlib-wrapped.
		-- Try zlib first, fall back to raw deflate.
		local ok, result = pcall(zlib.decompress, buffer.fromstring(data))
		if ok then
			return buffer.tostring(result)
		end
		return buffer.tostring(zlib.decompressRaw(buffer.fromstring(data), zlib.RAW_WBITS))
	elseif enc == "br" then
		return buffer.tostring(brotli.decompress(buffer.fromstring(data)))
	end
	return data
end

--[=[
	Decompresses an HTTP response body based on a `Content-Encoding`
	header.

	Supports stacked encodings such as `"gzip, br"`, applying them in the
	reverse order required by HTTP.

	@param body The encoded response body bytes.
	@param encoding The `Content-Encoding` header value.
	@return string -- The decoded body bytes.
]=]
function body.decompress(body: string, encoding: string?): string
	if not encoding or #body == 0 then
		return body
	end

	local encodings = {}
	for item in string.gmatch(encoding, "([^,]+)") do
		table.insert(encodings, trim(item))
	end

	for i = #encodings, 1, -1 do
		body = decompressOne(body, encodings[i])
	end

	return body
end

local function createStage(encoding: string): StreamDecoder?
	local enc = string.lower(trim(encoding))
	if enc == "" or enc == "identity" then
		return nil
	elseif enc == "gzip" or enc == "x-gzip" then
		local decoder = gzip.createDecompressor()
		return {
			write = function(self, data: string): string
				local out = select(1, decoder:write(buffer.fromstring(data)))
				return buffer.tostring(out)
			end,
			close = function(self)
				decoder:close()
			end,
		}
	elseif enc == "deflate" then
		local decoder = zlib.createInflate(zlib.AUTO_WBITS)
		return {
			write = function(self, data: string): string
				local out = select(1, decoder:write(buffer.fromstring(data)))
				return buffer.tostring(out)
			end,
			close = function(self)
				decoder:close()
			end,
		}
	elseif enc == "br" then
		local decoder = brotli.createDecompressor()
		return {
			write = function(self, data: string): string
				local out = select(1, decoder:write(buffer.fromstring(data)))
				return buffer.tostring(out)
			end,
			close = function(self)
				decoder:close()
			end,
		}
	end

	error("Unsupported Content-Encoding for streaming decode: " .. encoding)
end

--[=[
	Creates an incremental decoder for a `Content-Encoding` header value.

	This is used by streamed HTTP responses so callers can consume
	decompressed data incrementally instead of buffering the whole encoded
	body first.

	@param encoding The `Content-Encoding` header value.
	@return StreamDecoder? -- A decoder object, or `nil` when no decoding is
	required.
]=]
function body.createDecoder(encoding: string?): StreamDecoder?
	if not encoding or encoding == "" then
		return nil
	end

	local stages = {}
	for item in string.gmatch(encoding, "([^,]+)") do
		local stage = createStage(item)
		if stage ~= nil then
			table.insert(stages, 1, stage)
		end
	end

	if #stages == 0 then
		return nil
	end

	return {
		write = function(self, data: string): string
			local out = data
			for _, stage in stages do
				if out == "" then
					break
				end
				out = stage:write(out)
			end
			return out
		end,
		close = function(self)
			for _, stage in stages do
				stage:close()
			end
		end,
	}
end

return table.freeze(body)
