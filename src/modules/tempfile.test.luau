local fs = require("@eryx/fs")
local tempfile = require("@self/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("tempfile")

suite:test("open returns a writable file-like handle and path", function()
	local tf = tempfile.open("tempfile-open")
	local path = tf.path
	test.expect(path):toBeType("string")
	test.expect(fs.exists(path)):toBeTrue()

	tf.file:writeSync("hello")
	tf.file:seek(0, "set")
	test.expect(tf.file:readSync()):toBe("hello")

	tf:close()
	test.expect(fs.exists(path)):toBeFalse()
end)

suite:test("explicit close deletes temp directory", function()
	local td = tempfile.openDir("tempdir-open")
	local path = td.path
	test.expect(fs.exists(path)):toBeTrue()
	test.expect(fs.isDirectory(path)):toBeTrue()

	td:close()
	test.expect(fs.exists(path)):toBeFalse()
end)

suite:test("mktemp returns a unique path that does not exist", function()
	local pathA = tempfile.mktemp("mktemp-case")
	local pathB = tempfile.mktemp("mktemp-case")
	test.expect(pathA == pathB):toBeFalse()
	test.expect(fs.exists(pathA)):toBeFalse()
	test.expect(fs.exists(pathB)):toBeFalse()
end)

return suite
