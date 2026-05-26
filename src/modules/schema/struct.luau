--[=[
	Struct (table) schema primitives.
	Supports field validation, unknown-key policies, schema transforms, and shape composition.
	This library is the primary tool for object-like contracts where each key
	has its own schema and unknown-key behavior must be explicit.
]=]
local t = require("./types")
local optional = require("./optional")

local schema = {}

type UnknownKeysMode = "strict" | "strip" | "passthrough"

type TableMetadata = {
	fields: { [string]: t.Schema<any> },
	unknownKeys: UnknownKeysMode,
	catchall: t.Schema<any>?,
	readonly: boolean?,
}

type TableOptions = {
	unknownKeys: UnknownKeysMode?,
	catchall: t.Schema<any>?,
	readonly: boolean?,
}

type function mergeTables(first: type, second: type): type -- (T={}, U={}) -> T+U
	local new = types.newtable()
	for k, v in first:properties() do
		if v.read == v.write then
			new:setproperty(k, v.read)
		else
			if v.read then
				new:setreadproperty(k, v.read)
			end
			if v.write then
				new:setreadproperty(k, v.write)
			end
		end
	end
	for k, v in second:properties() do
		if v.read == v.write then
			new:setproperty(k, v.read)
		else
			if v.read then
				new:setreadproperty(k, v.read)
			end
			if v.write then
				new:setreadproperty(k, v.write)
			end
		end
	end
	return new
end

type function extractTableSchema(ty: type): type -- (Schema<T={}>) -> (T)
	if ty:is("intersection") then
		ty = ty:components()[1]
	end

	if ty and ty:is("table") then
		local _type = ty:readproperty(types.singleton("_type"))
		if _type and _type:is("table") then
			local inhabits = _type:readproperty(types.singleton("inhabits"))
			if inhabits then
				if inhabits.tag ~= "table" then
					error(`Expected table but got {inhabits.tag}`)
				end
				return inhabits
			end
		end
	end
	error(`Expected Schema but got {ty.tag}`)
end

-- @ignore
export type TableSchema<T> = t.Schema<T> & {
	read _type: {
		read type: "table",
		read metadata: TableMetadata,
	},
}

--[=[
	Clone field schemas from one table into a new table.
	This is used by shape transforms (`pick`, `omit`, `extend`) to preserve
	immutability-style behavior while reusing field definitions.
	@param fields Field map where each key points to a child schema.
	@return A shallow copy of field schema definitions.
]=]
local function cloneFields(fields: { [string]: t.Schema<any> }): { [string]: t.Schema<any> }
	local out = {}
	for k, v in fields do
		out[k] = v
	end
	return out
end

--[=[
	Normalize old/new metadata formats into the current table metadata shape.
	This keeps parsing resilient across metadata layout changes and schema
	instances created by older helper paths.
	@param metadata Runtime metadata table to normalize into the canonical shape.
	@return A normalized metadata table.
]=]
local function normalizeMetadata(metadata: any): TableMetadata
	if metadata.fields then
		return metadata
	end
	return {
		fields = metadata,
		unknownKeys = "strict",
		catchall = nil,
		readonly = nil,
	}
end

--[=[
	Clone and update table metadata for fluent transform helpers.
	All table transformation helpers route through this to ensure consistent
	policy propagation for unknown-key handling, catchalls, and readonly flags.
	@param patch Partial table-metadata updates to apply.
	@return A new table schema with merged metadata.
]=]
local function withMetadata(struct: TableSchema<any>, patch: TableOptions): TableSchema<any>
	local md = normalizeMetadata(struct._type.metadata)
	return schema.table(md.fields, {
		unknownKeys = patch.unknownKeys or md.unknownKeys,
		catchall = if patch.catchall ~= nil then patch.catchall else md.catchall,
		readonly = if patch.readonly ~= nil then patch.readonly else md.readonly,
	})
end

--[=[
	Check whether a schema should be treated as optional in struct field checks.
	A union is treated as optional when at least one branch is optional.
	This allows expressive patterns like `anyOf(optional(string), number)`.
	@param schema_ Candidate field schema being inspected for optional semantics.
	@return Whether the schema is optional (directly or via a union branch).
]=]
local function isOptional<T>(schema_: t.Schema<T>): boolean
	if schema_._type.type == "optional" then
		return true
	end

	if schema_._type.type == "union" then
		for k, v in schema_._type.metadata do
			if k == "n" then
				continue
			end
			if isOptional(v) then
				return true
			end
		end
	end

	return false
end

--[=[
	Remove one layer of optional wrapper when possible.
	Used by `required(...)` so callers can convert optional fields back into
	required fields without rebuilding each child manually.
	@param child Field schema that may be optional-wrapped.
	@return The unwrapped child schema when optional metadata is available.
]=]
local function unwrapOptional(child: t.Schema<any>): t.Schema<any>
	if child._type.type ~= "optional" then
		return child
	end
	local metadata = child._type.metadata
	if typeof(metadata) == "table" and metadata.child then
		return metadata.child :: any
	end
	if typeof(metadata) == "table" and metadata._type then
		return metadata :: t.Schema<any>
	end
	return child
end

--[=[
	Extract a default value from an optional schema if one exists.
	This is used at parse time to materialize missing optional fields into
	concrete values for easier downstream consumption.
	@param schema_ Candidate schema inspected for optional defaults.
	@return Whether a default exists and the default value.
]=]
local function getOptionalDefault<T>(schema_: t.Schema<T>): (boolean, any)
	if schema_._type.type ~= "optional" then
		return false, nil
	end
	local metadata = schema_._type.metadata
	if typeof(metadata) ~= "table" then
		return false, nil
	end
	if metadata.hasDefault then
		return true, metadata.defaultValue
	end
	return false, nil
end

--[=[
	Parse and validate a table schema against an input value.
	Known fields are validated by their child schemas. Unknown-key behavior is
	determined by policy (`strict`, `strip`, `passthrough`) and optional catchall.
	Missing required fields are reported with field-path error messages.
	@param s Schema instance containing field definitions and table policies.
	@param object Runtime value expected to be an object-like table.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseTable<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "table")

	if typeof(object) ~= "table" then
		return false, `Expected table but got {typeof(object)}`
	end

	local metadata = normalizeMetadata(s._type.metadata)
	local fields = metadata.fields
	local result = {}

	for k, v in object do
		local fieldSchema = fields[k]
		if fieldSchema then
			local res, parsed = fieldSchema:parse(v :: any)
			if not res then
				return false, `.{k}{if parsed:sub(1, 1) == "#" or parsed:sub(1, 1) == "." then "" else ": "}{parsed}`
			end
			result[k] = parsed
			continue
		end

		if metadata.catchall then
			local ok, parsed = metadata.catchall:parse(v)
			if not ok then
				return false, `.{k}{if parsed:sub(1, 1) == "#" or parsed:sub(1, 1) == "." then "" else ": "}{parsed}`
			end
			if metadata.unknownKeys ~= "strip" then
				result[k] = parsed
			end
		elseif metadata.unknownKeys == "strict" then
			return false, `Unexpected key {k} in table`
		elseif metadata.unknownKeys == "passthrough" then
			result[k] = v
		end
	end

	for k, v in fields do
		if result[k] == nil then
			if not isOptional(v) then
				return false, `.{k}: Field missing`
			end
			local hasDefault, defaultValue = getOptionalDefault(v)
			if hasDefault then
				result[k] = defaultValue
			end
		end
	end

	if metadata.readonly then
		table.freeze(result)
	end

	return true, result
end

--[=[
	Validate input against a table schema.
	Returns only pass/fail. Prefer parse when you need transformed data,
	default materialization, or error-path diagnostics.
	@param s Schema instance containing field definitions and table policies.
	@param object Runtime value expected to be an object-like table.
	@return Whether the input satisfies the table schema.
]=]
local function validateTable<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	return (parseTable(s, object))
end

--[=[
	Convert a list of keys into a lookup set.
	Internal helper used by `pick`, `omit`, and keyed `required`.
	@param keys Field names to convert into a lookup set.
	@return A key-set table for quick membership checks.
]=]
local function collectKeySet(keys: { string }): { [string]: boolean }
	local out = {}
	for _, key in keys do
		out[key] = true
	end
	return out
end

--[=[
	Set unknown-key handling to strict mode.
	Unknown keys fail parsing.
	Use strict mode for closed contracts, API request validation, and places
	where extra fields likely indicate caller errors.
	@return A new table schema in strict mode.
]=]
function schema.strict<T>(struct: TableSchema<T>): TableSchema<T>
	return withMetadata(struct, { unknownKeys = "strict" }) :: any
end

--[=[
	Set unknown-key handling to strip mode.
	Unknown keys are accepted but removed from parsed output.
	Use strip mode at permissive boundaries when forward compatibility is
	desired but unknown fields should not propagate internally.
	@return A new table schema in strip mode.
]=]
function schema.strip<T>(struct: TableSchema<T>): TableSchema<T>
	return withMetadata(struct, { unknownKeys = "strip" }) :: any
end

--[=[
	Set unknown-key handling to passthrough mode.
	Unknown keys are accepted and retained in parsed output.
	Use passthrough mode when extension fields are expected and should remain
	available to callers or downstream systems.
	@return A new table schema in passthrough mode.
]=]
function schema.passthrough<T>(struct: TableSchema<T>): TableSchema<T>
	return withMetadata(struct, { unknownKeys = "passthrough" }) :: any
end

--[=[
	Validate unknown keys using a catchall schema.
	Catchall applies schema validation to keys not listed in `fields`.
	Combine with strip/passthrough depending on whether validated extras should
	be dropped or retained in parsed output.
	@param child Schema applied to unknown keys when catchall is enabled.
	@return A new table schema with catchall validation.
]=]
function schema.catchall<T>(struct: TableSchema<T>, child: t.Schema<any>): TableSchema<T>
	return withMetadata(struct, { catchall = child }) :: any
end

--[=[
	Make all fields optional.
	Ideal for PATCH-style inputs and partial update payloads.
	Existing optional fields remain optional; required fields are wrapped.
	@return A new table schema with optionalized fields.
]=]
function schema.partial<T>(struct: TableSchema<T>): TableSchema<any>
	local md = normalizeMetadata(struct._type.metadata)
	local fields = cloneFields(md.fields)
	for k, v in fields do
		if not isOptional(v) then
			fields[k] = optional.optional(v)
		end
	end
	return schema.table(fields, {
		unknownKeys = md.unknownKeys,
		catchall = md.catchall,
		readonly = md.readonly,
	}) :: any
end

--[=[
	Keep only the selected field keys.
	Useful for endpoint/view-specific projections built from a shared base shape.
	@param keys Field names to keep in the resulting schema.
	@return A new table schema containing picked fields.
]=]
function schema.pick<T>(struct: TableSchema<T>, keys: { string }): TableSchema<any>
	local md = normalizeMetadata(struct._type.metadata)
	local allow = collectKeySet(keys)
	local fields = {}
	for k, v in md.fields do
		if allow[k] then
			fields[k] = v
		end
	end
	return schema.table(fields, {
		unknownKeys = md.unknownKeys,
		catchall = md.catchall,
		readonly = md.readonly,
	}) :: any
end

--[=[
	Drop the selected field keys.
	Useful for deriving public-facing shapes from internal objects.
	@param keys Field names to remove from the resulting schema.
	@return A new table schema without omitted fields.
]=]
function schema.omit<T>(struct: TableSchema<T>, keys: { string }): TableSchema<any>
	local md = normalizeMetadata(struct._type.metadata)
	local reject = collectKeySet(keys)
	local fields = {}
	for k, v in md.fields do
		if not reject[k] then
			fields[k] = v
		end
	end
	return schema.table(fields, {
		unknownKeys = md.unknownKeys,
		catchall = md.catchall,
		readonly = md.readonly,
	}) :: any
end

--[=[
	Make fields required by unwrapping optional wrappers.
	If keys are omitted, all fields are made required.
	Use keyed required mode to tighten selected fields while preserving the
	rest of a partial schema.
	@param keys Optional subset of fields to force as required.
	@return A new table schema with required fields.
]=]
function schema.required<T>(struct: TableSchema<T>, keys: { string }?): TableSchema<any>
	local md = normalizeMetadata(struct._type.metadata)
	local target = if keys then collectKeySet(keys) else nil
	local fields = cloneFields(md.fields)

	for k, v in fields do
		if target == nil or target[k] then
			fields[k] = unwrapOptional(v)
		end
	end

	return schema.table(fields, {
		unknownKeys = md.unknownKeys,
		catchall = md.catchall,
		readonly = md.readonly,
	}) :: any
end

--[=[
	Freeze parsed output tables so downstream code cannot mutate them.
	Useful when parsed data should be treated as immutable configuration or
	value objects.
	@return A new table schema that freezes parsed results.
]=]
function schema.readonly<T>(struct: TableSchema<T>): TableSchema<T>
	return withMetadata(struct, { readonly = true }) :: any
end

--[=[
	Alias for readonly table output.
	Provided for naming parity with libraries that expose `freeze`.
	@return A new table schema that freezes parsed results.
]=]
function schema.freeze<T>(struct: TableSchema<T>): TableSchema<T>
	return schema.readonly(struct)
end

--[=[
	Merge fields from two table schemas.
	When keys overlap, the second schema's field definition wins.
	The resulting schema keeps policy metadata from the first schema.
	Use this to build layered shapes from reusable fragments.
	@param first Left/base table schema whose policies are retained.
	@param second Right/extension table schema whose fields are merged in.
	@return A merged table schema.
]=]
function schema.extend<T, U>(first: TableSchema<T>, second: U): TableSchema<mergeTables<T, extractTableSchema<U>>>
	local first_ = first :: t.Schema<any>
	local second_ = second :: t.Schema<any>

	assert(first_._type.type == "table")
	assert(second_._type.type == "table")

	local md = normalizeMetadata(first_._type.metadata)
	local secondMd = normalizeMetadata(second_._type.metadata)
	local merged = cloneFields(md.fields)
	for k, v in secondMd.fields do
		merged[k] = v
	end

	return schema.table(merged, {
		unknownKeys = md.unknownKeys,
		catchall = md.catchall,
		readonly = md.readonly,
	}) :: any
end

--[=[
	Create a table schema from field definitions.
	Each key maps to a child schema. By default, unknown keys are rejected
	unless policy is changed via struct helpers.
	@reexportonly
	@param fields Field map where each key points to a child schema.
	@param options Optional unknown-key/catchall/readonly configuration.
	@return A table schema.
]=]
function schema.table<T>(fields: T & { [string]: t.Schema<any> }, options: TableOptions?): TableSchema<t.stripIndexer<T>>
	local metadata = {
		fields = fields :: { [string]: t.Schema<any> },
		unknownKeys = if options and options.unknownKeys then options.unknownKeys else "strict",
		catchall = if options then options.catchall else nil,
		readonly = if options then options.readonly else nil,
	}

	return {
		_type = {
			inhabits = nil :: any,
			type = "table",
			metadata = metadata,
		},
		validate = validateTable,
		parse = parseTable,
	}
end

return table.freeze(schema)
