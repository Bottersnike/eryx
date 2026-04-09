--[=[
	Number schema primitives.
	Supports numeric validation rules like ranges, divisibility, and integer checks.
	Use numeric modifiers to encode business constraints directly in schema
	declarations instead of spreading checks through application code.
]=]
local t = require("./types")

local schema = {}

type NumberMetadata = {
	gt: number?,
	gte: number?,
	lt: number?,
	lte: number?,
	multipleOf: number?,
	int: boolean?,
}

export type NumberSchema = t.Schema<number> & {
	-- @ignore
	read _type: {
		read type: "number",
		read metadata: NumberMetadata,
	},

	read gt: (self: NumberSchema, val: number) -> NumberSchema,
	read gte: (self: NumberSchema, val: number) -> NumberSchema,
	read lt: (self: NumberSchema, val: number) -> NumberSchema,
	read lte: (self: NumberSchema, val: number) -> NumberSchema,
	read positive: (self: NumberSchema) -> NumberSchema,
	read nonnegative: (self: NumberSchema) -> NumberSchema,
	read negative: (self: NumberSchema) -> NumberSchema,
	read nonpositive: (self: NumberSchema) -> NumberSchema,
	read multipleOf: (self: NumberSchema, val: number) -> NumberSchema,
	read int: (self: NumberSchema) -> NumberSchema,
}

--[=[
	Clone and update number metadata for fluent modifier methods.
	This helper enables immutable-style chaining and conflict resolution
	(through optional field clearing) between related numeric constraints.
	@param patch Partial numeric metadata updates to apply.
	@param clears Metadata keys to clear before patch values are merged.
	@return A new number schema with merged metadata.
]=]
local function withMetadata(self: NumberSchema, patch: NumberMetadata, clears: { string }?): NumberSchema
	local metadata = table.clone(self._type.metadata)
	if clears then
		for _, key in clears do
			(metadata :: any)[key] = nil
		end
	end
	if patch.gt ~= nil then
		metadata.gt = patch.gt
	end
	if patch.gte ~= nil then
		metadata.gte = patch.gte
	end
	if patch.lt ~= nil then
		metadata.lt = patch.lt
	end
	if patch.lte ~= nil then
		metadata.lte = patch.lte
	end
	if patch.multipleOf ~= nil then
		metadata.multipleOf = patch.multipleOf
	end
	if patch.int ~= nil then
		metadata.int = patch.int
	end

	return schema.number(metadata)
end

--[=[
	Parse and validate a number schema against an input value.
	Validation is strict and sequential: type check first, then numeric
	constraints. Failures return readable constraint-specific messages.
	@param s Schema instance containing number constraints.
	@param object Runtime value supplied for numeric parsing.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseNumber<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "number")

	if typeof(object) ~= "number" then
		return false, `Expected number but got {typeof(object)}`
	end

	local metadata = s._type.metadata :: NumberMetadata
	if metadata.gt and object <= metadata.gt then
		return false, `Expected number > {metadata.gt} but got {object}`
	end
	if metadata.gte and object < metadata.gte then
		return false, `Expected number >= {metadata.gte} but got {object}`
	end
	if metadata.lt and object >= metadata.lt then
		return false, `Expected number < {metadata.lt} but got {object}`
	end
	if metadata.lte and object > metadata.lte then
		return false, `Expected number <= {metadata.lte} but got {object}`
	end
	if metadata.multipleOf and object % metadata.multipleOf ~= 0 then
		return false, `Expected number multiple of {metadata.multipleOf} but got {object}`
	end
	if metadata.int and object % 1 ~= 0 then
		return false, `Expected integer but got {object}`
	end

	return true, object
end
--[=[
	Validate input against a number schema.
	Uses the same logic as parse and returns only pass/fail.
	Use parse when you need detailed failure reasons.
	@param s Schema instance containing number constraints.
	@param object Runtime value supplied for numeric validation.
	@return Whether the input satisfies number constraints.
]=]
local function validateNumber<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseNumber(s, object))
end

--[=[
	Require the value to be greater than a threshold.
	Best used for exclusive lower bounds like IDs, sizes, or ratios.
	@param val Exclusive lower-bound value.
	@return A new number schema.
]=]
local function gt(self: NumberSchema, val: number): NumberSchema
	return withMetadata(self, { gt = val })
end

--[=[
	Require the value to be greater than or equal to a threshold.
	Best used for inclusive lower bounds such as zero-minimum counters.
	@param val Inclusive lower-bound value.
	@return A new number schema.
]=]
local function gte(self: NumberSchema, val: number): NumberSchema
	return withMetadata(self, { gte = val })
end

--[=[
	Require the value to be less than a threshold.
	Best used for exclusive upper limits where boundary values are invalid.
	@param val Exclusive upper-bound value.
	@return A new number schema.
]=]
local function lt(self: NumberSchema, val: number): NumberSchema
	return withMetadata(self, { lt = val })
end

--[=[
	Require the value to be less than or equal to a threshold.
	Best used for inclusive upper limits such as quota caps.
	@param val Inclusive upper-bound value.
	@return A new number schema.
]=]
local function lte(self: NumberSchema, val: number): NumberSchema
	return withMetadata(self, { lte = val })
end

--[=[
	Require the value to be strictly greater than zero.
	This convenience clears conflicting inclusive lower-bound metadata.
	@return A new number schema.
]=]
local function positive(self: NumberSchema): NumberSchema
	return withMetadata(self, { gt = 0 }, { "gte" })
end

--[=[
	Require the value to be zero or greater.
	This convenience clears conflicting exclusive lower-bound metadata.
	@return A new number schema.
]=]
local function nonnegative(self: NumberSchema): NumberSchema
	return withMetadata(self, { gte = 0 }, { "gt" })
end

--[=[
	Require the value to be strictly less than zero.
	This convenience clears conflicting inclusive upper-bound metadata.
	@return A new number schema.
]=]
local function negative(self: NumberSchema): NumberSchema
	return withMetadata(self, { lt = 0 }, { "lte" })
end

--[=[
	Require the value to be zero or less.
	This convenience clears conflicting exclusive upper-bound metadata.
	@return A new number schema.
]=]
local function nonpositive(self: NumberSchema): NumberSchema
	return withMetadata(self, { lte = 0 }, { "lt" })
end

--[=[
	Require the value to be an exact multiple of a non-zero factor.
	Useful for step sizes, quantization, and unit alignment checks.
	@param val Non-zero divisor used for multiple-of checks.
	@return A new number schema.
]=]
local function multipleOf(self: NumberSchema, val: number): NumberSchema
	assert(val ~= 0, "multipleOf cannot be 0")
	return withMetadata(self, { multipleOf = val })
end

--[=[
	Require the value to be an integer.
	This rule allows negative integers and zero; combine with sign/range rules
	for tighter domain constraints.
	@return A new number schema.
]=]
local function int(self: NumberSchema): NumberSchema
	return withMetadata(self, { int = true })
end

--[=[
	Create a number schema.
	By default, this schema accepts any runtime number and applies no extra
	constraints until modifiers are chained.
	@reexportonly
	@param metadata Internal metadata snapshot used when deriving chained schemas.
	@return A number schema.
]=]
function schema.number(metadata: NumberMetadata?): NumberSchema
	return {
		_type = {
			inhabits = nil :: any,
			type = "number",
			metadata = metadata or ({} :: NumberMetadata),
		},
		validate = validateNumber,
		parse = parseNumber,
		gt = gt,
		gte = gte,
		lt = lt,
		lte = lte,
		positive = positive,
		nonnegative = nonnegative,
		negative = negative,
		nonpositive = nonpositive,
		multipleOf = multipleOf,
		int = int,
	}
end

return schema
