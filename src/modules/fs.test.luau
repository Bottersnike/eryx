local fs = require("@eryx/fs")
local osmod = require("@eryx/os")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("fs")

suite:test("stat includes readonly and hasPermission returns boolean", function()
	tempfile.withTempFile(function(file)
		local st = fs.stat(file.path)
		test.expect(type(st)):toBe("table")
		test.expect(type(st.readonly)):toBe("boolean")

		test.expect(type(fs.hasPermission(file.path, "read"))):toBe("boolean")
		test.expect(type(fs.hasPermission(file.path, "write"))):toBe("boolean")
		test.expect(type(fs.hasPermission(file.path, "readAcl"))):toBe("boolean")
		test.expect(type(fs.hasPermission(file.path, "writeAcl"))):toBe("boolean")
	end)
end)

suite:test("hasPermission rejects unknown permission token", function()
	tempfile.withTempFile(function(file)
		test.expect(function()
			fs.hasPermission(file.path, "banana" :: any)
		end):toError("unknown permission token")
	end)
end)

suite:test("readonly getter/setter roundtrip", function()
	tempfile.withTempFile(function(file)
		local before = fs.getReadonly(file.path)
		test.expect(type(before)):toBe("boolean")

		fs.setReadonly(file.path, true)
		test.expect(fs.getReadonly(file.path)):toBeTrue()
		test.expect(fs.stat(file.path).readonly):toBeTrue()

		fs.setReadonly(file.path, false)
		test.expect(fs.getReadonly(file.path)):toBeFalse()
	end)
end)

suite:test("POSIX chmod/chgrp operate on temp files", function()
	test.skipIf(osmod.platform() == "windows", "posix-only")

	tempfile.withTempFile(function(file)
		fs.chmod(file.path, 384) -- 0o600
		test.expect(fs.hasPermission(file.path, "read")):toBeTrue()

		local gid = osmod.gid()
		if type(gid) == "number" then
			fs.chgrp(file.path, gid)
		end
	end)
end)

suite:test("Windows-only hidden/system/unsupported APIs", function()
	test.skipIf(osmod.platform() ~= "windows", "windows-only")

	tempfile.withTempFile(function(file)
		test.expect(type(fs.getHidden(file.path))):toBe("boolean")
		test.expect(type(fs.getSystem(file.path))):toBe("boolean")

		fs.setHidden(file.path, true)
		test.expect(fs.getHidden(file.path)):toBeTrue()
		fs.setHidden(file.path, false)
		test.expect(fs.getHidden(file.path)):toBeFalse()

		fs.setSystem(file.path, true)
		test.expect(fs.getSystem(file.path)):toBeTrue()
		fs.setSystem(file.path, false)
		test.expect(fs.getSystem(file.path)):toBeFalse()

		test.expect(function()
			fs.chmod(file.path, 384)
		end):toError("not supported on Windows")

		test.expect(function()
			fs.chgrp(file.path, 0)
		end):toError("not supported on Windows")
	end)
end)

suite:test("Windows ACL get/set roundtrip", function()
	test.skipIf(osmod.platform() ~= "windows", "windows-only")

	tempfile.withTempFile(function(file)
		local acl = fs.getAcl(file.path)
		test.expect(type(acl)):toBe("table")

		if not fs.hasPermission(file.path, "writeAcl") then
			test.skip("current user cannot write ACL for this path")
		end

		fs.setAcl(file.path, acl)
		local after = fs.getAcl(file.path)
		test.expect(type(after)):toBe("table")
	end)
end)

return suite
