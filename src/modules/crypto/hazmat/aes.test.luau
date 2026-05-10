local zip = require("@eryx/compression/zip")
local test = require("@eryx/test")
local hex = require("@eryx/encoding/hex")
local http = require("@eryx/http")
local text = require("@eryx/text")
local aes = require("./aes")
local pkcs7 = require("./pkcs7")

local suite = test.Suite.new("AES")

local function join(parts: { buffer }): buffer
	local total = 0
	for _, part in parts do
		total += buffer.len(part)
	end

	local out = buffer.create(total)
	local offset = 0
	for _, part in parts do
		buffer.copy(out, offset, part)
		offset += buffer.len(part)
	end
	return out
end

local function crypt(
	key: buffer,
	mode: aes.Mode,
	operation: aes.Operation,
	ivOrNonce: buffer?,
	chunks: { buffer }
): buffer
	local ctx = aes.new(key, mode, operation, ivOrNonce)
	local out = {}
	for _, chunk in chunks do
		table.insert(out, ctx:update(chunk))
	end
	table.insert(out, ctx:final())
	return join(out)
end

type RspCase = {
	count: number?,
	fields: { [string]: string },
	fail: boolean,
}

type RspSection = {
	metadata: { [string]: string },
	sharedFields: { [string]: string },
	cases: { RspCase },
}

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$") or value
end

local function parseRsp(source: string): { RspSection }
	local sections = {}
	local currentSection: RspSection = {
		metadata = {},
		sharedFields = {},
		cases = {},
	}
	local currentCase: RspCase? = nil

	local function flushCase()
		if currentCase == nil then
			return
		end

		table.insert(currentSection.cases, currentCase :: RspCase)
		currentCase = nil
	end

	local function flushSection()
		if next(currentSection.metadata) == nil and #currentSection.cases == 0 then
			return
		end

		table.insert(sections, currentSection)
		currentSection = {
			metadata = {},
			sharedFields = {},
			cases = {},
		}
	end

	for rawLine in (source .. "\n"):gmatch("(.-)\r?\n") do
		local line = rawLine

		if line == "" then
			flushCase()
			continue
		end

		if line:sub(1, 1) == "#" then
			continue
		end

		local header = line:match("^%[(.*)%]$")
		if header ~= nil then
			flushCase()
			if #currentSection.cases > 0 then
				flushSection()
			end

			for entry in header:gmatch("[^,]+") do
				local sectionKey, sectionValue = trim(entry):match("^(.-)%s*=%s*(.-)$")
				if sectionKey == nil or sectionValue == nil then
					error(`Unsupported RSP header entry: {entry}`)
				end
				currentSection.metadata[trim(sectionKey)] = trim(sectionValue)
			end
			continue
		end

		if line == "FAIL" then
			if currentCase == nil then
				currentCase = {
					fields = {},
					fail = false,
				}
			end
			(currentCase :: RspCase).fail = true
			flushCase()
			continue
		end

		local field, value = line:match("^(.-)%s*=%s*(.*)$")
		if field == nil then
			error(`Unsupported RSP line: {line}`)
		end

		if field == "Count" then
			flushCase()
			currentCase = {
				count = tonumber(value),
				fields = {},
				fail = false,
			}
			continue
		end

		if currentCase == nil then
			currentSection.sharedFields[field] = value
			continue
		end
		currentCase.fields[field] = value
	end

	flushCase()
	flushSection()

	return sections
end

local function getRspField(section: RspSection, case: RspCase, name: string): string?
	return case.fields[name] or section.sharedFields[name]
end

local function getSectionField(section: RspSection, name: string): string?
	return section.metadata[name] or section.sharedFields[name]
end

local function getSectionNumber(section: RspSection, name: string): number?
	local value = getSectionField(section, name)
	if value == nil then
		return nil
	end
	return tonumber(value)
end

local function decodeCcmField(value: string?, expectedLength: number?): buffer
	if value == nil then
		return hex.decode("")
	end

	if expectedLength == 0 and value == "00" then
		return hex.decode("")
	end

	return hex.decode(value)
end

local function takePrefix(data: buffer, length: number): buffer
	local out = buffer.create(length)
	buffer.copy(out, 0, data, 0, length)
	return out
end

local function concat2(a: buffer, b: buffer): buffer
	local out = buffer.create(buffer.len(a) + buffer.len(b))
	buffer.copy(out, 0, a)
	buffer.copy(out, buffer.len(a), b)
	return out
end

local function runGcmDecryptCase(section: RspSection, case: RspCase)
	local key = hex.decode(getRspField(section, case, "Key") or "")
	local iv = hex.decode(getRspField(section, case, "IV") or "")
	local ct = hex.decode(getRspField(section, case, "CT") or "")
	local aad = hex.decode(getRspField(section, case, "AAD") or "")
	local tag = hex.decode(getRspField(section, case, "Tag") or "")

	local function decrypt(): buffer
		local ctx = aes.new(key, "gcm", "decrypt", iv)
		ctx:updateAAD(aad)
		ctx:setTag(tag)
		return join({
			ctx:update(ct),
			ctx:final(),
		})
	end

	if case.fail then
		test.expect(decrypt):toError()
	else
		test.expect(decrypt()):toBe(hex.decode(getRspField(section, case, "PT") or ""))
	end
end

local function runGcmEncryptCase(section: RspSection, case: RspCase)
	local key = hex.decode(getRspField(section, case, "Key") or "")
	local iv = hex.decode(getRspField(section, case, "IV") or "")
	local pt = hex.decode(getRspField(section, case, "PT") or "")
	local aad = hex.decode(getRspField(section, case, "AAD") or "")
	local expectedCt = hex.decode(getRspField(section, case, "CT") or "")
	local expectedTag = hex.decode(getRspField(section, case, "Tag") or "")
	local taglenBits = tonumber(section.metadata.Taglen or "128") or 128
	local taglenBytes = taglenBits // 8

	local ctx = aes.new(key, "gcm", "encrypt", iv)
	ctx:updateAAD(aad)
	local ciphertext = join({
		ctx:update(pt),
		ctx:final(),
	})

	test.expect(ciphertext):toBe(expectedCt)
	test.expect(takePrefix(ctx:getTag(), taglenBytes)):toBe(expectedTag)
end

-- https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf
-- Covers:
--  * ECB
--  * CBC
--  * CTR
--  * CFB128
--  * OFB
-- We don't support CFB1 or CFB8.

suite:test("F.1.1 ECB-AES128.Encrypt", function()
	local ctx = aes.new(hex.decode("2b7e151628aed2a6abf7158809cf4f3c"), "ecb", "encrypt")

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("3ad77bb40d7a3660a89ecaf32466ef97"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("f5d3d58503b9699de785895a96fdbaaf"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("43b1cd7f598ece23881b00e3ed030688"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("7b0c785e27e8ad3f8223207104725dd4"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.1.2 ECB-AES128.Decrypt", function()
	local ctx = aes.new(hex.decode("2b7e151628aed2a6abf7158809cf4f3c"), "ecb", "decrypt")

	test.expect(ctx:update(hex.decode("3ad77bb40d7a3660a89ecaf32466ef97")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("f5d3d58503b9699de785895a96fdbaaf")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("43b1cd7f598ece23881b00e3ed030688")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("7b0c785e27e8ad3f8223207104725dd4")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.1.3 ECB-AES192.Encrypt", function()
	local ctx = aes.new(hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"), "ecb", "encrypt")

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("bd334f1d6e45f25ff712a214571fa5cc"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("974104846d0ad3ad7734ecb3ecee4eef"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("ef7afd2270e2e60adce0ba2face6444e"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("9a4b41ba738d6c72fb16691603c18e0e"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.1.4 ECB-AES192.Decrypt", function()
	local ctx = aes.new(hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"), "ecb", "decrypt")

	test.expect(ctx:update(hex.decode("bd334f1d6e45f25ff712a214571fa5cc")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("974104846d0ad3ad7734ecb3ecee4eef")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("ef7afd2270e2e60adce0ba2face6444e")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("9a4b41ba738d6c72fb16691603c18e0e")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.1.5 ECB-AES256.Encrypt", function()
	local ctx =
		aes.new(hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"), "ecb", "encrypt")

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("f3eed1bdb5d2a03c064b5a7e3db181f8"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("591ccb10d410ed26dc5ba74a31362870"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("b6ed21b99ca6f4f9f153e7b1beafed1d"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("23304b7a39f9f3ff067d8d8f9e24ecc7"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.1.6 ECB-AES256.Decrypt", function()
	local ctx =
		aes.new(hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"), "ecb", "decrypt")

	test.expect(ctx:update(hex.decode("f3eed1bdb5d2a03c064b5a7e3db181f8")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("591ccb10d410ed26dc5ba74a31362870")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("b6ed21b99ca6f4f9f153e7b1beafed1d")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("23304b7a39f9f3ff067d8d8f9e24ecc7")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.1 CBC-AES128.Encrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"cbc",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("7649abac8119b246cee98e9b12e9197d"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("5086cb9b507219ee95db113a917678b2"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("73bed6b8e3c1743b7116e69e22229516"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("3ff1caa1681fac09120eca307586e1a7"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.2 CBC-AES128.Decrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"cbc",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("7649abac8119b246cee98e9b12e9197d")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("5086cb9b507219ee95db113a917678b2")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("73bed6b8e3c1743b7116e69e22229516")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("3ff1caa1681fac09120eca307586e1a7")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.3 CBC-AES192.Encrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"cbc",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("4f021db243bc633d7178183a9fa071e8"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("b4d9ada9ad7dedf4e5e738763f69145a"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("571b242012fb7ae07fa9baac3df102e0"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("08b0e27988598881d920a9e64f5615cd"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.4 CBC-AES192.Decrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"cbc",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("4f021db243bc633d7178183a9fa071e8")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("b4d9ada9ad7dedf4e5e738763f69145a")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("571b242012fb7ae07fa9baac3df102e0")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("08b0e27988598881d920a9e64f5615cd")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.5 CBC-AES256.Encrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"cbc",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("f58c4c04d6e5f1ba779eabfb5f7bfbd6"))
	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("9cfc4e967edb808d679f777bc6702c7d"))
	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("39f23369a9d9bacfa530e26304231461"))
	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("b2eb05e2c39be9fcda6c19078c6a9d1b"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.2.6 CBC-AES256.Decrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"cbc",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("f58c4c04d6e5f1ba779eabfb5f7bfbd6")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))
	test.expect(ctx:update(hex.decode("9cfc4e967edb808d679f777bc6702c7d")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))
	test.expect(ctx:update(hex.decode("39f23369a9d9bacfa530e26304231461")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))
	test.expect(ctx:update(hex.decode("b2eb05e2c39be9fcda6c19078c6a9d1b")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.13 CFB128-AES128.Encrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"cfb128",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("3b3fd92eb72dad20333449f8e83cfb4a"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("c8a64537a0b3a93fcde3cdad9f1ce58b"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("26751f67a3cbb140b1808cf187a4f4df"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("c04b05357c5d1c0eeac4c66f9ff7f2e6"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.14 CFB128-AES128.Decrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"cfb128",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("3b3fd92eb72dad20333449f8e83cfb4a")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("c8a64537a0b3a93fcde3cdad9f1ce58b")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("26751f67a3cbb140b1808cf187a4f4df")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("c04b05357c5d1c0eeac4c66f9ff7f2e6")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.15 CFB128-AES192.Encrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"cfb128",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("cdc80d6fddf18cab34c25909c99a4174"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("67ce7f7f81173621961a2b70171d3d7a"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("2e1e8a1dd59b88b1c8e60fed1efac4c9"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("c05f9f9ca9834fa042ae8fba584b09ff"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.16 CFB128-AES192.Decrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"cfb128",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("cdc80d6fddf18cab34c25909c99a4174")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("67ce7f7f81173621961a2b70171d3d7a")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("2e1e8a1dd59b88b1c8e60fed1efac4c9")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("c05f9f9ca9834fa042ae8fba584b09ff")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.17 CFB128-AES256.Encrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"cfb128",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("dc7e84bfda79164b7ecd8486985d3860"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("39ffed143b28b1c832113c6331e5407b"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("df10132415e54b92a13ed0a8267ae2f9"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("75a385741ab9cef82031623d55b1e471"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.3.18 CFB128-AES256.Decrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"cfb128",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("dc7e84bfda79164b7ecd8486985d3860")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("39ffed143b28b1c832113c6331e5407b")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("df10132415e54b92a13ed0a8267ae2f9")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("75a385741ab9cef82031623d55b1e471")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.1 OFB-AES128.Encrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"ofb",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("3b3fd92eb72dad20333449f8e83cfb4a"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("7789508d16918f03f53c52dac54ed825"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("9740051e9c5fecf64344f7a82260edcc"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("304c6528f659c77866a510d9c1d6ae5e"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.2 OFB-AES128.Decrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"ofb",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("3b3fd92eb72dad20333449f8e83cfb4a")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("7789508d16918f03f53c52dac54ed825")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("9740051e9c5fecf64344f7a82260edcc")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("304c6528f659c77866a510d9c1d6ae5e")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.3 OFB-AES192.Encrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"ofb",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("cdc80d6fddf18cab34c25909c99a4174"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("fcc28b8d4c63837c09e81700c1100401"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("8d9a9aeac0f6596f559c6d4daf59a5f2"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("6d9f200857ca6c3e9cac524bd9acc92a"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.4 OFB-AES192.Decrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"ofb",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("cdc80d6fddf18cab34c25909c99a4174")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("fcc28b8d4c63837c09e81700c1100401")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("8d9a9aeac0f6596f559c6d4daf59a5f2")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("6d9f200857ca6c3e9cac524bd9acc92a")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.5 OFB-AES256.Encrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"ofb",
		"encrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("dc7e84bfda79164b7ecd8486985d3860"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("4febdc6740d20b3ac88f6ad82a4fb08d"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("71ab47a086e86eedf39d1c5bba97c408"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("0126141d67f37be8538f5a8be740e484"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.4.6 OFB-AES256.Decrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"ofb",
		"decrypt",
		hex.decode("000102030405060708090a0b0c0d0e0f")
	)

	test.expect(ctx:update(hex.decode("dc7e84bfda79164b7ecd8486985d3860")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("4febdc6740d20b3ac88f6ad82a4fb08d")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("71ab47a086e86eedf39d1c5bba97c408")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("0126141d67f37be8538f5a8be740e484")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.1 CTR-AES128.Encrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"ctr",
		"encrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("874d6191b620e3261bef6864990db6ce"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("9806f66b7970fdff8617187bb9fffdff"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("5ae4df3edbd5d35e5b4f09020db03eab"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("1e031dda2fbe03d1792170a0f3009cee"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.2 CTR-AES128.Decrypt", function()
	local ctx = aes.new(
		hex.decode("2b7e151628aed2a6abf7158809cf4f3c"),
		"ctr",
		"decrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("874d6191b620e3261bef6864990db6ce")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("9806f66b7970fdff8617187bb9fffdff")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("5ae4df3edbd5d35e5b4f09020db03eab")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("1e031dda2fbe03d1792170a0f3009cee")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.3 CTR-AES192.Encrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"ctr",
		"encrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("1abc932417521ca24f2b0459fe7e6e0b"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("090339ec0aa6faefd5ccc2c6f4ce8e94"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("1e36b26bd1ebc670d1bd1d665620abf7"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("4f78a7f6d29809585a97daec58c6b050"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.4 CTR-AES192.Decrypt", function()
	local ctx = aes.new(
		hex.decode("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"),
		"ctr",
		"decrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("1abc932417521ca24f2b0459fe7e6e0b")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("090339ec0aa6faefd5ccc2c6f4ce8e94")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("1e36b26bd1ebc670d1bd1d665620abf7")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("4f78a7f6d29809585a97daec58c6b050")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.5 CTR-AES256.Encrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"ctr",
		"encrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("6bc1bee22e409f96e93d7e117393172a")))
		:toBe(hex.decode("601ec313775789a5b7a7f504bbf3d228"))

	test.expect(ctx:update(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51")))
		:toBe(hex.decode("f443e3ca4d62b59aca84e990cacaf5c5"))

	test.expect(ctx:update(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef")))
		:toBe(hex.decode("2b0930daa23de94ce87017ba2d84988d"))

	test.expect(ctx:update(hex.decode("f69f2445df4f9b17ad2b417be66c3710")))
		:toBe(hex.decode("dfc9c58db67aada613c2dd08457941a6"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("F.5.6 CTR-AES256.Decrypt", function()
	local ctx = aes.new(
		hex.decode("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
		"ctr",
		"decrypt",
		hex.decode("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	)

	test.expect(ctx:update(hex.decode("601ec313775789a5b7a7f504bbf3d228")))
		:toBe(hex.decode("6bc1bee22e409f96e93d7e117393172a"))

	test.expect(ctx:update(hex.decode("f443e3ca4d62b59aca84e990cacaf5c5")))
		:toBe(hex.decode("ae2d8a571e03ac9c9eb76fac45af8e51"))

	test.expect(ctx:update(hex.decode("2b0930daa23de94ce87017ba2d84988d")))
		:toBe(hex.decode("30c81c46a35ce411e5fbc1191a0a52ef"))

	test.expect(ctx:update(hex.decode("dfc9c58db67aada613c2dd08457941a6")))
		:toBe(hex.decode("f69f2445df4f9b17ad2b417be66c3710"))

	test.expect(ctx:final()):toBe(hex.decode(""))
end)

suite:test("CBC composes cleanly with PKCS7", function()
	local key = buffer.fromstring("0123456789abcdef")
	local iv = buffer.fromstring("0000000000000000")
	local plaintext = buffer.fromstring("Hello, AES!")

	local padded = pkcs7.pad(plaintext, 16)
	local ciphertext = crypt(key, "cbc", "encrypt", iv, { padded })
	local decrypted = crypt(key, "cbc", "decrypt", iv, { ciphertext })

	test.expect(pkcs7.unpad(decrypted, 16)):toBe(plaintext)
end)

-- https://csrc.nist.gov/Projects/cryptographic-algorithm-validation-program/cavp-testing-block-cipher-modes
-- Covers:
--  * GCM
--  * CCM

local gcm = http.get(
	"https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/gcmtestvectors.zip"
)
local gcmArchive = buffer.fromstring(gcm.body)
for _, file in zip.list(gcmArchive) do
	if not text.endsWith(file.name, ".rsp") then
		continue
	end

	local data = zip.read(gcmArchive, file.name)
	assert(data)

	local sections = parseRsp(buffer.tostring(data))

	suite:test(`GCM CAVP {file.name}`, function()
		for _, section in sections do
			for _, case in section.cases do
				if file.name:match("^gcmDecrypt") then
					runGcmDecryptCase(section, case)
				elseif file.name:match("^gcmEncrypt") then
					runGcmEncryptCase(section, case)
				else
					error(`Unsupported GCM vector file: {file.name}`)
				end
			end
		end
	end)
end

local ccm = http.get(
	"https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/ccmtestvectors.zip"
)
local ccmArchive = buffer.fromstring(ccm.body)
for _, file in zip.list(ccmArchive) do
	if not text.endsWith(file.name, ".rsp") then
		continue
	end

	local data = zip.read(ccmArchive, file.name)
	assert(data)

	local sections = parseRsp(buffer.tostring(data))

	suite:test(`CCM CAVP {file.name}`, function()
		local lastAlen: number? = nil
		local lastPlen: number? = nil
		local lastTlen: number? = nil
		local lastNlen: number? = nil

		for _, section in sections do
			local key = hex.decode(section.sharedFields.Key or "")
			local alen = (getSectionNumber(section, "Alen") or lastAlen) :: number
			local plen = (getSectionNumber(section, "Plen") or lastPlen) :: number
			local tlen = (getSectionNumber(section, "Tlen") or lastTlen) :: number
			local nlen = (getSectionNumber(section, "Nlen") or lastNlen) :: number

			test.expect(alen):toNotBeNil()
			test.expect(plen):toNotBeNil()
			test.expect(tlen):toNotBeNil()
			test.expect(nlen):toNotBeNil()

			lastAlen = alen
			lastPlen = plen
			lastTlen = tlen
			lastNlen = nlen

			for _, case in section.cases do
				local nonce = decodeCcmField(getRspField(section, case, "Nonce"), nlen)
				local aad = decodeCcmField(getRspField(section, case, "Adata"), alen)
				local payload = decodeCcmField(getRspField(section, case, "Payload"), plen)
				local combined = decodeCcmField(getRspField(section, case, "CT"), plen + tlen)
				local combinedString = buffer.tostring(combined)
				local ciphertext = buffer.fromstring(combinedString:sub(1, plen))
				local tag = buffer.fromstring(combinedString:sub(plen + 1))
				local result = getRspField(section, case, "Result") or ""

				if file.name:match("^DVPT") then
					if result:match("^Pass") then
						test.expect(aes.decryptCCM(key, nonce, ciphertext, tag, aad)):toBe(payload)
					else
						test.expect(function()
							aes.decryptCCM(key, nonce, ciphertext, tag, aad)
						end):toError()
					end
				else
					local actualCt, actualTag = aes.encryptCCM(key, nonce, payload, aad, tlen)
					test.expect(concat2(actualCt, actualTag)):toBe(combined)
				end
			end
		end
	end)
end

-- Misc tests

suite:test("streaming CBC encrypt/decrypt round-trips across chunk boundaries", function()
	local key = buffer.fromstring("0123456789abcdef")
	local iv = buffer.fromstring("0000000000000000")
	local plaintext = pkcs7.pad(buffer.fromstring("stream me please"), 16)

	local ciphertext = crypt(key, "cbc", "encrypt", iv, {
		buffer.fromstring(buffer.tostring(plaintext):sub(1, 5)),
		buffer.fromstring(buffer.tostring(plaintext):sub(6)),
	})

	local recovered = crypt(key, "cbc", "decrypt", iv, {
		buffer.fromstring(buffer.tostring(ciphertext):sub(1, 7)),
		buffer.fromstring(buffer.tostring(ciphertext):sub(8)),
	})

	test.expect(pkcs7.unpad(recovered, 16)):toBe(buffer.fromstring("stream me please"))
end)

suite:test("streaming GCM supports AAD and tags", function()
	local key = hex.decode("000102030405060708090a0b0c0d0e0f")
	local nonce = hex.decode("101112131415161718191a1b")
	local aad = buffer.fromstring("header")
	local plaintext = buffer.fromstring("hello world")

	local enc = aes.new(key, "gcm", "encrypt", nonce)
	enc:updateAAD(aad)
	local ciphertext = join({
		enc:update(buffer.fromstring("hello ")),
		enc:update(buffer.fromstring("world")),
		enc:final(),
	})
	local tag = enc:getTag()

	local dec = aes.new(key, "gcm", "decrypt", nonce)
	dec:updateAAD(aad)
	dec:setTag(tag)
	local recovered = join({
		dec:update(buffer.fromstring(buffer.tostring(ciphertext):sub(1, 4))),
		dec:update(buffer.fromstring(buffer.tostring(ciphertext):sub(5))),
		dec:final(),
	})

	test.expect(recovered):toBe(plaintext)
end)

suite:test("ECB rejects non-block-aligned input", function()
	test.expect(function()
		crypt(buffer.fromstring("0123456789abcdef"), "ecb", "encrypt", nil, { buffer.fromstring("abc") })
	end):toError("cipher block size")
end)

suite:test("CBC rejects non-block-aligned input", function()
	test.expect(function()
		crypt(
			buffer.fromstring("0123456789abcdef"),
			"cbc",
			"encrypt",
			buffer.fromstring("0000000000000000"),
			{ buffer.fromstring("abc") }
		)
	end):toError("cipher block size")
end)

return suite
