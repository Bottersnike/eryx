local test = require("@eryx/test")
local uuid = require("@eryx/uuid")

local suite = test.Suite.new("uuid")

local function fixedRandom(bytesOut: { number }): (number) -> buffer
	return function(byteCount: number): buffer
		test.expect(byteCount):toBe(#bytesOut)
		local out = buffer.create(byteCount)
		for i = 1, byteCount do
			buffer.writeu8(out, i - 1, bytesOut[i])
		end
		return out
	end
end

local function fixedRandomCalls(chunks: { { number } }): (number) -> buffer
	local index = 0
	return function(byteCount: number): buffer
		index += 1
		local bytesOut = chunks[index]
		test.expect(bytesOut):toNotBeNil()
		test.expect(byteCount):toBe(#(bytesOut :: { number }))
		local out = buffer.create(byteCount)
		for i = 1, byteCount do
			buffer.writeu8(out, i - 1, (bytesOut :: { number })[i])
		end
		return out
	end
end

local function expectBufferEquals(actual: buffer, expected: { number })
	test.expect(buffer.len(actual)):toBe(#expected)
	for i = 1, #expected do
		test.expect(buffer.readu8(actual, i - 1)):toBe(expected[i])
	end
end

suite:test("parse accepts canonical strings and normalizes uppercase", function()
	local parsed = uuid.parse("01890F3A-B5F7-7C0D-8F50-8F8C2C7ADF4D")

	test.expect(parsed.kind):toBe("v7")
	test.expect(parsed.version):toBe(7)
	test.expect(parsed.variant):toBe("rfc4122")
	test.expect(uuid.format(parsed)):toBe("01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d")
end)

suite:test("parse supports simple braced and urn forms only when enabled", function()
	test.expect(uuid.parse("01890f3ab5f77c0d8f508f8c2c7adf4d", { allowSimple = true }).kind):toBe("v7")
	test.expect(uuid.parse("{01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d}", { allowBraced = true }).kind):toBe("v7")
	test.expect(uuid.parse("urn:uuid:01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d", { allowUrn = true }).kind):toBe("v7")

	test.expect(function()
		uuid.parse("01890f3ab5f77c0d8f508f8c2c7adf4d")
	end):toError("invalid UUID string")

	test.expect(function()
		uuid.parse("{01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d}")
	end):toError("invalid UUID string")

	test.expect(function()
		uuid.parse("urn:uuid:01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d")
	end):toError("invalid UUID string")
end)

suite:test("parse rejects malformed strings", function()
	test.expect(function()
		uuid.parse("not-a-uuid")
	end):toError("invalid UUID string")

	test.expect(function()
		uuid.parse("01890f3a_b5f7_7c0d_8f50_8f8c2c7adf4d")
	end):toError("invalid UUID string")

	test.expect(function()
		uuid.parse("01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4")
	end):toError("invalid UUID string")

	test.expect(function()
		uuid.parse("01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4z")
	end):toError("invalid UUID string")

	test.expect(uuid.tryParse("not-a-uuid")):toBeNil()
	test.expect(uuid.validate("not-a-uuid")):toBe(false)
end)

suite:test("from accepts UUID strings buffers and UUID objects", function()
	local canonical = "00112233-4455-4677-8899-aabbccddeeff"
	local fromString = uuid.from(canonical)
	local fromBuffer = uuid.from(buffer.fromstring("\x00\x11\x22\x33\x44\x55\x46\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff"))
	local fromObject = uuid.from(fromString)

	test.expect(uuid.format(fromString)):toBe(canonical)
	test.expect(uuid.format(fromBuffer)):toBe(canonical)
	test.expect(fromObject):toBe(fromString)
end)

suite:test("from rejects bad buffers and unsupported values", function()
	test.expect(function()
		uuid.from(buffer.create(15) :: any)
	end):toError("exactly 16 bytes")

	test.expect(function()
		uuid.from(12345 :: any)
	end):toError("expected UUID, UUID string, or 16%-byte buffer")

	test.expect(uuid.validate(buffer.create(15) :: any)):toBe(false)
end)

suite:test("format supports every public style and rejects bad styles", function()
	local canonical = "01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d"
	local parsed = uuid.parse(canonical)

	test.expect(uuid.format(parsed, "canonical")):toBe(canonical)
	test.expect(uuid.format(parsed, "simple")):toBe("01890f3ab5f77c0d8f508f8c2c7adf4d")
	test.expect(uuid.format(parsed, "braced")):toBe("{01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d}")
	test.expect(uuid.format(parsed, "urn")):toBe("urn:uuid:01890f3a-b5f7-7c0d-8f50-8f8c2c7adf4d")

	test.expect(function()
		uuid.format(parsed, "octal" :: any)
	end):toError("invalid UUID format style")
end)

suite:test("unknown variants stay untagged and nil UUIDs are recognized", function()
	local nilUuid = uuid.from(buffer.create(16))

	test.expect(nilUuid.kind):toBeNil()
	test.expect(nilUuid.version):toBeNil()
	test.expect(nilUuid.variant):toBe("ncs")
	test.expect(nilUuid:isNil()):toBe(true)
	test.expect(nilUuid:unixMilliseconds()):toBeNil()
	test.expect(uuid.format(nilUuid)):toBe("00000000-0000-0000-0000-000000000000")
end)

suite:test("toBuffer returns a defensive copy", function()
	local id = uuid.parse("00112233-4455-4677-8899-aabbccddeeff")
	local copy = id:toBuffer()

	buffer.writeu8(copy, 0, 0xff)

	test.expect(uuid.format(id)):toBe("00112233-4455-4677-8899-aabbccddeeff")
	test.expect(buffer.readu8(copy, 0)):toBe(0xff)
end)

suite:test("equals and compare work across representations", function()
	local id = uuid.parse("00112233-4455-4677-8899-aabbccddeeff")
	local same = buffer.fromstring("\x00\x11\x22\x33\x44\x55\x46\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff")
	local lower = uuid.parse("00112233-4455-4677-8899-aabbccddeeff")
	local higher = uuid.parse("00112233-4455-4677-8899-aabbccddff00")

	test.expect(id:equals(same)):toBe(true)
	test.expect(uuid.equals(id, same)):toBe(true)
	test.expect(id:compare(same)):toBe(0)
	test.expect(uuid.compare(lower, higher)):toBe(-1)
	test.expect(uuid.compare(higher, lower)):toBe(1)
end)

suite:test("v1 packs timestamp clock sequence and node", function()
	local id = uuid.v1({
		unixMillis = 0i,
		clockSequence = 0,
		node = "010203040506",
	})

	test.expect(id.kind):toBe("v1")
	test.expect(id.version):toBe(1)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(id.unixMillis):toBe(0i)
	test.expect(id.clockSequence):toBe(0)
	test.expect(id.timestamp):toBe(122192928000000000i)
	test.expect(id:unixMilliseconds()):toBe(0i)
	test.expect(uuid.format(id)):toBe("13814000-1dd2-11b2-8000-010203040506")
	expectBufferEquals(id.node, { 1, 2, 3, 4, 5, 6 })
end)

suite:test("v1 can derive clock sequence and node from secure random bytes", function()
	local id = uuid.v1({
		unixMillis = 0i,
		random = fixedRandomCalls({
			{ 0xaa, 0xbb },
			{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
		}),
	})

	test.expect(id.clockSequence):toBe(0x2abb)
	expectBufferEquals(id.node, { 0x01, 0x11, 0x22, 0x33, 0x44, 0x55 })
end)

suite:test("v1 rejects invalid option values", function()
	test.expect(function()
		uuid.v1({ unixMillis = -1i })
	end):toError("non%-negative")

	test.expect(function()
		uuid.v1({ unixMillis = 200000000000000i })
	end):toError("out of range")

	test.expect(function()
		uuid.v1({ nanoseconds = 123 })
	end):toError("multiple of 100")

	test.expect(function()
		uuid.v1({ clockSequence = 0x4000 })
	end):toError("0%.%.16383")

	test.expect(function()
		uuid.v1({ node = "abcd" })
	end):toError("12 hex digits")

	test.expect(function()
		uuid.v1({ node = "zzzzzzzzzzzz" })
	end):toError("hexadecimal")
end)

suite:test("v3 matches the RFC namespace-name example", function()
	local id = uuid.v3({
		namespace = "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
		name = "www.widgets.com",
	})

	test.expect(id.kind):toBe("v3")
	test.expect(id.version):toBe(3)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(uuid.format(id)):toBe("3d813cbb-47fb-32ba-91df-831e1593ac29")
end)

suite:test("v3 and v5 accept buffer names and UUID objects as namespaces", function()
	local namespace = uuid.parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	local v3FromString = uuid.v3({
		namespace = namespace,
		name = "www.widgets.com",
	})
	local v3FromBuffer = uuid.v3({
		namespace = namespace,
		name = buffer.fromstring("www.widgets.com"),
	})
	local v5FromString = uuid.v5({
		namespace = namespace,
		name = "www.widgets.com",
	})
	local v5FromBuffer = uuid.v5({
		namespace = namespace,
		name = buffer.fromstring("www.widgets.com"),
	})

	test.expect(uuid.equals(v3FromString, v3FromBuffer)):toBe(true)
	test.expect(uuid.equals(v5FromString, v5FromBuffer)):toBe(true)
end)

suite:test("v4 sets version and variant bits", function()
	local id = uuid.v4({
		random = fixedRandom({
			0x00,
			0x11,
			0x22,
			0x33,
			0x44,
			0x55,
			0x66,
			0x77,
			0x88,
			0x99,
			0xaa,
			0xbb,
			0xcc,
			0xdd,
			0xee,
			0xff,
		}),
	})

	test.expect(id.kind):toBe("v4")
	test.expect(id.version):toBe(4)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(tostring(id)):toBe("00112233-4455-4677-8899-aabbccddeeff")
end)

suite:test("v5 matches the RFC namespace-name example", function()
	local id = uuid.v5({
		namespace = "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
		name = "www.widgets.com",
	})

	test.expect(id.kind):toBe("v5")
	test.expect(id.version):toBe(5)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(uuid.format(id)):toBe("21f7f8de-8051-5b89-8680-0195ef798b6a")
end)

suite:test("v6 packs reordered timestamps while preserving metadata", function()
	local id = uuid.v6({
		unixMillis = 0i,
		clockSequence = 0,
		node = "010203040506",
	})

	test.expect(id.kind):toBe("v6")
	test.expect(id.version):toBe(6)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(id.unixMillis):toBe(0i)
	test.expect(id.clockSequence):toBe(0)
	test.expect(id.timestamp):toBe(122192928000000000i)
	test.expect(uuid.format(id)):toBe("1b21dd21-3814-6000-8000-010203040506")
	expectBufferEquals(id.node, { 1, 2, 3, 4, 5, 6 })
end)

suite:test("v6 rejects invalid option values", function()
	test.expect(function()
		uuid.v6({ unixMillis = -1i })
	end):toError("non%-negative")

	test.expect(function()
		uuid.v6({ unixMillis = 200000000000000i })
	end):toError("out of range")

	test.expect(function()
		uuid.v6({ nanoseconds = 999999 })
	end):toError("multiple of 100")

	test.expect(function()
		uuid.v6({ node = buffer.create(5) })
	end):toError("exactly 6 bytes")
end)

suite:test("v7 encodes unix milliseconds and preserves metadata", function()
	local id = uuid.v7({
		unixMillis = 0x0123456789ABi,
		random = fixedRandom({
			0x12,
			0x34,
			0xaa,
			0xbb,
			0xcc,
			0xdd,
			0xee,
			0xff,
			0x10,
			0x20,
		}),
	})

	test.expect(id.kind):toBe("v7")
	test.expect(id.version):toBe(7)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(id.unixMillis):toBe(0x0123456789ABi)
	test.expect(id.randA):toBe(0x123)
	test.expect(uuid.format(id)):toBe("01234567-89ab-7123-aabb-ccddeeff1020")
	expectBufferEquals(id.randB, { 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20 })
	test.expect(id:unixMilliseconds()):toBe(0x0123456789ABi)
end)

suite:test("v7 is monotonic when sequence is not provided", function()
	local first = uuid.v7({
		unixMillis = 0x0fff00000000i,
		random = fixedRandom({
			0x12,
			0x30,
			0xaa,
			0xbb,
			0xcc,
			0xdd,
			0xee,
			0xff,
			0x10,
			0x20,
		}),
	})
	local second = uuid.v7({
		unixMillis = 0x0fff00000000i,
		random = fixedRandom({
			0x99,
			0x90,
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x06,
			0x07,
			0x08,
		}),
	})
	local third = uuid.v7({
		unixMillis = 0x0ffeffffffffi,
		random = fixedRandom({
			0xaa,
			0xa0,
			0x09,
			0x08,
			0x07,
			0x06,
			0x05,
			0x04,
			0x03,
			0x02,
		}),
	})

	test.expect(first.unixMillis):toBe(0x0fff00000000i)
	test.expect(first.randA):toBe(0x123)
	test.expect(second.unixMillis):toBe(0x0fff00000000i)
	test.expect(second.randA):toBe(0x124)
	test.expect(third.unixMillis):toBe(0x0fff00000000i)
	test.expect(third.randA):toBe(0x125)
	test.expect(uuid.compare(first, second)):toBe(-1)
	test.expect(uuid.compare(second, third)):toBe(-1)
end)

suite:test("v7 uses explicit sequence exactly and rejects invalid ranges", function()
	local id = uuid.v7({
		unixMillis = 0x0123456789ABi,
		sequence = 0xabc,
		random = fixedRandom({
			0x00,
			0x00,
			0xaa,
			0xbb,
			0xcc,
			0xdd,
			0xee,
			0xff,
			0x10,
			0x20,
		}),
	})

	test.expect(id.randA):toBe(0xabc)
	test.expect(uuid.format(id)):toBe("01234567-89ab-7abc-aabb-ccddeeff1020")

	test.expect(function()
		uuid.v7({ unixMillis = -1i })
	end):toError("48%-bit range")

	test.expect(function()
		uuid.v7({ unixMillis = 281474976710656i })
	end):toError("48%-bit range")

	test.expect(function()
		uuid.v7({ sequence = 0x1000 })
	end):toError("0%.%.4095")
end)

suite:test("v8 normalizes version and variant bits while preserving other payload bytes", function()
	local id = uuid.v8({
		bytes = buffer.fromstring("\x00\x11\x22\x33\x44\x55\x66\x77\xc8\x99\xaa\xbb\xcc\xdd\xee\xff"),
	})

	test.expect(id.kind):toBe("v8")
	test.expect(id.version):toBe(8)
	test.expect(id.variant):toBe("rfc4122")
	test.expect(uuid.format(id)):toBe("00112233-4455-8677-8899-aabbccddeeff")
end)

suite:test("v8 rejects non-16-byte payloads", function()
	test.expect(function()
		uuid.v8({ bytes = buffer.create(15) })
	end):toError("exactly 16 bytes")
end)

suite:test("generated UUIDs round-trip through parse with metadata preserved", function()
	local values = {
		uuid.v1({
			unixMillis = 1000i,
			nanoseconds = 500000,
			clockSequence = 123,
			node = "a1b2c3d4e5f6",
		}),
		uuid.v3({
			namespace = "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
			name = "www.widgets.com",
		}),
		uuid.v4({
			random = fixedRandom({
				0x10,
				0x20,
				0x30,
				0x40,
				0x50,
				0x60,
				0x70,
				0x80,
				0x90,
				0xa0,
				0xb0,
				0xc0,
				0xd0,
				0xe0,
				0xf0,
				0x00,
			}),
		}),
		uuid.v5({
			namespace = "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
			name = "www.widgets.com",
		}),
		uuid.v6({
			unixMillis = 1000i,
			nanoseconds = 500000,
			clockSequence = 123,
			node = "a1b2c3d4e5f6",
		}),
		uuid.v7({
			unixMillis = 0x0123456789ABi,
			sequence = 0x222,
			random = fixedRandom({
				0x00,
				0x00,
				0x10,
				0x20,
				0x30,
				0x40,
				0x50,
				0x60,
				0x70,
				0x80,
			}),
		}),
		uuid.v8({
			bytes = buffer.fromstring("\xde\xad\xbe\xef\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb"),
		}),
	}

	for _, value in values do
		local reparsed = uuid.parse(uuid.format(value))
		test.expect(uuid.equals(value, reparsed)):toBe(true)
		test.expect(reparsed.kind):toBe(value.kind)
	end
end)

return suite
