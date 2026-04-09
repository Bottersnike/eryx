--[=[
	High-level message digests.

	This module provides a single digest API for application code that
	does not want to care which hash function is currently preferred.

	The returned digest is a tagged `buffer`, allowing the underlying
	algorithm to change in the future without making stored digests
	ambiguous.

	The current format is:

	- `"$h$" || raw_digest`

	```luau
	local hash = require("@eryx/crypto/hash")

	local digest = hash.digest(buffer.fromstring("hello"))
	assert(hash.verify(buffer.fromstring("hello"), digest))
	```
]=]

local hazmatHash = require("@eryx/crypto/hazmat/hash")

local hash = {}

local DIGEST_TAG = "$h$"

local function taggedDigest(data: buffer): buffer
	return buffer.fromstring(DIGEST_TAG .. buffer.tostring(hazmatHash.sha256(data)))
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
	Computes a tagged digest of `data`.

	The current implementation uses a fixed hash choice internally and
	returns a self-describing tagged `buffer` rather than exposing the
	algorithm at the call site.

	@param data Input data.
	@return buffer -- Tagged digest.
]=]
function hash.digest(data: buffer): buffer
	return taggedDigest(data)
end

--[=[
	Verifies that `digest` matches `data`.

	Returns `true` if the digest is well-formed, uses a supported tag, and
	matches the supplied data. Returns `false` for malformed or mismatched
	values.

	@param data   Input data to check.
	@param digest Tagged digest previously returned by [[digest]].
	@return boolean -- `true` if the digest matches.
]=]
function hash.verify(data: buffer, digest: buffer): boolean
	local digestLen = buffer.len(digest)

	if digestLen < #DIGEST_TAG then
		return false
	end

	if buffer.readstring(digest, 0, #DIGEST_TAG) ~= DIGEST_TAG then
		return false
	end

	return constantTimeEqual(taggedDigest(data), digest)
end

return table.freeze(hash)
