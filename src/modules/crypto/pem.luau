--[=[
	PEM (Privacy-Enhanced Mail) encoding and decoding.

	PEM is the standard text format for cryptographic objects such as
	keys and certificates. A PEM file wraps a base64-encoded DER blob
	between `-----BEGIN <label>-----` and `-----END <label>-----` markers.

	This module handles the text-level encoding only - it converts between
	PEM strings and raw DER `buffer` values. It does not parse the ASN.1
	structure inside the DER. To work with RSA keys specifically, see
	`@eryx/crypto/rsa` which provides [[rsa.private_to_der]], etc.

	```luau
	local pem = require("@eryx/crypto/pem")
	local rsa = require("@eryx/crypto/rsa")

	local priv = rsa.generate_key()

	-- Convert PEM -> DER -> PEM (round-trip)
	local der   = rsa.private_to_der(priv)
	local pemS = pem.encode("RSA PRIVATE KEY", der)
	local label, der2 = pem.decode(pemS)
	assert(label == "RSA PRIVATE KEY")
	```
]=]

local base64 = require("@eryx/encoding/base64")

local pem = {}

--[=[
	Wraps raw DER bytes in a PEM block with the given label.

	The output follows RFC 7468: base64-encoded content is line-wrapped at
	64 characters, with `-----BEGIN <label>-----` and `-----END <label>-----`
	header/footer lines.

	Common labels: `"RSA PRIVATE KEY"`, `"PUBLIC KEY"`, `"CERTIFICATE"`,
	`"CERTIFICATE REQUEST"`.

	```luau
	local pemS = pem.encode("PUBLIC KEY", derBytes)
	-- "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n"
	```

	@param label The PEM label (the text that appears between the dashes).
	@param data  Raw DER bytes to encode.
	@return string -- PEM-formatted string.
]=]
function pem.encode(label: string, data: buffer): string
	local b64 = base64.encode(data)
	local lines = {}
	for i = 1, #b64, 64 do
		table.insert(lines, b64:sub(i, i + 63))
	end
	return "-----BEGIN " .. label .. "-----\n"
		.. table.concat(lines, "\n")
		.. "\n-----END " .. label .. "-----\n"
end

--[=[
	Decodes the **first** PEM block found in `pemStr` and returns its
	label and raw DER bytes.

	Whitespace inside the base64 body (including CRLF line endings) is
	ignored. Raises an error if no valid PEM block is found.

	```luau
	local label, der = pem.decode(pemStr)
	print(label)  -- e.g. "RSA PRIVATE KEY"
	```

	@param pemStr A string containing at least one PEM block.
	@return string -- The label from the BEGIN line.
	@return buffer -- Raw DER bytes.
]=]
function pem.decode(pemStr: string): (string, buffer)
	local results = pem.decodeAll(pemStr)
	if #results == 0 then
		error("pem.decode: no PEM block found")
	end
	return results[1].label, results[1].data
end

--[=[
	Decodes **all** PEM blocks found in `pemStr` and returns them as an
	array.

	Useful when a single file contains multiple certificates or keys (e.g.
	a CA bundle or a certificate chain).

	```luau
	local blocks = pem.decodeAll(chain_pem)
	for _, block in blocks do
	    print(block.label, buffer.len(block.data))
	end
	```

	@param pemStr A string containing one or more PEM blocks.
	@return {{label: string, data: buffer}} -- Array of decoded PEM blocks.
]=]
function pem.decodeAll(pemStr: string): { { label: string, data: buffer } }
	local results = {}
	local pos = 1
	while true do
		-- Find the next BEGIN header
		local ls, le, label = pemStr:find("%-%-%-%-%-BEGIN ([^%-%\n]+)%-%-%-%-%-", pos)
		if not ls then break end

		-- Skip the newline(s) after the header
		local bodyStart = le + 1
		if pemStr:sub(bodyStart, bodyStart) == "\r" then bodyStart += 1 end
		if pemStr:sub(bodyStart, bodyStart) == "\n" then bodyStart += 1 end

		-- Find the matching END marker
		local endPos = pemStr:find("%-%-%-%-%-END", bodyStart)
		if not endPos then
			error("pem.decodeAll: missing END marker for label: " .. label)
		end

		-- Extract and clean the base64 body
		local b64 = pemStr:sub(bodyStart, endPos - 1):gsub("[\r\n%s]+", "")
		label = label:match("^%s*(.-)%s*$")  -- trim whitespace

		table.insert(results, { label = label, data = base64.decode(b64) })

		-- Advance past the END line
		local nl = pemStr:find("\n", endPos)
		pos = nl and nl + 1 or #pemStr + 1
	end
	return results
end

return pem
