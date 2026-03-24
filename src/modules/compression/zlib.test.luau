local test = require("@eryx/test")
local zlib = require("@eryx/compression/zlib")

local suite = test.Suite.new("zlib")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:test("round-trip: hello", function()
	local c = zlib.compress(HELLO)
	test.expect(buffer.tostring(zlib.decompress(c))):toBe("hello")
end)

suite:test("round-trip: pangram", function()
	local c = zlib.compress(PANGRAM)
	test.expect(buffer.tostring(zlib.decompress(c))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("compression reduces size for repetitive data", function()
	local c = zlib.compress(REPEAT)
	test.expect(buffer.len(c)):toBeLessThan(buffer.len(REPEAT))
end)

suite:test("adler32: known value for empty", function()
	-- Adler-32 of empty data = 1
	test.expect(zlib.adler32(buffer.fromstring(""))):toBe(1)
end)

suite:test("adler32: chaining produces same result", function()
	local full = zlib.adler32(PANGRAM)
	local half = #buffer.tostring(PANGRAM) // 2
	local part1 = buffer.fromstring(buffer.tostring(PANGRAM):sub(1, half))
	local part2 = buffer.fromstring(buffer.tostring(PANGRAM):sub(half + 1))
	local chained = zlib.adler32(part2, zlib.adler32(part1))
	test.expect(chained):toBe(full)
end)

suite:test("crc32: known value for empty", function()
	-- CRC-32 of empty data = 0
	test.expect(zlib.crc32(buffer.fromstring(""))):toBe(0)
end)

suite:test("compressBound: returns value >= input length", function()
	test.expect(zlib.compressBound(1000)):toBeGreaterThanOrEqual(1000)
end)

suite:test("raw deflate round-trip", function()
	local c = zlib.compressRaw(HELLO, nil, zlib.RAW_WBITS)
	local d = zlib.decompressRaw(c, zlib.RAW_WBITS)
	test.expect(buffer.tostring(d)):toBe("hello")
end)

return suite
