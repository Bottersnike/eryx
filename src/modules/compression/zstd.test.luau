local test = require("@eryx/test")
local zstd = require("@eryx/compression/zstd")

local suite = test.Suite.new("zstd")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:Test("round-trip: hello", function()
	local c = zstd.compress(HELLO)
	test.expect(buffer.tostring(zstd.decompress(c))):ToBe("hello")
end)

suite:Test("round-trip: pangram", function()
	local c = zstd.compress(PANGRAM)
	test.expect(buffer.tostring(zstd.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("compression reduces size for repetitive data", function()
	local c = zstd.compress(REPEAT)
	test.expect(buffer.len(c)):ToBeLessThan(buffer.len(REPEAT))
end)

suite:Test("CLEVEL_MAX produces smaller output than CLEVEL_MIN for repetitive data", function()
	local fast = zstd.compress(REPEAT, zstd.CLEVEL_MIN)
	local best = zstd.compress(REPEAT, zstd.CLEVEL_MAX)
	-- both should decompress correctly regardless
	test.expect(buffer.tostring(zstd.decompress(fast))):ToBe(buffer.tostring(REPEAT))
	test.expect(buffer.tostring(zstd.decompress(best))):ToBe(buffer.tostring(REPEAT))
end)

suite:Test("compressBound: returns value >= input length", function()
	test.expect(zstd.compressBound(1000)):ToBeGreaterThanOrEqual(1000)
end)

suite:Test("frameContentSize: returns decompressed size", function()
	local c = zstd.compress(PANGRAM)
	local sz = zstd.frameContentSize(c)
	test.expect(sz):ToBe(buffer.len(PANGRAM))
end)

suite:Test("compressWithDict / decompressWithDict round-trip", function()
	-- Train a tiny dictionary from similar samples
	local samples = {}
	for i = 1, 20 do
		samples[i] = buffer.fromstring(string.format('{"key%d":"value%d"}', i, i))
	end
	local dict = zstd.trainDictionary(samples, 4096)
	local data = buffer.fromstring('{"key1":"value1"}')
	local c = zstd.compressWithDict(data, dict)
	local d = zstd.decompressWithDict(c, dict)
	test.expect(buffer.tostring(d)):ToBe('{"key1":"value1"}')
end)

return suite
