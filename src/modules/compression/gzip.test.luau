local test = require("@eryx/test")
local gzip = require("@eryx/compression/gzip")

local suite = test.Suite.new("gzip")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:Test("round-trip: hello", function()
	local c = gzip.compress(HELLO)
	test.expect(gzip.isGzip(c)):ToBeTrue()
	test.expect(buffer.tostring(gzip.decompress(c))):ToBe("hello")
end)

suite:Test("round-trip: pangram", function()
	local c = gzip.compress(PANGRAM)
	test.expect(buffer.tostring(gzip.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("compression reduces size for repetitive data", function()
	local c = gzip.compress(REPEAT)
	test.expect(buffer.len(c)):ToBeLessThan(buffer.len(REPEAT))
end)

suite:Test("best speed level round-trip", function()
	local c = gzip.compress(PANGRAM, gzip.BEST_SPEED)
	test.expect(buffer.tostring(gzip.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("best compression level round-trip", function()
	local c = gzip.compress(PANGRAM, gzip.BEST_COMPRESSION)
	test.expect(buffer.tostring(gzip.decompress(c))):ToBe(buffer.tostring(PANGRAM))
end)

suite:Test("isGzip: rejects non-gzip data", function()
	test.expect(gzip.isGzip(buffer.fromstring("not gzip data"))):ToBeFalse()
end)

suite:Test("compressEx: filename in header", function()
	local c = gzip.compressEx(HELLO, { name = "hello.txt" })
	test.expect(gzip.isGzip(c)):ToBeTrue()
	local hdr = gzip.readHeader(c)
	test.expect(hdr.name):ToBe("hello.txt")
	test.expect(buffer.tostring(gzip.decompress(c))):ToBe("hello")
end)

suite:Test("compressEx: mtime in header", function()
	local c = gzip.compressEx(HELLO, { mtime = 1000000 })
	local hdr = gzip.readHeader(c)
	test.expect(hdr.mtime):ToBe(1000000)
end)

suite:Test("readHeader: standard compress has method 8", function()
	local hdr = gzip.readHeader(gzip.compress(HELLO))
	test.expect(hdr.method):ToBe(8)
end)

return suite
