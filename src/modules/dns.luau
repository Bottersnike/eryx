local ip = require("@eryx/ip")
local ssl = require("@eryx/_ssl")
local socket = require("@eryx/_socket")
local BufferBuilder = require("@eryx/bufferBuilder")

local MAX_DNS_NAME_JUMPS = 32
local DEFAULT_EDNS_UDP_PAYLOAD_SIZE = 1232

local DEFAULT_DNS_PORT = 53
local DEFAULT_DNS_TLS_PORT = 853
local DNS_TCP_FRAME_OVERHEAD = 2
local MAX_DNS_UDP_PACKET_SIZE = 65535

local dns = {}
dns.proto = {}

local function reverseLookup<A>(t: A, needle: index<A, keyof<A>> | keyof<A>): keyof<A>
	if typeof(needle) == "string" then
		return needle
	end
	for k, v in t :: any do
		if v == needle then
			return k
		end
	end
	assert(false)
end
local function reverseLookupOrNumber<A>(t: A, needle: index<A, keyof<A>> | keyof<A>): keyof<A> | number
	if typeof(needle) == "string" then
		return needle
	end
	for k, v in t :: any do
		if v == needle then
			return k
		end
	end
	return needle :: number
end
local function enumLookup<A>(t: A, needle: keyof<A> | index<A, keyof<A>>): index<A, keyof<A>>
	if typeof(needle) ~= "string" then
		return needle
	end
	return (t :: any)[needle]
end

local QR = {
	QUERY = false :: false,
	RESPONSE = true :: true,
}

-- The following enums are based on:
-- https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml

local OPCODE = table.freeze({
	QUERY = 0,
	IQUERY = 1,
	STATUS = 2,
	NOTIFY = 4,
	UPDATE = 5,
})

local RCODE = table.freeze({
	NoError = 0,
	FormErr = 1,
	ServFail = 2,
	NXDomain = 3,
	NotImp = 4,
	Refused = 5,
	YXDomain = 6,
	YXRRSet = 7,
	NXRRSet = 8,
	NotAuth = 9,
	NotZone = 10,
	DSOTYPENI = 11,
	BADVERS = 16,
	BADSIG = 16,
	BADKEY = 17,
	BADTIME = 18,
	BADMOD = 19,
	BADNAME = 20,
	BADALG = 21,
	BADTRUNC = 22,
	BADCOOKIE = 23,
})

local TYPE = table.freeze({
	A = 1, -- a host address
	NS = 2, -- an authoritative name server
	MD = 3, -- a mail destination (OBSOLETE - use MX)
	MF = 4, -- a mail forwarder (OBSOLETE - use MX)
	CNAME = 5, -- the canonical name for an alias
	SOA = 6, -- marks the start of a zone of authority
	MB = 7, -- a mailbox domain name (EXPERIMENTAL)
	MG = 8, -- a mail group member (EXPERIMENTAL)
	MR = 9, -- a mail rename domain name (EXPERIMENTAL)
	NULL = 10, -- a null RR (EXPERIMENTAL)
	WKS = 11, -- a well known service description
	PTR = 12, -- a domain name pointer
	HINFO = 13, -- host information
	MINFO = 14, -- mailbox or mail list information
	MX = 15, -- mail exchange
	TXT = 16, -- text strings
	RP = 17, -- for Responsible Person
	AFSDB = 18, -- for AFS Data Base location
	X25 = 19, -- for X.25 PSDN address
	ISDN = 20, -- for ISDN address
	RT = 21, -- for Route Through
	NSAP = 22, -- for NSAP address, NSAP style A record (DEPRECATED)
	NSAP_PTR = 23, -- for domain name pointer, NSAP style (DEPRECATED)
	SIG = 24, -- for security signature
	KEY = 25, -- for security key
	PX = 26, -- X.400 mail mapping information
	GPOS = 27, -- Geographical Position
	AAAA = 28, -- IP6 Address
	LOC = 29, -- Location Information
	NXT = 30, -- Next Domain (OBSOLETE)
	EID = 31, -- Endpoint Identifier
	NIMLOC = 32, -- Nimrod Locator
	SRV = 33, -- Server Selection
	ATMA = 34, -- ATM Address
	NAPTR = 35, -- Naming Authority Pointer
	KX = 36, -- Key Exchanger
	CERT = 37, -- CERT
	A6 = 38, -- A6 (OBSOLETE - use AAAA)
	DNAME = 39, -- DNAME
	SINK = 40, -- SINK
	OPT = 41, -- OPT
	APL = 42, -- APL
	DS = 43, -- Delegation Signer
	SSHFP = 44, -- SSH Key Fingerprint
	IPSECKEY = 45, -- IPSECKEY
	RRSIG = 46, -- RRSIG
	NSEC = 47, -- NSEC
	DNSKEY = 48, -- DNSKEY
	DHCID = 49, -- DHCID
	NSEC3 = 50, -- NSEC3
	NSEC3PARAM = 51, -- NSEC3PARAM
	TLSA = 52, -- TLSA
	SMIMEA = 53, -- S/MIME cert association

	HIP = 55, -- Host Identity Protocol

	NINFO = 56, -- NINFO
	RKEY = 57, -- RKEY
	TALINK = 58, -- Trust Anchor LINK
	CDS = 59, -- Child DS
	CDNSKEY = 60, -- DNSKEY(s) the Child wants reflected in DS
	OPENPGPKEY = 61, -- OpenPGP Key
	CSYNC = 62, -- Child-To-Parent Synchronization
	ZONEMD = 63, -- Message Digest Over Zone Data
	SVCB = 64, -- General-purpose service binding
	HTTPS = 65, -- SVCB-compatible type for use with HTTP
	DSYNC = 66, -- Endpoint discovery for delegation synchronization
	HHIT = 67, -- Hierarchical Host Identity Tag
	BRID = 68, -- UAS Broadcast Remote Identification

	SPF = 99,
	UINFO = 100,
	UID = 101,
	GID = 102,
	UNSPEC = 103,
	NID = 104,
	L32 = 105,
	L64 = 106,
	LP = 107,
	EUI48 = 108, -- an EUI-48 address
	EUI64 = 109, -- an EUI-64 address

	NXNAME = 128, -- NXDOMAIN indicator for Compact Denial of Existence

	TKEY = 249, -- Transaction Key
	TSIG = 250, -- Transaction Signature
	IXFR = 251, -- incremental transfer
	AXFR = 252, -- transfer of an entire zone
	MAILB = 253, -- mailbox-related RRs (MB, MG or MR)
	MAILA = 254, -- mail agent RRs (OBSOLETE - see MX)

	ALL_RECORDS = 255, -- A request for some or all records the server has available
	URI = 256, -- URI
	CAA = 257, -- Certification Authority Restriction
	AVC = 258, -- Application Visibility and Control
	DOA = 259, -- Digital Object Architecture
	AMTRELAY = 260, -- Automatic Multicast Tunneling Relay
	RESINFO = 261, -- Resolver Information as Key/Value Pairs
	WALLET = 262, -- Public wallet address
	CLA = 263, -- BP Convergence Layer Adapter
	IPN = 264, -- BP Node Number

	TA = 32768, -- DNSSEC Trust Authorities
	DLV = 32769, -- DNSSEC Lookaside Validation (OBSOLETE)
})

local CLASS = table.freeze({
	-- Internet
	IN = 1,
	-- Chaos
	CH = 3,
	-- Hesiod
	HS = 4,
	NONE = 254,
	ANY = 255,
})

local DNSSEC_ALGORITHM = table.freeze({
	RSAMD5 = 1,
	DH = 2,
	DSA = 3,
	ECC = 4,
	RSASHA1 = 5,
	DSA_NSEC3_SHA1 = 6,
	RSASHA1_NSEC3_SHA1 = 7,
	RSASHA256 = 8,
	RSASHA512 = 10,
	ECC_GOST = 12,
	ECDSAP256SHA256 = 13,
	ECDSAP384SHA384 = 14,
	ED25519 = 15,
	ED448 = 16,
	INDIRECT = 252,
	PRIVATEDNS = 253,
	PRIVATEOID = 254,
})

local DNSKEY_PROTOCOL = table.freeze({
	DNSSEC = 3,
})

local DS_DIGEST_TYPE = table.freeze({
	SHA1 = 1,
	SHA256 = 2,
	GOST_R_34_11_94 = 3,
	SHA384 = 4,
})

local NSEC3_HASH_ALGORITHM = table.freeze({
	SHA1 = 1,
})

local EDNS_OPTION_CODE = table.freeze({
	LLQ = 1,
	UL = 2,
	NSID = 3,
	DAU = 5,
	DHU = 6,
	N3U = 7,
	CLIENT_SUBNET = 8,
	EXPIRE = 9,
	COOKIE = 10,
	TCP_KEEPALIVE = 11,
	PADDING = 12,
	CHAIN = 13,
	KEY_TAG = 14,
	EXTENDED_DNS_ERROR = 15,
})

export type Header = {
	--- Exchange identifier
	id: number,
	--- Query or response?
	qr: keyof<typeof(QR)>,
	--- Kind of query
	opcode: keyof<typeof(OPCODE)> | number,
	--- (Response only) authoritative answer?
	aa: boolean,
	--- Truncated?
	tc: boolean,
	--- Recursion desired
	rd: boolean,
	--- Recursion available
	ra: boolean,
	--- Authentic Data. Indicates the response data was authenticated by the resolver.
	ad: boolean,
	--- Checking Disabled. Requests that DNSSEC signature validation not be performed.
	cd: boolean,
	--- Remaining reserved Z bit. Should normally be 0.
	z: number?,
	--- Response code
	rcode: keyof<typeof(RCODE)> | number,
	--- Number of entries in question section
	qdcount: number,
	--- Number of resource records in the answer section
	ancount: number,
	--- Number of name server resource records in the authority section
	nscount: number,
	--- Number of resource records in the additional records section
	arcount: number,
}

export type Question = {
	name: string,
	type: keyof<typeof(TYPE)> | number,
	class: keyof<typeof(CLASS)> | number,
}

export type EdnsOption = {
	code: keyof<typeof(EDNS_OPTION_CODE)> | number,
	data: buffer,
}

export type RDataRaw = { kind: "raw", value: buffer }
export type RDataA = { kind: "A", address: ip.IPv4Address }
export type RDataAAAA = { kind: "AAAA", address: ip.IPv6Address }
export type RDataCNAME = { kind: "CNAME", alias: string }
export type RDataMX = { kind: "MX", preference: number, host: string }
export type RDataNS = { kind: "NS", host: string }
export type RDataPTR = { kind: "PTR", host: string }
export type RDataTXT = { kind: "TXT", texts: { string } }
export type RDataRRSIG = {
	kind: "RRSIG",
	typeCovered: keyof<typeof(TYPE)> | number,
	algorithm: keyof<typeof(DNSSEC_ALGORITHM)> | number,
	labels: number,
	originalTtl: number,
	signatureExpiration: number,
	signatureInception: number,
	keyTag: number,
	signerName: string,
	signature: buffer,
}
export type RDataDNSKEY = {
	kind: "DNSKEY",
	flags: number,
	protocol: keyof<typeof(DNSKEY_PROTOCOL)> | number,
	algorithm: keyof<typeof(DNSSEC_ALGORITHM)> | number,
	publicKey: buffer,
}
export type RDataDS = {
	kind: "DS",
	keyTag: number,
	algorithm: keyof<typeof(DNSSEC_ALGORITHM)> | number,
	digestType: keyof<typeof(DS_DIGEST_TYPE)> | number,
	digest: buffer,
}
export type RDataNSEC = {
	kind: "NSEC",
	nextDomain: string,
	types: { keyof<typeof(TYPE)> | number },
}
export type RDataNSEC3 = {
	kind: "NSEC3",
	hashAlgorithm: keyof<typeof(NSEC3_HASH_ALGORITHM)> | number,
	flags: number,
	iterations: number,
	salt: buffer,
	nextHashedOwnerName: buffer,
	types: { keyof<typeof(TYPE)> | number },
}
export type RDataNSEC3PARAM = {
	kind: "NSEC3PARAM",
	hashAlgorithm: keyof<typeof(NSEC3_HASH_ALGORITHM)> | number,
	flags: number,
	iterations: number,
	salt: buffer,
}
export type RDataOPT = {
	kind: "OPT",
	udpPayloadSize: number,
	extendedRcode: keyof<typeof(RCODE)> | number,
	version: number,
	dnssecOk: boolean,
	z: number?,
	options: { EdnsOption },
}
export type RDataSOA = {
	kind: "SOA",
	mname: string,
	rname: string,
	serial: number,
	refresh: number,
	retry: number,
	expire: number,
	minimum: number,
}
export type RData =
	| RDataRaw
	| RDataA
	| RDataAAAA
	| RDataCNAME
	| RDataMX
	| RDataNS
	| RDataPTR
	| RDataTXT
	| RDataRRSIG
	| RDataDNSKEY
	| RDataDS
	| RDataNSEC
	| RDataNSEC3
	| RDataNSEC3PARAM
	| RDataOPT
	| RDataSOA

export type Answer = {
	type: string | number,
	class: string | number,
	name: string,
	ttl: number,
	rdata: RData,
}

export type Message = {
	header: Header,
	questions: { Question },
	answers: { Answer },
	authorities: { Answer },
	additional: { Answer },
}

type RequestTransport = "udp" | "tcp" | "tls" | "auto"

export type EdnsConfig = {
	enabled: boolean?,
	udpPayloadSize: number?,
	extendedRcode: keyof<typeof(RCODE)> | number?,
	version: number?,
	dnssecOk: boolean?,
	z: number?,
	options: { EdnsOption }?,
}

type RequestConfig = {
	transport: RequestTransport?,
	port: number?,
	timeout: number?,
	edns: EdnsConfig?,
}

type RequestResult = {
	server: string,
	port: number,
	transport: "udp" | "tcp" | "tls",
	messages: { Message },
}

local function readu16be(buf: buffer, offset: number): number
	return bit32.bor(buffer.readu8(buf, offset + 1), bit32.lshift(buffer.readu8(buf, offset), 8))
end

local function readu32be(buf: buffer, offset: number): number
	return bit32.bor(
		bit32.lshift(buffer.readu8(buf, offset), 24),
		bit32.lshift(buffer.readu8(buf, offset + 1), 16),
		bit32.lshift(buffer.readu8(buf, offset + 2), 8),
		buffer.readu8(buf, offset + 3)
	)
end

local function assertAvailable(buf: buffer, offset: number, size: number, what: string)
	assert(offset >= 0 and size >= 0 and offset + size <= buffer.len(buf), `truncated DNS packet while reading {what}`)
end

type NameOffsets = { [string]: number }

function dns.proto.writeName(b: BufferBuilder.BufferBuilder, nameOffsets: NameOffsets, name: string)
	if name == "" then
		b:writeU8(0)
		return
	end

	local labels = name:split(".")

	for i = 1, #labels do
		local suffix = table.concat(labels, ".", i)
		local existing = nameOffsets[suffix]

		if existing ~= nil and existing <= 0x3fff then
			b:writeU16be(bit32.bor(0xc000, existing))
			return
		end

		nameOffsets[suffix] = b:tell()

		local label = labels[i]
		assert(#label <= 63, "DNS label too long")

		b:writeU8(#label)
		b:writeString(label)
	end

	b:writeU8(0)
end

function dns.proto.parseName(buf: buffer, offset: number): (string, number)
	local labels: { string } = {}
	local endOffset = offset
	local jumped = false
	local jumps = 0

	while true do
		assertAvailable(buf, offset, 1, "DNS name")

		local len = buffer.readu8(buf, offset)
		local tag = bit32.band(len, 0xc0)

		if tag == 0xc0 then
			assertAvailable(buf, offset, 2, "DNS compression pointer")

			local b2 = buffer.readu8(buf, offset + 1)
			local pointer = bit32.bor(bit32.lshift(bit32.band(len, 0x3f), 8), b2)

			assert(pointer < buffer.len(buf), "DNS compression pointer out of bounds")

			if not jumped then
				endOffset = offset + 2
				jumped = true
			end

			jumps += 1
			assert(jumps <= MAX_DNS_NAME_JUMPS, "too many DNS compression jumps")

			offset = pointer
		elseif tag ~= 0 then
			error("invalid DNS label tag")
		elseif len == 0 then
			offset += 1

			if not jumped then
				endOffset = offset
			end

			break
		else
			offset += 1
			assertAvailable(buf, offset, len, "DNS label")

			table.insert(labels, buffer.readstring(buf, offset, len))
			offset += len
		end
	end

	return table.concat(labels, "."), endOffset
end

function dns.proto.writeHeader(b: BufferBuilder.BufferBuilder, header: Header)
	b:writeU16be(header.id)

	local row2 = 0
	row2 = bit32.bor(row2, bit32.lshift(if enumLookup(QR, header.qr) == QR.RESPONSE then 1 else 0, 15))
	row2 = bit32.bor(row2, bit32.lshift(bit32.band(enumLookup(OPCODE, header.opcode) or 0, 0b1111), 11))
	row2 = bit32.bor(row2, bit32.lshift(if header.aa then 1 else 0, 10))
	row2 = bit32.bor(row2, bit32.lshift(if header.tc then 1 else 0, 9))
	row2 = bit32.bor(row2, bit32.lshift(if header.rd then 1 else 0, 8))
	row2 = bit32.bor(row2, bit32.lshift(if header.ra then 1 else 0, 7))
	row2 = bit32.bor(row2, bit32.lshift(if header.ad then 1 else 0, 5))
	row2 = bit32.bor(row2, bit32.lshift(if header.cd then 1 else 0, 4))
	row2 = bit32.bor(row2, bit32.lshift(bit32.band(header.z or 0, 0b1), 6))
	row2 = bit32.bor(row2, bit32.band(enumLookup(RCODE, header.rcode) or 0, 0b1111))

	b:writeU16be(row2)
	b:writeU16be(header.qdcount or 0)
	b:writeU16be(header.ancount or 0)
	b:writeU16be(header.nscount or 0)
	b:writeU16be(header.arcount or 0)
end

function dns.proto.parseHeader(buf: buffer, offset: number): (Header, number)
	assertAvailable(buf, offset, 12, "DNS header")

	local head = {} :: Header
	head.id = readu16be(buf, offset)
	local row2 = readu16be(buf, offset + 2)

	head.qr = reverseLookup(QR, bit32.band(bit32.rshift(row2, 15), 0b1) ~= 0)
	head.opcode = reverseLookup(OPCODE, bit32.band(bit32.rshift(row2, 11), 0b1111))
	head.aa = bit32.band(bit32.rshift(row2, 10), 0b1) ~= 0
	head.tc = bit32.band(bit32.rshift(row2, 9), 0b1) ~= 0
	head.rd = bit32.band(bit32.rshift(row2, 8), 0b1) ~= 0
	head.ra = bit32.band(bit32.rshift(row2, 7), 0b1) ~= 0
	head.z = bit32.band(bit32.rshift(row2, 6), 0b1)
	head.ad = bit32.band(bit32.rshift(row2, 5), 0b1) ~= 0
	head.cd = bit32.band(bit32.rshift(row2, 4), 0b1) ~= 0
	head.rcode = reverseLookup(RCODE, bit32.band(row2, 0b1111))

	head.qdcount = readu16be(buf, offset + 4)
	head.ancount = readu16be(buf, offset + 6)
	head.nscount = readu16be(buf, offset + 8)
	head.arcount = readu16be(buf, offset + 10)

	return head, offset + 12
end

function dns.proto.writeQuestion(b: BufferBuilder.BufferBuilder, nameOffsets: NameOffsets, question: Question)
	dns.proto.writeName(b, nameOffsets, question.name)
	b:writeU16be(enumLookup(TYPE, question.type))
	b:writeU16be(enumLookup(CLASS, question.class))
end

function dns.proto.parseQuestion(buf: buffer, offset: number): (Question, number)
	local question = {} :: Question

	question.name, offset = dns.proto.parseName(buf, offset)
	assertAvailable(buf, offset, 4, "DNS question")

	question.type = reverseLookup(TYPE, readu16be(buf, offset))
	question.class = reverseLookup(CLASS, readu16be(buf, offset + 2))

	return question, offset + 4
end

local function sliceBuffer(src: buffer, offset: number, len: number): buffer
	local out = buffer.create(len)
	buffer.copy(out, 0, src, offset, len)
	return out
end

local function writeTypeBitmap(b: BufferBuilder.BufferBuilder, types_: { keyof<typeof(TYPE)> | number })
	local numericTypes: { number } = {}
	for _, ty in types_ do
		table.insert(numericTypes, enumLookup(TYPE, ty))
	end

	table.sort(numericTypes)

	local i = 1
	while i <= #numericTypes do
		local current = numericTypes[i]
		local window = math.floor(current / 256)
		local windowTypes: { number } = {}

		while i <= #numericTypes and math.floor(numericTypes[i] / 256) == window do
			table.insert(windowTypes, numericTypes[i] % 256)
			i += 1
		end

		local highest = windowTypes[#windowTypes]
		local bitmapLength = math.floor(highest / 8) + 1
		local bitmap = buffer.create(bitmapLength)

		for _, value in windowTypes do
			local octet = math.floor(value / 8)
			local bitIndex = value % 8
			local currentByte = buffer.readu8(bitmap, octet)
			buffer.writeu8(bitmap, octet, bit32.bor(currentByte, bit32.lshift(1, 7 - bitIndex)))
		end

		b:writeU8(window)
		b:writeU8(bitmapLength)
		b:writeBuffer(bitmap)
	end
end

local function parseTypeBitmap(buf: buffer, offset: number, length: number): { keyof<typeof(TYPE)> | number }
	local out: { keyof<typeof(TYPE)> | number } = {}
	local endOffset = offset + length

	while offset < endOffset do
		assertAvailable(buf, offset, 2, "DNS type bitmap header")
		local window = buffer.readu8(buf, offset)
		local bitmapLength = buffer.readu8(buf, offset + 1)
		offset += 2

		assertAvailable(buf, offset, bitmapLength, "DNS type bitmap body")

		for octet = 0, bitmapLength - 1 do
			local value = buffer.readu8(buf, offset + octet)
			if value ~= 0 then
				for bitIndex = 0, 7 do
					if bit32.band(value, bit32.lshift(1, 7 - bitIndex)) ~= 0 then
						local rrType = window * 256 + octet * 8 + bitIndex
						table.insert(out, reverseLookup(TYPE, rrType))
					end
				end
			end
		end

		offset += bitmapLength
	end

	assert(offset == endOffset, "DNS type bitmap length mismatch")

	return out
end

local function splitExtendedRcode(value: keyof<typeof(RCODE)> | number): (number, number)
	local numeric = enumLookup(RCODE, value)
	return bit32.band(numeric, 0x0f), bit32.band(bit32.rshift(numeric, 4), 0xff)
end

local function combineExtendedRcode(
	baseRcode: keyof<typeof(RCODE)> | number,
	extendedRcode: keyof<typeof(RCODE)> | number
): keyof<typeof(RCODE)> | number
	local low = bit32.band(enumLookup(RCODE, baseRcode), 0x0f)
	local high = bit32.band(enumLookup(RCODE, extendedRcode), 0xff)
	return reverseLookupOrNumber(RCODE, bit32.bor(low, bit32.lshift(high, 4)))
end

local function buildEdnsTtl(
	extendedRcode: keyof<typeof(RCODE)> | number,
	version: number,
	dnssecOk: boolean,
	z: number?
): number
	local ttl = 0
	ttl = bit32.bor(ttl, bit32.lshift(bit32.band(enumLookup(RCODE, extendedRcode), 0xff), 24))
	ttl = bit32.bor(ttl, bit32.lshift(bit32.band(version, 0xff), 16))

	local flags = bit32.band(z or 0, 0x7fff)
	if dnssecOk then
		flags = bit32.bor(flags, 0x8000)
	end

	return bit32.bor(ttl, flags)
end

local function parseEdnsTtl(ttl: number): (keyof<typeof(RCODE)> | number, number, boolean, number)
	local extendedRcode = reverseLookupOrNumber(RCODE, bit32.band(bit32.rshift(ttl, 24), 0xff))
	local version = bit32.band(bit32.rshift(ttl, 16), 0xff)
	local flags = bit32.band(ttl, 0xffff)
	local dnssecOk = bit32.band(flags, 0x8000) ~= 0
	local z = bit32.band(flags, 0x7fff)
	return extendedRcode, version, dnssecOk, z
end

function dns.proto.writeEdnsOptions(b: BufferBuilder.BufferBuilder, options: { EdnsOption })
	for _, option in options do
		b:writeU16be(enumLookup(EDNS_OPTION_CODE, option.code))
		b:writeU16be(buffer.len(option.data))
		b:writeBuffer(option.data)
	end
end

function dns.proto.parseEdnsOptions(buf: buffer): { EdnsOption }
	local out: { EdnsOption } = {}
	local offset = 0
	local length = buffer.len(buf)

	while offset < length do
		assertAvailable(buf, offset, 4, "EDNS option header")
		local code = reverseLookupOrNumber(EDNS_OPTION_CODE, readu16be(buf, offset))
		local optionLength = readu16be(buf, offset + 2)
		offset += 4

		assertAvailable(buf, offset, optionLength, "EDNS option data")
		table.insert(out, {
			code = code,
			data = sliceBuffer(buf, offset, optionLength),
		})
		offset += optionLength
	end

	return out
end

local function writeAnswerRData(b: BufferBuilder.BufferBuilder, nameOffsets: NameOffsets, rdata: RData)
	if rdata.kind == "raw" then
		b:writeBuffer(rdata.value)
	elseif rdata.kind == "A" then
		b:writeBuffer(rdata.address:toBytes())
	elseif rdata.kind == "AAAA" then
		b:writeBuffer(rdata.address:toBytes())
	elseif rdata.kind == "CNAME" then
		dns.proto.writeName(b, nameOffsets, rdata.alias)
	elseif rdata.kind == "MX" then
		b:writeU16be(rdata.preference)
		dns.proto.writeName(b, nameOffsets, rdata.host)
	elseif rdata.kind == "NS" then
		dns.proto.writeName(b, nameOffsets, rdata.host)
	elseif rdata.kind == "PTR" then
		dns.proto.writeName(b, nameOffsets, rdata.host)
	elseif rdata.kind == "TXT" then
		for _, text in rdata.texts do
			assert(#text <= 255, "DNS TXT chunk too long")
			b:writeU8(#text)
			b:writeString(text)
		end
	elseif rdata.kind == "RRSIG" then
		b:writeU16be(enumLookup(TYPE, rdata.typeCovered))
		b:writeU8(enumLookup(DNSSEC_ALGORITHM, rdata.algorithm))
		b:writeU8(rdata.labels)
		b:writeU32be(rdata.originalTtl)
		b:writeU32be(rdata.signatureExpiration)
		b:writeU32be(rdata.signatureInception)
		b:writeU16be(rdata.keyTag)
		dns.proto.writeName(b, nameOffsets, rdata.signerName)
		b:writeBuffer(rdata.signature)
	elseif rdata.kind == "DNSKEY" then
		b:writeU16be(rdata.flags)
		b:writeU8(enumLookup(DNSKEY_PROTOCOL, rdata.protocol))
		b:writeU8(enumLookup(DNSSEC_ALGORITHM, rdata.algorithm))
		b:writeBuffer(rdata.publicKey)
	elseif rdata.kind == "DS" then
		b:writeU16be(rdata.keyTag)
		b:writeU8(enumLookup(DNSSEC_ALGORITHM, rdata.algorithm))
		b:writeU8(enumLookup(DS_DIGEST_TYPE, rdata.digestType))
		b:writeBuffer(rdata.digest)
	elseif rdata.kind == "NSEC" then
		dns.proto.writeName(b, nameOffsets, rdata.nextDomain)
		writeTypeBitmap(b, rdata.types)
	elseif rdata.kind == "NSEC3" then
		assert(buffer.len(rdata.salt) <= 255, "DNS NSEC3 salt too long")
		assert(buffer.len(rdata.nextHashedOwnerName) <= 255, "DNS NSEC3 next hashed owner name too long")
		b:writeU8(enumLookup(NSEC3_HASH_ALGORITHM, rdata.hashAlgorithm))
		b:writeU8(rdata.flags)
		b:writeU16be(rdata.iterations)
		b:writeU8(buffer.len(rdata.salt))
		b:writeBuffer(rdata.salt)
		b:writeU8(buffer.len(rdata.nextHashedOwnerName))
		b:writeBuffer(rdata.nextHashedOwnerName)
		writeTypeBitmap(b, rdata.types)
	elseif rdata.kind == "NSEC3PARAM" then
		assert(buffer.len(rdata.salt) <= 255, "DNS NSEC3PARAM salt too long")
		b:writeU8(enumLookup(NSEC3_HASH_ALGORITHM, rdata.hashAlgorithm))
		b:writeU8(rdata.flags)
		b:writeU16be(rdata.iterations)
		b:writeU8(buffer.len(rdata.salt))
		b:writeBuffer(rdata.salt)
	elseif rdata.kind == "OPT" then
		dns.proto.writeEdnsOptions(b, rdata.options)
	elseif rdata.kind == "SOA" then
		dns.proto.writeName(b, nameOffsets, rdata.mname)
		dns.proto.writeName(b, nameOffsets, rdata.rname)
		b:writeU32be(rdata.serial)
		b:writeU32be(rdata.refresh)
		b:writeU32be(rdata.retry)
		b:writeU32be(rdata.expire)
		b:writeU32be(rdata.minimum)
	else
		error(`unsupported DNS RDATA kind: {(rdata :: any).kind}`)
	end
end

function dns.proto.writeAnswer(b: BufferBuilder.BufferBuilder, nameOffsets: NameOffsets, answer: Answer)
	if answer.rdata.kind == "OPT" then
		dns.proto.writeName(b, nameOffsets, "")
		b:writeU16be(TYPE.OPT)
		b:writeU16be(answer.rdata.udpPayloadSize)
		b:writeU32be(
			buildEdnsTtl(answer.rdata.extendedRcode, answer.rdata.version, answer.rdata.dnssecOk, answer.rdata.z)
		)

		local rdlengthOffset = b:tell()
		b:writeU16be(0)

		local rdataOffset = b:tell()
		writeAnswerRData(b, nameOffsets, answer.rdata)
		local endOffset = b:tell()
		b:seek(rdlengthOffset)
		b:writeU16be(endOffset - rdataOffset)
		b:seek(endOffset)
		return
	end

	dns.proto.writeName(b, nameOffsets, answer.name)
	b:writeU16be(enumLookup(TYPE, answer.type :: any))
	b:writeU16be(enumLookup(CLASS, answer.class :: any))
	b:writeU32be(answer.ttl)

	local rdlengthOffset = b:tell()
	b:writeU16be(0)

	local rdataOffset = b:tell()
	writeAnswerRData(b, nameOffsets, answer.rdata)
	local endOffset = b:tell()
	b:seek(rdlengthOffset)
	b:writeU16be(endOffset - rdataOffset)
	b:seek(endOffset)
end

function dns.proto.parseAnswer(buf: buffer, offset: number): (Answer, number)
	local answer = {} :: Answer

	answer.name, offset = dns.proto.parseName(buf, offset)
	assertAvailable(buf, offset, 10, "DNS answer")

	local answerType = readu16be(buf, offset)
	local answerClass = readu16be(buf, offset + 2)

	answer.type = reverseLookup(TYPE, answerType)
	answer.class = if answerType == TYPE.OPT then answerClass else reverseLookup(CLASS, answerClass)
	answer.ttl = readu32be(buf, offset + 4)
	local rdlength = readu16be(buf, offset + 8)

	offset += 10
	assertAvailable(buf, offset, rdlength, "DNS answer RDATA")

	local rdata = buffer.create(rdlength)
	buffer.copy(rdata, 0, buf, offset, rdlength)

	if answer.type == "OPT" then
		local extendedRcode, version, dnssecOk, z = parseEdnsTtl(answer.ttl)
		answer.rdata = {
			kind = "OPT",
			udpPayloadSize = answer.class :: number,
			extendedRcode = extendedRcode,
			version = version,
			dnssecOk = dnssecOk,
			z = z,
			options = dns.proto.parseEdnsOptions(rdata),
		} :: RDataOPT
	elseif answer.type == "A" and answer.class == "IN" then
		answer.rdata = { kind = "A", address = ip.IPv4Address.fromBytes(rdata) }
	elseif answer.type == "AAAA" and answer.class == "IN" then
		answer.rdata = { kind = "AAAA", address = ip.IPv6Address.fromBytes(rdata) }
	elseif answer.type == "CNAME" then
		answer.rdata = { kind = "CNAME", alias = dns.proto.parseName(buf, offset) } :: RDataCNAME
	elseif answer.type == "MX" then
		answer.rdata = {
			kind = "MX",
			preference = readu16be(rdata, 0),
			host = dns.proto.parseName(buf, offset + 2),
		} :: RDataMX
	elseif answer.type == "NS" then
		answer.rdata = {
			kind = "NS",
			host = dns.proto.parseName(buf, offset),
		} :: RDataNS
	elseif answer.type == "PTR" then
		answer.rdata = {
			kind = "PTR",
			host = dns.proto.parseName(buf, offset),
		} :: RDataPTR
	elseif answer.type == "TXT" then
		local texts: { string } = {}
		local localOffset = 0

		while localOffset < rdlength do
			assertAvailable(rdata, localOffset, 1, "DNS TXT chunk length")
			local textLength = buffer.readu8(rdata, localOffset)
			localOffset += 1
			assertAvailable(rdata, localOffset, textLength, "DNS TXT chunk")
			table.insert(texts, buffer.readstring(rdata, localOffset, textLength))
			localOffset += textLength
		end

		answer.rdata = {
			kind = "TXT",
			texts = texts,
		}
	elseif answer.type == "RRSIG" then
		assertAvailable(rdata, 0, 18, "DNS RRSIG header")
		local typeCovered = reverseLookup(TYPE, readu16be(rdata, 0))
		local algorithm = reverseLookupOrNumber(DNSSEC_ALGORITHM, buffer.readu8(rdata, 2))
		local labels = buffer.readu8(rdata, 3)
		local originalTtl = readu32be(rdata, 4)
		local signatureExpiration = readu32be(rdata, 8)
		local signatureInception = readu32be(rdata, 12)
		local keyTag = readu16be(rdata, 16)
		local signerName, signerOffset = dns.proto.parseName(buf, offset + 18)
		local signatureOffset = signerOffset - offset
		assert(signatureOffset <= rdlength, "DNS RRSIG signer name extends beyond RDATA")

		answer.rdata = {
			kind = "RRSIG",
			typeCovered = typeCovered,
			algorithm = algorithm,
			labels = labels,
			originalTtl = originalTtl,
			signatureExpiration = signatureExpiration,
			signatureInception = signatureInception,
			keyTag = keyTag,
			signerName = signerName,
			signature = sliceBuffer(rdata, signatureOffset, rdlength - signatureOffset),
		}
	elseif answer.type == "DNSKEY" or answer.type == "CDNSKEY" then
		assertAvailable(rdata, 0, 4, "DNS DNSKEY header")
		answer.rdata = {
			kind = "DNSKEY",
			flags = readu16be(rdata, 0),
			protocol = reverseLookupOrNumber(DNSKEY_PROTOCOL, buffer.readu8(rdata, 2)),
			algorithm = reverseLookupOrNumber(DNSSEC_ALGORITHM, buffer.readu8(rdata, 3)),
			publicKey = sliceBuffer(rdata, 4, rdlength - 4),
		}
	elseif answer.type == "DS" or answer.type == "CDS" then
		assertAvailable(rdata, 0, 4, "DNS DS header")
		answer.rdata = {
			kind = "DS",
			keyTag = readu16be(rdata, 0),
			algorithm = reverseLookupOrNumber(DNSSEC_ALGORITHM, buffer.readu8(rdata, 2)),
			digestType = reverseLookupOrNumber(DS_DIGEST_TYPE, buffer.readu8(rdata, 3)),
			digest = sliceBuffer(rdata, 4, rdlength - 4),
		}
	elseif answer.type == "NSEC" then
		local nextDomain, nextOffset = dns.proto.parseName(buf, offset)
		local bitmapOffset = nextOffset - offset
		assert(bitmapOffset <= rdlength, "DNS NSEC next domain extends beyond RDATA")

		answer.rdata = {
			kind = "NSEC",
			nextDomain = nextDomain,
			types = parseTypeBitmap(rdata, bitmapOffset, rdlength - bitmapOffset),
		} :: RDataNSEC
	elseif answer.type == "NSEC3" then
		assertAvailable(rdata, 0, 5, "DNS NSEC3 header")
		local saltLength = buffer.readu8(rdata, 4)
		local saltOffset = 5
		assertAvailable(rdata, saltOffset, saltLength, "DNS NSEC3 salt")
		local nextLengthOffset = saltOffset + saltLength
		assertAvailable(rdata, nextLengthOffset, 1, "DNS NSEC3 hash length")
		local nextLength = buffer.readu8(rdata, nextLengthOffset)
		local nextOffset = nextLengthOffset + 1
		assertAvailable(rdata, nextOffset, nextLength, "DNS NSEC3 next hashed owner name")
		local bitmapOffset = nextOffset + nextLength

		answer.rdata = {
			kind = "NSEC3",
			hashAlgorithm = reverseLookupOrNumber(NSEC3_HASH_ALGORITHM, buffer.readu8(rdata, 0)),
			flags = buffer.readu8(rdata, 1),
			iterations = readu16be(rdata, 2),
			salt = sliceBuffer(rdata, saltOffset, saltLength),
			nextHashedOwnerName = sliceBuffer(rdata, nextOffset, nextLength),
			types = parseTypeBitmap(rdata, bitmapOffset, rdlength - bitmapOffset),
		}
	elseif answer.type == "NSEC3PARAM" then
		assertAvailable(rdata, 0, 5, "DNS NSEC3PARAM header")
		local saltLength = buffer.readu8(rdata, 4)
		local saltOffset = 5
		assertAvailable(rdata, saltOffset, saltLength, "DNS NSEC3PARAM salt")

		answer.rdata = {
			kind = "NSEC3PARAM",
			hashAlgorithm = reverseLookupOrNumber(NSEC3_HASH_ALGORITHM, buffer.readu8(rdata, 0)),
			flags = buffer.readu8(rdata, 1),
			iterations = readu16be(rdata, 2),
			salt = sliceBuffer(rdata, saltOffset, saltLength),
		}
	elseif answer.type == "SOA" then
		local mname, rname, offset2
		mname, offset2 = dns.proto.parseName(buf, offset)
		rname, offset2 = dns.proto.parseName(buf, offset2)
		local localOffset = offset2 - offset
		local serial = readu32be(rdata, localOffset)
		local refresh = readu32be(rdata, localOffset + 4)
		local retry = readu32be(rdata, localOffset + 8)
		local expire = readu32be(rdata, localOffset + 12)
		local minimum = readu32be(rdata, localOffset + 16)

		answer.rdata = {
			kind = "SOA",
			mname = mname,
			rname = rname,
			serial = serial,
			refresh = refresh,
			retry = retry,
			expire = expire,
			minimum = minimum,
		} :: RDataSOA
	else
		answer.rdata = { kind = "raw", value = rdata }
	end

	return answer, offset + rdlength
end

function dns.proto.buildPacket(
	header: Header,
	questions: { Question },
	answers: { Answer }?,
	authorities: { Answer }?,
	additional: { Answer }?
): buffer
	questions = questions or {} :: { Question }
	answers = answers or {} :: { Answer }
	authorities = authorities or {} :: { Answer }
	additional = additional or {} :: { Answer }

	local additionalToWrite = table.clone(additional)
	local optIndex: number? = nil
	for i, record in additionalToWrite do
		if record.rdata.kind == "OPT" then
			optIndex = i
			break
		end
	end

	local baseRcode, extendedRcode = splitExtendedRcode(header.rcode)
	if optIndex ~= nil then
		local optRecord = table.clone(additionalToWrite[optIndex])
		local optRdata = table.clone(optRecord.rdata :: any)
		optRdata.extendedRcode = extendedRcode
		optRecord.rdata = optRdata
		additionalToWrite[optIndex] = optRecord
	elseif extendedRcode ~= 0 then
		error("extended DNS RCODE requires an OPT record")
	end

	local b = BufferBuilder.new()

	local headerToWrite = table.clone(header)
	headerToWrite.qdcount = #questions
	headerToWrite.ancount = #answers
	headerToWrite.nscount = #authorities
	headerToWrite.arcount = #additionalToWrite
	headerToWrite.rcode = baseRcode

	dns.proto.writeHeader(b, headerToWrite)
	local nameOffsets: NameOffsets = {}

	for _, question in questions do
		dns.proto.writeQuestion(b, nameOffsets, question)
	end

	for _, answer in answers do
		dns.proto.writeAnswer(b, nameOffsets, answer)
	end

	for _, authority in authorities do
		dns.proto.writeAnswer(b, nameOffsets, authority)
	end

	for _, additionalRecord in additionalToWrite do
		dns.proto.writeAnswer(b, nameOffsets, additionalRecord)
	end

	return b:finish()
end

function dns.proto.parsePacket(buf: buffer): Message
	local header, offset = dns.proto.parseHeader(buf, 0)

	local questions: { Question } = {}
	local answers: { Answer } = {}
	local authorities: { Answer } = {}
	local additional: { Answer } = {}

	for _ = 1, header.qdcount do
		local question
		question, offset = dns.proto.parseQuestion(buf, offset)
		table.insert(questions, question)
	end

	for _ = 1, header.ancount do
		local answer
		answer, offset = dns.proto.parseAnswer(buf, offset)
		table.insert(answers, answer)
	end

	for _ = 1, header.nscount do
		local authority
		authority, offset = dns.proto.parseAnswer(buf, offset)
		table.insert(authorities, authority)
	end

	for _ = 1, header.arcount do
		local additional_
		additional_, offset = dns.proto.parseAnswer(buf, offset)
		table.insert(additional, additional_)
	end

	for _, record in additional do
		if record.rdata.kind == "OPT" then
			header.rcode = combineExtendedRcode(header.rcode, record.rdata.extendedRcode)
			break
		end
	end

	return {
		header = header,
		questions = questions,
		answers = answers,
		authorities = authorities,
		additional = additional,
	}
end

local function resolveSocketFamily(host: string, port: number, sockType: number, proto: number): number
	if string.find(host, ":", 1, true) then
		return socket.AF_INET6
	end

	local results = socket.getAddrInfo(host, port, socket.AF_UNSPEC, sockType, proto)
	if #results > 0 then
		return results[1].family
	end

	return socket.AF_INET
end

local function isZoneTransferQuestion(question: Question): boolean
	local type = enumLookup(TYPE, question.type)
	return type == TYPE.AXFR or type == TYPE.IXFR
end

local function recvExact(sock: any, size: number): buffer
	local b = BufferBuilder.new(size)
	local remaining = size

	while remaining > 0 do
		local chunk = sock:recv(remaining)
		assert(chunk ~= nil, "DNS socket unexpectedly would block while receiving")

		local len = buffer.len(chunk)
		assert(len > 0, "DNS socket closed before the full response was received")

		b:writeBuffer(chunk)
		remaining -= len
	end

	return b:finish()
end

local function buildTcpFrame(packet: buffer): buffer
	local b = BufferBuilder.new(buffer.len(packet) + DNS_TCP_FRAME_OVERHEAD)
	b:writeU16be(buffer.len(packet))
	b:writeBuffer(packet)
	return b:finish()
end

local function recvTcpFrame(sock: any): buffer
	local lengthBuf = recvExact(sock, DNS_TCP_FRAME_OVERHEAD)
	local packetLength = readu16be(lengthBuf, 0)
	assert(packetLength > 0, "DNS over TCP frame had an invalid length")
	return recvExact(sock, packetLength)
end

local function parseAndValidateResponse(responseBuf: buffer, expectedId: number): Message
	local packet = dns.proto.parsePacket(responseBuf)
	assert(packet.header.qr == "RESPONSE", "DNS server returned a non-response packet")
	assert(packet.header.id == expectedId, "DNS server returned a response with an unexpected ID")
	return packet
end

local function countSoaRecords(packet: Message, zoneName: string): number
	local count = 0

	local function countSection(records: { Answer })
		for _, record in records do
			if enumLookup(TYPE, record.type :: any) == TYPE.SOA and record.name == zoneName then
				count += 1
			end
		end
	end

	countSection(packet.answers)
	countSection(packet.authorities)
	countSection(packet.additional)

	return count
end

local function configureBlockingSocketTimeout(sock: any, timeout: number?)
	sock:setBlocking(true)
	if timeout ~= nil then
		sock:setTimeout(timeout)
	end
end

local function relativiseName(name: string, zone: string): string
	if name == zone then
		return name
	end

	local lowerName = string.lower(name)
	local lowerZone = string.lower(zone)
	local suffix = "." .. lowerZone
	if string.sub(lowerName, -#suffix) == suffix then
		return string.sub(name, 1, #name - #suffix)
	end

	return name
end

local function relativiseAnswer(answer: Answer, zone: string): Answer
	local relativised = table.clone(answer)
	relativised.name = relativiseName(answer.name, zone)

	local rdata = answer.rdata
	if rdata.kind == "CNAME" then
		relativised.rdata = {
			kind = "CNAME",
			alias = relativiseName(rdata.alias, zone),
		}
	elseif rdata.kind == "MX" then
		relativised.rdata = {
			kind = "MX",
			preference = rdata.preference,
			host = relativiseName(rdata.host, zone),
		}
	elseif rdata.kind == "NS" then
		relativised.rdata = {
			kind = "NS",
			host = relativiseName(rdata.host, zone),
		}
	elseif rdata.kind == "PTR" then
		relativised.rdata = {
			kind = "PTR",
			host = relativiseName(rdata.host, zone),
		}
	elseif rdata.kind == "SOA" then
		relativised.rdata = {
			kind = "SOA",
			mname = relativiseName(rdata.mname, zone),
			rname = relativiseName(rdata.rname, zone),
			serial = rdata.serial,
			refresh = rdata.refresh,
			retry = rdata.retry,
			expire = rdata.expire,
			minimum = rdata.minimum,
		}
	end

	return relativised
end

local function flattenTransferAnswers(messages: { Message }, zone: string, relativise: boolean?): { Answer }
	local answers: { Answer } = {}
	for _, message in messages do
		for _, answer in message.answers do
			table.insert(answers, if relativise then relativiseAnswer(answer, zone) else answer)
		end
	end

	return answers
end

local function sendStreamRequest(
	transport: "tcp" | "tls",
	server: string,
	port: number,
	requestBuf: buffer,
	requestId: number,
	questions: { Question },
	timeout: number?
): { Message }
	local family = resolveSocketFamily(server, port, socket.SOCK_STREAM, socket.IPPROTO_TCP)
	local sock = socket.socket(family, socket.SOCK_STREAM, socket.IPPROTO_TCP)

	local ok, result = pcall(function()
		configureBlockingSocketTimeout(sock, timeout)
		sock:setSockOpt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true)
		sock:connect(server, port)

		local stream = sock :: any
		if transport == "tls" then
			local wrapped, err = ssl.wrapSocket(sock, server)
			assert(wrapped ~= nil, err or "TLS handshake failed")
			stream = wrapped
		end

		stream:sendAll(buildTcpFrame(requestBuf))

		local messages: { Message } = {}
		local isZoneTransfer = false
		local zoneName = ""

		for _, question in questions do
			if isZoneTransferQuestion(question) then
				isZoneTransfer = true
				zoneName = question.name
				break
			end
		end

		local soaCount = 0
		repeat
			local responseBuf = recvTcpFrame(stream)
			local packet = parseAndValidateResponse(responseBuf, requestId)
			table.insert(messages, packet)

			if isZoneTransfer then
				if enumLookup(RCODE, packet.header.rcode) ~= RCODE.NoError then
					break
				end

				soaCount += countSoaRecords(packet, zoneName)
			end
		until not isZoneTransfer or soaCount >= 2

		stream:close()
		return messages
	end)

	if not ok then
		sock:close()
		error(result, 0)
	end

	return result :: { Message }
end

function dns.buildOptAnswer(edns: EdnsConfig?): Answer?
	if edns == nil or edns.enabled == false then
		return nil
	end

	return {
		name = "",
		type = "OPT",
		class = 0,
		ttl = 0,
		rdata = {
			kind = "OPT",
			udpPayloadSize = edns.udpPayloadSize or DEFAULT_EDNS_UDP_PAYLOAD_SIZE,
			extendedRcode = edns.extendedRcode or ("NoError" :: "NoError"),
			version = edns.version or 0,
			dnssecOk = if edns.dnssecOk ~= nil then edns.dnssecOk else false,
			z = edns.z or 0,
			options = edns.options or {},
		},
	}
end

local function buildRequestHeader(questionCount: number): Header
	return {
		id = math.random(0, 0xffff),
		qr = "QUERY",
		opcode = "QUERY",
		aa = false,
		tc = false,
		rd = true,
		ra = false,
		ad = false,
		cd = false,
		rcode = "NoError",
		qdcount = questionCount,
		ancount = 0,
		nscount = 0,
		arcount = 0,
	}
end

-----------------

dns.query = {}

function dns.query.prepareQuery(
	questions: { Question },
	config: {
		id: number?,
		opcode: keyof<typeof(OPCODE)> | number?,
		recursive: boolean?, -- default true
		authenticData: boolean?,
		checkingDisabled: boolean?,
		edns: EdnsConfig?,
	}?
): Message
	assert(#questions > 0, "DNS queries must include at least one question")

	local header = buildRequestHeader(#questions)
	if config ~= nil then
		if config.id ~= nil then
			header.id = config.id
		end
		if config.opcode ~= nil then
			header.opcode = config.opcode
		end
		if config.recursive ~= nil then
			header.rd = config.recursive
		end
		if config.authenticData ~= nil then
			header.ad = config.authenticData
		end
		if config.checkingDisabled ~= nil then
			header.cd = config.checkingDisabled
		end
	end

	local additional: { Answer } = {}
	local optAnswer = dns.buildOptAnswer(if config ~= nil then config.edns else nil)
	if optAnswer ~= nil then
		table.insert(additional, optAnswer)
	end

	return {
		header = header,
		questions = table.clone(questions),
		answers = {},
		authorities = {},
		additional = additional,
	}
end
-- No prepareResponse helper, because that's a much more complex task

function dns.query.queryUdp(
	host: string,
	message: Message,
	config: {
		timeout: number?,
		port: number?,
		-- Default to false
		useTcpIfTruncated: boolean?,
	}?
): Message
	local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
	local timeout = if config then config.timeout else nil
	local family = resolveSocketFamily(host, port, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
	local sock = socket.socket(family, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

	local ok, result = pcall(function()
		configureBlockingSocketTimeout(sock, timeout)
		sock:connect(host, port)
		dns.query.sendUdp(sock, message, {
			timeout = timeout,
			port = port,
		})

		local response = dns.query.recvUdp(sock, {
			timeout = timeout,
		})
		assert(response.header.id == message.header.id, "DNS server returned a response with an unexpected ID")
		assert(response.header.qr == "RESPONSE", "DNS server returned a non-response packet")

		sock:close()

		if response.header.tc and config and config.useTcpIfTruncated then
			return dns.query.queryTcp(host, message, {
				timeout = timeout,
				port = port,
			})
		end

		return response
	end)

	if not ok then
		sock:close()
		error(result, 0)
	end

	return result :: Message
end

function dns.query.sendUdp(
	host: string | socket.Socket,
	message: Message,
	config: {
		timeout: number?,
		port: number?,
	}?
): ()
	local packet = dns.proto.buildPacket(
		message.header,
		message.questions,
		message.answers,
		message.authorities,
		message.additional
	)

	if typeof(host) == "string" then
		local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
		local timeout = if config then config.timeout else nil
		local family = resolveSocketFamily(host, port, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
		local sock = socket.socket(family, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

		local ok, result = pcall(function()
			configureBlockingSocketTimeout(sock, timeout)
			sock:sendTo(packet, host, port)
		end)

		sock:close()

		if not ok then
			error(result, 0)
		end

		return
	end

	local sock = host
	if config ~= nil and config.timeout ~= nil then
		configureBlockingSocketTimeout(sock, config.timeout)
	end

	local remoteHost, remotePort = sock:getPeerName()
	sock:sendTo(packet, remoteHost, remotePort)
end

function dns.query.recvUdp(
	host: string | socket.Socket,
	config: {
		timeout: number?,
		port: number?,
	}?
): Message
	if typeof(host) == "string" then
		local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
		local timeout = if config then config.timeout else nil
		local family = resolveSocketFamily(host, port, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
		local sock = socket.socket(family, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

		local ok, result = pcall(function()
			configureBlockingSocketTimeout(sock, timeout)
			sock:connect(host, port)

			local responseBuf = sock:recv(MAX_DNS_UDP_PACKET_SIZE)
			assert(responseBuf ~= nil, "DNS UDP socket unexpectedly would block while receiving")
			return dns.proto.parsePacket(responseBuf)
		end)

		sock:close()

		if not ok then
			error(result, 0)
		end

		return result :: Message
	end

	local sock = host
	if config ~= nil and config.timeout ~= nil then
		configureBlockingSocketTimeout(sock, config.timeout)
	end

	local responseBuf = sock:recv(MAX_DNS_UDP_PACKET_SIZE)
	assert(responseBuf ~= nil, "DNS UDP socket unexpectedly would block while receiving")
	return dns.proto.parsePacket(responseBuf)
end

function dns.query.queryTcp(
	host: string,
	message: Message,
	config: {
		timeout: number?,
		port: number?,
	}?
): Message
	local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
	local timeout = if config then config.timeout else nil
	local family = resolveSocketFamily(host, port, socket.SOCK_STREAM, socket.IPPROTO_TCP)
	local sock = socket.socket(family, socket.SOCK_STREAM, socket.IPPROTO_TCP)

	local ok, result = pcall(function()
		configureBlockingSocketTimeout(sock, timeout)
		sock:setSockOpt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true)
		sock:connect(host, port)
		dns.query.sendTcp(sock, message, config)

		local responseBuf = recvTcpFrame(sock)
		local response = parseAndValidateResponse(responseBuf, message.header.id)

		sock:close()
		return response
	end)

	if not ok then
		sock:close()
		error(result, 0)
	end

	return result :: Message
end

function dns.query.sendTcp(
	sock: socket.Socket | ssl.SslSocket,
	message: Message,
	config: {
		timeout: number?,
	}?
): ()
	if config ~= nil and config.timeout ~= nil then
		configureBlockingSocketTimeout(sock, config.timeout)
	end

	local packet = dns.proto.buildPacket(
		message.header,
		message.questions,
		message.answers,
		message.authorities,
		message.additional
	);
	(sock :: any):sendAll(buildTcpFrame(packet))
end

function dns.query.recvTcp(
	sock: socket.Socket | ssl.SslSocket,
	config: {
		timeout: number?,
	}?
): Message
	if config ~= nil and config.timeout ~= nil then
		configureBlockingSocketTimeout(sock, config.timeout)
	end

	local responseBuf = recvTcpFrame(sock)
	return dns.proto.parsePacket(responseBuf)
end

function dns.query.queryTls(
	host: string,
	message: Message,
	config: {
		timeout: number?,
		port: number?,
	}?
): Message
	local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_TLS_PORT
	local timeout = if config then config.timeout else nil
	local family = resolveSocketFamily(host, port, socket.SOCK_STREAM, socket.IPPROTO_TCP)
	local sock = socket.socket(family, socket.SOCK_STREAM, socket.IPPROTO_TCP)

	local ok, result = pcall(function()
		configureBlockingSocketTimeout(sock, timeout)
		sock:setSockOpt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true)
		sock:connect(host, port)

		local stream, err = ssl.wrapSocket(sock, host)
		assert(stream ~= nil, err or "TLS handshake failed")
		dns.query.sendTcp(stream, message, config)

		local responseBuf = recvTcpFrame(stream)
		local response = parseAndValidateResponse(responseBuf, message.header.id)

		stream:close()
		return response
	end)

	if not ok then
		sock:close()
		error(result, 0)
	end

	return result :: Message
end

function dns.query.zoneTransferAxfr(
	host: string,
	zone: string,
	config: {
		timeout: number?,
		port: number?,
		relativise: boolean?,
	}?
): { Answer }
	local timeout = if config then config.timeout else nil
	local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
	local message = dns.query.prepareQuery({
		{
			name = zone,
			type = "AXFR",
			class = "IN",
		},
	}, {
		recursive = false,
	})
	local requestBuf = dns.proto.buildPacket(
		message.header,
		message.questions,
		message.answers,
		message.authorities,
		message.additional
	)
	local messages = sendStreamRequest("tcp", host, port, requestBuf, message.header.id, message.questions, timeout)
	return flattenTransferAnswers(messages, zone, if config then config.relativise else nil)
end

function dns.query.zoneTransferIxfr(
	host: string,
	zone: string,
	serial: number,
	config: {
		timeout: number?,
		port: number?,
		relativise: boolean?,
	}?
): { Answer }
	local timeout = if config then config.timeout else nil
	local port = if config and config.port ~= nil then config.port else DEFAULT_DNS_PORT
	local message = dns.query.prepareQuery({
		{
			name = zone,
			type = "IXFR",
			class = "IN",
		},
	}, {
		recursive = false,
	})
	message.authorities = {
		{
			name = zone,
			type = "SOA",
			class = "IN",
			ttl = 0,
			rdata = {
				kind = "SOA",
				mname = "",
				rname = "",
				serial = serial,
				refresh = 0,
				retry = 0,
				expire = 0,
				minimum = 0,
			},
		},
	}
	local requestBuf = dns.proto.buildPacket(
		message.header,
		message.questions,
		message.answers,
		message.authorities,
		message.additional
	)
	local messages = sendStreamRequest("tcp", host, port, requestBuf, message.header.id, message.questions, timeout)
	return flattenTransferAnswers(messages, zone, if config then config.relativise else nil)
end

table.freeze(dns.query)
table.freeze(dns.proto)
return table.freeze(dns)
