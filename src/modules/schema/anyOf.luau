local t = require("./types")
local literal = require("./literal")

local schema = {}

-- @ignore
export type UnionSchema<T> = t.Schema<T>

--[=[
	Parse and validate a union schema against an input value.
	Branches are attempted in declaration order, and parsing stops at the first
	successful branch. If no branch matches, a generic union failure is returned.
	@param s Schema instance whose union branches are being evaluated.
	@param object Runtime value tested against each union branch.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseAnyOf<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "union")

	for k, child in s._type.metadata do
		if k == "n" then
			continue
		end
		local ok, parsed = (child :: t.Schema<any>):parse(object)
		if ok then
			return true, parsed
		end
	end

	return false, "Failed to match any schemas"
end

--[=[
	Validate input against a union schema.
	Uses the same branch traversal as `parse`, but returns only a boolean.
	This is useful for quick guards without collecting error context.
	@param s Schema instance whose union branches are being evaluated.
	@param object Runtime value tested against each union branch.
	@return Whether the input satisfies at least one branch.
]=]
local function validateAnyOf<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseAnyOf(s, object))
end

--[=[
	Create a union schema that succeeds when any child schema matches.
	Raw literal values are promoted to literal schemas.
	This allows concise declarations like `schema.anyOf("a", "b", 3)`.
	At least one branch is required.
	@reexportonly
	@return A union schema.
]=]
function schema.anyOf<T>(...: T | t.Schema<any>): UnionSchema<t.extractChildrenFromAnyOfUnion<T>>
	local packed = table.pack(...)
	assert(packed.n > 0, "anyOf requires at least one schema")
	for i = 1, packed.n do
		local candidate = packed[i]
		if typeof(candidate) == "table" and candidate._type then
			continue
		end
		packed[i] = literal.literal(candidate :: any)
	end

	return {
		_type = {
			inhabits = nil :: any,
			type = "union",
			metadata = packed,
		},
		validate = validateAnyOf,
		parse = parseAnyOf,
	}
end

return table.freeze(schema)
