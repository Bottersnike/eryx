local asn1 = {}

local MAX_TAG_BYTES = 6
local MAX_LENGTH_BYTES = 4

local CLASS_NAME = {
	[0] = "universal",
	[1] = "application",
	[2] = "context",
	[3] = "private",
}
local UNIVERSAL_TAG_NAME = {
	[0] = "EOC", -- End-of-contents (BER only)
	[1] = "BOOLEAN",
	[2] = "INTEGER",
	[3] = "BIT STRING",
	[4] = "OCTET STRING",
	[5] = "NULL",
	[6] = "OBJECT IDENTIFIER",
	[7] = "ObjectDescriptor",
	[8] = "EXTERNAL",
	[9] = "REAL",
	[10] = "ENUMERATED",
	[11] = "EMBEDDED PDV",
	[12] = "UTF8String",
	[13] = "RELATIVE-OID",
	[14] = "TIME",
	[15] = "Reserved",
	[16] = "SEQUENCE",
	[17] = "SET",
	[18] = "NumericString",
	[19] = "PrintableString",
	[20] = "TeletexString",
	[21] = "VideotexString",
	[22] = "IA5String",
	[23] = "UTCTime",
	[24] = "GeneralizedTime",
	[25] = "GraphicString",
	[26] = "VisibleString",
	[27] = "GeneralString",
	[28] = "UniversalString",
	[29] = "CHARACTER STRING",
	[30] = "BMPString",
}

local function readTag(data: buffer, offset: number, limit: number): (number, boolean, number, number)
	if offset >= limit then
		error("truncated tag")
	end

	local b = buffer.readu8(data, offset)
	offset += 1

	local class = bit32.rshift(b, 6)
	local constructed = bit32.band(b, 0x20) ~= 0
	local tag = bit32.band(b, 0x1F)

	if tag == 0x1F then
		tag = 0
		local count = 0

		while true do
			if offset >= limit then
				error("truncated extended tag")
			end
			if count > MAX_TAG_BYTES then
				error("tag too large")
			end

			local t = buffer.readu8(data, offset)
			offset += 1
			count += 1

			tag = bit32.lshift(tag, 7) + bit32.band(t, 0x7F)

			if bit32.band(t, 0x80) == 0 then
				break
			end
		end
	end

	return class, constructed, tag, offset
end

local function readLength(data: buffer, offset: number, limit: number)
	if offset >= limit then
		error("truncated length")
	end

	local b = buffer.readu8(data, offset)
	offset += 1

	if b < 0x80 then
		return b, offset
	end

	if b == 0x80 then
		error("indefinite length not allowed in DER")
	end

	local n = bit32.band(b, 0x7F)

	if n > MAX_LENGTH_BYTES then
		error("length too large")
	end
	if offset + n > limit then
		error("truncated long length")
	end

	local len = 0

	for i = 1, n do
		len = bit32.lshift(len, 8) + buffer.readu8(data, offset)
		offset += 1
	end

	return len, offset
end

export type Asn1Node = {
	class: string,
	tag: number | string,
	constructed: boolean,
	children: { Asn1Node }?,
	value: buffer?,
}

function asn1.parseDer(data: buffer, offset: number?, limit: number?): (Asn1Node, number)
	if not offset then
		offset = 0
	end
	if not limit then
		limit = buffer.len(data)
	end

	local class, constructed, tag
	class, constructed, tag, offset = readTag(data, offset :: number, limit :: number)
	local len
	len, offset = readLength(data, offset, limit :: number)

	local valueStart = offset
	local valueEnd = offset + len

	local node: Asn1Node = {
		class = CLASS_NAME[class],
		tag = if CLASS_NAME[class] == "universal" then UNIVERSAL_TAG_NAME[tag] else tag,
		constructed = constructed,
	}

	if constructed then
		local children = {} :: { Asn1Node }

		while offset < valueEnd do
			local child
			child, offset = asn1.parseDer(data, offset, valueEnd)
			table.insert(children, child)
		end

		node.children = children
	else
		local target = buffer.create(len)
		buffer.copy(target, 0, data, valueStart, len)
		node.value = target
		offset = valueEnd
	end

	return node, offset
end

local function nodeName(node: Asn1Node): string
	if type(node.tag) == "string" then
		return node.tag
	else
		return "[" .. tostring(node.tag) .. "]"
	end
end

local function nodeLength(node: Asn1Node): number
	if node.constructed then
		local total = 0
		if node.children then
			for _, child in node.children do
				total += nodeLength(child)
			end
		end
		return total
	else
		assert(node.value)
		return buffer.len(node.value)
	end
end

function asn1.dumpNode(node: Asn1Node, indent: number?): string
	indent = indent or 0

	local prefix = string.rep("  ", indent)
	local name = nodeName(node)
	local len = nodeLength(node)

	local out = prefix .. name .. " (len=" .. tostring(len) .. ")"

	if node.constructed then
		if node.children then
			for _, child in node.children do
				out ..= "\n" .. asn1.dumpNode(child, indent + 1)
			end
		end
	end

	return out
end

-- -- Decoder helpers
-- local function expect(node: TNode, tag: string)
-- 	if node.class ~= "universal" or node.tag ~= tag then
-- 		error("expected " .. tag)
-- 	end
-- 	return node
-- end

-- local function seq(node: TNode)
-- 	expect(node, "SEQUENCE")
-- 	if not node.children then
-- 		error("sequence missing children")
-- 	end
-- 	return node.children
-- end

-- local function int(node: TNode)
-- 	expect(node, "INTEGER")
-- 	return node.value
-- end

-- local function decodeOID(buf: buffer): string
-- 	local len = buffer.len(buf)
-- 	if len == 0 then
-- 		return "<invalid>"
-- 	end

-- 	local first = buffer.readu8(buf, 0)
-- 	local oid = {}

-- 	local v1 = math.floor(first / 40)
-- 	local v2 = first % 40

-- 	table.insert(oid, tostring(v1))
-- 	table.insert(oid, tostring(v2))

-- 	local value = 0

-- 	for i = 1, len - 1 do
-- 		local b = buffer.readu8(buf, i)

-- 		value = value * 128 + bit32.band(b, 0x7F)

-- 		if bit32.band(b, 0x80) == 0 then
-- 			table.insert(oid, tostring(value))
-- 			value = 0
-- 		end
-- 	end

-- 	return table.concat(oid, ".")
-- end

-- local function oid(node: TNode)
-- 	expect(node, "OBJECT IDENTIFIER")
-- 	assert(node.value)
-- 	return decodeOID(node.value)
-- end

-- local function bitstring(node: TNode)
-- 	expect(node, "BIT STRING")

-- 	assert(node.value)
-- 	local unused = buffer.readu8(node.value, 0)

-- 	local slice = buffer.create(buffer.len(node.value) - 1)
-- 	buffer.copy(slice, 0, node.value, 1, buffer.len(node.value) - 1)

-- 	return unused, slice
-- end

-- function asn1.decodeRSAPublicKey(node: TNode)
-- 	local c = seq(node)

-- 	return {
-- 		modulus = int(c[1]),
-- 		exponent = int(c[2]),
-- 	}
-- end

type Schema = {
	optional: true?,
	multiple: true?,
	tag: string | number,
	children: { Schema }?,
	name: string?,
	encapsulates: Schema?,
}

local SCHEMA_VERSION: Schema = {
	tag = "INTEGER",
	name = "version",
}
local SCHEMA_OTHER_PRIME_INFO: Schema = {
	tag = "SEQUENCE",
	children = {
		{ tag = "INTEGER", name = "prime" },
		{ tag = "INTEGER", name = "exponent" },
		{ tag = "INTEGER", name = "coefficient" },
	},
}

local SCHEMA_RSA_PUBLIC_KEY: Schema = {
	tag = "SEQUENCE",
	children = {
		{ tag = "INTEGER", name = "modulus" },
		{ tag = "INTEGER", name = "publicExponent" },
	},
}
local SCHEMA_RSA_PRIVATE_KEY: Schema = {
	tag = "SEQUENCE",
	children = {
		SCHEMA_VERSION,
		{ tag = "INTEGER", name = "modulus" },
		{ tag = "INTEGER", name = "publicExponent" },
		{ tag = "INTEGER", name = "privateExponent" },
		{ tag = "INTEGER", name = "prime1" },
		{ tag = "INTEGER", name = "prime2" },
		{ tag = "INTEGER", name = "exponent1" },
		{ tag = "INTEGER", name = "exponent2" },
		{ tag = "INTEGER", name = "coefficient" },
		{
			tag = "SEQUENCE",
			multiple = true,
			children = { SCHEMA_OTHER_PRIME_INFO },
			name = "otherPrimeInfos",
			optional = true,
		},
	},
}

local SCHEMA_ALGORITHM_IDENTIFIER: Schema = {
	tag = "SEQUENCE",
	children = {
		{ tag = "OBJECT IDENTIFIER", name = "algorithm" },
		-- TODO: parameters
	},
}
local SCHEMA_SUBJECT_PUBLIC_KEY_INFO: Schema = {
	tag = "SEQUENCE",
	children = {
		SCHEMA_ALGORITHM_IDENTIFIER,
		{ tag = "BIT STRING", name = "subjectPublicKey", encapsulates = SCHEMA_RSA_PUBLIC_KEY },
	},
}
local SCHEMA_SUBJECT_PRIVATE_KEY_INFO: Schema = {
	tag = "SEQUENCE",
	children = {
		SCHEMA_VERSION,
		SCHEMA_ALGORITHM_IDENTIFIER,
		{ tag = "OCTET STRING", name = "subjectPrivateKey", encapsulates = SCHEMA_RSA_PRIVATE_KEY },
	},
}

local function decodeBitString(bitBuf: buffer): buffer
	local unusedBits = buffer.readu8(bitBuf, 0)

	if unusedBits > 7 then
		error("Invalid unused bits in bit string")
	end

	local data = buffer.create(buffer.len(bitBuf) - 1)
	buffer.copy(data, 0, bitBuf, 1, buffer.len(bitBuf) - 1)

	if unusedBits == 0 then
		return data
	end

	-- Clear unused bits
	local lastByte = buffer.readu8(data, buffer.len(data) - 1)
	local mask = 0xFF - (bit32.lshift(1, unusedBits) - 1)
	buffer.writeu8(data, buffer.len(data) - 1, bit32.band(lastByte, mask))
	return data
end

local function decodeBoolean(data: buffer): boolean
	return buffer.readu8(data, 0) ~= 0
end
local function decodeInteger(data: buffer): buffer | number
	local offset = 0
	-- Strip leading 00 if present
	if buffer.readu8(data, 0) == 0 and buffer.len(data) > 1 then
		offset = 1
	end

	if buffer.len(data) - offset <= 6 then
		local n = 0
		--

		for i = offset, buffer.len(data) - 1 do
			n = bit32.bor(bit32.lshift(n, 8), buffer.readu8(data, i))
		end
		return n
	else
		return data
	end
end

local function decodeOID(data: buffer): string
	local arcs = {}
	local first = buffer.readu8(data, 0)
	arcs[1] = math.floor(first / 40)
	arcs[2] = first % 40

	local value = 0
	for i = 1, buffer.len(data) - 1 do
		local b = buffer.readu8(data, i)
		value = bit32.bor(bit32.lshift(value, 7), bit32.band(b, 0x7F))
		if bit32.band(b, 0x80) == 0 then
			table.insert(arcs, value)
			value = 0
		end
	end
	return table.concat(arcs, ".")
end

function asn1.parseBySchema(node: Asn1Node?, schema: Schema, extractInto: { [string]: any }): ()
	-- print("\n\nParsing", node)
	-- print("\n", schema)

	-- local extracted = {}

	if not node then
		if schema.optional then
			return
		end

		print(node, schema)
		error(`Expected {schema.tag} but not present`)
	end

	if node.tag ~= schema.tag then
		error(`Expected {schema.tag} but had tag {node.tag}`)
	end

	local value = node.value
	if schema.encapsulates then
		if not (node.tag == "BIT STRING" or node.tag == "OCTET STRING") then
			error(`Cannot encapsulate anything other than raw data`)
		end

		assert(node.value)
		value = {}

		if node.tag == "OCTET STRING" then
			asn1.parseBySchema(asn1.parseDer(node.value), schema.encapsulates, value)
		else
			asn1.parseBySchema(asn1.parseDer(decodeBitString(node.value)), schema.encapsulates, value)
		end
	elseif node.tag == "INTEGER" then
		value = decodeInteger(value :: buffer)
	elseif node.tag == "BOOLEAN" then
		value = decodeBoolean(value :: buffer)
	elseif node.tag == "OBJECT IDENTIFIER" then
		value = decodeOID(value :: buffer)
	end

	if schema.name then
		extractInto[schema.name] = value
	end

	if schema.multiple then
		if not schema.children then
			error(`Cannot have multiple without children`)
		end
		if #schema.children ~= 1 then
			error(`Cannot have multiple with more than one child schema`)
		end

		print(node.value)
		error(":(")
	end

	if schema.children then
		assert(node.children)
		for i = 1, #schema.children do
			asn1.parseBySchema(node.children[i], schema.children[i], extractInto)
		end
	end
end

export type Asn1Integer = buffer | number

export type SubjectPublicKeyInfo = {
	algorithm: string,
	subjectPublicKey: {
		modulus: Asn1Integer,
		publicExponent: Asn1Integer,
	},
}
function asn1.parsePublicRsaKey(node: Asn1Node): SubjectPublicKeyInfo
	local extracted = {}
	asn1.parseBySchema(node, SCHEMA_SUBJECT_PUBLIC_KEY_INFO, extracted)
	return extracted
end

export type OtherPrimeInfo = {
	prime: Asn1Integer,
	exponent: Asn1Integer,
	coefficient: Asn1Integer,
}
export type SubjectPrivateKeyInfo = {
	algorithm: string,
	version: Asn1Integer,
	subjectPrivateKey: {
		version: Asn1Integer,
		modulus: Asn1Integer,
		publicExponent: Asn1Integer,
		privateExponent: Asn1Integer,
		prime1: Asn1Integer,
		prime2: Asn1Integer,
		exponent1: Asn1Integer,
		exponent2: Asn1Integer,
		coefficient: Asn1Integer,
		otherPrimeInfos: { OtherPrimeInfo }?,
	},
}
function asn1.parsePrivateRsaKey(node: Asn1Node): SubjectPrivateKeyInfo
	local extracted = {}
	asn1.parseBySchema(node, SCHEMA_SUBJECT_PRIVATE_KEY_INFO, extracted)
	return extracted
end

return asn1
