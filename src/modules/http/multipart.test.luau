local test = require("@eryx/test")
local multipart = require("./multipart")

local suite = test.Suite.new("http multipart")

suite:test("parse: decodes multipart form fields and files", function()
	local body, contentType = multipart.encodeFields({
		{ name = "username", value = "alice" },
		{ name = "avatar", value = "PNGDATA", filename = "pic.png", contentType = "image/png" },
	})

	local fields = multipart.parse(body, contentType)
	test.expect(#fields):toBe(2)
	test.expect(fields[1].name):toBe("username")
	test.expect(fields[1].value):toBe("alice")
	test.expect(fields[1].filename):toBeNil()
	test.expect(fields[2].name):toBe("avatar")
	test.expect(fields[2].filename):toBe("pic.png")
	test.expect(fields[2].contentType):toBe("image/png")
	test.expect(fields[2].value):toBe("PNGDATA")
end)

suite:test("parse: accepts a raw boundary string", function()
	local boundary = "DemoBoundary"
	local body = table.concat({
		"--DemoBoundary\r\n",
		'Content-Disposition: form-data; name="field"\r\n',
		"\r\n",
		"value\r\n",
		"--DemoBoundary--\r\n",
	})

	local fields = multipart.parse(body, boundary)
	test.expect(#fields):toBe(1)
	test.expect(fields[1].name):toBe("field")
	test.expect(fields[1].value):toBe("value")
end)

return suite
