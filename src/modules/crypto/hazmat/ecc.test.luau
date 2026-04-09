local test = require("@eryx/test")
local ecc = require("@eryx/crypto/hazmat/ecc")
local hex = require("@eryx/encoding/hex")

local suite = test.Suite.new("ecc")

local function buf(s: string): buffer
	return buffer.fromstring(s)
end

local function h(b: buffer): string
	return hex.encode(b)
end

suite:test("generateKey: defaults to secp256r1", function()
	local priv = ecc.generateKey()
	local pub = ecc.getPublicPem(priv)

	test.expect(ecc.getCurve(priv)):toBe("secp256r1")
	test.expect(ecc.getCurve(pub)):toBe("secp256r1")
	test.expect(ecc.getKeyBits(priv)):toBe(256)
end)

suite:test("sign/verify: round-trips on secp256r1", function()
	local priv = ecc.generateKey("secp256r1")
	local pub = ecc.getPublicPem(priv)
	local data = buf("hello from ecc")
	local sig = ecc.sign(priv, data, "sha256")

	test.expect(ecc.verify(pub, data, sig, "sha256")):toBe(true)
	test.expect(ecc.verify(pub, buf("goodbye from ecc"), sig, "sha256")):toBe(false)
end)

suite:test("derive: both parties compute the same shared secret", function()
	local alicePriv = ecc.generateKey("secp256r1")
	local alicePub = ecc.getPublicPem(alicePriv)
	local bobPriv = ecc.generateKey("secp256r1")
	local bobPub = ecc.getPublicPem(bobPriv)

	local aliceSecret = ecc.derive(alicePriv, bobPub)
	local bobSecret = ecc.derive(bobPriv, alicePub)

	test.expect(h(aliceSecret)):toBe(h(bobSecret))
end)

suite:test("private/public DER conversion: round-trips curve metadata", function()
	local priv = ecc.generateKey("secp384r1")
	local pub = ecc.getPublicPem(priv)

	local privDer = ecc.privateToDer(priv)
	local pubDer = ecc.publicToDer(pub)

	local priv2 = ecc.privateFromDer(privDer)
	local pub2 = ecc.publicFromDer(pubDer)

	test.expect(ecc.getCurve(priv2)):toBe("secp384r1")
	test.expect(ecc.getCurve(pub2)):toBe("secp384r1")
	test.expect(ecc.getKeyBits(priv2)):toBe(384)
end)

return suite
