local test = require("@eryx/test")
local gzip = require("@eryx/compression/gzip")

local suite = test.Suite.new("gzip")

local HELLO = buffer.fromstring("hello")
local PANGRAM = buffer.fromstring("The quick brown fox jumps over the lazy dog")
local REPEAT = buffer.fromstring(string.rep("abcdefgh", 100)) -- repetitive data compresses well

suite:test("round-trip: hello", function()
	local c = gzip.compress(HELLO)
	test.expect(gzip.isGzip(c)):toBeTrue()
	test.expect(buffer.tostring(gzip.decompress(c))):toBe("hello")
end)

suite:test("round-trip: pangram", function()
	local c = gzip.compress(PANGRAM)
	test.expect(buffer.tostring(gzip.decompress(c))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("compression reduces size for repetitive data", function()
	local c = gzip.compress(REPEAT)
	test.expect(buffer.len(c)):toBeLessThan(buffer.len(REPEAT))
end)

suite:test("best speed level round-trip", function()
	local c = gzip.compress(PANGRAM, gzip.BEST_SPEED)
	test.expect(buffer.tostring(gzip.decompress(c))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("best compression level round-trip", function()
	local c = gzip.compress(PANGRAM, gzip.BEST_COMPRESSION)
	test.expect(buffer.tostring(gzip.decompress(c))):toBe(buffer.tostring(PANGRAM))
end)

suite:test("isGzip: rejects non-gzip data", function()
	test.expect(gzip.isGzip(buffer.fromstring("not gzip data"))):toBeFalse()
end)

suite:test("compressEx: filename in header", function()
	local c = gzip.compressEx(HELLO, { name = "hello.txt" })
	test.expect(gzip.isGzip(c)):toBeTrue()
	local hdr = gzip.readHeader(c)
	test.expect(hdr.name):toBe("hello.txt")
	test.expect(buffer.tostring(gzip.decompress(c))):toBe("hello")
end)

suite:test("compressEx: mtime in header", function()
	local c = gzip.compressEx(HELLO, { mtime = 1000000 })
	local hdr = gzip.readHeader(c)
	test.expect(hdr.mtime):toBe(1000000)
end)

suite:test("readHeader: standard compress has method 8", function()
	local hdr = gzip.readHeader(gzip.compress(HELLO))
	test.expect(hdr.method):toBe(8)
end)

return suite
