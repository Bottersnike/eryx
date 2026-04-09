local t = require("./types")

local schema = {}

-- @ignore
export type LiteralSchema<T> = t.Schema<T> & {
	read _type: { read type: "literal" },
}

--[=[
	Parse and validate a literal schema against an input value.
	The parser first checks runtime type equality, then exact value equality.
	Both checks are strict: no coercion and no fuzzy matching.
	Use this when you need explicit protocol-level contracts.
	@param s Schema instance whose runtime rules are being applied.
	@param object Runtime value provided by the caller.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseLiteral<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "literal")

	if typeof(object) ~= typeof(s._type.metadata) then
		return false, `Expected {typeof(s._type.metadata)} but got {typeof(object)}`
	end
	if s._type.metadata and object ~= s._type.metadata then
		return false, `Expected literal "{s._type.metadata}" but got "{object}"`
	end
	return true, object
end
--[=[
	Validate input against a literal schema.
	This delegates to the same logic as `parse`, but only returns a boolean.
	Prefer `parse` if you want diagnostics on failure.
	@param s Schema instance whose runtime rules are being applied.
	@param object Runtime value provided by the caller.
	@return Whether the input satisfies the schema.
]=]
local function validateLiteral<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseLiteral(s, object))
end

--[=[
	Create a schema that matches exactly one literal value.
	Typical usage is in union branches and tagged object fields, for example
	`kind = schema.literal("user")`.
	@reexportonly
	@param literal Exact value this schema must match.
	@return A literal schema.
]=]
function schema.literal<T>(
	literal: (
		(T & (string | number | boolean)) | "__MAGIC_USED_FOR_IMPLICIT_LITERAL_VALUES_NARROWING__"
	)?
	-- ): LiteralSchema<t.extractLiteralFromMagicUnion<T, any>>
): LiteralSchema<T>
	return {
		_type = {
			inhabits = nil :: any,
			type = "literal",
			metadata = literal,
		},
		validate = validateLiteral,
		parse = parseLiteral,
		match = function(self, pattern)
			return self
		end,
	}
end

return table.freeze(schema)
