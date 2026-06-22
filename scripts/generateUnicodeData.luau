local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local http = require("@eryx/http")
local dawg = require("./dawg")

type UcdRow = { string }
type ExpandedUcd = { [number]: number | { string } }
type BinaryProperties = { [string]: boolean }
type DerivedNameRange = { [number]: string | number }
type AliasEntry = { [number]: string | number }
type NamedSequence = { [number]: string | { number } }
type BlockEntry = { [number]: number | string }
type SpecialCaseTriplet = { [number]: { number } }
type TypeRecord = { number }
type DataRecord = { number }
type NumericEntry = { value: string, cps: { number } }
type NumericPair = { codepoint: number, expression: string }
type NameEntry = { name: string, codepoint: number }
type UcdRecord = {
	codepoint: string,
	name: string,
	generalCategory: string,
	canonicalCombiningClass: string,
	bidiClass: string,
	decompositionType: string,
	decompositionMapping: string,
	numericType: string,
	numericValue: string,
	bidiMirrored: string,
	unicode1Name: string,
	isoComment: string,
	simpleUppercaseMapping: string,
	simpleLowercaseMapping: string,
	simpleTitlecaseMapping: string,
	eastAsianWidth: string?,
	binaryProperties: BinaryProperties,
	quickCheck: number,
	incb: string,
}
type UcdSource = {
	label: string,
	fetchUrl: ((string, boolean) -> (buffer | string)?)?,
	readText: (string) -> string?,
	readBinary: (string) -> buffer?,
	close: (() -> ())?,
}
type UnicodeData = {
	version: string,
	filename: string,
	table: { UcdRecord? },
	chars: { number },
	changed: { string },
	derivedNameRanges: { DerivedNameRange },
	derivedNamePrefixes: { [string]: number },
	derivedNamePrefixesList: { string },
	aliases: { AliasEntry },
	namedSequences: { NamedSequence },
	exclusions: { [number]: boolean },
	widths: { string? },
	bidiClasses: { string? },
	specialCasing: { [number]: SpecialCaseTriplet },
	caseFolding: { [number]: { number } },
	graphemeBreaks: { string? },
	extPicts: { boolean },
	blocks: { BlockEntry },
}

local UNIDATA_VERSION = "17.0.0"

local UNICODE_DATA = "UnicodeData%s.txt"
local COMPOSITION_EXCLUSIONS = "CompositionExclusions%s.txt"
local EASTASIAN_WIDTH = "EastAsianWidth%s.txt"
local UNIHAN = "Unihan%s.zip"
local DERIVED_BIDI_CLASS = "extracted/DerivedBidiClass%s.txt"
local DERIVED_CORE_PROPERTIES = "DerivedCoreProperties%s.txt"
local DERIVEDNORMALIZATION_PROPS = "DerivedNormalizationProps%s.txt"
local LINE_BREAK = "LineBreak%s.txt"
local NAME_ALIASES = "NameAliases%s.txt"
local NAMED_SEQUENCES = "NamedSequences%s.txt"
local SPECIAL_CASING = "SpecialCasing%s.txt"
local CASE_FOLDING = "CaseFolding%s.txt"
local GRAPHEME_CLUSTER_BREAK = "auxiliary/GraphemeBreakProperty%s.txt"
local EMOJI_DATA = "emoji/emoji-data%s.txt"
local BLOCKS = "Blocks%s.txt"

local NAME_ALIASES_START = 0xF0000
local NAMED_SEQUENCES_START = 0xF0200

local CATEGORY_NAMES = {
	"Cn",
	"Lu",
	"Ll",
	"Lt",
	"Mn",
	"Mc",
	"Me",
	"Nd",
	"Nl",
	"No",
	"Zs",
	"Zl",
	"Zp",
	"Cc",
	"Cf",
	"Cs",
	"Co",
	"Cn",
	"Lm",
	"Lo",
	"Pc",
	"Pd",
	"Ps",
	"Pe",
	"Pi",
	"Pf",
	"Po",
	"Sm",
	"Sc",
	"Sk",
	"So",
}

local BIDIRECTIONAL_NAMES = {
	"",
	"L",
	"LRE",
	"LRO",
	"R",
	"AL",
	"RLE",
	"RLO",
	"PDF",
	"EN",
	"ES",
	"ET",
	"AN",
	"CS",
	"NSM",
	"BN",
	"B",
	"S",
	"WS",
	"ON",
	"LRI",
	"RLI",
	"FSI",
	"PDI",
}

local BIDI_LONG_NAMES = {
	Left_To_Right = "L",
	Right_To_Left = "R",
	Arabic_Letter = "AL",
	European_Number = "EN",
	European_Separator = "ES",
	European_Terminator = "ET",
	Arabic_Number = "AN",
	Common_Separator = "CS",
	Nonspacing_Mark = "NSM",
	Boundary_Neutral = "BN",
	Paragraph_Separator = "B",
	Segment_Separator = "S",
	White_Space = "WS",
	Other_Neutral = "ON",
	Left_To_Right_Embedding = "LRE",
	Left_To_Right_Override = "LRO",
	Right_To_Left_Embedding = "RLE",
	Right_To_Left_Override = "RLO",
	Pop_Directional_Format = "PDF",
	Left_To_Right_Isolate = "LRI",
	Right_To_Left_Isolate = "RLI",
	First_Strong_Isolate = "FSI",
	Pop_Directional_Isolate = "PDI",
}

local GRAPHEME_CLUSTER_NAMES = {
	"Other",
	"Prepend",
	"CR",
	"LF",
	"Control",
	"Extend",
	"Regional_Indicator",
	"SpacingMark",
	"L",
	"V",
	"T",
	"LV",
	"LVT",
	"ZWJ",
}

local INDIC_CONJUNCT_BREAK_NAMES = { "None", "Linker", "Consonant", "Extend" }
local EASTASIANWIDTH_NAMES = { "N", "H", "W", "Na", "A", "F" }
local MANDATORY_LINE_BREAKS = { BK = true, CR = true, LF = true, NL = true }

local ALPHA_MASK = 0x01
local DECIMAL_MASK = 0x02
local DIGIT_MASK = 0x04
local LOWER_MASK = 0x08
local LINEBREAK_MASK = 0x10
local SPACE_MASK = 0x20
local TITLE_MASK = 0x40
local UPPER_MASK = 0x80
local XID_START_MASK = 0x100
local XID_CONTINUE_MASK = 0x200
local PRINTABLE_MASK = 0x400
local NUMERIC_MASK = 0x800
local CASE_IGNORABLE_MASK = 0x1000
local CASED_MASK = 0x2000
local EXTENDED_CASE_MASK = 0x4000

local derivedNameRangeName = {
	{ "Hangul Syllable", "HANGUL SYLLABLE " },
	{ "CJK Ideograph", "CJK UNIFIED IDEOGRAPH-" },
	{ "Tangut Ideograph", "TANGUT IDEOGRAPH-" },
}

local parser = argparse.Parser.new("generateUnicodeData")
parser:addPositional("ucd-dir", "string", nil, false, "Directory with UCD files (optional)")
parser:addOption(
	"ucd-zip-url",
	"u",
	"string",
	"https://www.unicode.org/Public/UCD/latest/ucd/UCD.zip",
	false,
	"UCD zip URL used when ucd-dir is omitted"
)
parser:addOption(
	"output-dir",
	"o",
	"string",
	"src/modules/unicode/_data",
	false,
	"Directory to write generated Luau modules"
)
parser:addOption("cpp-output-dir", nil, "string", nil, false, "Directory to write generated C++ Unicode data")
parser:addFlag("trace", "Enable splitbins trace logging")
parser:addFlag("with-unihan", "Enable Unihan numeric import (can be slow/heavy)")
local args = parser:parse()

local function trim(s: string): string
	return s:match("^%s*(.-)%s*$") :: string
end

local function splitChar(s: string, sep: string): { string }
	local out: { string } = {}
	local i = 1
	while true do
		local at = string.find(s, sep, i, true)
		if not at then
			table.insert(out, string.sub(s, i))
			break
		end
		table.insert(out, string.sub(s, i, at - 1))
		i = at + #sep
	end
	return out
end

local function expandRange(charRange: string): (number, number)
	local first, last = charRange:match("^([0-9A-Fa-f]+)%.%.([0-9A-Fa-f]+)$")
	if first then
		return tonumber(first, 16) :: number, tonumber(last, 16) :: number
	end
	local cp = tonumber(charRange, 16) :: number
	return cp, cp
end

local function requiredUcdField(row: UcdRow, index: number, context: string): string
	local value = row[index]
	if value == nil then
		error(string.format("Missing field %d while parsing %s", index, context))
	end
	return value
end

local function requiredStringField(row: { string }, index: number, context: string): string
	local value = row[index]
	if value == nil then
		error(string.format("Missing field %d while parsing %s", index, context))
	end
	return value
end

local function requiredIndexOf(list: { string }, value: string, context: string): number
	for i, item in list do
		if item == value then
			return i
		end
	end
	error(string.format("Unknown %s value: %s", context, value))
end

local function expandedCodepoint(expanded: ExpandedUcd, context: string): number
	local cp = expanded[1]
	if type(cp) ~= "number" then
		error("Invalid expanded codepoint in " .. context)
	end
	return cp
end

local function expandedFields(expanded: ExpandedUcd, context: string): { string }
	local rest = expanded[2]
	if type(rest) ~= "table" then
		error("Invalid expanded fields in " .. context)
	end
	return rest
end

local function parseHex(s: string, context: string): number
	local value = tonumber(s, 16)
	if value == nil then
		error("Invalid hex number in " .. context .. ": " .. s)
	end
	return value
end

local function parseDec(s: string, context: string): number
	local value = tonumber(s)
	if value == nil then
		error("Invalid decimal number in " .. context .. ": " .. s)
	end
	return value
end

local function indexOf(list: { string }, value: string): number?
	for i, item in list do
		if item == value then
			return i
		end
	end
	return nil
end

local function ensureParent(path: string)
	local parent = fs.path.dirname(path)
	if parent == "" or parent == "." then
		return
	end
	if fs.exists(parent) then
		return
	end
	ensureParent(parent)
	fs.mkdir(parent)
end

local function createLocalSource(root: string): UcdSource
	local base = fs.path.canonicalize(root)
	return {
		label = "dir:" .. base,
		fetchUrl = nil,
		readText = function(name): string?
			local path = fs.path.join(base, name)
			if not fs.exists(path) then
				return nil
			end
			return fs.openSync(path, "r"):readSync()
		end,
		readBinary = function(name): buffer?
			local path = fs.path.join(base, name)
			if not fs.exists(path) then
				return nil
			end
			return fs.openSync(path, "r"):readBufferSync()
		end,
	}
end

local function createZipSource(url: string): UcdSource
	local base: string = url:gsub("/UCD%.zip$", "")
	local textCache: { [string]: string } = {}
	local binCache: { [string]: buffer } = {}
	local function fetch(name: string, binary: boolean): (buffer | string)?
		local fileUrl = base .. "/" .. name
		local response = http.get(fileUrl, { decompress = false, maxRedirects = 10 })
		if response.status < 200 or response.status >= 300 then
			return nil
		end
		if binary then
			return buffer.fromstring(response.body)
		end
		return response.body
	end
	return {
		label = "http:" .. base,
		fetchUrl = fetch,
		readText = function(name): string?
			if textCache[name] ~= nil then
				return textCache[name]
			end
			local value = fetch(name, false) :: string?
			if value == nil then
				return nil
			end
			textCache[name] = value
			return value
		end,
		readBinary = function(name): buffer?
			if binCache[name] ~= nil then
				return binCache[name]
			end
			local value = fetch(name, true) :: buffer?
			if value == nil then
				return nil
			end
			binCache[name] = value
			return value
		end,
	}
end

local source: UcdSource
if args["ucd-dir"] then
	source = createLocalSource(args["ucd-dir"])
else
	source = createZipSource(args["ucd-zip-url"])
end
print("Using UCD source: " .. source.label)

local function openDataText(template: string, version: string): string
	local name = string.format(template, "")
	if version == "3.2.0" then
		name = string.format(template, "-" .. version)
	end
	local content = source.readText(name)
	if content == nil and source.fetchUrl then
		content = source.fetchUrl(name, false) :: string?
	end
	if content == nil then
		error("Missing required UCD text file: " .. name)
	end
	return content
end

local function openDataBinary(template: string, version: string): buffer
	local name = string.format(template, "")
	if version == "3.2.0" then
		name = string.format(template, "-" .. version)
	end
	local content = source.readBinary(name)
	if content == nil and source.fetchUrl then
		local fetched = source.fetchUrl(name, true)
		if type(fetched) == "string" then
			content = buffer.fromstring(fetched)
		else
			content = fetched
		end
	end
	if content == nil then
		error("Missing required UCD binary file: " .. name)
	end
	return content
end

local function parseUcdRecords(text: string): { UcdRow }
	local out: { UcdRow } = {}
	for rawLine in (text .. "\n"):gmatch("([^\n]*)\n") do
		local line = trim((rawLine:gsub("#.*$", "")))
		if line ~= "" then
			local fields = splitChar(line, ";")
			for i, field in fields do
				fields[i] = trim(field)
			end
			table.insert(out, fields)
		end
	end
	return out
end

local function ucdExpanded(text: string): { ExpandedUcd }
	local out: { ExpandedUcd } = {}
	for _, record in parseUcdRecords(text) do
		local first, last = expandRange(record[1])
		local rest: { string } = {}
		for i = 2, #record do
			table.insert(rest, record[i])
		end
		for cp = first, last do
			table.insert(out, { cp, rest })
		end
	end
	return out
end

local function newRecord(row: UcdRow): UcdRecord
	return {
		codepoint = requiredUcdField(row, 1, "UnicodeData"),
		name = requiredUcdField(row, 2, "UnicodeData"),
		generalCategory = requiredUcdField(row, 3, "UnicodeData"),
		canonicalCombiningClass = requiredUcdField(row, 4, "UnicodeData"),
		bidiClass = requiredUcdField(row, 5, "UnicodeData"),
		decompositionType = requiredUcdField(row, 6, "UnicodeData"),
		decompositionMapping = requiredUcdField(row, 7, "UnicodeData"),
		numericType = requiredUcdField(row, 8, "UnicodeData"),
		numericValue = requiredUcdField(row, 9, "UnicodeData"),
		bidiMirrored = requiredUcdField(row, 10, "UnicodeData"),
		unicode1Name = requiredUcdField(row, 11, "UnicodeData"),
		isoComment = requiredUcdField(row, 12, "UnicodeData"),
		simpleUppercaseMapping = requiredUcdField(row, 13, "UnicodeData"),
		simpleLowercaseMapping = requiredUcdField(row, 14, "UnicodeData"),
		simpleTitlecaseMapping = requiredUcdField(row, 15, "UnicodeData"),
		eastAsianWidth = nil,
		binaryProperties = {},
		quickCheck = 0,
		incb = "None",
	}
end

local function copyRecord15(rec: UcdRecord, codepoint: string): UcdRecord
	return newRecord({
		codepoint,
		rec.name,
		rec.generalCategory,
		rec.canonicalCombiningClass,
		rec.bidiClass,
		rec.decompositionType,
		rec.decompositionMapping,
		rec.numericType,
		rec.numericValue,
		rec.bidiMirrored,
		rec.unicode1Name,
		rec.isoComment,
		rec.simpleUppercaseMapping,
		rec.simpleLowercaseMapping,
		rec.simpleTitlecaseMapping,
	})
end

local function buildUnicodeData(version: string): UnicodeData
	local self: UnicodeData = {
		version = version,
		filename = string.format(UNICODE_DATA, ""),
		table = table.create(0x110000) :: { UcdRecord? },
		chars = {},
		changed = {},
		derivedNameRanges = {},
		derivedNamePrefixes = {},
		derivedNamePrefixesList = {},
		aliases = {},
		namedSequences = {},
		exclusions = {},
		widths = table.create(0x110000) :: { string? },
		bidiClasses = table.create(0x110000) :: { string? },
		specialCasing = {},
		caseFolding = {},
		graphemeBreaks = table.create(0x110000) :: { string? },
		extPicts = table.create(0x110000, false) :: { boolean },
		blocks = {},
	}

	for i = 0, 0x10FFFF do
		self.chars[i + 1] = i
	end

	for i, entry in derivedNameRangeName do
		self.derivedNamePrefixes[entry[2]] = i
		self.derivedNamePrefixesList[i] = entry[2]
	end

	for _, row in parseUcdRecords(openDataText(UNICODE_DATA, version)) do
		local cp = parseHex(requiredUcdField(row, 1, "UnicodeData"), "UnicodeData")
		self.table[cp + 1] = newRecord(row)
	end

	local field: UcdRecord? = nil
	for i = 0, 0x10FFFF do
		local rec = self.table[i + 1]
		if rec then
			if string.sub(rec.name, -6) == "First>" then
				rec.name = ""
				field = rec
			elseif string.sub(rec.name, -5) == "Last>" then
				if field == nil then
					error("Encountered Last> marker without matching First>")
				end
				for j, rn in derivedNameRangeName do
					if string.sub(rec.name, 1, #rn[1] + 1) == "<" .. rn[1] then
						table.insert(self.derivedNameRanges, { field.codepoint, rec.codepoint, j - 1 })
						break
					end
				end
				rec.name = ""
				field = nil
			else
				local codepoint = rec.codepoint
				if string.sub(rec.name, -#codepoint) == codepoint then
					local prefix = string.sub(rec.name, 1, #rec.name - #codepoint)
					local j = self.derivedNamePrefixes[prefix]
					if j == nil then
						j = #self.derivedNamePrefixesList + 1
						self.derivedNamePrefixes[prefix] = j
						self.derivedNamePrefixesList[j] = prefix
					end
					local last = self.derivedNameRanges[#self.derivedNameRanges]
					local lastKind = if last then last[3] else nil
					local lastEnd = if last then last[2] else nil
					if
						last
						and type(lastKind) == "number"
						and lastKind == (j - 1)
						and type(lastEnd) == "string"
						and parseHex(lastEnd, "derived name range") == i - 1
					then
						last[2] = codepoint
					else
						table.insert(self.derivedNameRanges, { codepoint, codepoint, j - 1 })
					end
					rec.name = ""
				end
			end
		elseif field then
			self.table[i + 1] = copyRecord15(field, string.format("%04X", i))
		end
	end

	for _, row in parseUcdRecords(openDataText(NAME_ALIASES, version)) do
		local cp = parseHex(requiredUcdField(row, 1, "NameAliases"), "NameAliases")
		local name = requiredUcdField(row, 2, "NameAliases")
		table.insert(self.aliases, { name, cp })
		local puaIndex = NAME_ALIASES_START + #self.aliases - 1
		local aliasRec = self.table[puaIndex + 1]
		if aliasRec == nil then
			error(string.format("Missing alias PUA slot U+%X", puaIndex))
		end
		aliasRec.name = name
	end

	for _, row in parseUcdRecords(openDataText(NAMED_SEQUENCES, version)) do
		local name = requiredUcdField(row, 1, "NamedSequences")
		local chars: { number } = {}
		for token in requiredUcdField(row, 2, "NamedSequences"):gmatch("%S+") do
			table.insert(chars, parseHex(token, "NamedSequences"))
		end
		table.insert(self.namedSequences, { name, chars })
		local puaIndex = NAMED_SEQUENCES_START + #self.namedSequences - 1
		local seqRec = self.table[puaIndex + 1]
		if seqRec == nil then
			error(string.format("Missing sequence PUA slot U+%X", puaIndex))
		end
		seqRec.name = name
	end

	for _, row in parseUcdRecords(openDataText(COMPOSITION_EXCLUSIONS, version)) do
		local cp = parseHex(requiredUcdField(row, 1, "CompositionExclusions"), "CompositionExclusions")
		self.exclusions[cp] = true
	end

	for _, expanded in ucdExpanded(openDataText(EASTASIAN_WIDTH, version)) do
		local cp = expandedCodepoint(expanded, "EastAsianWidth")
		self.widths[cp + 1] = requiredStringField(expandedFields(expanded, "EastAsianWidth"), 1, "EastAsianWidth")
	end
	for i = 0, 0x10FFFF do
		local rec = self.table[i + 1]
		if rec then
			rec.eastAsianWidth = self.widths[i + 1]
		end
	end

	for i = 0, 0x10FFFF do
		local rec = self.table[i + 1]
		if rec then
			self.bidiClasses[i + 1] = rec.bidiClass
		end
	end

	do
		local text = openDataText(DERIVED_BIDI_CLASS, version)
		for rawLine in (text .. "\n"):gmatch("([^\n]*)\n") do
			local range, longName = rawLine:match("^# @missing: ([%dA-F]+%.%.[%dA-F]+); (%w+)")
			if range and BIDI_LONG_NAMES[longName] then
				local first, last = expandRange(range)
				local short = BIDI_LONG_NAMES[longName]
				for cp = first, last do
					self.bidiClasses[cp + 1] = short
				end
			end
		end
	end
	for _, expanded in ucdExpanded(openDataText(DERIVED_BIDI_CLASS, version)) do
		local cp = expandedCodepoint(expanded, "DerivedBidiClass")
		self.bidiClasses[cp + 1] =
			requiredStringField(expandedFields(expanded, "DerivedBidiClass"), 1, "DerivedBidiClass")
	end

	for _, expanded in ucdExpanded(openDataText(DERIVED_CORE_PROPERTIES, version)) do
		local cp = expandedCodepoint(expanded, "DerivedCoreProperties")
		local fields = expandedFields(expanded, "DerivedCoreProperties")
		local propname = requiredStringField(fields, 1, "DerivedCoreProperties")
		local propinfo = fields[2]
		local rec = self.table[cp + 1]
		if rec then
			if propinfo == nil then
				rec.binaryProperties[propname] = true
			elseif propname == "InCB" then
				rec.incb = propinfo
			end
		end
	end

	for _, row in parseUcdRecords(openDataText(LINE_BREAK, version)) do
		local value = row[2]
		if MANDATORY_LINE_BREAKS[value] then
			local first, last = expandRange(row[1])
			for cp = first, last do
				local rec = self.table[cp + 1]
				if rec then
					rec.binaryProperties.Line_Break = true
				end
			end
		end
	end

	local quickchecks = table.create(0x110000, 0)
	local qcOrder: { [string]: number } = { NFD_QC = 0, NFKD_QC = 1, NFC_QC = 2, NFKC_QC = 3 }
	for _, row in parseUcdRecords(openDataText(DERIVEDNORMALIZATION_PROPS, version)) do
		local kind = requiredUcdField(row, 2, "DerivedNormalizationProps")
		local status = row[3]
		if status == nil then
			continue
		end
		local qci = qcOrder[kind]
		if qci ~= nil and (status == "M" or status == "N") then
			local quick = (if status == "M" then 1 else 2)
			local shift = qci * 2
			local first, last = expandRange(requiredUcdField(row, 1, "DerivedNormalizationProps"))
			for cp = first, last do
				local old = quickchecks[cp + 1]
				quickchecks[cp + 1] = old + bit32.lshift(quick, shift)
			end
		end
	end
	for i = 0, 0x10FFFF do
		local rec = self.table[i + 1]
		if rec then
			rec.quickCheck = quickchecks[i + 1]
		end
	end

	if args["with-unihan"] then
		local ok, err = pcall(function()
			local zip = require("@eryx/compression/zip")
			local unihanZipBuf = openDataBinary(UNIHAN, version)
			local unihanZip = zip.open(unihanZipBuf)
			local target = "Unihan_NumericValues.txt"
			local raw = unihanZip:read(target)
			if raw == nil then
				target = "Unihan-3.2.0.txt"
				raw = unihanZip:read(target)
			end
			if raw ~= nil then
				local text = buffer.tostring(raw)
				for line in (text .. "\n"):gmatch("([^\n]*)\n") do
					if string.sub(line, 1, 2) == "U+" then
						local code, tag, value = line:match("^(U%+[%x]+)%s+(%S+)%s+(%S+)")
						if
							code and (tag == "kAccountingNumeric" or tag == "kPrimaryNumeric" or tag == "kOtherNumeric")
						then
							local cp = parseHex(string.sub(code, 3), "Unihan")
							local rec = self.table[cp + 1]
							if rec and value then
								rec.numericValue = value:gsub(",", "")
							end
						end
					end
				end
			end
			unihanZip:close()
		end)
		if not ok then
			print("warning: failed to read Unihan numeric values: " .. tostring(err))
		end
	end

	for _, row in parseUcdRecords(openDataText(SPECIAL_CASING, version)) do
		if requiredUcdField(row, 5, "SpecialCasing") == "" then
			local cp = parseHex(requiredUcdField(row, 1, "SpecialCasing"), "SpecialCasing")
			local lower: { number } = {}
			local title: { number } = {}
			local upper: { number } = {}
			for tok in requiredUcdField(row, 2, "SpecialCasing"):gmatch("%S+") do
				table.insert(lower, parseHex(tok, "SpecialCasing"))
			end
			for tok in requiredUcdField(row, 3, "SpecialCasing"):gmatch("%S+") do
				table.insert(title, parseHex(tok, "SpecialCasing"))
			end
			for tok in requiredUcdField(row, 4, "SpecialCasing"):gmatch("%S+") do
				table.insert(upper, parseHex(tok, "SpecialCasing"))
			end
			self.specialCasing[cp] = { lower, title, upper }
		end
	end

	for _, row in parseUcdRecords(openDataText(CASE_FOLDING, version)) do
		local status = requiredUcdField(row, 2, "CaseFolding")
		if status == "C" or status == "F" then
			local cp = parseHex(requiredUcdField(row, 1, "CaseFolding"), "CaseFolding")
			local chars: { number } = {}
			for tok in requiredUcdField(row, 3, "CaseFolding"):gmatch("%S+") do
				table.insert(chars, parseHex(tok, "CaseFolding"))
			end
			self.caseFolding[cp] = chars
		end
	end

	for _, expanded in ucdExpanded(openDataText(GRAPHEME_CLUSTER_BREAK, version)) do
		local cp = expandedCodepoint(expanded, "GraphemeBreakProperty")
		self.graphemeBreaks[cp + 1] =
			requiredStringField(expandedFields(expanded, "GraphemeBreakProperty"), 1, "GraphemeBreakProperty")
	end
	for _, expanded in ucdExpanded(openDataText(EMOJI_DATA, version)) do
		local cp = expandedCodepoint(expanded, "emoji-data")
		if requiredStringField(expandedFields(expanded, "emoji-data"), 1, "emoji-data") == "Extended_Pictographic" then
			self.extPicts[cp + 1] = true
		end
	end
	for _, row in parseUcdRecords(openDataText(BLOCKS, version)) do
		local first, last = expandRange(requiredUcdField(row, 1, "Blocks"))
		table.insert(self.blocks, { first, last, requiredUcdField(row, 2, "Blocks") })
	end
	table.sort(self.blocks, function(a: BlockEntry, b: BlockEntry)
		local af = a[1]
		local bf = b[1]
		if type(af) ~= "number" or type(bf) ~= "number" then
			error("Invalid block range while sorting")
		end
		return af < bf
	end)

	return self
end

local function getsize(data: { number }): number
	local maxdata = 0
	for _, v in data do
		if v > maxdata then
			maxdata = v
		end
	end
	if maxdata < 256 then
		return 1
	elseif maxdata < 65536 then
		return 2
	end
	return 4
end

local function splitbins(t: { number }, trace: boolean): ({ number }, { number }, number)
	local function dump(t1: { number }, t2: { number }, shift: number, bytes: number)
		print(string.format("%d+%d bins at shift %d; %d bytes", #t1, #t2, shift, bytes))
	end

	if trace then
		print("Size of original table: " .. (#t * getsize(t)) .. " bytes")
	end

	local n = #t - 1
	local maxshift = 0
	while n > 1 do
		n = bit32.rshift(n, 1)
		maxshift += 1
	end

	local bestT1: { number } = {}
	local bestT2: { number } = {}
	local bestShift = 0
	local bestBytes = math.huge
	for shift = 0, maxshift do
		local t1: { number } = {}
		local t2: { number } = {}
		local size = 2 ^ shift
		local bincache: { [string]: number } = {}
		for i = 1, #t, size do
			local chunk: { number } = {}
			for j = i, math.min(i + size - 1, #t) do
				table.insert(chunk, t[j])
			end
			local key = table.concat(chunk, ",")
			local index = bincache[key]
			if index == nil then
				index = #t2
				bincache[key] = index
				for _, v in chunk do
					table.insert(t2, v)
				end
			end
			table.insert(t1, bit32.rshift(index, shift))
		end
		local bytes = #t1 * getsize(t1) + #t2 * getsize(t2)
		if trace then
			dump(t1, t2, shift, bytes)
		end
		if bytes < bestBytes then
			bestT1, bestT2, bestShift = t1, t2, shift
			bestBytes = bytes
		end
	end
	return bestT1, bestT2, bestShift
end

local function _arrayToLuau(name: string, data: { number | string }): string
	local lines = { "local " .. name .. " = {" }
	local s = "  "
	for _, item in data do
		local part = tostring(item) .. ","
		if #s + #part > 110 then
			table.insert(lines, s)
			s = "  " .. part
		else
			s = s .. part
		end
	end
	if #trim(s) > 0 then
		table.insert(lines, s)
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

local function openWriter(path: string): (string) -> ()
	ensureParent(path)
	local file = fs.openSync(path, "w")
	local function w(line: string)
		file:writeSync(line .. "\n")
	end
	return w
end

local function writeArrayStream(w: (string) -> (), name: string, data: { number }, attachToData: boolean)
	w("local " .. name .. "={")
	local s = ""
	local parts: { string } = {}
	for _, item in data do
		table.insert(parts, tostring(item))
	end
	w(table.concat(parts, ","))
	if #trim(s) > 0 then
		w(s)
	end
	w("}")
	if attachToData then
		w("data." .. name .. "=" .. name)
	end
end

local function cppIntegerType(data: { number }): string
	local minValue = 0
	local maxValue = 0
	for _, value in data do
		minValue = math.min(minValue, value)
		maxValue = math.max(maxValue, value)
	end

	if minValue < 0 then
		if minValue >= -0x8000 and maxValue <= 0x7FFF then
			return "std::int16_t"
		end
		return "std::int32_t"
	end
	if maxValue <= 0xFF then
		return "std::uint8_t"
	elseif maxValue <= 0xFFFF then
		return "std::uint16_t"
	end
	return "std::uint32_t"
end

local function writeCppArray(w: (string) -> (), ctype: string, name: string, values: { number })
	w("constexpr " .. ctype .. " " .. name .. "[] = {")
	local line = "    "
	for _, value in values do
		local part = tostring(value) .. ","
		if #line + #part + 1 > 110 then
			w(line)
			line = "    " .. part
		else
			line ..= part
		end
	end
	if #trim(line) > 0 then
		w(line)
	end
	w("};")
	w("")
end

local function writeCppUnicodeData(
	outdir: string,
	version: string,
	shift: number,
	recordTable: { DataRecord },
	index1: { number },
	index2: { number },
	decompShift: number,
	decompData: { number },
	decompIndex1: { number },
	decompIndex2: { number },
	compShift: number,
	compIndex: { number },
	compData: { number },
	compFirstRanges: { { number } },
	compLastRanges: { { number } },
	totalLast: number
)
	local namespace = "eryx::unicode::data"
	local headerPath = fs.path.join(outdir, "unicode_data.hpp")
	local sourcePath = fs.path.join(outdir, "unicode_data.cpp")
	print("Writing " .. headerPath)
	local h = openWriter(headerPath)
	h("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	h("#pragma once")
	h("")
	h("#include <cstdint>")
	h("")
	h("namespace " .. namespace)
	h("{")
	h("")
	h("struct Record")
	h("{")
	h("    std::uint8_t category;")
	h("    std::uint8_t combiningClass;")
	h("    std::uint8_t bidirectional;")
	h("    std::uint8_t mirrored;")
	h("    std::uint8_t eastAsianWidth;")
	h("    std::uint8_t quickCheck;")
	h("    std::uint8_t graphemeBreak;")
	h("    std::uint8_t indicConjunctBreak;")
	h("    std::uint8_t extendedPictographic;")
	h("};")
	h("")
	h("inline constexpr const char* Version = " .. string.format("%q", version) .. ";")
	h("const Record& recordFor(std::uint32_t codepoint);")
	h(
		"bool decompositionFor(std::uint32_t codepoint, bool compatibility, const std::uint32_t*& values, std::uint8_t& count);"
	)
	h("std::uint32_t composePair(std::uint32_t first, std::uint32_t last);")
	h("")
	h("} // namespace " .. namespace)

	print("Writing " .. sourcePath)
	local w = openWriter(sourcePath)
	w("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	w('#include "unicode_data.hpp"')
	w("")
	w("#include <cstddef>")
	w("#include <iterator>")
	w("")
	w("namespace " .. namespace)
	w("{")
	w("namespace")
	w("{")
	w("")
	w("constexpr std::uint32_t Shift = " .. shift .. ";")
	w("constexpr std::uint32_t Mask = (1u << Shift) - 1u;")
	w("")
	w("constexpr Record Records[] = {")
	for _, item in recordTable do
		w(
			string.format(
				"    {%d,%d,%d,%d,%d,%d,%d,%d,%d},",
				item[1],
				item[2],
				item[3],
				item[4],
				item[5],
				item[6],
				item[7],
				item[8],
				item[9]
			)
		)
	end
	w("};")
	w("")
	writeCppArray(w, cppIntegerType(index1), "Index1", index1)
	writeCppArray(w, cppIntegerType(index2), "Index2", index2)
	w("constexpr std::uint32_t DecompShift = " .. decompShift .. ";")
	w("constexpr std::uint32_t DecompMask = (1u << DecompShift) - 1u;")
	writeCppArray(w, cppIntegerType(decompData), "DecompData", decompData)
	writeCppArray(w, cppIntegerType(decompIndex1), "DecompIndex1", decompIndex1)
	writeCppArray(w, cppIntegerType(decompIndex2), "DecompIndex2", decompIndex2)
	w("struct CompositionRange { std::uint32_t first; std::uint32_t last; std::uint16_t index; };")
	w("constexpr CompositionRange CompositionFirst[] = {")
	for _, range in compFirstRanges do
		w(string.format("    {%d,%d,%d},", range[1], range[2], range[3]))
	end
	w("};")
	w("constexpr CompositionRange CompositionLast[] = {")
	for _, range in compLastRanges do
		w(string.format("    {%d,%d,%d},", range[1], range[2], range[3]))
	end
	w("};")
	w("constexpr std::uint32_t CompositionShift = " .. compShift .. ";")
	w("constexpr std::uint32_t CompositionMask = (1u << CompositionShift) - 1u;")
	w("constexpr std::uint32_t CompositionLastCount = " .. totalLast .. ";")
	writeCppArray(w, cppIntegerType(compIndex), "CompositionIndex", compIndex)
	writeCppArray(w, cppIntegerType(compData), "CompositionData", compData)
	w("} // namespace")
	w("")
	w("const Record& recordFor(std::uint32_t codepoint)")
	w("{")
	w("    if (codepoint > 0x10ffff)")
	w("        return Records[0];")
	w("")
	w("    const std::uint32_t block = Index1[codepoint >> Shift];")
	w("    const std::uint32_t record = Index2[(block << Shift) + (codepoint & Mask)];")
	w("    return Records[record == 0 ? 0 : record - 1];")
	w("}")
	w("")
	w(
		"bool decompositionFor(std::uint32_t codepoint, bool compatibility, const std::uint32_t*& values, std::uint8_t& count)"
	)
	w("{")
	w("    if (codepoint > 0x10ffff)")
	w("        return false;")
	w("    const std::uint32_t block = DecompIndex1[codepoint >> DecompShift];")
	w("    const std::uint32_t offset = DecompIndex2[(block << DecompShift) + (codepoint & DecompMask)];")
	w("    if (offset == 0)")
	w("        return false;")
	w("    const std::uint32_t header = DecompData[offset];")
	w("    if (!compatibility && (header & 0xffu) != 0)")
	w("        return false;")
	w("    count = static_cast<std::uint8_t>(header >> 8);")
	w("    values = DecompData + offset + 1;")
	w("    return count != 0;")
	w("}")
	w("")
	w("std::uint32_t compositionIndex(const CompositionRange* ranges, std::size_t count, std::uint32_t codepoint)")
	w("{")
	w("    std::size_t low = 0;")
	w("    std::size_t high = count;")
	w("    while (low < high)")
	w("    {")
	w("        const std::size_t middle = low + (high - low) / 2;")
	w("        const CompositionRange& range = ranges[middle];")
	w("        if (codepoint < range.first)")
	w("            high = middle;")
	w("        else if (codepoint > range.last)")
	w("            low = middle + 1;")
	w("        else")
	w("            return range.index + codepoint - range.first;")
	w("    }")
	w("    return UINT32_MAX;")
	w("}")
	w("")
	w("std::uint32_t composePair(std::uint32_t first, std::uint32_t last)")
	w("{")
	w("    const std::uint32_t firstIndex = compositionIndex(CompositionFirst, std::size(CompositionFirst), first);")
	w("    const std::uint32_t lastIndex = compositionIndex(CompositionLast, std::size(CompositionLast), last);")
	w("    if (firstIndex == UINT32_MAX || lastIndex == UINT32_MAX)")
	w("        return 0;")
	w("    const std::uint32_t logical = firstIndex * CompositionLastCount + lastIndex;")
	w("    const std::uint32_t block = CompositionIndex[logical >> CompositionShift];")
	w("    return CompositionData[(block << CompositionShift) + (logical & CompositionMask)];")
	w("}")
	w("")
	w("} // namespace " .. namespace)
end

local function writeCppUnicodeType(
	outdir: string,
	shift: number,
	records: { TypeRecord },
	extendedCase: { number },
	index1: { number },
	index2: { number },
	numericEntries: { NumericEntry }
)
	local namespace = "eryx::unicode::type"
	local headerPath = fs.path.join(outdir, "unicode_type.hpp")
	local sourcePath = fs.path.join(outdir, "unicode_type.cpp")
	print("Writing " .. headerPath)
	local h = openWriter(headerPath)
	h("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	h("#pragma once")
	h("")
	h("#include <cstdint>")
	h("")
	h("namespace " .. namespace)
	h("{")
	h("enum class CaseMapping : std::uint8_t { Upper, Lower, Title, Fold };")
	h("std::uint8_t mapCase(std::uint32_t codepoint, CaseMapping mapping, std::uint32_t output[3]);")
	h("bool numericValue(std::uint32_t codepoint, double& value);")
	h("} // namespace " .. namespace)

	print("Writing " .. sourcePath)
	local w = openWriter(sourcePath)
	w("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	w('#include "unicode_type.hpp"')
	w("")
	w("#include <algorithm>")
	w("#include <cstddef>")
	w("#include <iterator>")
	w("")
	w("namespace " .. namespace)
	w("{")
	w("namespace")
	w("{")
	w("constexpr std::uint32_t Shift = " .. shift .. ";")
	w("constexpr std::uint32_t Mask = (1u << Shift) - 1u;")
	w("constexpr std::uint32_t ExtendedCaseMask = 0x4000;")
	w("struct TypeRecord { std::int32_t upper; std::int32_t lower; std::int32_t title; std::uint16_t flags; };")
	w("constexpr TypeRecord Records[] = {")
	for _, item in records do
		w(string.format("    {%d,%d,%d,%d},", item[1], item[2], item[3], item[6]))
	end
	w("};")
	writeCppArray(w, cppIntegerType(extendedCase), "ExtendedCase", extendedCase)
	writeCppArray(w, cppIntegerType(index1), "Index1", index1)
	writeCppArray(w, cppIntegerType(index2), "Index2", index2)
	w("struct NumericEntry { std::uint32_t codepoint; double value; };")
	w("constexpr NumericEntry Numeric[] = {")
	local numericPairs: { NumericPair } = {}
	for _, entry in numericEntries do
		local numerator, denominator = entry.value:match("^(-?%d+)/(%d+)$")
		local expression = if numerator and denominator
			then string.format("double(%s) / double(%s)", numerator, denominator)
			else entry.value
		for _, codepoint in entry.cps do
			table.insert(numericPairs, { codepoint = codepoint, expression = expression })
		end
	end
	table.sort(numericPairs, function(a: NumericPair, b: NumericPair)
		return a.codepoint < b.codepoint
	end)
	for _, pair in numericPairs do
		w(string.format("    {%d,%s},", pair.codepoint, pair.expression))
	end
	w("};")
	w("")
	w("const TypeRecord& recordFor(std::uint32_t codepoint)")
	w("{")
	w("    if (codepoint > 0x10ffff)")
	w("        return Records[0];")
	w("    const std::uint32_t block = Index1[codepoint >> Shift];")
	w("    const std::uint32_t record = Index2[(block << Shift) + (codepoint & Mask)];")
	w("    return Records[record == 0 ? 0 : record - 1];")
	w("}")
	w("} // namespace")
	w("")
	w("std::uint8_t mapCase(std::uint32_t codepoint, CaseMapping mapping, std::uint32_t output[3])")
	w("{")
	w("    const TypeRecord& record = recordFor(codepoint);")
	w("    std::int32_t field = mapping == CaseMapping::Upper ? record.upper")
	w("        : mapping == CaseMapping::Title ? record.title : record.lower;")
	w("    if ((record.flags & ExtendedCaseMask) != 0)")
	w("    {")
	w("        const std::uint32_t index = std::uint32_t(field) & 0xfffff;")
	w("        std::uint32_t count = std::uint32_t(field) >> 24;")
	w("        std::uint32_t offset = index;")
	w("        if (mapping == CaseMapping::Fold)")
	w("        {")
	w("            const std::uint32_t foldCount = (std::uint32_t(field) >> 20) & 0xf;")
	w("            if (foldCount != 0)")
	w("            {")
	w("                offset += count;")
	w("                count = foldCount;")
	w("            }")
	w("        }")
	w("        for (std::uint32_t i = 0; i < count; ++i)")
	w("            output[i] = ExtendedCase[offset + i];")
	w("        return static_cast<std::uint8_t>(count);")
	w("    }")
	w("    output[0] = field == 0 ? codepoint : std::uint32_t(std::int64_t(codepoint) + field);")
	w("    return 1;")
	w("}")
	w("")
	w("bool numericValue(std::uint32_t codepoint, double& value)")
	w("{")
	w("    const auto found = std::lower_bound(std::begin(Numeric), std::end(Numeric), codepoint,")
	w("        [](const NumericEntry& entry, std::uint32_t target) { return entry.codepoint < target; });")
	w("    if (found == std::end(Numeric) || found->codepoint != codepoint)")
	w("        return false;")
	w("    value = found->value;")
	w("    return true;")
	w("}")
	w("} // namespace " .. namespace)
end

local function writeCppUnicodeName(
	outdir: string,
	packedDawg: { number },
	posToCodepoint: { number },
	shift: number,
	index1: { number },
	index2: { number },
	notfound: number,
	aliases: { AliasEntry },
	namedSequences: { NamedSequence },
	derivedRanges: { DerivedNameRange },
	derivedPrefixes: { string }
)
	local namespace = "eryx::unicode::name"
	local headerPath = fs.path.join(outdir, "unicode_name.hpp")
	local sourcePath = fs.path.join(outdir, "unicode_name.cpp")
	print("Writing " .. headerPath)
	local h = openWriter(headerPath)
	h("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	h("#pragma once")
	h("")
	h("#include <cstdint>")
	h("#include <string>")
	h("#include <string_view>")
	h("#include <vector>")
	h("")
	h("namespace " .. namespace)
	h("{")
	h("bool codepointsFromName(std::string_view value, std::vector<std::uint32_t>& output);")
	h("bool nameFor(std::uint32_t codepoint, std::string& output);")
	h("} // namespace " .. namespace)

	print("Writing " .. sourcePath)
	local w = openWriter(sourcePath)
	w("// Auto-generated by scripts/generateUnicodeData.luau. Do not edit.")
	w('#include "unicode_name.hpp"')
	w("")
	w("#include <cstdio>")
	w("#include <iterator>")
	w("")
	w("namespace " .. namespace)
	w("{")
	w("namespace")
	w("{")
	w("constexpr std::uint32_t Shift = " .. shift .. ";")
	w("constexpr std::uint32_t Mask = (1u << Shift) - 1u;")
	w("constexpr std::uint32_t NotFound = " .. notfound .. ";")
	writeCppArray(w, cppIntegerType(packedDawg), "PackedDawg", packedDawg)
	writeCppArray(w, cppIntegerType(posToCodepoint), "PositionToCodepoint", posToCodepoint)
	writeCppArray(w, cppIntegerType(index1), "CodepointIndex1", index1)
	writeCppArray(w, cppIntegerType(index2), "CodepointIndex2", index2)
	local aliasCodepoints: { number } = {}
	for _, alias in aliases do
		table.insert(aliasCodepoints, alias[2] :: number)
	end
	writeCppArray(w, cppIntegerType(aliasCodepoints), "Aliases", aliasCodepoints)
	local sequenceOffsets = { 0 }
	local sequenceCodepoints: { number } = {}
	for _, sequence in namedSequences do
		for _, codepoint in sequence[2] :: { number } do
			table.insert(sequenceCodepoints, codepoint)
		end
		table.insert(sequenceOffsets, #sequenceCodepoints)
	end
	writeCppArray(w, cppIntegerType(sequenceOffsets), "SequenceOffsets", sequenceOffsets)
	writeCppArray(w, cppIntegerType(sequenceCodepoints), "SequenceCodepoints", sequenceCodepoints)
	w("struct DerivedRange { std::uint32_t first; std::uint32_t last; std::uint8_t prefix; };")
	w("constexpr DerivedRange DerivedRanges[] = {")
	for _, range in derivedRanges do
		local first = range[1] :: string
		local last = range[2] :: string
		local prefix = range[3] :: number
		w(string.format("    {0x%s,0x%s,%d},", first, last, prefix))
	end
	w("};")
	w("constexpr const char* DerivedPrefixes[] = {")
	for _, prefix in derivedPrefixes do
		w("    " .. string.format("%q", prefix) .. ",")
	end
	w("};")
	w("std::uint32_t decodeVarint(std::size_t& offset)")
	w("{")
	w("    std::uint32_t result = 0;")
	w("    std::uint32_t shift = 0;")
	w("    while (true)")
	w("    {")
	w("        const std::uint8_t byte = PackedDawg[offset++];")
	w("        result |= std::uint32_t(byte & 0x7f) << shift;")
	w("        if ((byte & 0x80) == 0)")
	w("            return result;")
	w("        shift += 7;")
	w("    }")
	w("}")
	w("void decodeNode(std::size_t node, std::uint32_t& descendants, bool& final, std::size_t& edges)")
	w("{")
	w("    edges = node;")
	w("    const std::uint32_t value = decodeVarint(edges);")
	w("    descendants = value >> 1;")
	w("    final = (value & 1) != 0;")
	w("}")
	w("void decodeEdge(std::size_t edgeIndex, std::size_t previousChild, std::size_t& edgeOffset,")
	w("    std::size_t& child, bool& last, std::size_t& label, std::size_t& length)")
	w("{")
	w("    const std::uint32_t value = decodeVarint(edgeOffset);")
	w("    child = previousChild + (value >> 2);")
	w("    last = (value & 1) != 0;")
	w("    length = 1;")
	w("    label = edgeOffset;")
	w("    if ((value & 2) == 0)")
	w("    {")
	w("        length = decodeVarint(label);")
	w("        edgeOffset = label;")
	w("    }")
	w("}")
	w("bool lookup(std::string_view value, std::uint32_t& position)")
	w("{")
	w("    std::size_t stringOffset = 0;")
	w("    std::size_t node = 0;")
	w("    std::uint32_t skipped = 0;")
	w("    while (stringOffset < value.size())")
	w("    {")
	w("        std::uint32_t descendants = 0;")
	w("        bool final = false;")
	w("        std::size_t edgeOffset = 0;")
	w("        decodeNode(node, descendants, final, edgeOffset);")
	w("        std::size_t previousChild = edgeOffset;")
	w("        bool matched = false;")
	w("        for (std::size_t edgeIndex = 0;; ++edgeIndex)")
	w("        {")
	w("            std::size_t child = 0;")
	w("            bool last = false;")
	w("            std::size_t label = 0;")
	w("            std::size_t length = 0;")
	w("            decodeEdge(edgeIndex, previousChild, edgeOffset, child, last, label, length);")
	w("            previousChild = child;")
	w("            if (stringOffset + length <= value.size() &&")
	w("                std::string_view(reinterpret_cast<const char*>(PackedDawg + label), length) ==")
	w("                    value.substr(stringOffset, length))")
	w("            {")
	w("                if (final)")
	w("                    ++skipped;")
	w("                stringOffset += length;")
	w("                node = child;")
	w("                matched = true;")
	w("                break;")
	w("            }")
	w("            if (last)")
	w("                break;")
	w("            std::uint32_t childDescendants = 0;")
	w("            bool childFinal = false;")
	w("            std::size_t childEdges = 0;")
	w("            decodeNode(child, childDescendants, childFinal, childEdges);")
	w("            skipped += childDescendants;")
	w("            edgeOffset = label + length;")
	w("        }")
	w("        if (!matched)")
	w("            return false;")
	w("    }")
	w("    std::uint32_t descendants = 0;")
	w("    bool final = false;")
	w("    std::size_t edges = 0;")
	w("    decodeNode(node, descendants, final, edges);")
	w("    position = skipped;")
	w("    return final;")
	w("}")
	w("bool inverseLookup(std::uint32_t position, std::string& output)")
	w("{")
	w("    std::size_t node = 0;")
	w("    while (true)")
	w("    {")
	w("        std::uint32_t descendants = 0;")
	w("        bool final = false;")
	w("        std::size_t edgeOffset = 0;")
	w("        decodeNode(node, descendants, final, edgeOffset);")
	w("        if (final)")
	w("        {")
	w("            if (position == 0)")
	w("                return true;")
	w("            --position;")
	w("        }")
	w("        std::size_t previousChild = edgeOffset;")
	w("        for (std::size_t edgeIndex = 0;; ++edgeIndex)")
	w("        {")
	w("            std::size_t child = 0;")
	w("            bool last = false;")
	w("            std::size_t label = 0;")
	w("            std::size_t length = 0;")
	w("            decodeEdge(edgeIndex, previousChild, edgeOffset, child, last, label, length);")
	w("            previousChild = child;")
	w("            std::uint32_t childDescendants = 0;")
	w("            bool childFinal = false;")
	w("            std::size_t childEdges = 0;")
	w("            decodeNode(child, childDescendants, childFinal, childEdges);")
	w("            if (position < childDescendants)")
	w("            {")
	w("                output.append(reinterpret_cast<const char*>(PackedDawg + label), length);")
	w("                node = child;")
	w("                break;")
	w("            }")
	w("            position -= childDescendants;")
	w("            if (last)")
	w("                return false;")
	w("            edgeOffset = label + length;")
	w("        }")
	w("    }")
	w("}")
	w("} // namespace")
	w("")
	w("bool codepointsFromName(std::string_view value, std::vector<std::uint32_t>& output)")
	w("{")
	w("    std::uint32_t position = 0;")
	w("    if (!lookup(value, position) || position >= std::size(PositionToCodepoint))")
	w("        return false;")
	w("    const std::uint32_t codepoint = PositionToCodepoint[position];")
	w("    if (codepoint >= 0xf0000 && codepoint < 0xf0000 + std::size(Aliases))")
	w("        output.push_back(Aliases[codepoint - 0xf0000]);")
	w("    else if (codepoint >= 0xf0200 && codepoint < 0xf0200 + std::size(SequenceOffsets) - 1)")
	w("    {")
	w("        const std::size_t index = codepoint - 0xf0200;")
	w("        output.insert(output.end(), SequenceCodepoints + SequenceOffsets[index],")
	w("            SequenceCodepoints + SequenceOffsets[index + 1]);")
	w("    }")
	w("    else")
	w("        output.push_back(codepoint);")
	w("    return true;")
	w("}")
	w("")
	w("bool nameFor(std::uint32_t codepoint, std::string& output)")
	w("{")
	w("    if (codepoint <= 0x10ffff)")
	w("    {")
	w("        const std::uint32_t block = CodepointIndex1[codepoint >> Shift];")
	w("        const std::uint32_t position = CodepointIndex2[(block << Shift) + (codepoint & Mask)];")
	w("        if (position != NotFound && inverseLookup(position, output))")
	w("            return true;")
	w("    }")
	w("    for (const DerivedRange& range : DerivedRanges)")
	w("    {")
	w("        if (codepoint >= range.first && codepoint <= range.last)")
	w("        {")
	w("            char suffix[16];")
	w('            std::snprintf(suffix, sizeof(suffix), "%X", codepoint);')
	w("            output = DerivedPrefixes[range.prefix];")
	w("            output += suffix;")
	w("            return true;")
	w("        }")
	w("    }")
	w("    return false;")
	w("}")
	w("} // namespace " .. namespace)
end

local function formatStringList(list: { string }): string
	local items: { string } = {}
	for _, item in list do
		table.insert(items, string.format("%q", item))
	end
	return "{" .. table.concat(items, ",") .. "}"
end

local function makeunicodedata(unicode: UnicodeData, outdir: string, trace: boolean)
	local recordTable: { DataRecord } = { { 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
	local cache: { [string]: number } = {}
	local index = table.create(#unicode.chars, 0)

	local function internRecord(item: DataRecord): number
		local key = table.concat(item, "|")
		local i = cache[key]
		if i == nil then
			i = #recordTable + 1
			cache[key] = i
			table.insert(recordTable, item)
		end
		return i
	end

	cache["0|0|0|0|0|0|0|0|0"] = 1

	local decompDataCache: { [string]: number } = {}
	local decompData = { 0 }
	local decompPrefix = { "" }
	local decompIndex = table.create(#unicode.chars, 0)

	local compPairs: { { number } } = {}
	local compFirstSet: { [number]: boolean } = {}
	local compLastSet: { [number]: boolean } = {}

	for _, char in unicode.chars do
		local rec: UcdRecord? = unicode.table[char + 1]
		local eastAsianWidth = requiredIndexOf(EASTASIANWIDTH_NAMES, unicode.widths[char + 1] or "N", "EastAsianWidth")
			- 1
		local graphemeBreak = requiredIndexOf(
			GRAPHEME_CLUSTER_NAMES,
			unicode.graphemeBreaks[char + 1] or "Other",
			"GraphemeBreak"
		) - 1
		local extpict = if unicode.extPicts[char + 1] then 1 else 0
		local bidirectional = requiredIndexOf(BIDIRECTIONAL_NAMES, unicode.bidiClasses[char + 1] or "", "Bidirectional")
			- 1
		local item: DataRecord?
		if rec then
			item = {
				requiredIndexOf(CATEGORY_NAMES, rec.generalCategory, "Category") - 1,
				parseDec(rec.canonicalCombiningClass, "UnicodeData canonical combining class"),
				bidirectional,
				if rec.bidiMirrored == "Y" then 1 else 0,
				eastAsianWidth,
				rec.quickCheck,
				graphemeBreak,
				requiredIndexOf(INDIC_CONJUNCT_BREAK_NAMES, rec.incb, "InCB") - 1,
				extpict,
			}
		else
			if eastAsianWidth ~= 0 or graphemeBreak ~= 0 or extpict ~= 0 or bidirectional ~= 0 then
				item = { 0, 0, bidirectional, 0, eastAsianWidth, 0, graphemeBreak, 0, extpict }
			end
		end

		if item then
			index[char + 1] = internRecord(item)
		end

		if rec and rec.decompositionType ~= "" then
			local parts = splitChar(rec.decompositionType, " ")
			local prefix = ""
			if string.sub(parts[1], 1, 1) == "<" then
				local removed = table.remove(parts, 1)
				if removed then
					prefix = removed
				end
			end
			local prefixIndex = indexOf(decompPrefix, prefix)
			if prefixIndex == nil then
				table.insert(decompPrefix, prefix)
				prefixIndex = #decompPrefix
			end
			local prefixIndexNum = prefixIndex :: number
			local values: { number } = { (prefixIndexNum - 1) + bit32.lshift(#parts, 8) }
			for _, p in parts do
				table.insert(values, parseHex(p, "decomposition mapping"))
			end
			if prefix == "" and #values == 3 and not unicode.exclusions[char] then
				local l = values[2]
				local r = values[3]
				local recL = unicode.table[l + 1]
				if recL and recL.canonicalCombiningClass == "0" then
					compFirstSet[l] = true
					compLastSet[r] = true
					table.insert(compPairs, { l, r, char })
				end
			end
			local dkey = table.concat(values, "|")
			local di = decompDataCache[dkey]
			if di == nil then
				di = #decompData
				decompDataCache[dkey] = di
				for _, v in values do
					table.insert(decompData, v)
				end
			end
			decompIndex[char + 1] = di
		end
	end

	local f, l = 0, 0
	local compFirst: { [number]: number } = {}
	local compLast: { [number]: number } = {}
	local compFirstRanges: { { number } } = {}
	local compLastRanges: { { number } } = {}
	local prevF: { number }? = nil
	local prevL: { number }? = nil
	for _, cp in unicode.chars do
		if compFirstSet[cp] then
			compFirst[cp] = f
			f += 1
			if prevF == nil then
				prevF = { cp, cp }
			elseif prevF[2] + 1 == cp then
				prevF[2] = cp
			else
				prevF[3] = compFirst[prevF[1]]
				table.insert(compFirstRanges, prevF)
				prevF = { cp, cp }
			end
		end
		if compLastSet[cp] then
			compLast[cp] = l
			l += 1
			if prevL == nil then
				prevL = { cp, cp }
			elseif prevL[2] + 1 == cp then
				prevL[2] = cp
			else
				prevL[3] = compLast[prevL[1]]
				table.insert(compLastRanges, prevL)
				prevL = { cp, cp }
			end
		end
	end
	if prevF then
		prevF[3] = compFirst[prevF[1]]
		table.insert(compFirstRanges, prevF)
	end
	if prevL then
		prevL[3] = compLast[prevL[1]]
		table.insert(compLastRanges, prevL)
	end

	local totalFirst = f
	local totalLast = l
	local compData = table.create(totalFirst * totalLast, 0)
	for _, pair in compPairs do
		local leftI = compFirst[pair[1]] :: number
		local rightI = compLast[pair[2]] :: number
		compData[leftI * totalLast + rightI + 1] = pair[3]
	end

	local index1, index2, shift = splitbins(index, trace)
	local decompIndex1, decompIndex2, decompShift = splitbins(decompIndex, trace)
	local compIndex, compData2, compShift = splitbins(compData, trace)

	local outfile = fs.path.join(outdir, "data.luau")
	print("Writing " .. outfile)
	local w = openWriter(outfile)
	w("--- @ignore")
	w("--- Auto-generated. Do not edit!")
	w("")
	w("local data = {}")
	w("data.UNIDATA_VERSION = " .. string.format("%q", UNIDATA_VERSION))
	w("data.TOTAL_FIRST = " .. totalFirst)
	w("data.TOTAL_LAST = " .. totalLast)
	w("data.SHIFT = " .. shift)
	w("data.DECOMP_SHIFT = " .. decompShift)
	w("data.COMP_SHIFT = " .. compShift)

	w("data.databaseRecords = {")
	for _, item in recordTable do
		w(
			string.format(
				"  {%d,%d,%d,%d,%d,%d,%d,%d,%d},",
				item[1],
				item[2],
				item[3],
				item[4],
				item[5],
				item[6],
				item[7],
				item[8],
				item[9]
			)
		)
	end
	w("}")

	w("data.nfcFirst = {")
	for _, r in compFirstRanges do
		w(string.format("  {%d,%d,%d},", r[1], r[2] - r[1], compFirst[r[1]]))
	end
	w("}")

	w("data.nfcLast = {")
	for _, r in compLastRanges do
		w(string.format("  {%d,%d,%d},", r[1], r[2] - r[1], compLast[r[1]]))
	end
	w("}")

	w("data.categoryNames = " .. formatStringList(CATEGORY_NAMES))
	w("data.bidirectionalNames = " .. formatStringList(BIDIRECTIONAL_NAMES))
	w("data.eastAsianWidthNames = " .. formatStringList(EASTASIANWIDTH_NAMES))
	w("data.graphemeBreakNames = " .. formatStringList(GRAPHEME_CLUSTER_NAMES))
	w("data.indicConjunctBreakNames = " .. formatStringList(INDIC_CONJUNCT_BREAK_NAMES))

	local blockNames: { string } = {}
	local blockNameToIndex: { [string]: number } = {}
	local blocks: { { number } } = {}
	for _, b in unicode.blocks do
		local blockName = b[3]
		local first = b[1]
		local last = b[2]
		if type(blockName) ~= "string" or type(first) ~= "number" or type(last) ~= "number" then
			error("Invalid block entry")
		end
		local bi = blockNameToIndex[blockName]
		if bi == nil then
			bi = #blockNames
			blockNameToIndex[blockName] = bi
			table.insert(blockNames, blockName)
		end
		table.insert(blocks, { first, last, bi })
	end
	w("data.blockNames = {")
	for _, n in blockNames do
		w("  " .. string.format("%q", n) .. ",")
	end
	w("}")
	w("data.blocks = {")
	for _, b in blocks do
		w(string.format("  {0x%X,0x%X,%d},", b[1], b[2], b[3]))
	end
	w("}")
	w("data.BLOCK_COUNT = " .. #blocks)

	w("data.decompPrefix = {")
	for _, p in decompPrefix do
		w("  " .. string.format("%q", p) .. ",")
	end
	w("}")

	writeArrayStream(w, "index1", index1, true)
	writeArrayStream(w, "index2", index2, true)
	writeArrayStream(w, "decompData", decompData, true)
	writeArrayStream(w, "decompIndex1", decompIndex1, true)
	writeArrayStream(w, "decompIndex2", decompIndex2, true)
	writeArrayStream(w, "compIndex", compIndex, true)
	writeArrayStream(w, "compData", compData2, true)

	w("return table.freeze(data)")

	local cppOutputDir = args["cpp-output-dir"]
	if cppOutputDir then
		writeCppUnicodeData(
			fs.path.canonicalize(cppOutputDir),
			UNIDATA_VERSION,
			shift,
			recordTable,
			index1,
			index2,
			decompShift,
			decompData,
			decompIndex1,
			decompIndex2,
			compShift,
			compIndex,
			compData2,
			compFirstRanges,
			compLastRanges,
			totalLast
		)
	end
end

local function makeunicodetype(unicode: UnicodeData, outdir: string, trace: boolean)
	local dummy = { 0, 0, 0, 0, 0, 0 }
	local tableRecords: { TypeRecord } = { dummy }
	local cache: { [string]: number } = { ["0|0|0|0|0|0"] = 1 }
	local index = table.create(#unicode.chars, 0)
	local numeric: { [string]: { number } } = {}
	local spaces: { number } = {}
	local linebreaks: { number } = {}
	local extraCasing: { number } = {}

	for _, char in unicode.chars do
		local rec = unicode.table[char + 1]
		if rec then
			local category = rec.generalCategory
			local bidi = unicode.bidiClasses[char + 1]
			local props = rec.binaryProperties
			local flags = 0
			if category == "Lm" or category == "Lt" or category == "Lu" or category == "Ll" or category == "Lo" then
				flags += ALPHA_MASK
			end
			if props.Lowercase then
				flags += LOWER_MASK
			end
			if props.Line_Break or bidi == "B" then
				flags += LINEBREAK_MASK
				table.insert(linebreaks, char)
			end
			if category == "Zs" or bidi == "WS" or bidi == "B" or bidi == "S" then
				flags += SPACE_MASK
				table.insert(spaces, char)
			end
			if category == "Lt" then
				flags += TITLE_MASK
			end
			if props.Uppercase then
				flags += UPPER_MASK
			end
			if
				char == string.byte(" ") or (string.sub(category, 1, 1) ~= "C" and string.sub(category, 1, 1) ~= "Z")
			then
				flags += PRINTABLE_MASK
			end
			if props.XID_Start then
				flags += XID_START_MASK
			end
			if props.XID_Continue then
				flags += XID_CONTINUE_MASK
			end
			if props.Cased then
				flags += CASED_MASK
			end
			if props.Case_Ignorable then
				flags += CASE_IGNORABLE_MASK
			end

			local sc: SpecialCaseTriplet? = unicode.specialCasing[char]
			local cf = unicode.caseFolding[char] or { char }
			local upper = if rec.simpleUppercaseMapping ~= ""
				then parseHex(rec.simpleUppercaseMapping, "simple uppercase mapping")
				else char
			local lower = if rec.simpleLowercaseMapping ~= ""
				then parseHex(rec.simpleLowercaseMapping, "simple lowercase mapping")
				else char
			local title = if rec.simpleTitlecaseMapping ~= ""
				then parseHex(rec.simpleTitlecaseMapping, "simple titlecase mapping")
				else upper

			if sc == nil and #cf == 1 and cf[1] ~= lower then
				sc = { { lower }, { title }, { upper } }
			end
			if sc == nil then
				if upper == lower and lower == title then
					upper, lower, title = 0, 0, 0
				else
					upper -= char
					lower -= char
					title -= char
				end
			else
				flags += EXTENDED_CASE_MASK
				lower = #extraCasing + bit32.lshift(#sc[1], 24)
				for _, c in sc[1] do
					table.insert(extraCasing, c)
				end
				local cfDiff = #cf ~= #sc[1]
				if not cfDiff then
					for i = 1, #cf do
						if cf[i] ~= sc[1][i] then
							cfDiff = true
							break
						end
					end
				end
				if cfDiff then
					lower += bit32.lshift(#cf, 20)
					for _, c in cf do
						table.insert(extraCasing, c)
					end
				end
				upper = #extraCasing + bit32.lshift(#sc[3], 24)
				for _, c in sc[3] do
					table.insert(extraCasing, c)
				end
				local same = #sc[2] == #sc[3]
				if same then
					for i = 1, #sc[2] do
						if sc[2][i] ~= sc[3][i] then
							same = false
							break
						end
					end
				end
				if same then
					title = upper
				else
					title = #extraCasing + bit32.lshift(#sc[2], 24)
					for _, c in sc[2] do
						table.insert(extraCasing, c)
					end
				end
			end

			local decimal = 0
			if rec.decompositionMapping ~= "" then
				flags += DECIMAL_MASK
				decimal = parseDec(rec.decompositionMapping, "decimal decomposition mapping")
			end
			local digit = 0
			if rec.numericType ~= "" then
				flags += DIGIT_MASK
				digit = parseDec(rec.numericType, "numeric type")
			end
			if rec.numericValue ~= "" then
				flags += NUMERIC_MASK
				if numeric[rec.numericValue] == nil then
					numeric[rec.numericValue] = {}
				end
				table.insert(numeric[rec.numericValue], char)
			end

			local item: TypeRecord = { upper, lower, title, decimal, digit, flags }
			local key = table.concat(item, "|")
			local i = cache[key]
			if i == nil then
				i = #tableRecords + 1
				cache[key] = i
				table.insert(tableRecords, item)
			end
			index[char + 1] = i
		end
	end

	local index1, index2, shift = splitbins(index, trace)
	local outfile = fs.path.join(outdir, "type.luau")
	print("Writing " .. outfile)
	local w = openWriter(outfile)
	w("--- @ignore")
	w("--- Auto-generated. Do not edit!")
	w("")
	w("local data = {}")
	w("data.SHIFT = " .. shift)
	w("data.typeRecords = {")
	for _, item in tableRecords do
		w(string.format("  {%d,%d,%d,%d,%d,%d},", item[1], item[2], item[3], item[4], item[5], item[6]))
	end
	w("}")
	writeArrayStream(w, "extendedCase", extraCasing, true)
	writeArrayStream(w, "index1", index1, true)
	writeArrayStream(w, "index2", index2, true)

	local numericEntries: { NumericEntry } = {}
	for value, cps in numeric do
		table.sort(cps)
		table.insert(numericEntries, { value = value, cps = cps })
	end
	table.sort(numericEntries, function(a: NumericEntry, b: NumericEntry)
		local av = parseDec((a.value:gsub("/", ".")), "numeric sort")
		local bv = parseDec((b.value:gsub("/", ".")), "numeric sort")
		return av < bv
	end)
	w("data.numeric = {")
	for _, entry in numericEntries do
		local value = entry.value
		local cps = entry.cps
		w("  { " .. string.format("%q", value) .. ", { " .. table.concat(cps, ",") .. " } },")
	end
	w("}")
	table.sort(spaces)
	table.sort(linebreaks)
	writeArrayStream(w, "spaces", spaces, true)
	writeArrayStream(w, "linebreaks", linebreaks, true)
	w("return table.freeze(data)")

	local cppOutputDir = args["cpp-output-dir"]
	if cppOutputDir then
		writeCppUnicodeType(
			fs.path.canonicalize(cppOutputDir),
			shift,
			tableRecords,
			extraCasing,
			index1,
			index2,
			numericEntries
		)
	end
end

local function makeunicodename(unicode: UnicodeData, outdir: string, trace: boolean)
	local data: { NameEntry } = {}
	for _, char in unicode.chars do
		local rec = unicode.table[char + 1]
		if rec then
			local name = trim(rec.name)
			if name ~= "" and string.sub(name, 1, 1) ~= "<" then
				table.insert(data, { name = name, codepoint = char })
			end
		end
	end
	table.sort(data, function(a: NameEntry, b: NameEntry)
		return a.name < b.name
	end)
	local dawgInput: { { string | number } } = {}
	for _, item in data do
		table.insert(dawgInput, { item.name, item.codepoint })
	end
	local packedDawg, posToCodepoint = dawg.buildCompressionDawg(dawgInput)

	local notfound = #posToCodepoint
	local inverseList = table.create(#unicode.chars, notfound)
	for pos, codepoint in posToCodepoint do
		inverseList[codepoint + 1] = pos - 1
	end
	local index1, index2, shift = splitbins(inverseList, trace)

	local outfile = fs.path.join(outdir, "name.luau")
	print("Writing " .. outfile)
	local w = openWriter(outfile)
	w("--- @ignore")
	w("--- Auto-generated. Do not edit!")
	w("")
	w("local data = {}")
	w("data.NAME_MAXLEN = 256")
	w("data.DAWG_CODEPOINT_TO_POS_SHIFT = " .. shift)
	w("data.DAWG_CODEPOINT_TO_POS_NOTFOUND = " .. notfound)
	w("data.aliasesStart = " .. NAME_ALIASES_START)
	w("data.aliasesEnd = " .. (NAME_ALIASES_START + #unicode.aliases))
	w("data.namedSequencesStart = " .. NAMED_SEQUENCES_START)
	w("data.namedSequencesSnd = " .. (NAMED_SEQUENCES_START + #unicode.namedSequences))
	writeArrayStream(w, "packedNameDawg", packedDawg, true)
	writeArrayStream(w, "dawgPosToCodepoint", posToCodepoint, true)
	writeArrayStream(w, "dawgCodepointToPosIndex1", index1, true)
	writeArrayStream(w, "dawgCodepointToPosIndex2", index2, true)
	w("data.nameAliases = {")
	for _, item in unicode.aliases do
		local cp = item[2]
		if type(cp) ~= "number" then
			error("Invalid alias codepoint type")
		end
		w(string.format("  0x%04X,", cp))
	end
	w("}")
	w("data.namedSequences = {")
	for _, item in unicode.namedSequences do
		local chars = item[2]
		if type(chars) ~= "table" then
			error("Invalid named sequence chars type")
		end
		w(string.format("{%d,{%s}},", #chars, table.concat(chars, ",")))
	end
	w("}")
	w("data.derivedNameRanges = {")
	for _, r in unicode.derivedNameRanges do
		local first = r[1]
		local last = r[2]
		local kind = r[3]
		if type(first) ~= "string" or type(last) ~= "string" or type(kind) ~= "number" then
			error("Invalid derived name range entry")
		end
		w(string.format("  {0x%s,0x%s,%d},", first, last, kind))
	end
	w("}")
	w("data.derivedNamePrefixes = {")
	for _, p in unicode.derivedNamePrefixesList do
		w("  " .. string.format("%q", p) .. ",")
	end
	w("}")
	w("return table.freeze(data)")

	local cppOutputDir = args["cpp-output-dir"]
	if cppOutputDir then
		writeCppUnicodeName(
			fs.path.canonicalize(cppOutputDir),
			packedDawg,
			posToCodepoint,
			shift,
			index1,
			index2,
			notfound,
			unicode.aliases,
			unicode.namedSequences,
			unicode.derivedNameRanges,
			unicode.derivedNamePrefixesList
		)
	end
end

local function maketables(trace: boolean)
	local unicode = buildUnicodeData(UNIDATA_VERSION)
	print("Loaded Unicode entries")
	makeunicodename(unicode, fs.path.canonicalize(args["output-dir"]), trace)
	makeunicodedata(unicode, fs.path.canonicalize(args["output-dir"]), trace)
	makeunicodetype(unicode, fs.path.canonicalize(args["output-dir"]), trace)
end

maketables(args.trace)

if source.close then
	source.close()
end
