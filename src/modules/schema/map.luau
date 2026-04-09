local t = require("./types")
local literal = require("./literal")

local schema = {}

type MapMetadata = { t.Schema<any> }

-- @ignore
export type MapSchema<K, V> = t.Schema<{ [K]: V }> & {
	read _type: {
		read type: "map",
		read metadata: MapMetadata,
	},
}

--[=[
	Parse and validate a map schema against an input value.
	Each key is validated first, then each value. Parsed keys and values are
	used in the output table, so transforms can affect both sides.
	@param s Schema instance containing key/value child schemas.
	@param object Runtime table to parse as a validated dictionary.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseMap<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "map")

	if typeof(object) ~= "table" then
		return false, `Expected map but for {typeof(object)}`
	end

	local mapped = {}
	local keySchema = s._type.metadata[1] :: t.Schema<any>
	local valueSchema = s._type.metadata[2] :: t.Schema<any>

	for k, v in object do
		local ok, keyOrErr = keySchema:parse(k)
		if not ok then
			return false, `Map key {k} invalid: {keyOrErr}`
		end
		local parsedKey = keyOrErr

		local okValue, valueOrErr = valueSchema:parse(v)
		if not okValue then
			return false, `Map value for {k} invalid: {valueOrErr}`
		end
		local parsedValue = valueOrErr

		mapped[parsedKey] = parsedValue
	end

	return true, mapped
end

--[=[
	Validate input against a map schema.
	Uses the same key/value traversal as `parse` but returns only pass/fail.
	Use this when you do not need transformed dictionary output.
	@param s Schema instance containing key/value child schemas.
	@param object Runtime table to validate as a dictionary.
	@return Whether the input satisfies key and value schemas.
]=]
local function validateMap<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseMap(s, object))
end

--[=[
	Create a map schema from key and value schemas (or literal shorthands).
	Literal key/value inputs are promoted automatically, allowing concise forms
	like `schema.map("status", "ok")` when strict constants are desired.
	@reexportonly
	@param key Schema (or literal shorthand) used to validate map keys.
	@param value Schema (or literal shorthand) used to validate map values.
	@return A map schema.
]=]
function schema.map<T, U>(
	key: T | t.Schema<any>,
	value: U | t.Schema<any>
): MapSchema<t.extractSchemaType<T>, t.extractSchemaType<U>>
	local keySchema = key
	if typeof(keySchema) ~= "table" or not (keySchema :: any)._type then
		keySchema = literal.literal(key :: any)
	end

	local valueSchema = value
	if typeof(valueSchema) ~= "table" or not (valueSchema :: any)._type then
		valueSchema = literal.literal(value :: any)
	end

	return {
		_type = {
			inhabits = nil :: any,
			type = "map",
			metadata = { keySchema :: t.Schema<any>, valueSchema :: t.Schema<any> },
		},
		validate = validateMap,
		parse = parseMap,
	}
end

return table.freeze(schema)
