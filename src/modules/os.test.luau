local fs = require("@eryx/fs")
local osmod = require("@eryx/os")
local test = require("@eryx/test")

local suite = test.Suite.new("os")

suite:test("signals table exposes TERM aliases", function()
	test.expect(type(osmod.signals)):toBe("table")
	if osmod.signals.TERM ~= nil and osmod.signals.SIGTERM ~= nil then
		test.expect(osmod.signals.TERM):toBe(osmod.signals.SIGTERM)
	end
end)

suite:test("uid/gid api returns platform-appropriate identity types", function()
	local platform = osmod.platform()
	local uid = osmod.uid()
	local gid = osmod.gid()
	local euid = osmod.euid()
	local egid = osmod.egid()

	if platform == "windows" then
		test.expect(type(uid)):toBe("string")
		test.expect(type(gid)):toBe("string")
		test.expect(type(euid)):toBe("string")
		test.expect(type(egid)):toBe("string")
	else
		test.expect(type(uid)):toBe("number")
		test.expect(type(gid)):toBe("number")
		test.expect(type(euid)):toBe("number")
		test.expect(type(egid)):toBe("number")
	end
end)

suite:test("currentEryxBinary returns the running binary path", function()
	local binary = tostring(osmod.currentEryxBinary())
	test.expect(type(binary)):toBe("string")
	test.expect(binary):toNotBe("")
	test.expect(fs.isFile(binary)):toBeTrue()
end)

suite:test("userInfo and groupInfo return principal metadata", function()
	local user = osmod.userInfo()
	local group = osmod.groupInfo()
	test.expect(type(user)):toBe("table")
	test.expect(type(group)):toBe("table")
	assert(typeof(user) == "table")
	assert(typeof(group) == "table")
	test.expect(user.kind):toBe("user")
	test.expect(group.kind):toBe("group")

	if osmod.platform() == "windows" then
		test.expect(type(user.id)):toBe("string")
		test.expect(type(group.id)):toBe("string")
		if user.home ~= nil then
			test.expect(type(user.home)):toBe("string")
		end
	end
end)

suite:test("userInfo/groupInfo resolve explicit subjects", function()
	local user = osmod.userInfo(osmod.uid())
	local group = osmod.groupInfo(osmod.gid())
	test.expect(type(user)):toBe("table")
	test.expect(type(group)):toBe("table")
	assert(typeof(user) == "table")
	assert(typeof(group) == "table")
	test.expect(user.kind):toBe("user")
	test.expect(group.kind):toBe("group")
end)

suite:test("ProcessHandle.kill accepts signal names", function()
	local platform = osmod.platform()
	local p
	if platform == "windows" then
		p = osmod.spawn("cmd.exe", { "/C", "ping -n 5 127.0.0.1 >nul" })
	else
		p = osmod.spawn("sleep", { "5" })
	end

	p:kill("TERM")
	local result = p:wait()
	test.expect(type(result.code)):toBe("number")
end)

suite:test("ProcessHandle.kill accepts SIG-prefixed aliases", function()
	local platform = osmod.platform()
	local p
	if platform == "windows" then
		p = osmod.spawn("cmd.exe", { "/C", "ping -n 5 127.0.0.1 >nul" })
	else
		p = osmod.spawn("sleep", { "5" })
	end

	p:kill("SIGTERM")
	local result = p:wait()
	test.expect(type(result.code)):toBe("number")
end)

return suite
