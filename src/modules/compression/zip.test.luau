local test = require("@eryx/test")
local zip = require("@eryx/compression/zip")

local suite = test.Suite.new("zip")

local HELLO = buffer.fromstring("hello")

suite:Test("isZip: accepts valid archive", function()
	local archive = zip.pack({ ["hello.txt"] = HELLO })
	test.expect(zip.isZip(archive)):ToBeTrue()
end)

suite:Test("isZip: rejects non-zip data", function()
	test.expect(zip.isZip(buffer.fromstring("not a zip"))):ToBeFalse()
end)

suite:Test("pack/unpack round-trip", function()
	local files: { [string]: buffer } = {
		["hello.txt"] = buffer.fromstring("hello"),
		["world.txt"] = buffer.fromstring("world"),
	}
	local archive = zip.pack(files)
	local unpacked = zip.unpack(archive)
	test.expect(buffer.tostring(unpacked["hello.txt"])):ToBe("hello")
	test.expect(buffer.tostring(unpacked["world.txt"])):ToBe("world")
end)

suite:Test("list: returns entry names", function()
	local archive = zip.pack({ ["a.txt"] = HELLO, ["b.txt"] = HELLO })
	local entries = zip.list(archive)
	test.expect(#entries):ToBe(2)
	local names: { string } = {}
	for _, e in entries do
		table.insert(names, e.name)
	end
	table.sort(names)
	test.expect(names[1]):ToBe("a.txt")
	test.expect(names[2]):ToBe("b.txt")
end)

suite:Test("read: reads a specific entry", function()
	local archive = zip.pack({ ["greet.txt"] = buffer.fromstring("hi") })
	local data = zip.read(archive, "greet.txt")
	test.expect(data):ToNotBeNil()
	test.expect(buffer.tostring(data :: buffer)):ToBe("hi")
end)

suite:Test("read: returns nil for missing entry", function()
	local archive = zip.pack({ ["a.txt"] = HELLO })
	test.expect(zip.read(archive, "missing.txt")):ToBeNil()
end)

suite:Test("pack with store method: entry method is METHOD_STORE", function()
	local archive = zip.pack({ ["f.txt"] = HELLO }, { method = "store" })
	local entries = zip.list(archive)
	test.expect(entries[1].method):ToBe(zip.METHOD_STORE)
end)

suite:Test("open: ZipReader:List and Read", function()
	local archive = zip.pack({ ["doc.txt"] = buffer.fromstring("content") })
	local reader = zip.open(archive)
	local entries = reader:List()
	test.expect(#entries):ToBe(1)
	test.expect(entries[1].name):ToBe("doc.txt")
	local data = reader:Read("doc.txt")
	test.expect(buffer.tostring(data :: buffer)):ToBe("content")
	reader:Close()
end)

return suite
