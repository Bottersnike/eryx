local _random = require("@eryx/crypto/hazmat/_crypto").random

local random = {}

--[=[
Generate a random number from 0 to `limit` using a secure RNG.
@param limit The upper bound for the random number
]=]
function random.integer(limit: number)
	if limit < 0 then
		error("random.integer generates only positive integers")
	end

	return _random.randint(limit)
end

--[=[
Securely select at random a single item from `options`
@param options The options to chose from
]=]
function random.choice<T>(options: { T }): T
	return _random.choice(options)
end

--[=[
Generate a random number of size `k` bits
@param k The number of bits the returned number should be. Integer from 1 to 53
]=]
function random.bits(k: number): number
	if k < 1 or k > 53 then
		error("argument #1 out of range for random.bits (1-53)")
	end
	if math.ceil(k) ~= k then
		error("argument #1 must be a whole number")
	end
	return _random.bits(k)
end

--[=[
Generate a buffer of `k` random bytes
@param k The number of bytes long the returned buffer should be
]=]
function random.bytes(k: number): buffer
	if k < 1 then
		error("argument #1 out of range for random.bytes (1-inf)")
	end
	if math.ceil(k) ~= k then
		error("argument #1 must be a whole number")
	end
	return _random.bytes(k)
end

--[=[
Generate a buffer of `k` random bytes, returned as a hex string
@param k The number of bytes long the returned buffer should be
]=]
function random.hex(k: number): string
	if k < 1 then
		error("argument #1 out of range for random.hex (1-inf)")
	end
	if math.ceil(k) ~= k then
		error("argument #1 must be a whole number")
	end
	return _random.hex(k)
end

return random
