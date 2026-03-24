local test = require("@eryx/test")
local hash = require("@eryx/crypto/hash")
local base64 = require("@eryx/encoding/base64")
local hex = require("@eryx/encoding/hex")

local suite = test.Suite.new("websocket handshake")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function computeAccept(key: string): (string, string)
	key = string.match(key, "^%s*(.-)%s*$") :: string
	local input = key .. WS_GUID
	local sha1 = hash.sha1(buffer.fromstring(input))
	return base64.encode(sha1), hex.encode(sha1)
end

-- RFC 6455 Section 4.2.2, page 7 - the canonical test vector
suite:test("accept: RFC 6455 test vector", function()
	local accept, sha1hex = computeAccept("dGhlIHNhbXBsZSBub25jZQ==")
	test.expect(sha1hex):toBe("b37a4f2cc0624f1690f64606cf385945b2bec4ea")
	test.expect(accept):toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

-- Extra: key with leading/trailing whitespace (RFC 7230 OWS)
suite:test("accept: key with whitespace trimmed", function()
	local accept = computeAccept("  dGhlIHNhbXBsZSBub25jZQ==  ")
	test.expect(accept):toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

-- Verify base64 of known SHA-1 independently
suite:test("base64: encode 20 raw bytes", function()
	-- SHA-1 of "" = da39a3ee5e6b4b0d3255bfef95601890afd80709
	local sha1 = hash.sha1(buffer.fromstring(""))
	local b64 = base64.encode(sha1)
	test.expect(b64):toBe("2jmj7l5rSw0yVb/vlWAYkK/YBwk=")
end)

-- A second key to catch any input-dependent issues
suite:test("accept: another key", function()
	-- Manually computed: key = "x3JJHMbDL1EzLkh9GBhXDw=="
	-- concat = "x3JJHMbDL1EzLkh9GBhXDw==258EAFA5-E914-47DA-95CA-5AB5DC85B7AD"
	-- SHA-1 = 1d29ab734b0c9585240069a6e4e3e91b61da1969
	-- base64 = HSmrc0sMlYUkAGmm5OPpG2HaGWk=
	local accept, sha1hex = computeAccept("x3JJHMbDL1EzLkh9GBhXDw==")
	test.expect(sha1hex):toBe("1d29ab734b0c9585240069a6e4e3e91b61da1969")
	test.expect(accept):toBe("HSmrc0sMlYUkAGmm5OPpG2HaGWk=")
end)

return suite
