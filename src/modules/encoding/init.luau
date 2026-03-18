--[=[
	Data encoding and decoding utilities.

	This module re-exports all encoding sub-modules, giving convenient
	access to common binary-to-text encodings from a single import.

	```luau
	local encoding = require("@eryx/encoding")

	local encoded = encoding.base64.encode(buffer.fromstring("Hello!"))
	print(encoded) -- "SGVsbG8h"

	local hex = encoding.hex.encode(buffer.fromstring("\xff\x0a"))
	print(hex) -- "ff0a"
	```

	Available sub-modules:
	- [[base32]] - RFC 4648 Base32
	- [[base64]] - RFC 4648 Base64 (standard & URL-safe)
	- [[base85]] - Z85 encoding
	- [[hex]]    - Hexadecimal
	- [[json]]   - JSON encoding / decoding (RFC 8259)
	- [[url]]    - Percent-encoding (URL encoding)
	- [[yaml]]   - YAML encoding / decoding (1.2 subset)
]=]

return {
	hex = require("@self/hex"),
	base32 = require("@self/base32"),
	base64 = require("@self/base64"),
	base85 = require("@self/base85"),
	url = require("@self/url"),
	json = require("@self/json"),
	yaml = require("@self/yaml"),
}

