local CookieJar = require("./CookieJar")
local cookies = require("./cookies")
local test = require("@eryx/test")

local suite = test.Suite.new("http cookie jar")

suite:test("parseCookie: Expires is parsed as an absolute HTTP date", function()
	local cookie =
		cookies.parseCookie("session=abc; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/", "example.com", "/login")

	test.expect(cookie):toBeType("table")
	test.expect((cookie :: cookies.Cookie).expires):toBe(1445412480)
end)

suite:test("CookieJar: expired Expires cookies are discarded before reuse", function()
	local jar = CookieJar.new()
	jar:parseSetCookie("old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/", "example.com", "/login")
	jar:parseSetCookie("fresh=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/", "example.com", "/login")

	test.expect(jar:count()):toBe(2)
	test.expect(jar:headerFor("https", "example.com", "/dashboard")):toBe("fresh=1")
	test.expect(jar:count()):toBe(1)
end)

return suite
