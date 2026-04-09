--[=[
	Optional schema primitives.
	Wraps child schemas so nil is accepted and optional defaults can be applied.
	Useful for patch/update payloads and backward-compatible input evolution.
]=]
local t = require("./types")

local schema = {}

type OptionalMetadata<T> = {
	child: t.Schema<T>,
	hasDefault: boolean,
	defaultValue: T?,
}

export type OptionalSchema<T> = t.Schema<T?> & {
	-- @ignore
	read _type: {
		read type: "optional",
		read metadata: OptionalMetadata<T>,
	},

	read default: (self: OptionalSchema<T>, value: T) -> OptionalSchema<T>,
}

--[=[
	Parse and validate an optional schema against an input value.
	If input is nil, parsing succeeds immediately and may emit a configured
	default value. Otherwise, the child schema is applied as normal.
	@param s Schema instance containing optional-child metadata.
	@param object Runtime value that may be nil or child-compatible.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseOptional<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "optional")
	local metadata = s._type.metadata :: OptionalMetadata<any>

	if object == nil then
		if metadata.hasDefault then
			return true, metadata.defaultValue
		end
		return true, nil :: any
	end

	return metadata.child:parse(object)
end

--[=[
	Validate input against an optional schema.
	Returns true for nil input and for any value accepted by the child schema.
	Defaults affect parse output only, not validation semantics.
	@param s Schema instance containing optional-child metadata.
	@param object Runtime value that may be nil or child-compatible.
	@return Whether the input satisfies the optional child schema.
]=]
local function validateOptional<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseOptional(s, object))
end

--[=[
	Attach a default value used when an optional input is nil.
	Defaults are materialized during parsing. This is especially useful for
	struct fields that should always exist in parsed output.
	@param value Default value returned when parsed input is nil.
	@return A new optional schema with default handling.
]=]
function schema.default<T>(self: OptionalSchema<T>, value: T): OptionalSchema<T>
	local metadata = self._type.metadata
	return schema.optional(metadata.child, {
		hasDefault = true,
		defaultValue = value,
	})
end

--[=[
	Create an optional schema around a child schema.
	Use this to model fields that may be absent. For predictable downstream
	shapes, pair with `:default(...)`.
	@reexportonly
	@param child Schema used when input is not nil.
	@param options Internal optional metadata, including default configuration.
	@return An optional schema.
]=]
function schema.optional<T>(child: t.Schema<T>, options: { hasDefault: boolean, defaultValue: T? }?): OptionalSchema<T>
	local hasDefault = false
	local defaultValue = nil
	if options then
		hasDefault = options.hasDefault
		defaultValue = options.defaultValue
	end

	return {
		_type = {
			inhabits = nil :: any,
			type = "optional",
			metadata = {
				child = child,
				hasDefault = hasDefault,
				defaultValue = defaultValue,
			},
		},
		validate = validateOptional,
		parse = parseOptional,
		default = schema.default,
	}
end

return table.freeze(schema)
