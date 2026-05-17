local test = require("@eryx/test")
local zip = require("@eryx/archive/zip")

local suite = test.Suite.new("zip")

local HELLO = buffer.fromstring("hello")

suite:test("isZip: accepts valid archive", function()
	local archive = zip.pack({ ["hello.txt"] = HELLO })
	test.expect(zip.isZip(archive)):toBeTrue()
end)

suite:test("isZip: rejects non-zip data", function()
	test.expect(zip.isZip(buffer.fromstring("not a zip"))):toBeFalse()
end)

suite:test("pack/unpack round-trip", function()
	local files: { [string]: buffer } = {
		["hello.txt"] = buffer.fromstring("hello"),
		["world.txt"] = buffer.fromstring("world"),
	}
	local archive = zip.pack(files)
	local unpacked = zip.unpack(archive)
	test.expect(buffer.tostring(unpacked["hello.txt"])):toBe("hello")
	test.expect(buffer.tostring(unpacked["world.txt"])):toBe("world")
end)

suite:test("list: returns entry names", function()
	local archive = zip.pack({ ["a.txt"] = HELLO, ["b.txt"] = HELLO })
	local entries = zip.list(archive)
	test.expect(#entries):toBe(2)
	local names: { string } = {}
	for _, e in entries do
		table.insert(names, e.name)
	end
	table.sort(names)
	test.expect(names[1]):toBe("a.txt")
	test.expect(names[2]):toBe("b.txt")
end)

suite:test("read: reads a specific entry", function()
	local archive = zip.pack({ ["greet.txt"] = buffer.fromstring("hi") })
	local data = zip.read(archive, "greet.txt")
	test.expect(data):toNotBeNil()
	test.expect(buffer.tostring(data :: buffer)):toBe("hi")
end)

suite:test("read: returns nil for missing entry", function()
	local archive = zip.pack({ ["a.txt"] = HELLO })
	test.expect(zip.read(archive, "missing.txt")):toBeNil()
end)

suite:test("pack with store method: entry method is METHOD_STORE", function()
	local archive = zip.pack({ ["f.txt"] = HELLO }, { method = "store" })
	local entries = zip.list(archive)
	test.expect(entries[1].method):toBe(zip.METHOD_STORE)
end)

suite:test("open: ZipReader:list and Read", function()
	local archive = zip.pack({ ["doc.txt"] = buffer.fromstring("content") })
	local reader = zip.open(archive)
	local entries = reader:list()
	test.expect(#entries):toBe(1)
	test.expect(entries[1].name):toBe("doc.txt")
	local data = reader:read("doc.txt")
	test.expect(buffer.tostring(data :: buffer)):toBe("content")
	reader:close()
end)

return suite
