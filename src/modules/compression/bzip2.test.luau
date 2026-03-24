local test = require("@eryx/test")
local bzip2 = require("@eryx/compression/bzip2")

local suite = test.Suite.new("bzip2")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:test("round-trip: hello", function()
	local c = bzip2.compress(HELLO)
	test.expect(buffer.tostring(bzip2.decompress(c))):toBe("hello")
end)

suite:test("round-trip: pangram", function()
	local c = bzip2.compress(PANGRAM)
	test.expect(buffer.tostring(bzip2.decompress(c))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("compression reduces size for repetitive data", function()
	local c = bzip2.compress(REPEAT)
	test.expect(buffer.len(c)):toBeLessThan(buffer.len(REPEAT))
end)

suite:test("BLOCK_FAST and BLOCK_BEST both round-trip", function()
	local fast = bzip2.compress(PANGRAM, bzip2.BLOCK_FAST)
	local best = bzip2.compress(PANGRAM, bzip2.BLOCK_BEST)
	test.expect(buffer.tostring(bzip2.decompress(fast))):toBe(buffer.tostring(PANGRAM))
	test.expect(buffer.tostring(bzip2.decompress(best))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("small-memory decompressor round-trip", function()
	local c = bzip2.compress(HELLO)
	test.expect(buffer.tostring(bzip2.decompress(c, true))):toBe("hello")
end)

suite:test("compressBound: returns value >= input length", function()
	test.expect(bzip2.compressBound(1000)):toBeGreaterThanOrEqual(1000)
end)

return suite
