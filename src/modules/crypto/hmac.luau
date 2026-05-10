--[=[
	High-level keyed message authentication.

	This module provides a single HMAC API for application code that wants
	authenticity and integrity without choosing a concrete hash function at
	every call site.

	The returned MAC is a tagged `buffer`, allowing the underlying
	algorithm choice to evolve later.

	The current format is:

	- `"$m$" || raw_mac`

	```luau
	local hmac = require("@eryx/crypto/hmac")

	local mac = hmac.digest(buffer.fromstring("secret"), buffer.fromstring("hello"))
	assert(hmac.verify(buffer.fromstring("secret"), buffer.fromstring("hello"), mac))
	```
]=]

local hazmatHmac = require("@eryx/crypto/hazmat/hmac")

local hmac = {}

local MAC_TAG = "$m$"

local function taggedMac(key: buffer, data: buffer): buffer
	local ctx = hazmatHmac.new("sha256", key)
	ctx:update(data)
	return buffer.fromstring(MAC_TAG .. buffer.tostring(ctx:final()))
end

local function constantTimeEqual(left: buffer, right: buffer): boolean
	local leftLen = buffer.len(left)
	local rightLen = buffer.len(right)

	if leftLen ~= rightLen then
		return false
	end

	local diff = 0

	for i = 0, leftLen - 1 do
		diff = bit32.bor(diff, bit32.bxor(buffer.readu8(left, i), buffer.readu8(right, i)))
	end

	return diff == 0
end

--[=[
	Computes a tagged MAC over `data` using `key`.

	The current implementation uses a fixed HMAC choice internally and
	returns a tagged `buffer` so callers do not depend on that detail.

	@param key  Secret key.
	@param data Input data.
	@return buffer -- Tagged MAC.
]=]
function hmac.digest(key: buffer, data: buffer): buffer
	return taggedMac(key, data)
end

--[=[
	Verifies that `mac` matches `data` under `key`.

	Returns `true` if the MAC is well-formed, uses a supported tag, and
	matches the supplied key and data. Returns `false` for malformed or
	mismatched values.

	@param key  Secret key.
	@param data Input data.
	@param mac  Tagged MAC previously returned by [[digest]].
	@return boolean -- `true` if the MAC matches.
]=]
function hmac.verify(key: buffer, data: buffer, mac: buffer): boolean
	local macLen = buffer.len(mac)

	if macLen < #MAC_TAG then
		return false
	end

	if buffer.readstring(mac, 0, #MAC_TAG) ~= MAC_TAG then
		return false
	end

	return constantTimeEqual(taggedMac(key, data), mac)
end

return table.freeze(hmac)
