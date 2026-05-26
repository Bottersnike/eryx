--[=[
The `unicode` library provides Unicode-aware string operations built on top of Luau's built-in `utf8` library.
It covers encoding conversion (UTF-8 <-> UTF-16 <-> UTF-32), normalisation (NFC/NFD/NFKC/NFKD),
case conversion, character name lookup, and grapheme-based string slicing.

All string inputs and outputs use UTF-8 unless otherwise stated.

```luau
local unicode = require("@eryx/unicode")

-- Case conversion
print(unicode.toUpperCase("héllo")) -- "HÉLLO"
print(unicode.toLowercase("ÑOÑO")) -- "ñoño"

-- Normalisation
local nfc = unicode.normalise("e\xCC\x81", "NFC") -- é (composed)
print(unicode.isNormalised(nfc, "NFC")) -- true

-- Character name lookup
print(unicode.name("€")) -- "EURO SIGN"
print(unicode.fromName("SNOWMAN")) -- "☃"

-- Grapheme-aware length and slicing
print(unicode.len("héllo")) -- 5
print(unicode.sub("héllo", 2, 4)) -- "éll"

-- Encoding round-trip
local utf16 = unicode.toUtf16("hello")
print(unicode.fromUtf16(utf16)) -- "hello"
```
]=]

local unicode = {}

type UnicodedataDb = {
	SHIFT: number,
	DECOMP_SHIFT: number,
	COMP_SHIFT: number,
	TOTAL_LAST: number,
	index1: { number },
	index2: { number },
	decompPrefix: { string },
	decompData: { number },
	decompIndex1: { number },
	decompIndex2: { number },
	nfcFirst: { { number } },
	nfcLast: { { number } },
	compIndex: { number },
	compData: { number },
	databaseRecords: { { number } },
}

type UnicodetypeDb = {
	SHIFT: number,
	index1: { number },
	index2: { number },
	typeRecords: { { number } },
	extendedCase: { number },
	numeric: { { string | { number } } },
}

type UnicodenameDb = {
	DAWG_CODEPOINT_TO_POS_SHIFT: number,
	DAWG_CODEPOINT_TO_POS_NOTFOUND: number,
	aliasesStart: number,
	aliasesEnd: number,
	namedSequencesStart: number,
	namedSequencesEnd: number,
	packedNameDawg: { number },
	dawgPosToCodepoint: { number },
	dawgCodepointToPosIndex1: { number },
	dawgCodepointToPosIndex2: { number },
	nameAliases: { number },
	namedSequences: { { number | { number } } },
	derivedNameRanges: { { string | number } },
	derivedNamePrefixes: { string },
}

local tables = require("@self/_data/data") :: UnicodedataDb
local typeDb = require("@self/_data/type") :: UnicodetypeDb
local nameDb = require("@self/_data/name") :: UnicodenameDb

local EXTENDED_CASE_MASK = 0x4000

local SBase = 0xAC00
local LBase = 0x1100
local VBase = 0x1161
local TBase = 0x11A7
local LCount = 19
local VCount = 21
local TCount = 28
local NCount = VCount * TCount
local SCount = LCount * NCount

local function readByteTable(bytes: { number }, index0: number): number
	local value = bytes[index0 + 1]
	if value == nil then
		error(`byte index out of range: {index0}`)
	end
	return value
end

local function splitLookup(index1: { number }, index2: { number }, shift: number, cp: number): number
	local block = index1[bit32.rshift(cp, shift) + 1]
	local mask = bit32.lshift(1, shift) - 1
	return index2[bit32.lshift(block, shift) + bit32.band(cp, mask) + 1]
end

local function utf8FromCodepoints(codepoints: { number }): string
	local out: { string } = {}
	for _, cp in codepoints do
		table.insert(out, utf8.char(cp))
	end
	return table.concat(out)
end

local function decodeVarintUnsigned(bytes: { number }, index0: number): (number, number)
	local res = 0
	local shift = 0
	local index = index0
	while true do
		local byte = readByteTable(bytes, index)
		res += bit32.lshift(bit32.band(byte, 0x7F), shift)
		index += 1
		shift += 7
		if bit32.band(byte, 0x80) == 0 then
			return res, index
		end
	end
end

local function splitBits1(x: number): (number, number)
	return bit32.rshift(x, 1), bit32.band(x, 1)
end

local function splitBits2(x: number): (number, number, number)
	return bit32.rshift(x, 2), bit32.band(bit32.rshift(x, 1), 1), bit32.band(x, 1)
end

local function decodeNode(packed: { number }, nodeOffset: number): (number, number, number)
	local x, nextOffset = decodeVarintUnsigned(packed, nodeOffset)
	local nodeCount, final = splitBits1(x)
	return nodeCount, final, nextOffset
end

local function decodeEdge(
	packed: { number },
	edgeIndex: number,
	prevChildOffset: number,
	offset: number
): (number, number, number, number)
	local x, nextOffset = decodeVarintUnsigned(packed, offset)
	if x == 0 and edgeIndex == 0 then
		error("decode past final node")
	end
	local childOffsetDiff, len1, lastEdge = splitBits2(x)
	local childOffset = prevChildOffset + childOffsetDiff
	local size = 1
	local labelOffset = nextOffset
	if len1 == 0 then
		size, labelOffset = decodeVarintUnsigned(packed, nextOffset)
	end
	return childOffset, lastEdge, size, labelOffset
end

local function matchEdge(packed: { number }, s: string, size: number, nodeOffset: number, stringPos0: number): boolean
	if size > 1 and stringPos0 + size > #s then
		return false
	end
	for i = 0, size - 1 do
		local packedByte = readByteTable(packed, nodeOffset + i)
		local sByte = string.byte(s, stringPos0 + i + 1)
		if sByte == nil or packedByte ~= sByte then
			return false
		end
	end
	return true
end

local function dawgLookupPos(packed: { number }, s: string): number?
	local stringPos0 = 0
	local nodeOffset = 0
	local skipped = 0
	while stringPos0 < #s do
		local _, final, edgeOffset = decodeNode(packed, nodeOffset)
		local prevChildOffset = edgeOffset
		local edgeIndex = 0
		local localEdgeOffset = edgeOffset
		local matched = false
		while true do
			local childOffset, lastEdge, size, labelOffset =
				decodeEdge(packed, edgeIndex, prevChildOffset, localEdgeOffset)
			edgeIndex += 1
			prevChildOffset = childOffset
			if matchEdge(packed, s, size, labelOffset, stringPos0) then
				if final == 1 then
					skipped += 1
				end
				stringPos0 += size
				nodeOffset = childOffset
				matched = true
				break
			end
			if lastEdge == 1 then
				break
			end
			local descendantCount = decodeNode(packed, childOffset)
			skipped += descendantCount
			localEdgeOffset = labelOffset + size
		end
		if not matched then
			return nil
		end
	end
	local _, final = decodeNode(packed, nodeOffset)
	if final == 1 then
		return skipped
	end
	return nil
end

local function dawgInverseLookup(packed: { number }, pos: number): string
	local out: { number } = {}
	local nodeOffset = 0
	local currentPos = pos
	while true do
		local _, final, edgeOffset = decodeNode(packed, nodeOffset)
		if final == 1 then
			if currentPos == 0 then
				local chars: { string } = {}
				for _, b in out do
					table.insert(chars, string.char(b))
				end
				return table.concat(chars)
			end
			currentPos -= 1
		end
		local prevChildOffset = edgeOffset
		local edgeIndex = 0
		local localEdgeOffset = edgeOffset
		while true do
			local childOffset, lastEdge, size, labelOffset =
				decodeEdge(packed, edgeIndex, prevChildOffset, localEdgeOffset)
			edgeIndex += 1
			prevChildOffset = childOffset
			local descendantCount = decodeNode(packed, childOffset)
			local nextPos = currentPos - descendantCount
			if nextPos < 0 then
				for i = 0, size - 1 do
					table.insert(out, readByteTable(packed, labelOffset + i))
				end
				nodeOffset = childOffset
				break
			end
			if lastEdge == 1 then
				error("inverse lookup miss")
			end
			currentPos = nextPos
			localEdgeOffset = labelOffset + size
		end
	end
end

local function normalizeName(name: string): string
	local out = string.upper(name)
	out = out:gsub("[%s_]+", " ")
	out = out:gsub("^%s+", "")
	out = out:gsub("%s+$", "")
	return out
end

local function getOnlyCodepoint(s: string): number?
	local first: number? = nil
	local count = 0
	for _, cp in utf8.codes(s) do
		count += 1
		if count == 1 then
			first = cp
		else
			return nil
		end
	end
	return first
end

local function getTypeRecord(cp: number): { number }
	local logicalIndex = splitLookup(typeDb.index1, typeDb.index2, typeDb.SHIFT, cp)
	local record = typeDb.typeRecords[logicalIndex]
	if record == nil then
		record = typeDb.typeRecords[1]
	end
	return record
end

local function getDbRecord(cp: number): { number }
	local logicalIndex = splitLookup(tables.index1, tables.index2, tables.SHIFT, cp)
	local record = tables.databaseRecords[logicalIndex]
	if record == nil then
		record = tables.databaseRecords[1]
	end
	return record
end

local function categoryName(cp: number): string
	local categoryIndex = getDbRecord(cp)[1]
	return tables.categoryNames[categoryIndex + 1] or "Cn"
end

local function combiningClass(cp: number): number
	return getDbRecord(cp)[2]
end

local function findNfcIndex(ranges: { { number } }, cp: number): number?
	local lo = 1
	local hi = #ranges
	while lo <= hi do
		local mid = bit32.rshift(lo + hi, 1)
		local item = ranges[mid]
		local startCp = item[1]
		local delta = item[2]
		local baseIndex = item[3]
		local lastCp = startCp + delta
		if cp < startCp then
			hi = mid - 1
		elseif cp > lastCp then
			lo = mid + 1
		else
			return baseIndex + (cp - startCp)
		end
	end
	return nil
end

local function composePair(starter: number, ch: number): number?
	-- Algorithmic Hangul composition (UAX #15).
	local lIndex = starter - LBase
	if lIndex >= 0 and lIndex < LCount then
		local vIndex = ch - VBase
		if vIndex >= 0 and vIndex < VCount then
			return SBase + (lIndex * VCount + vIndex) * TCount
		end
	end

	local sIndex = starter - SBase
	if sIndex >= 0 and sIndex < SCount and (sIndex % TCount) == 0 then
		local tIndex = ch - TBase
		if tIndex > 0 and tIndex < TCount then
			return starter + tIndex
		end
	end

	local firstIndex = findNfcIndex(tables.nfcFirst, starter)
	if firstIndex == nil then
		return nil
	end
	local lastIndex = findNfcIndex(tables.nfcLast, ch)
	if lastIndex == nil then
		return nil
	end
	local flatIndex = firstIndex * tables.TOTAL_LAST + lastIndex
	local composed = splitLookup(tables.compIndex, tables.compData, tables.COMP_SHIFT, flatIndex)
	if composed == 0 then
		return nil
	end
	return composed
end

local function getDecomp(cp: number, compat: boolean): { number }?
	local di = splitLookup(tables.decompIndex1, tables.decompIndex2, tables.DECOMP_SHIFT, cp)
	if di == 0 then
		return nil
	end
	local header = tables.decompData[di + 1]
	if header == nil then
		return nil
	end
	local prefixIndex = bit32.band(header, 0xFF)
	local prefix = tables.decompPrefix[prefixIndex + 1] or ""
	if prefix ~= "" and not compat then
		return nil
	end
	local count = bit32.rshift(header, 8)
	local out: { number } = {}
	for i = 1, count do
		local part = tables.decompData[di + 1 + i]
		if part then
			table.insert(out, part)
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

local function appendCanonicalOrdered(out: { number }, cp: number)
	table.insert(out, cp)
	local ccc = combiningClass(cp)
	if ccc == 0 then
		return
	end
	local i = #out
	while i > 1 do
		local prev = out[i - 1]
		local prevCcc = combiningClass(prev)
		if prevCcc == 0 or prevCcc <= ccc then
			break
		end
		out[i] = prev
		out[i - 1] = cp
		i -= 1
	end
end

local function decomposeInto(cp: number, compat: boolean, out: { number })
	-- Algorithmic Hangul decomposition (UAX #15).
	local sIndex = cp - SBase
	if sIndex >= 0 and sIndex < SCount then
		local l = LBase + math.floor(sIndex / NCount)
		local v = VBase + math.floor((sIndex % NCount) / TCount)
		local t = TBase + (sIndex % TCount)
		appendCanonicalOrdered(out, l)
		appendCanonicalOrdered(out, v)
		if t ~= TBase then
			appendCanonicalOrdered(out, t)
		end
		return
	end

	local decomp = getDecomp(cp, compat)
	if decomp == nil then
		appendCanonicalOrdered(out, cp)
		return
	end
	for _, part in decomp do
		decomposeInto(part, compat, out)
	end
end

local function recomposeCanonical(decomp: { number }): { number }
	if #decomp <= 1 then
		return decomp
	end
	local out: { number } = { decomp[1] }
	local starterPos = 1
	local starter = out[starterPos]
	local lastCcc = 0
	for i = 2, #decomp do
		local ch = decomp[i]
		local chCcc = combiningClass(ch)
		local composed: number? = nil
		if starter and (lastCcc < chCcc or chCcc == 0) then
			composed = composePair(starter, ch)
		end
		if composed then
			out[starterPos] = composed
			starter = composed
		else
			if chCcc == 0 then
				starterPos = #out + 1
				starter = ch
			end
			table.insert(out, ch)
			lastCcc = chCcc
		end
	end
	return out
end

local function mappedCase(codepoint: number, field: number, flags: number): { number }
	if bit32.band(flags, EXTENDED_CASE_MASK) ~= 0 then
		local index = bit32.band(field, 0xFFFFF)
		local count = bit32.rshift(field, 24)
		local out: { number } = {}
		for i = 1, count do
			table.insert(out, typeDb.extendedCase[index + i])
		end
		return out
	end
	if field == 0 then
		return { codepoint }
	end
	return { codepoint + field }
end

local function foldCaseMap(codepoint: number, lowerField: number, flags: number): { number }
	if bit32.band(flags, EXTENDED_CASE_MASK) ~= 0 then
		local index = bit32.band(lowerField, 0xFFFFF)
		local lowerCount = bit32.rshift(lowerField, 24)
		local foldCount = bit32.band(bit32.rshift(lowerField, 20), 0xF)
		local out: { number } = {}
		if foldCount > 0 then
			for i = 1, foldCount do
				table.insert(out, typeDb.extendedCase[index + lowerCount + i])
			end
			return out
		end
		for i = 1, lowerCount do
			table.insert(out, typeDb.extendedCase[index + i])
		end
		return out
	end
	if lowerField == 0 then
		return { codepoint }
	end
	return { codepoint + lowerField }
end

local numericByCodepoint: { [number]: number }? = nil

local function ensureNumericMap(): { [number]: number }
	if numericByCodepoint then
		return numericByCodepoint
	end
	local map: { [number]: number } = {}
	for _, entry in typeDb.numeric do
		local raw = entry[1]
		local cps = entry[2]
		if type(raw) == "string" and type(cps) == "table" then
			local value: number?
			local a, b = raw:match("^(-?%d+)/(%d+)$")
			if a and b then
				local num = tonumber(a)
				local den = tonumber(b)
				if num and den and den ~= 0 then
					value = num / den
				end
			else
				value = tonumber(raw)
			end
			if value then
				for _, cp in cps do
					map[cp] = value
				end
			end
		end
	end
	numericByCodepoint = map
	return map
end

local function codepointToPos(cp: number): number?
	local shift = nameDb.DAWG_CODEPOINT_TO_POS_SHIFT
	local mask = bit32.lshift(1, shift) - 1
	local block = nameDb.dawgCodepointToPosIndex1[bit32.rshift(cp, shift) + 1]
	local pos = nameDb.dawgCodepointToPosIndex2[bit32.lshift(block, shift) + bit32.band(cp, mask) + 1]
	if pos == nameDb.DAWG_CODEPOINT_TO_POS_NOTFOUND then
		return nil
	end
	return pos
end

local function getDerivedName(cp: number): string?
	for _, item in nameDb.derivedNameRanges do
		local startHex = item[1]
		local endHex = item[2]
		local prefixIndex = item[3]
		if type(startHex) == "string" and type(endHex) == "string" and type(prefixIndex) == "number" then
			local first = tonumber(startHex, 16)
			local last = tonumber(endHex, 16)
			if first and last and cp >= first and cp <= last then
				local prefix = nameDb.derivedNamePrefixes[prefixIndex + 1]
				if prefix then
					return prefix .. string.format("%X", cp)
				end
			end
		end
	end
	return nil
end

--[=[
Get the unicode representation (UTF-8) of a character by name (e.g. `LEFT CURLY BRACKET`)
@param name The unicode character name to look up
@param default The value to return if the name is not found
@return The UTF-8 string for the named character, or `default` if not found
]=]
function unicode.fromName(name: string, default: string?): string?
	local query = normalizeName(name)
	local pos = dawgLookupPos(nameDb.packedNameDawg, query)
	if pos == nil then
		return default
	end
	local cp = nameDb.dawgPosToCodepoint[pos + 1]
	if cp == nil then
		return default
	end
	if cp >= nameDb.aliasesStart and cp < nameDb.aliasesEnd then
		local aliasCp = nameDb.nameAliases[cp - nameDb.aliasesStart + 1]
		if aliasCp == nil then
			return default
		end
		return utf8.char(aliasCp)
	end
	if cp >= nameDb.namedSequencesStart and cp < nameDb.namedSequencesEnd then
		local seq = nameDb.namedSequences[cp - nameDb.namedSequencesStart + 1]
		if seq == nil then
			return default
		end
		local cps = seq[2]
		if type(cps) ~= "table" then
			return default
		end
		return utf8FromCodepoints(cps)
	end
	return utf8.char(cp)
end

--[=[
Converts a unicode grapheme to its numeric value, e.g. `"٩"` (`ARABIC-INDIC DIGIT NINE`) -> 9, `"½"` -> 0.5
@param grapheme The UTF-8 grapheme to convert
@return The numeric value of the grapheme, or nil if it is not a numeric character
]=]
function unicode.toNumber(grapheme: string): number?
	local cp = getOnlyCodepoint(grapheme)
	if cp == nil then
		return nil
	end
	return ensureNumericMap()[cp]
end

--[=[
Returns the Unicode general category for a codepoint.
@param cp The Unicode codepoint to inspect
@return The two-letter Unicode general category (for example `"Lu"` or `"Nd"`)
]=]
function unicode.category(cp: number): string
	return categoryName(cp)
end

--[=[
Get the unicode name for a grapheme (e.g. `LATIN SMALL LETTER A`)
@param grapheme The UTF-8 grapheme to look up
@return The unicode name of the grapheme
]=]
function unicode.name(grapheme: string): string
	local cp = getOnlyCodepoint(grapheme)
	if cp == nil then
		error("unicode.name expects exactly one codepoint")
	end
	local pos = codepointToPos(cp)
	if pos ~= nil then
		return dawgInverseLookup(nameDb.packedNameDawg, pos)
	end
	local derived = getDerivedName(cp)
	if derived ~= nil then
		return derived
	end
	error(("No unicode name found for U+%X"):format(cp))
end

--[=[
Normalise a UTF-8 string to the given unicode normalisation form
@param source The UTF-8 string to normalise
@param format The normalisation form to apply
@return The normalised UTF-8 string
]=]
function unicode.normalise(source: string, format: "NFC" | "NFKC" | "NFD" | "NFKD"): string
	local compat = format == "NFKC" or format == "NFKD"
	local compose = format == "NFC" or format == "NFKC"

	local decomposed: { number } = {}
	for _, cp in utf8.codes(source) do
		decomposeInto(cp, compat, decomposed)
	end

	local result = if compose then recomposeCanonical(decomposed) else decomposed
	return utf8FromCodepoints(result)
end

--[=[
Returns whether a UTF-8 string is already in the given normalisation form
@param source The UTF-8 string to check
@param format The normalisation form to check against
@return Whether the string is already normalised to the given form
]=]
function unicode.isNormalised(source: string, format: "NFC" | "NFKC" | "NFD" | "NFKD"): boolean
	return unicode.normalise(source, format) == source
end

--[=[
Unicode case folding algorithm; produces a canonical lowercase form suitable for case-insensitive comparison
@param source The UTF-8 string to case-fold
@return The case-folded UTF-8 string
]=]
function unicode.foldCase(source: string): string
	local out: { number } = {}
	for _, cp in utf8.codes(source) do
		local rec = getTypeRecord(cp)
		for _, mapped in foldCaseMap(cp, rec[2], rec[6]) do
			table.insert(out, mapped)
		end
	end
	return utf8FromCodepoints(out)
end

--[=[
Convert a UTF-8 string to uppercase
@param source The UTF-8 string to convert
@return The uppercase UTF-8 string
]=]
function unicode.toUpperCase(source: string): string
	local out: { number } = {}
	for _, cp in utf8.codes(source) do
		local rec = getTypeRecord(cp)
		for _, mapped in mappedCase(cp, rec[1], rec[6]) do
			table.insert(out, mapped)
		end
	end
	return utf8FromCodepoints(out)
end

--[=[
Convert a UTF-8 string to lowercase
@param source The UTF-8 string to convert
@return The lowercase UTF-8 string
]=]
function unicode.toLowercase(source: string): string
	local out: { number } = {}
	for _, cp in utf8.codes(source) do
		local rec = getTypeRecord(cp)
		for _, mapped in mappedCase(cp, rec[2], rec[6]) do
			table.insert(out, mapped)
		end
	end
	return utf8FromCodepoints(out)
end

--[=[
Convert a UTF-8 string to title case, capitalising the first codepoint
@param source The UTF-8 string to convert
@return The title-cased UTF-8 string
]=]
function unicode.toTitleCase(source: string): string
	local out: { number } = {}
	local isFirst = true
	for _, cp in utf8.codes(source) do
		local rec = getTypeRecord(cp)
		local mapped = if isFirst then mappedCase(cp, rec[3], rec[6]) else mappedCase(cp, rec[2], rec[6])
		for _, outCp in mapped do
			table.insert(out, outCp)
		end
		isFirst = false
	end
	return utf8FromCodepoints(out)
end

--[=[
Returns an iterator over all graphemes in a UTF-8 string
@param source The UTF-8 string to iterate over
@return An iterator that yields each grapheme in turn
]=]
function unicode.graphemes(source: string): () -> string?
	local i = 1
	return function(): string?
		if i > #source then
			return nil
		end
		local nextPos = utf8.offset(source, 2, i)
		local result: string
		if nextPos == nil then
			result = string.sub(source, i)
			i = #source + 1
		else
			result = string.sub(source, i, nextPos - 1)
			i = nextPos
		end
		return result
	end
end

-- Helper function for writing a UTF-8 codepoint. Essentially utf8.char, but for buffers
local function writeUtf8Codepoint(out: buffer, index: number, cp: number): number
	if cp <= 0x7F then
		buffer.writeu8(out, index, cp)
		return index + 1
	elseif cp <= 0x7FF then
		buffer.writeu8(out, index, 0xC0 + bit32.rshift(cp, 6))
		buffer.writeu8(out, index + 1, 0x80 + bit32.band(cp, 0x3F))
		return index + 2
	elseif cp <= 0xFFFF then
		buffer.writeu8(out, index, 0xE0 + bit32.rshift(cp, 12))
		buffer.writeu8(out, index + 1, 0x80 + bit32.band(bit32.rshift(cp, 6), 0x3F))
		buffer.writeu8(out, index + 2, 0x80 + bit32.band(cp, 0x3F))
		return index + 3
	elseif cp <= 0x10FFFF then
		buffer.writeu8(out, index, 0xF0 + bit32.rshift(cp, 18))
		buffer.writeu8(out, index + 1, 0x80 + bit32.band(bit32.rshift(cp, 12), 0x3F))
		buffer.writeu8(out, index + 2, 0x80 + bit32.band(bit32.rshift(cp, 6), 0x3F))
		buffer.writeu8(out, index + 3, 0x80 + bit32.band(cp, 0x3F))
		return index + 4
	else
		error("writeUtf8Codepoint called with out-of-range codepoint")
	end
end
local function utf8LenFromCodepoint(cp: number): number
	if cp <= 0x7F then
		return 1
	elseif cp <= 0x7FF then
		return 2
	elseif cp <= 0xFFFF then
		return 3
	else
		return 4
	end
end
local function readu16be(buf: buffer, index: number): number
	return bit32.lshift(buffer.readu8(buf, index), 8) + buffer.readu8(buf, index + 1)
end
local function readu32be(buf: buffer, index: number): number
	return bit32.lshift(buffer.readu8(buf, index), 24)
		+ bit32.lshift(buffer.readu8(buf, index + 1), 16)
		+ bit32.lshift(buffer.readu8(buf, index + 2), 8)
		+ buffer.readu8(buf, index + 3)
end

export type Endian = "little" | "big"
export type BomKind = "utf16" | "utf32"

--[=[
Inspects the leading bytes of a string for a Unicode byte order mark (BOM) and returns the
encoding information encoded within it. UTF-32 BOMs are checked before UTF-16 to avoid
ambiguity (the UTF-32 LE BOM starts with the same two bytes as the UTF-16 LE BOM).
Returns nil for all three values when no BOM is present.
@param source The input string to inspect
@return The byte order indicated by the BOM, or nil if no BOM was found
@return The encoding kind indicated by the BOM (`utf16` or `utf32`), or nil if no BOM was found
@return The number of bytes consumed by the BOM (0 if no BOM was found)
]=]
function unicode.detectBom(source: string): (Endian?, BomKind?, number)
	local len = #source
	if len >= 4 then
		local b1, b2, b3, b4 = string.byte(source, 1, 4)

		if b1 == 0xFF and b2 == 0xFE and b3 == 0x00 and b4 == 0x00 then
			return "little", "utf32", 4
		elseif b1 == 0x00 and b2 == 0x00 and b3 == 0xFE and b4 == 0xFF then
			return "big", "utf32", 4
		end
	end

	if len >= 2 then
		local b1, b2 = string.byte(source, 1, 2)

		if b1 == 0xFF and b2 == 0xFE then
			return "little", "utf16", 2
		elseif b1 == 0xFE and b2 == 0xFF then
			return "big", "utf16", 2
		end
	end

	return nil, nil, 0
end

--[=[
Convert a UTF-16 encoded string to UTF-8
@param source The UTF-16 encoded string to convert
@param endian The byte order; inferred from BOM if not specified, defaults to little-endian
@param strict Whether to error on unpaired surrogates; defaults to false (permissive, preserves them)
@param preserveBom Whether to decode BOM bytes as U+FEFF / U+FFFE rather than using them for endian detection; defaults to false
@return The UTF-8 encoded string
]=]
function unicode.fromUtf16(source: string, endian: ("little" | "big")?, strict: boolean?, preserveBom: boolean?): string
	if strict == nil then
		strict = false
	end
	if preserveBom == nil then
		preserveBom = false
	end

	local input = buffer.fromstring(source)
	local len = buffer.len(input)

	if len % 2 ~= 0 then
		error("Malformed UTF-16 string: byte length must be even")
	end

	local start = 0

	if not preserveBom and len >= 2 then
		local b0 = buffer.readu8(input, 0)
		local b1 = buffer.readu8(input, 1)

		if b0 == 0xFF and b1 == 0xFE then
			if endian and endian ~= "little" then
				error("UTF-16 BOM indicates little-endian, but big-endian was requested")
			end
			endian = "little"
			start = 2
		elseif b0 == 0xFE and b1 == 0xFF then
			if endian and endian ~= "big" then
				error("UTF-16 BOM indicates big-endian, but little-endian was requested")
			end
			endian = "big"
			start = 2
		end
	end

	if not endian then
		endian = "little"
	end

	local outLen = 0
	local i = start

	while i < len do
		local w1 = if endian == "little" then buffer.readu16(input, i) else readu16be(input, i)

		if w1 >= 0xD800 and w1 <= 0xDBFF then
			-- high surrogate
			if i + 2 < len then
				local w2 = if endian == "little" then buffer.readu16(input, i + 2) else readu16be(input, i + 2)

				if w2 >= 0xDC00 and w2 <= 0xDFFF then
					local cp = 0x10000 + bit32.lshift(w1 - 0xD800, 10) + (w2 - 0xDC00)

					outLen += utf8LenFromCodepoint(cp)
					i += 4
					continue
				end
			end

			if strict then
				error(("Malformed UTF-16 string: unpaired high surrogate 0x%04X"):format(w1))
			end

			outLen += utf8LenFromCodepoint(w1)
			i += 2
		elseif w1 >= 0xDC00 and w1 <= 0xDFFF then
			if strict then
				error(("Malformed UTF-16 string: unpaired low surrogate 0x%04X"):format(w1))
			end

			outLen += utf8LenFromCodepoint(w1)
			i += 2
		else
			outLen += utf8LenFromCodepoint(w1)
			i += 2
		end
	end

	local out = buffer.create(outLen)
	local outIndex = 0
	i = start

	while i < len do
		local w1 = if endian == "little" then buffer.readu16(input, i) else readu16be(input, i)

		if w1 >= 0xD800 and w1 <= 0xDBFF then
			if i + 2 < len then
				local w2 = if endian == "little" then buffer.readu16(input, i + 2) else readu16be(input, i + 2)

				if w2 >= 0xDC00 and w2 <= 0xDFFF then
					local cp = 0x10000 + bit32.lshift(w1 - 0xD800, 10) + (w2 - 0xDC00)

					outIndex = writeUtf8Codepoint(out, outIndex, cp)
					i += 4
					continue
				end
			end

			outIndex = writeUtf8Codepoint(out, outIndex, w1)
			i += 2
		else
			outIndex = writeUtf8Codepoint(out, outIndex, w1)
			i += 2
		end
	end

	return buffer.tostring(out)
end

--[=[
Convert a UTF-32 encoded string to UTF-8
@param source The UTF-32 encoded string to convert
@param endian The byte order; inferred from BOM if not specified, defaults to little-endian
@param strict Whether to error on surrogate code points; defaults to false (permissive, preserves them)
@param preserveBom Whether to decode BOM bytes as U+FEFF rather than using them for endian detection; defaults to false
@return The UTF-8 encoded string
]=]
function unicode.fromUtf32(source: string, endian: ("little" | "big")?, strict: boolean?, preserveBom: boolean?): string
	if strict == nil then
		strict = false
	end
	if preserveBom == nil then
		preserveBom = false
	end

	local input = buffer.fromstring(source)
	local len = buffer.len(input)

	if len % 4 ~= 0 then
		error("Malformed UTF-32 string: byte length must be a multiple of 4")
	end

	local start = 0

	if not preserveBom and len >= 4 then
		local b0 = buffer.readu8(input, 0)
		local b1 = buffer.readu8(input, 1)
		local b2 = buffer.readu8(input, 2)
		local b3 = buffer.readu8(input, 3)

		if b0 == 0xFF and b1 == 0xFE and b2 == 0x00 and b3 == 0x00 then
			if endian and endian ~= "little" then
				error("UTF-32 BOM indicates little-endian, but big-endian was requested")
			end
			endian = "little"
			start = 4
		elseif b0 == 0x00 and b1 == 0x00 and b2 == 0xFE and b3 == 0xFF then
			if endian and endian ~= "big" then
				error("UTF-32 BOM indicates big-endian, but little-endian was requested")
			end
			endian = "big"
			start = 4
		end
	end

	if not endian then
		endian = "little"
	end

	local outLen = 0

	for i = start, len - 4, 4 do
		local cp = if endian == "little" then buffer.readu32(input, i) else readu32be(input, i)

		if cp > 0x10FFFF then
			error(("Invalid UTF-32 code point U+%X"):format(cp))
		end

		if strict and cp >= 0xD800 and cp <= 0xDFFF then
			error(("Surrogate code point U+%04X is not valid in strict UTF-32"):format(cp))
		end

		outLen += utf8LenFromCodepoint(cp)
	end

	local out = buffer.create(outLen)
	local outIndex = 0

	for i = start, len - 4, 4 do
		local cp = if endian == "little" then buffer.readu32(input, i) else readu32be(input, i)

		outIndex = writeUtf8Codepoint(out, outIndex, cp)
	end

	return buffer.tostring(out)
end

--[=[
Convert a UTF-8 string to UTF-16
@param source The UTF-8 string to convert
@param endian The byte order for the output; defaults to little-endian
@param includeBom Whether to prepend a byte order mark; defaults to true
@param strict Whether to error on surrogate code points in the source; defaults to false
@return The UTF-16 encoded string
]=]
function unicode.toUtf16(source: string, endian: ("little" | "big")?, includeBom: boolean?, strict: boolean?): string
	if not endian then
		endian = "little"
	end
	if includeBom == nil then
		includeBom = true
	end
	if strict == nil then
		strict = false
	end

	if not utf8.len(source) then
		error("Malformed UTF-8 string")
	end

	local len = if includeBom then 2 else 0
	for _, cp in utf8.codes(source) do
		if cp <= 0xD7FF or (cp >= 0xE000 and cp <= 0xFFFF) then
			len += 2
		elseif cp >= 0x10000 and cp <= 0x10FFFF then
			len += 4
		elseif cp >= 0xD800 and cp <= 0xDFFF then
			if strict then
				error(("Surrogate codepoint U+%04X not valid in strict UTF-16 encoding"):format(cp))
			else
				len += 2
			end
		else
			error(("Invalid Unicode codepoint U+%04X"):format(cp))
		end
	end

	local codepoints = buffer.create(len)
	local index = 0
	if includeBom then
		if endian == "little" then
			buffer.writeu16(codepoints, 0, 0xFEFF)
		else
			buffer.writeu16(codepoints, 0, 0xFFFE)
		end
		index += 2
	end

	if endian == "little" then
		for _, cp in utf8.codes(source) do
			if cp <= 0xD7FF or (cp >= 0xE000 and cp <= 0xFFFF) then
				buffer.writeu16(codepoints, index, cp)
				index += 2
			elseif cp >= 0x10000 and cp <= 0x10FFFF then
				local cpPrime = cp - 0x10000
				buffer.writeu16(codepoints, index, 0xD800 + bit32.rshift(cpPrime, 10))
				buffer.writeu16(codepoints, index + 2, 0xDC00 + bit32.band(cpPrime, 0x3FF))
				index += 4
			elseif cp >= 0xD800 and cp <= 0xDFFF then
				buffer.writeu16(codepoints, index, cp)
				index += 2
			end
		end
	else
		for _, cp in utf8.codes(source) do
			if cp <= 0xD7FF or (cp >= 0xE000 and cp <= 0xFFFF) then
				buffer.writeu8(codepoints, index, bit32.band(bit32.rshift(cp, 8), 0xFF))
				buffer.writeu8(codepoints, index + 1, bit32.band(cp, 0xFF))
				index += 2
			elseif cp >= 0x10000 and cp <= 0x10FFFF then
				local cpPrime = cp - 0x10000

				local w1 = 0xD800 + bit32.rshift(cpPrime, 10)
				buffer.writeu8(codepoints, index, bit32.band(bit32.rshift(w1, 8), 0xFF))
				buffer.writeu8(codepoints, index + 1, bit32.band(w1, 0xFF))
				local w2 = 0xDC00 + bit32.band(cpPrime, 0x3FF)
				buffer.writeu8(codepoints, index + 2, bit32.band(bit32.rshift(w2, 8), 0xFF))
				buffer.writeu8(codepoints, index + 3, bit32.band(w2, 0xFF))

				index += 4
			elseif cp >= 0xD800 and cp <= 0xDFFF then
				buffer.writeu8(codepoints, index, bit32.band(bit32.rshift(cp, 8), 0xFF))
				buffer.writeu8(codepoints, index + 1, bit32.band(cp, 0xFF))
				index += 2
			end
		end
	end

	return buffer.tostring(codepoints)
end

--[=[
Convert a UTF-8 string to UTF-32
@param source The UTF-8 string to convert
@param endian The byte order for the output; defaults to little-endian
@param includeBom Whether to prepend a byte order mark; defaults to false
@return The UTF-32 encoded string
]=]
function unicode.toUtf32(source: string, endian: ("little" | "big")?, includeBom: boolean?): string
	if not endian then
		endian = "little"
	end
	if includeBom == nil then
		includeBom = false
	end

	local len = utf8.len(source)
	if not len then
		error("Malformed UTF-8 string")
	end

	local codepoints = buffer.create(len * 4 + (if includeBom then 4 else 0))
	local index = 0

	if includeBom then
		if endian == "little" then
			buffer.writeu32(codepoints, 0, 0x0000FEFF)
		else
			buffer.writeu32(codepoints, 0, 0xFFFE0000)
		end
		index += 4
	end

	if endian == "little" then
		for _, cp in utf8.codes(source) do
			buffer.writeu32(codepoints, index, cp)
			index += 4
		end
	else
		for _, cp in utf8.codes(source) do
			buffer.writeu8(codepoints, index, bit32.band(bit32.rshift(cp, 24), 0xFF))
			buffer.writeu8(codepoints, index + 1, bit32.band(bit32.rshift(cp, 16), 0xFF))
			buffer.writeu8(codepoints, index + 2, bit32.band(bit32.rshift(cp, 8), 0xFF))
			buffer.writeu8(codepoints, index + 3, bit32.band(cp, 0xFF))
			index += 4
		end
	end
	return buffer.tostring(codepoints)
end

--[=[
Returns the length of a UTF-8 string measured in graphemes
@param source The UTF-8 string to measure
@return The number of graphemes in the string
]=]
function unicode.len(source: string): number
	local n = 0
	for _ in unicode.graphemes(source) do
		n += 1
	end
	return n
end

--[=[
Returns a substring of a UTF-8 string using grapheme indices rather than byte offsets
@param source The UTF-8 string to slice
@param start The first grapheme index (1-based; negative values count from the end)
@param end_ The last grapheme index, inclusive; defaults to the end of the string
@return The extracted substring
]=]
function unicode.sub(source: string, start: number, end_: number?): string
	local graphemeList: { string } = {}
	for g in unicode.graphemes(source) do
		table.insert(graphemeList, g)
	end
	local count = #graphemeList
	local last = end_ or count
	local s = if start < 0 then count + start + 1 else start
	local e = if last < 0 then count + last + 1 else last
	if s < 1 then
		s = 1
	end
	if e > count then
		e = count
	end
	if s > e then
		return ""
	end
	local out: { string } = {}
	for i = s, e do
		table.insert(out, graphemeList[i])
	end
	return table.concat(out)
end

return table.freeze(unicode)
