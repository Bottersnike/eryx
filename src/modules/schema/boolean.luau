local t = require("./types")

local schema = {}

-- @ignore
export type BooleanSchema = t.Schema<boolean>

--[=[
	Parse and validate a boolean schema against an input value.
	This check is strict and does not coerce values like `0`/`1` or `"true"`.
	Failures return clear type mismatch messages.
	@param s Schema instance whose runtime rules are being applied.
	@param object Runtime value provided by the caller.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseBoolean<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "boolean")

	if typeof(object) ~= "boolean" then
		return false, `Expected boolean but got {typeof(object)}`
	end
	if s._type.metadata and object ~= s._type.metadata then
		return false, `Expected boolean literal {s._type.metadata} but got {object}`
	end
	return true, object
end

--[=[
	Validate input against a boolean schema.
	This uses the same runtime rules as `parse` and returns only pass/fail.
	Call this when you need a fast gate without error reporting.
	@param s Schema instance whose runtime rules are being applied.
	@param object Runtime value provided by the caller.
	@return Whether the input satisfies the schema.
]=]
local function validateBoolean<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseBoolean(s, object))
end

--[=[
	Create a schema that accepts boolean values.
	The returned schema is intentionally minimal and composes cleanly inside
	table, map, optional, and union schemas.
	@reexportonly
	@return A boolean schema.
]=]
function schema.boolean<T>(): BooleanSchema
	return {
		_type = {
			inhabits = nil :: any,
			type = "boolean",
		},
		validate = validateBoolean,
		parse = parseBoolean,
	}
end

return table.freeze(schema)
