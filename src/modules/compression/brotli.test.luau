local test = require("@eryx/test")
local brotli = require("@eryx/compression/brotli")

local suite = test.Suite.new("brotli")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:Test("round-trip: hello", function()
	local c = brotli.compress(HELLO)
	test.expect(buffer.tostring(brotli.decompress(c))):ToBe("hello")
end)

suite:Test("round-trip: pangram", function()
	local c = brotli.compress(PANGRAM)
	test.expect(buffer.tostring(brotli.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("compression reduces size for repetitive data", function()
	local c = brotli.compress(REPEAT)
	test.expect(buffer.len(c)):ToBeLessThan(buffer.len(REPEAT))
end)

suite:Test("quality 0 and quality 11 both round-trip", function()
	local fast = brotli.compress(PANGRAM, brotli.QUALITY_MIN)
	local best = brotli.compress(PANGRAM, brotli.QUALITY_MAX)
	test.expect(buffer.tostring(brotli.decompress(fast))):ToBe(buffer.tostring(PANGRAM))
	test.expect(buffer.tostring(brotli.decompress(best))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("maxCompressedSize: returns value >= input length", function()
	test.expect(brotli.maxCompressedSize(1000)):ToBeGreaterThanOrEqual(1000)
end)

return suite
