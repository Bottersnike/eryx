--[=[
	Array schema primitives.
	Provides element validation plus array length constraints and non-empty checks.
	Use this for list-like tables where each element must satisfy the same schema.
]=]
local t = require("./types")

local schema = {}

type ArrayMetadata<T> = {
	of: t.Schema<T>,
	minLen: number?,
	maxLen: number?,
	length: number?,
}

export type ArraySchema<T> = t.Schema<{ T }> & {
	-- @ignore
	read _type: {
		read type: "array",
		read metadata: ArrayMetadata<T>,
	},

	read minLen: (self: ArraySchema<T>, len: number) -> ArraySchema<T>,
	read maxLen: (self: ArraySchema<T>, len: number) -> ArraySchema<T>,
	read length: (self: ArraySchema<T>, len: number) -> ArraySchema<T>,
	read nonempty: (self: ArraySchema<T>) -> ArraySchema<T>,
}

--[=[
	Clone and update array metadata for fluent modifier methods.
	This helper preserves immutability-style chaining by returning a new schema
	instead of mutating existing metadata in place.
	@param patch Partial array metadata updates to apply.
	@param clears Metadata keys to clear before patch values are merged.
	@return A new array schema with merged metadata.
]=]
local function withMetadata<T>(self: ArraySchema<T>, patch: ArrayMetadata<T>, clears: { string }?): ArraySchema<T>
	local metadata = table.clone(self._type.metadata)
	if clears then
		for _, key in clears do
			(metadata :: any)[key] = nil
		end
	end
	if patch.of ~= nil then
		metadata.of = patch.of
	end
	if patch.minLen ~= nil then
		metadata.minLen = patch.minLen
	end
	if patch.maxLen ~= nil then
		metadata.maxLen = patch.maxLen
	end
	if patch.length ~= nil then
		metadata.length = patch.length
	end

	return schema.array(metadata.of, metadata)
end

--[=[
	Parse and validate an array schema against an input value.
	Parsing enforces numeric keys, validates each element through the child
	schema, and then applies length constraints.
	@param s Schema instance containing child and length constraints.
	@param object Runtime value expected to be an array-like table.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseArray<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "array")

	if typeof(object) ~= "table" then
		return false, `Expected array but for {typeof(object)}`
	end
	local metadata = s._type.metadata :: ArrayMetadata<any>

	local result = {}
	local childSchema: t.Schema<any> = metadata.of
	local count = 0
	for k, v in object do
		if typeof(k) ~= "number" then
			return false, `Non-numeric key {k} in array`
		end
		local res, parsed = childSchema:parse(v :: any)
		if not res then
			local parsedS = parsed :: string
			return false, `#{k}{if parsedS:sub(1, 1) == "#" or parsedS:sub(1, 1) == "." then "" else ": "}{parsedS}`
		end
		result[k] = parsed
		count += 1
	end

	if metadata.minLen and count < metadata.minLen then
		return false, `Expected array length >= {metadata.minLen} but got {count}`
	end
	if metadata.maxLen and count > metadata.maxLen then
		return false, `Expected array length <= {metadata.maxLen} but got {count}`
	end
	if metadata.length and count ~= metadata.length then
		return false, `Expected array length {metadata.length} but got {count}`
	end

	return true, result
end

--[=[
	Validate input against an array schema.
	Returns true only when the same rules as `parse` would succeed.
	Use parse when you need nested error context or transformed children.
	@param s Schema instance containing child and length constraints.
	@param object Runtime value expected to be an array-like table.
	@return Whether the input satisfies array constraints.
]=]
local function validateArray<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseArray(s, object))
end

--[=[
	Set the minimum number of elements required in the array.
	Useful when empty input is syntactically valid but semantically incomplete.
	@param len Minimum allowed element count.
	@return A new array schema with minimum length validation.
]=]
local function minLen<T>(self: ArraySchema<T>, len: number): ArraySchema<T>
	assert(len >= 0, "minLen cannot be negative")
	return withMetadata(self, { of = self._type.metadata.of, minLen = len }, { "length" })
end

--[=[
	Set the maximum number of elements allowed in the array.
	Useful for bounded payloads and defensive resource control.
	@param len Maximum allowed element count.
	@return A new array schema with maximum length validation.
]=]
local function maxLen<T>(self: ArraySchema<T>, len: number): ArraySchema<T>
	assert(len >= 0, "maxLen cannot be negative")
	return withMetadata(self, { of = self._type.metadata.of, maxLen = len }, { "length" })
end

--[=[
	Require an exact element count for the array.
	Calling this clears min/max constraints to avoid contradictory metadata.
	@param len Exact required element count.
	@return A new array schema with exact length validation.
]=]
local function length<T>(self: ArraySchema<T>, len: number): ArraySchema<T>
	assert(len >= 0, "length cannot be negative")
	return withMetadata(self, { of = self._type.metadata.of, length = len }, { "minLen", "maxLen" })
end

--[=[
	Require the array to contain at least one element.
	This is a semantic convenience equivalent to `minLen(1)`.
	@return A new array schema with non-empty validation.
]=]
local function nonempty<T>(self: ArraySchema<T>): ArraySchema<T>
	return withMetadata(self, { of = self._type.metadata.of, minLen = 1 }, { "length" })
end

--[=[
	Create an array schema for values validated by a child schema.
	Child schemas can be primitive or composed; nested errors are path-prefixed
	using array indices (for example `#2`).
	@reexportonly
	@param of Child schema applied to each numeric-indexed element.
	@param metadata Internal metadata snapshot used for chained schema derivation.
	@return An array schema.
]=]
function schema.array<T>(of: t.Schema<T>, metadata: ArrayMetadata<T>?): ArraySchema<T>
	local md: ArrayMetadata<T> = metadata or {
		of = of,
		minLen = nil,
		maxLen = nil,
		length = nil,
	}
	return {
		_type = {
			inhabits = nil :: any,
			type = "array",
			metadata = md,
		},
		validate = validateArray,
		parse = parseArray,
		minLen = minLen,
		maxLen = maxLen,
		length = length,
		nonempty = nonempty,
	}
end

return table.freeze(schema)
