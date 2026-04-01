local fs = require("@eryx/fs")
local mime = require("@eryx/mime")
local test = require("@eryx/test")

local suite = test.Suite.new("mime")

suite:test("fromExtension: accepts dotted uppercase extensions", function()
	test.expect(mime.fromExtension(".TXT")):toBe("text/plain; charset=utf-8")
end)

suite:test("fromFileContent: sniffs PNG buffers", function()
	local png = buffer.fromstring("\137PNG\r\n\26\nrest")
	test.expect(mime.fromFileContent(png)):toBe("image/png")
end)

suite:test("fromFileContent: falls back to extension for empty files", function()
	local path = fs.path.join(_DIR, "mime-empty.JSON")
	local handle = fs.openSync(path, "w")
	handle:closeSync()

	local ok, err = pcall(function()
		test.expect(mime.fromFileContent(path)):toBe("application/json; charset=utf-8")
	end)

	if fs.exists(path) then
		fs.remove(path)
	end

	if not ok then
		error(err)
	end
end)

suite:test("fromFileContent: reads file paths as file contents", function()
	local path = fs.path.join(_DIR, "mime-body.txt")
	local handle = fs.openSync(path, "w")
	handle:writeSync("<!doctype html>")
	handle:closeSync()

	local ok, err = pcall(function()
		test.expect(mime.fromFileContent(path)):toBe("text/html; charset=utf-8")
	end)

	if fs.exists(path) then
		fs.remove(path)
	end

	if not ok then
		error(err)
	end
end)

suite:test("fromFileContent: raw strings still work when the path does not exist", function()
	test.expect(mime.fromFileContent('{"ok":true}')):toBe("application/json; charset=utf-8")
end)

return suite
