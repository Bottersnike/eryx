local test = require("@eryx/test")
local unicode = require("@eryx/unicode")

local suite = test.Suite.new("unicode")

local function utf8FromHexSequence(seq: string): string
	local out: { string } = {}
	for token in seq:gmatch("%S+") do
		local cp = tonumber(token, 16)
		if cp == nil then
			error(("invalid code point token: %s"):format(token))
		end
		table.insert(out, utf8.char(cp))
	end
	return table.concat(out)
end

local NORMALIZATION_TEST_CASES = [[
1E0A;1E0A;0044 0307;1E0A;0044 0307
1E14;1E14;0045 0304 0300;1E14;0045 0304 0300
331E 0334;331E 0334;331E 0334;30B3 30FC 30DD 0334;30B3 30FC 30DB 0334 309A
00AF;00AF;00AF;0020 0304;0020 0304
00C5;00C5;0041 030A;00C5;0041 030A
00D9;00D9;0055 0300;00D9;0055 0300
00EC;00EC;0069 0300;00EC;0069 0300
0100;0100;0041 0304;0100;0041 0304
0112;0112;0045 0304;0112;0045 0304
0122;0122;0047 0327;0122;0047 0327
0135;0135;006A 0302;0135;006A 0302
0148;0148;006E 030C;0148;006E 030C
015C;015C;0053 0302;015C;0053 0302
016E;016E;0055 030A;016E;0055 030A
017E;017E;007A 030C;017E;007A 030C
01CE;01CE;0061 030C;01CE;0061 030C
01DF;01DF;0061 0308 0304;01DF;0061 0308 0304
01F1;01F1;01F1;0044 005A;0044 005A
0203;0203;0061 0311;0203;0061 0311
0213;0213;0072 0311;0213;0072 0311
022B;022B;006F 0308 0304;022B;006F 0308 0304
02B7;02B7;02B7;0077;0077
0344;0308 0301;0308 0301;0308 0301;0308 0301
03AB;03AB;03A5 0308;03AB;03A5 0308
03D5;03D5;03D5;03C6;03C6
0439;0439;0438 0306;0439;0438 0306
04D6;04D6;0415 0306;04D6;0415 0306
04EC;04EC;042D 0308;04EC;042D 0308
0625;0625;0627 0655;0625;0627 0655
095C;0921 093C;0921 093C;0921 093C;0921 093C
0B4B;0B4B;0B47 0B3E;0B4B;0B47 0B3E
0D4C;0D4C;0D46 0D57;0D4C;0D46 0D57
0F73;0F71 0F72;0F71 0F72;0F71 0F72;0F71 0F72
1B08;1B08;1B07 1B35;1B08;1B07 1B35
1D33;1D33;1D33;0047;0047
1D44;1D44;1D44;0250;0250
1D55;1D55;1D55;1D17;1D17
1D65;1D65;1D65;0076;0076
1DA4;1DA4;1DA4;0268;0268
1DB4;1DB4;1DB4;0283;0283
1E04;1E04;0042 0323;1E04;0042 0323
1E14;1E14;0045 0304 0300;1E14;0045 0304 0300
1E24;1E24;0048 0323;1E24;0048 0323
1E34;1E34;004B 0331;1E34;004B 0331
1E44;1E44;004E 0307;1E44;004E 0307
1E54;1E54;0050 0301;1E54;0050 0301
1E64;1E64;0053 0301 0307;1E64;0053 0301 0307
1E74;1E74;0055 0330;1E74;0055 0330
1E84;1E84;0057 0308;1E84;0057 0308
1E94;1E94;005A 0331;1E94;005A 0331
1EA8;1EA8;0041 0302 0309;1EA8;0041 0302 0309
1EB8;1EB8;0045 0323;1EB8;0045 0323
1EC8;1EC8;0049 0309;1EC8;0049 0309
1ED8;1ED8;004F 0323 0302;1ED8;004F 0323 0302
1EE8;1EE8;0055 031B 0301;1EE8;0055 031B 0301
1EF8;1EF8;0059 0303;1EF8;0059 0303
1F0E;1F0E;0391 0313 0342;1F0E;0391 0313 0342
1F22;1F22;03B7 0313 0300;1F22;03B7 0313 0300
1F32;1F32;03B9 0313 0300;1F32;03B9 0313 0300
1F42;1F42;03BF 0313 0300;1F42;03BF 0313 0300
1F56;1F56;03C5 0313 0342;1F56;03C5 0313 0342
1F6A;1F6A;03A9 0313 0300;1F6A;03A9 0313 0300
1F7A;1F7A;03C5 0300;1F7A;03C5 0300
1F8C;1F8C;0391 0313 0301 0345;1F8C;0391 0313 0301 0345
1F9C;1F9C;0397 0313 0301 0345;1F9C;0397 0313 0301 0345
1FAC;1FAC;03A9 0313 0301 0345;1FAC;03A9 0313 0301 0345
1FBD;1FBD;1FBD;0020 0313;0020 0313
1FCE;1FCE;1FBF 0301;0020 0313 0301;0020 0313 0301
1FE1;1FE1;03C5 0304;1FE1;03C5 0304
1FF3;1FF3;03C9 0345;1FF3;03C9 0345
2005;2005;2005;0020;0020
203C;203C;203C;0021 0021;0021 0021
207B;207B;207B;2212;2212
208B;208B;208B;2212;2212
209C;209C;209C;0074;0074
2110;2110;2110;0049;0049
2128;2128;2128;005A;005A
213C;213C;213C;03C0;03C0
2156;2156;2156;0032 2044 0035;0032 2044 0035
2166;2166;2166;0056 0049 0049;0056 0049 0049
2176;2176;2176;0076 0069 0069;0076 0069 0069
21CF;21CF;21D2 0338;21CF;21D2 0338
226D;226D;224D 0338;226D;224D 0338
22AD;22AD;22A8 0338;22AD;22A8 0338
2463;2463;2463;0034;0034
2473;2473;2473;0032 0030;0032 0030
2483;2483;2483;0028 0031 0036 0029;0028 0031 0036 0029
2493;2493;2493;0031 0032 002E;0031 0032 002E
24A3;24A3;24A3;0028 0068 0029;0028 0068 0029
24B3;24B3;24B3;0028 0078 0029;0028 0078 0029
24C3;24C3;24C3;004E;004E
24D3;24D3;24D3;0064;0064
24E3;24E3;24E3;0074;0074
2E9F;2E9F;2E9F;6BCD;6BCD
2F0E;2F0E;2F0E;51AB;51AB
2F1E;2F1E;2F1E;56D7;56D7
2F2E;2F2E;2F2E;5DDB;5DDB
2F3E;2F3E;2F3E;6236;6236
2F4E;2F4E;2F4E;6BB3;6BB3
2F5E;2F5E;2F5E;7384;7384
2F6E;2F6E;2F6E;77E2;77E2
2F7E;2F7E;2F7E;8012;8012
2F8E;2F8E;2F8E;8840;8840
2F9E;2F9E;2F9E;8ECA;8ECA
2FAE;2FAE;2FAE;975E;975E
2FBE;2FBE;2FBE;9B25;9B25
2FCE;2FCE;2FCE;9F13;9F13
3052;3052;3051 3099;3052;3051 3099
3076;3076;3075 3099;3076;3075 3099
30B6;30B6;30B5 3099;30B6;30B5 3099
30D9;30D9;30D8 3099;30D9;30D8 3099
3136;3136;3136;11AD;11AD
3146;3146;3146;110A;110A
3156;3156;3156;1168;1168
3166;3166;3166;1115;1115
3176;3176;3176;1127;1127
3186;3186;3186;1159;1159
3199;3199;3199;7532;7532
3209;3209;3209;0028 110E 0029;0028 110E 0029
3219;3219;3219;0028 D0C0 0029;0028 1110 1161 0029
322A;322A;322A;0028 6708 0029;0028 6708 0029
323A;323A;323A;0028 547C 0029;0028 547C 0029
3252;3252;3252;0032 0032;0032 0032
3262;3262;3262;1103;1103
3272;3272;3272;B9C8;1106 1161
3283;3283;3283;56DB;56DB
3293;3293;3293;793E;793E
32A3;32A3;32A3;6B63;6B63
32B3;32B3;32B3;0033 0038;0033 0038
32C3;32C3;32C3;0034 6708;0034 6708
32D3;32D3;32D3;30A8;30A8
32E3;32E3;32E3;30C8;30C8
32F3;32F3;32F3;30E4;30E4
3303;3303;3303;30A2 30FC 30EB;30A2 30FC 30EB
3313;3313;3313;30AE 30EB 30C0 30FC;30AD 3099 30EB 30BF 3099 30FC
3323;3323;3323;30BB 30F3 30C8;30BB 30F3 30C8
3333;3333;3333;30D5 30A3 30FC 30C8;30D5 30A3 30FC 30C8
3343;3343;3343;30DE 30A4 30AF 30ED;30DE 30A4 30AF 30ED
3353;3353;3353;30EB 30D4 30FC;30EB 30D2 309A 30FC
3363;3363;3363;0031 0031 70B9;0031 0031 70B9
3373;3373;3373;0041 0055;0041 0055
3383;3383;3383;006D 0041;006D 0041
3393;3393;3393;0047 0048 007A;0047 0048 007A
33A3;33A3;33A3;006D 006D 0033;006D 006D 0033
33B3;33B3;33B3;006D 0073;006D 0073
33C3;33C3;33C3;0042 0071;0042 0071
33D3;33D3;33D3;006C 0078;006C 0078
33E3;33E3;33E3;0034 65E5;0034 65E5
33F3;33F3;33F3;0032 0030 65E5;0032 0030 65E5
A7F1;A7F1;A7F1;0053;0053
AC05;AC05;1100 1161 11AC;AC05;1100 1161 11AC
AC15;AC15;1100 1161 11BC;AC15;1100 1161 11BC
AC25;AC25;1100 1162 11B0;AC25;1100 1162 11B0
AC35;AC35;1100 1162 11C0;AC35;1100 1162 11C0
AC45;AC45;1100 1163 11B4;AC45;1100 1163 11B4
AC55;AC55;1100 1164 11A8;AC55;1100 1164 11A8
AC65;AC65;1100 1164 11B8;AC65;1100 1164 11B8
AC75;AC75;1100 1165 11AC;AC75;1100 1165 11AC
AC85;AC85;1100 1165 11BC;AC85;1100 1165 11BC
AC95;AC95;1100 1166 11B0;AC95;1100 1166 11B0
ACA5;ACA5;1100 1166 11C0;ACA5;1100 1166 11C0
ACB5;ACB5;1100 1167 11B4;ACB5;1100 1167 11B4
ACC5;ACC5;1100 1168 11A8;ACC5;1100 1168 11A8
ACD5;ACD5;1100 1168 11B8;ACD5;1100 1168 11B8
ACE5;ACE5;1100 1169 11AC;ACE5;1100 1169 11AC
ACF5;ACF5;1100 1169 11BC;ACF5;1100 1169 11BC
AD05;AD05;1100 116A 11B0;AD05;1100 116A 11B0
AD15;AD15;1100 116A 11C0;AD15;1100 116A 11C0
AD25;AD25;1100 116B 11B4;AD25;1100 116B 11B4
AD35;AD35;1100 116C 11A8;AD35;1100 116C 11A8
AD45;AD45;1100 116C 11B8;AD45;1100 116C 11B8
AD55;AD55;1100 116D 11AC;AD55;1100 116D 11AC
AD65;AD65;1100 116D 11BC;AD65;1100 116D 11BC
AD75;AD75;1100 116E 11B0;AD75;1100 116E 11B0
AD85;AD85;1100 116E 11C0;AD85;1100 116E 11C0
AD95;AD95;1100 116F 11B4;AD95;1100 116F 11B4
ADA5;ADA5;1100 1170 11A8;ADA5;1100 1170 11A8
ADB5;ADB5;1100 1170 11B8;ADB5;1100 1170 11B8
ADC5;ADC5;1100 1171 11AC;ADC5;1100 1171 11AC
ADD5;ADD5;1100 1171 11BC;ADD5;1100 1171 11BC
ADE5;ADE5;1100 1172 11B0;ADE5;1100 1172 11B0
ADF5;ADF5;1100 1172 11C0;ADF5;1100 1172 11C0
AE05;AE05;1100 1173 11B4;AE05;1100 1173 11B4
AE15;AE15;1100 1174 11A8;AE15;1100 1174 11A8
AE25;AE25;1100 1174 11B8;AE25;1100 1174 11B8
AE35;AE35;1100 1175 11AC;AE35;1100 1175 11AC
AE45;AE45;1100 1175 11BC;AE45;1100 1175 11BC
AE55;AE55;1101 1161 11B0;AE55;1101 1161 11B0
AE65;AE65;1101 1161 11C0;AE65;1101 1161 11C0
AE75;AE75;1101 1162 11B4;AE75;1101 1162 11B4
AE85;AE85;1101 1163 11A8;AE85;1101 1163 11A8
AE95;AE95;1101 1163 11B8;AE95;1101 1163 11B8
AEA5;AEA5;1101 1164 11AC;AEA5;1101 1164 11AC
AEB5;AEB5;1101 1164 11BC;AEB5;1101 1164 11BC
AEC5;AEC5;1101 1165 11B0;AEC5;1101 1165 11B0
AED5;AED5;1101 1165 11C0;AED5;1101 1165 11C0
AEE5;AEE5;1101 1166 11B4;AEE5;1101 1166 11B4
AEF5;AEF5;1101 1167 11A8;AEF5;1101 1167 11A8
AF05;AF05;1101 1167 11B8;AF05;1101 1167 11B8
AF15;AF15;1101 1168 11AC;AF15;1101 1168 11AC
AF25;AF25;1101 1168 11BC;AF25;1101 1168 11BC
AF35;AF35;1101 1169 11B0;AF35;1101 1169 11B0
AF45;AF45;1101 1169 11C0;AF45;1101 1169 11C0
AF55;AF55;1101 116A 11B4;AF55;1101 116A 11B4
AF65;AF65;1101 116B 11A8;AF65;1101 116B 11A8
AF75;AF75;1101 116B 11B8;AF75;1101 116B 11B8
AF85;AF85;1101 116C 11AC;AF85;1101 116C 11AC
AF95;AF95;1101 116C 11BC;AF95;1101 116C 11BC
AFA5;AFA5;1101 116D 11B0;AFA5;1101 116D 11B0
AFB5;AFB5;1101 116D 11C0;AFB5;1101 116D 11C0
AFC5;AFC5;1101 116E 11B4;AFC5;1101 116E 11B4
AFD5;AFD5;1101 116F 11A8;AFD5;1101 116F 11A8
AFE5;AFE5;1101 116F 11B8;AFE5;1101 116F 11B8
AFF5;AFF5;1101 1170 11AC;AFF5;1101 1170 11AC
B005;B005;1101 1170 11BC;B005;1101 1170 11BC
B015;B015;1101 1171 11B0;B015;1101 1171 11B0
B025;B025;1101 1171 11C0;B025;1101 1171 11C0
B035;B035;1101 1172 11B4;B035;1101 1172 11B4
B045;B045;1101 1173 11A8;B045;1101 1173 11A8
B055;B055;1101 1173 11B8;B055;1101 1173 11B8
B065;B065;1101 1174 11AC;B065;1101 1174 11AC
B075;B075;1101 1174 11BC;B075;1101 1174 11BC
B085;B085;1101 1175 11B0;B085;1101 1175 11B0
B095;B095;1101 1175 11C0;B095;1101 1175 11C0
]]

suite:test("fromName/name: basic round-trip", function()
	local a = unicode.fromName("LATIN SMALL LETTER A")
	test.expect(a):toBe("a")
	test.expect(unicode.name(a :: string)):toBe("LATIN SMALL LETTER A")
end)

suite:test("fromName: accepts extra spacing and underscores", function()
	local leftCurly = unicode.fromName("   left__curly   bracket  ")
	test.expect(leftCurly):toBe("{")
end)

suite:test("fromName: alias names resolve", function()
	local lf = unicode.fromName("LINE FEED")
	test.expect(lf):toBe("\n")
end)

suite:test("fromName: missing name returns provided default", function()
	test.expect(unicode.fromName("NOT A REAL UNICODE NAME", "?")):toBe("?")
end)

suite:test("name: errors for multi-codepoint strings", function()
	test.expect(function()
		unicode.name("ab")
	end):toError("expects exactly one codepoint")
end)

suite:test("toNumber: decimal digits", function()
	test.expect(unicode.toNumber("0")):toBe(0)
	test.expect(unicode.toNumber("9")):toBe(9)
	test.expect(unicode.toNumber("٣")):toBe(3)
end)

suite:test("toNumber: numeric fractions", function()
	test.expect(unicode.toNumber("½")):toBeCloseTo(0.5, 1e-12)
	test.expect(unicode.toNumber("⅔")):toBeCloseTo(2 / 3, 1e-12)
end)

suite:test("toNumber: non-numeric or multi-codepoint returns nil", function()
	test.expect(unicode.toNumber("A")):toBeNil()
	test.expect(unicode.toNumber("ab")):toBeNil()
end)

suite:test("category: basic Unicode general categories", function()
	test.expect(unicode.category(string.byte("A"))):toBe("Lu")
	test.expect(unicode.category(utf8.codepoint("π"))):toBe("Ll")
	test.expect(unicode.category(utf8.codepoint("١"))):toBe("Nd")
	test.expect(unicode.category(utf8.codepoint("\u{0301}"))):toBe("Mn")
end)

suite:test("case mapping: simple latin", function()
	test.expect(unicode.toUpperCase("hello")):toBe("HELLO")
	test.expect(unicode.toLowercase("HELLO")):toBe("hello")
	test.expect(unicode.foldCase("HeLLo")):toBe("hello")
end)

suite:test("case mapping: German sharp s and title case", function()
	test.expect(unicode.toUpperCase("straße")):toBe("STRASSE")
	test.expect(unicode.foldCase("Straße")):toBe("strasse")
	test.expect(unicode.toTitleCase("straße")):toBe("Straße")
end)

suite:test("case mapping: Greek sigma fold", function()
	test.expect(unicode.foldCase("Σίσυφος")):toBe("σίσυφοσ")
end)

suite:test("graphemes/len/sub: UTF-8 codepoint slicing helpers", function()
	local s = "Aé𝄞🙂"
	local parts: { string } = {}
	for g in unicode.graphemes(s) do
		table.insert(parts, g)
	end

	test.expect(#parts):toBe(4)
	test.expect(parts[1]):toBe("A")
	test.expect(parts[2]):toBe("é")
	test.expect(parts[3]):toBe("𝄞")
	test.expect(parts[4]):toBe("🙂")

	test.expect(unicode.len(s)):toBe(4)
	test.expect(unicode.sub(s, 2, 3)):toBe("é𝄞")
	test.expect(unicode.sub(s, -2, -1)):toBe("𝄞🙂")
	test.expect(unicode.sub(s, 10, 20)):toBe("")
end)

suite:test("UTF-16 round-trip with BOM", function()
	local source = "Hello 🙂 世界"
	local utf16 = unicode.toUtf16(source, "little", true)
	local roundTrip = unicode.fromUtf16(utf16)
	test.expect(roundTrip):toBe(source)
end)

suite:test("UTF-16 round-trip big-endian without BOM", function()
	local source = "Aé𝄞"
	local utf16 = unicode.toUtf16(source, "big", false)
	local roundTrip = unicode.fromUtf16(utf16, "big")
	test.expect(roundTrip):toBe(source)
end)

suite:test("UTF-32 round-trip little and big endian", function()
	local source = "Hello 𐐷🙂"

	local le = unicode.toUtf32(source, "little", true)
	test.expect(unicode.fromUtf32(le)):toBe(source)

	local be = unicode.toUtf32(source, "big", true)
	test.expect(unicode.fromUtf32(be)):toBe(source)
end)

suite:test("detectBom: identifies UTF-16/UTF-32 BOMs", function()
	local utf16le = unicode.toUtf16("A", "little", true)
	local endian16, kind16, size16 = unicode.detectBom(utf16le)
	test.expect(endian16):toBe("little")
	test.expect(kind16):toBe("utf16")
	test.expect(size16):toBe(2)

	local utf32be = unicode.toUtf32("A", "big", true)
	local endian32, kind32, size32 = unicode.detectBom(utf32be)
	test.expect(endian32):toBe("big")
	test.expect(kind32):toBe("utf32")
	test.expect(size32):toBe(4)
end)

suite:test("normalise: canonical and compatibility examples", function()
	local combiningAcute = "e\u{0301}"
	local precomposed = "é"
	test.expect(unicode.normalise(combiningAcute, "NFC")):toBe(precomposed)
	test.expect(unicode.normalise(precomposed, "NFD")):toBe(combiningAcute)

	local angstrom = "\u{212B}" -- ANGSTROM SIGN
	test.expect(unicode.normalise(angstrom, "NFKC")):toBe("\u{00C5}")
	test.expect(unicode.normalise(angstrom, "NFKD")):toBe("A\u{030A}")
end)

suite:test("isNormalised: basic truthy and falsy checks", function()
	test.expect(unicode.isNormalised("é", "NFC")):toBeTrue()
	test.expect(unicode.isNormalised("e\u{0301}", "NFC")):toBeFalse()
	test.expect(unicode.isNormalised("e\u{0301}", "NFD")):toBeTrue()
end)

suite:test("normalise: official NormalizationTest.txt sample", function()
	local raw = NORMALIZATION_TEST_CASES
	local checked = 0
	local expected = 0

	for rawLine in (raw .. "\n"):gmatch("([^\n]*)\n") do
		local line = rawLine:gsub("#.*$", "")
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line == "" then
			continue
		end
		if line:sub(1, 1) == "@" then
			continue
		end

		local cols: { string } = {}
		for part in line:gmatch("([^;]+)") do
			local v = part:gsub("^%s+", ""):gsub("%s+$", "")
			table.insert(cols, v)
		end
		if #cols < 5 then
			continue
		end
		expected += 1

		local c1 = utf8FromHexSequence(cols[1])
		local c2 = utf8FromHexSequence(cols[2])
		local c3 = utf8FromHexSequence(cols[3])
		local c4 = utf8FromHexSequence(cols[4])
		local c5 = utf8FromHexSequence(cols[5])

		local id = ("line=%s case=%d"):format(rawLine, checked + 1)

		if unicode.normalise(c1, "NFC") ~= c2 then
			error("NFC(c1) mismatch: " .. id)
		end
		if unicode.normalise(c2, "NFC") ~= c2 then
			error("NFC(c2) mismatch: " .. id)
		end
		if unicode.normalise(c3, "NFC") ~= c2 then
			error("NFC(c3) mismatch: " .. id)
		end
		if unicode.normalise(c4, "NFC") ~= c4 then
			error("NFC(c4) mismatch: " .. id)
		end
		if unicode.normalise(c5, "NFC") ~= c4 then
			error("NFC(c5) mismatch: " .. id)
		end

		if unicode.normalise(c1, "NFD") ~= c3 then
			error("NFD(c1) mismatch: " .. id)
		end
		if unicode.normalise(c2, "NFD") ~= c3 then
			error("NFD(c2) mismatch: " .. id)
		end
		if unicode.normalise(c3, "NFD") ~= c3 then
			error("NFD(c3) mismatch: " .. id)
		end
		if unicode.normalise(c4, "NFD") ~= c5 then
			error("NFD(c4) mismatch: " .. id)
		end
		if unicode.normalise(c5, "NFD") ~= c5 then
			error("NFD(c5) mismatch: " .. id)
		end

		if unicode.normalise(c1, "NFKC") ~= c4 then
			error("NFKC(c1) mismatch: " .. id)
		end
		if unicode.normalise(c2, "NFKC") ~= c4 then
			error("NFKC(c2) mismatch: " .. id)
		end
		if unicode.normalise(c3, "NFKC") ~= c4 then
			error("NFKC(c3) mismatch: " .. id)
		end
		if unicode.normalise(c4, "NFKC") ~= c4 then
			error("NFKC(c4) mismatch: " .. id)
		end
		if unicode.normalise(c5, "NFKC") ~= c4 then
			error("NFKC(c5) mismatch: " .. id)
		end

		if unicode.normalise(c1, "NFKD") ~= c5 then
			error("NFKD(c1) mismatch: " .. id)
		end
		if unicode.normalise(c2, "NFKD") ~= c5 then
			error("NFKD(c2) mismatch: " .. id)
		end
		if unicode.normalise(c3, "NFKD") ~= c5 then
			error("NFKD(c3) mismatch: " .. id)
		end
		if unicode.normalise(c4, "NFKD") ~= c5 then
			error("NFKD(c4) mismatch: " .. id)
		end
		if unicode.normalise(c5, "NFKD") ~= c5 then
			error("NFKD(c5) mismatch: " .. id)
		end

		if not unicode.isNormalised(c2, "NFC") then
			error("isNormalised NFC(c2) mismatch: " .. id)
		end
		if not unicode.isNormalised(c3, "NFD") then
			error("isNormalised NFD(c3) mismatch: " .. id)
		end
		if not unicode.isNormalised(c4, "NFKC") then
			error("isNormalised NFKC(c4) mismatch: " .. id)
		end
		if not unicode.isNormalised(c5, "NFKD") then
			error("isNormalised NFKD(c5) mismatch: " .. id)
		end

		checked += 1
	end

	test.expect(checked):toBe(expected)
	test.expect(checked):toBeGreaterThan(200)
end)

return suite
