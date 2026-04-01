local body = require("./body")
local brotli = require("@eryx/compression/brotli")
local gzip = require("@eryx/compression/gzip")
local test = require("@eryx/test")

local suite = test.Suite.new("http body")

suite:test("decompress: supports brotli", function()
	local compressed = brotli.compress(buffer.fromstring("hello world"))
	local decoded = body.decompress(buffer.tostring(compressed), "br")

	test.expect(decoded):toBe("hello world")
end)

suite:test("decompress: applies stacked encodings in reverse order", function()
	local original = "hello world"
	local gzipped = gzip.compress(buffer.fromstring(original))
	local brotlied = brotli.compress(gzipped)

	local decoded = body.decompress(buffer.tostring(brotlied), "gzip, br")
	test.expect(decoded):toBe(original)
end)

suite:test("createDecoder: incrementally decodes gzip streams", function()
	local original = "hello streamed world"
	local compressed = buffer.tostring(gzip.compress(buffer.fromstring(original)))
	local decoder = body.createDecoder("gzip")
	local streamDecoder = decoder :: any

	local out = streamDecoder:write(string.sub(compressed, 1, 8))
	out ..= streamDecoder:write(string.sub(compressed, 9))
	streamDecoder:close()

	test.expect(out):toBe(original)
end)

return suite
