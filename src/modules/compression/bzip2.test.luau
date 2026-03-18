local test = require("@eryx/test")
local bzip2 = require("@eryx/compression/bzip2")

local suite = test.Suite.new("bzip2")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:Test("round-trip: hello", function()
	local c = bzip2.compress(HELLO)
	test.expect(buffer.tostring(bzip2.decompress(c))):ToBe("hello")
end)

suite:Test("round-trip: pangram", function()
	local c = bzip2.compress(PANGRAM)
	test.expect(buffer.tostring(bzip2.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("compression reduces size for repetitive data", function()
	local c = bzip2.compress(REPEAT)
	test.expect(buffer.len(c)):ToBeLessThan(buffer.len(REPEAT))
end)

suite:Test("BLOCK_FAST and BLOCK_BEST both round-trip", function()
	local fast = bzip2.compress(PANGRAM, bzip2.BLOCK_FAST)
	local best = bzip2.compress(PANGRAM, bzip2.BLOCK_BEST)
	test.expect(buffer.tostring(bzip2.decompress(fast))):ToBe(buffer.tostring(PANGRAM))
	test.expect(buffer.tostring(bzip2.decompress(best))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("small-memory decompressor round-trip", function()
	local c = bzip2.compress(HELLO)
	test.expect(buffer.tostring(bzip2.decompress(c, true))):ToBe("hello")
end)

suite:Test("compressBound: returns value >= input length", function()
	test.expect(bzip2.compressBound(1000)):ToBeGreaterThanOrEqual(1000)
end)

return suite
