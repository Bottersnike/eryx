--[=[
	String schema primitives.
	Supports string validation rules and post-parse string transformations.
	Use validators for acceptance criteria and mutators for canonical output.
]=]
local t = require("./types")

local schema = {}

type StringMutator = "trimWhitespace" | "toUpperCase" | "toLowerCase"

type StringMetadata = {
	maxLen: number?,
	minLen: number?,
	length: number?,
	luaPatterns: { string },
	regexPatterns: { string },
	startsWith: { string },
	endsWith: { string },
	includes: { string },
	isUpperCase: boolean?,
	isLowerCase: boolean?,
	mutators: { StringMutator },
}

type StringMetadataPatch = {
	maxLen: number?,
	minLen: number?,
	length: number?,
	addLuaPattern: string?,
	addRegexPattern: string?,
	addStartsWith: string?,
	addEndsWith: string?,
	addIncludes: string?,
	isUpperCase: boolean?,
	isLowerCase: boolean?,
	addMutator: StringMutator?,
}

export type StringSchema = t.Schema<string> & {
	-- @ignore
	read _type: {
		read type: "string",
		read metadata: StringMetadata,
	},

	-- Validators
	read maxLen: (self: StringSchema, len: number) -> StringSchema,
	read minLen: (self: StringSchema, len: number) -> StringSchema,
	read length: (self: StringSchema, len: number) -> StringSchema,
	read match: (self: StringSchema, pattern: string) -> StringSchema, -- Lua pattern
	read regex: (self: StringSchema, pattern: string) -> StringSchema, -- @eryx/regex pattern
	read startsWith: (self: StringSchema, pattern: string) -> StringSchema,
	read endsWith: (self: StringSchema, pattern: string) -> StringSchema,
	read includes: (self: StringSchema, pattern: string) -> StringSchema,
	read isUpperCase: (self: StringSchema) -> StringSchema,
	read isLowerCase: (self: StringSchema) -> StringSchema,

	-- Post-parse mutators
	read trimWhitespace: (self: StringSchema) -> StringSchema,
	read toUpperCase: (self: StringSchema) -> StringSchema,
	read toLowerCase: (self: StringSchema) -> StringSchema,
}

--[=[
	Clone an array-like metadata field.
	This keeps metadata snapshots isolated across chained schema modifiers.
	@param list Source list to copy into a new metadata table.
	@return A shallow-copied list.
]=]
local function cloneList<T>(list: { T }): { T }
	local out = {}
	for _, v in list do
		table.insert(out, v)
	end
	return out
end

--[=[
	Clone full string metadata so chained modifiers return immutable schema snapshots.
	Without this copy, chained calls would share mutable state and become
	order-sensitive in unexpected ways.
	@param metadata Existing string metadata to duplicate.
	@return A copied metadata table.
]=]
local function cloneMetadata(metadata: StringMetadata): StringMetadata
	return {
		maxLen = metadata.maxLen,
		minLen = metadata.minLen,
		length = metadata.length,
		luaPatterns = cloneList(metadata.luaPatterns),
		regexPatterns = cloneList(metadata.regexPatterns),
		startsWith = cloneList(metadata.startsWith),
		endsWith = cloneList(metadata.endsWith),
		includes = cloneList(metadata.includes),
		isUpperCase = metadata.isUpperCase,
		isLowerCase = metadata.isLowerCase,
		mutators = cloneList(metadata.mutators),
	}
end

--[=[
	Create default metadata for a new string schema.
	All validators are disabled and no mutators are queued in this baseline.
	@return Metadata with no active validators or mutators.
]=]
local function defaultMetadata(): StringMetadata
	return {
		maxLen = nil,
		minLen = nil,
		length = nil,
		luaPatterns = {},
		regexPatterns = {},
		startsWith = {},
		endsWith = {},
		includes = {},
		isUpperCase = nil,
		isLowerCase = nil,
		mutators = {},
	}
end

--[=[
	Clone and update string metadata for fluent modifier methods.
	Patch-style fields are merged and optional clears remove conflicting rules.
	This powers immutable-style chaining semantics.
	@param patch Partial string metadata updates to apply.
	@param clears Metadata keys to clear before patch values are merged.
	@return A new string schema with merged metadata.
]=]
local function withMetadata(self: StringSchema, patch: StringMetadataPatch, clears: { string }?): StringSchema
	local metadata = cloneMetadata(self._type.metadata)
	if clears then
		for _, key in clears do
			(metadata :: any)[key] = nil
		end
	end

	if patch.maxLen ~= nil then
		metadata.maxLen = patch.maxLen
	end
	if patch.minLen ~= nil then
		metadata.minLen = patch.minLen
	end
	if patch.length ~= nil then
		metadata.length = patch.length
	end
	if patch.addLuaPattern ~= nil then
		table.insert(metadata.luaPatterns, patch.addLuaPattern)
	end
	if patch.addRegexPattern ~= nil then
		table.insert(metadata.regexPatterns, patch.addRegexPattern)
	end
	if patch.addStartsWith ~= nil then
		table.insert(metadata.startsWith, patch.addStartsWith)
	end
	if patch.addEndsWith ~= nil then
		table.insert(metadata.endsWith, patch.addEndsWith)
	end
	if patch.addIncludes ~= nil then
		table.insert(metadata.includes, patch.addIncludes)
	end
	if patch.isUpperCase ~= nil then
		metadata.isUpperCase = patch.isUpperCase
	end
	if patch.isLowerCase ~= nil then
		metadata.isLowerCase = patch.isLowerCase
	end
	if patch.addMutator ~= nil then
		table.insert(metadata.mutators, patch.addMutator)
	end

	return schema.string(metadata)
end

--[=[
	Parse and validate a string schema against an input value.
	Validation runs before mutators. When all rules pass, mutators execute in
	the order they were added, producing the final parsed output.
	@param s Schema instance containing string validators and mutators.
	@param object Runtime value supplied for parsing.
	@return Whether parsing succeeded and either parsed value or error message.
]=]
local function parseString<T>(s: t.Schema<T>, object: any): (boolean, T | string)
	assert(s._type.type == "string")

	if typeof(object) ~= "string" then
		return false, `Expected string but got {typeof(object)}`
	end

	local metadata = s._type.metadata :: StringMetadata
	local len = #object

	if metadata.maxLen and len > metadata.maxLen then
		return false, `Expected string length <= {metadata.maxLen} but got {len}`
	end
	if metadata.minLen and len < metadata.minLen then
		return false, `Expected string length >= {metadata.minLen} but got {len}`
	end
	if metadata.length and len ~= metadata.length then
		return false, `Expected string length {metadata.length} but got {len}`
	end

	for _, pattern in metadata.luaPatterns do
		if not string.match(object, pattern) then
			return false, `Expected string to match Lua pattern "{pattern}"`
		end
	end

	if #metadata.regexPatterns > 0 then
		local okLoad, regexOrError = pcall(require, "@eryx/regex")
		if not okLoad then
			return false, `Regex validator unavailable: {regexOrError}`
		end

		for _, pattern in metadata.regexPatterns do
			local okMatch, isMatchOrError = pcall(regexOrError.isMatch, pattern, object)
			if not okMatch then
				return false, `Invalid regex pattern "{pattern}": {isMatchOrError}`
			end
			if not isMatchOrError then
				return false, `Expected string to match regex "{pattern}"`
			end
		end
	end

	for _, prefix in metadata.startsWith do
		if object:sub(1, #prefix) ~= prefix then
			return false, `Expected string to start with "{prefix}"`
		end
	end

	for _, suffix in metadata.endsWith do
		if suffix == "" then
			continue
		end
		if object:sub(-#suffix) ~= suffix then
			return false, `Expected string to end with "{suffix}"`
		end
	end

	for _, part in metadata.includes do
		if not string.find(object, part, 1, true) then
			return false, `Expected string to include "{part}"`
		end
	end

	if metadata.isUpperCase and object ~= string.upper(object) then
		return false, "Expected uppercase string"
	end
	if metadata.isLowerCase and object ~= string.lower(object) then
		return false, "Expected lowercase string"
	end

	local parsed = object
	for _, mutator in metadata.mutators do
		if mutator == "trimWhitespace" then
			parsed = parsed:gsub("^%s*(.-)%s*$", "%1")
		elseif mutator == "toUpperCase" then
			parsed = string.upper(parsed)
		elseif mutator == "toLowerCase" then
			parsed = string.lower(parsed)
		end
	end

	return true, parsed :: any
end

--[=[
	Validate input against a string schema.
	Returns pass/fail using the same validation logic as parse, but does not
	expose transformed output or failure diagnostics.
	@param s Schema instance containing string validators.
	@param object Runtime value supplied for validation.
	@return Whether the input satisfies string constraints.
]=]
local function validateString<T>(s: t.Schema<T>, object: t.anyNotNil<>): boolean
	-- TODO: More lightweight, to avoid object construction
	return (parseString(s, object))
end

--[=[
	Set maximum allowed string length.
	Use this for upper-bound checks such as usernames, labels, and short codes.
	@param len Maximum allowed string length.
	@return A new string schema.
]=]
local function maxLen(self: StringSchema, len: number): StringSchema
	assert(len >= 0, "maxLen cannot be negative")
	return withMetadata(self, { maxLen = len }, { "length" })
end

--[=[
	Set minimum required string length.
	Use this to reject empty or underspecified string values.
	@param len Minimum required string length.
	@return A new string schema.
]=]
local function minLen(self: StringSchema, len: number): StringSchema
	assert(len >= 0, "minLen cannot be negative")
	return withMetadata(self, { minLen = len }, { "length" })
end

--[=[
	Require exact string length.
	This clears min/max constraints to avoid conflicting length metadata.
	@param len Exact required string length.
	@return A new string schema.
]=]
local function length(self: StringSchema, len: number): StringSchema
	assert(len >= 0, "length cannot be negative")
	return withMetadata(self, { length = len }, { "minLen", "maxLen" })
end

--[=[
	Add a Lua pattern that the string must match.
	Use this when standard Lua pattern syntax is sufficient and lightweight.
	@param pattern Lua pattern string that must match input.
	@return A new string schema.
]=]
local function match(self: StringSchema, pattern: string): StringSchema
	return withMetadata(self, { addLuaPattern = pattern })
end

--[=[
	Add a regex pattern that the string must match when regex support is available.
	Prefer this for richer pattern matching semantics beyond Lua patterns.
	If regex support is unavailable at runtime, parsing reports that explicitly.
	@param pattern Regex pattern string evaluated by the regex module.
	@return A new string schema.
]=]
local function regex(self: StringSchema, pattern: string): StringSchema
	return withMetadata(self, { addRegexPattern = pattern })
end

--[=[
	Require the string to start with a prefix.
	Useful for namespacing, URL fragments, and protocol marker checks.
	@param pattern Required starting substring.
	@return A new string schema.
]=]
local function startsWith(self: StringSchema, pattern: string): StringSchema
	return withMetadata(self, { addStartsWith = pattern })
end

--[=[
	Require the string to end with a suffix.
	Useful for extension-like checks and fixed trailing marker rules.
	@param pattern Required ending substring.
	@return A new string schema.
]=]
local function endsWith(self: StringSchema, pattern: string): StringSchema
	return withMetadata(self, { addEndsWith = pattern })
end

--[=[
	Require the string to include a substring.
	This uses plain substring search (not pattern mode), which is predictable
	for literal containment checks.
	@param pattern Required contained substring.
	@return A new string schema.
]=]
local function includes(self: StringSchema, pattern: string): StringSchema
	return withMetadata(self, { addIncludes = pattern })
end

--[=[
	Require uppercase string content.
	Combining with `isLowerCase` later will resolve to the latest rule.
	@return A new string schema.
]=]
local function isUpperCase(self: StringSchema): StringSchema
	return withMetadata(self, { isUpperCase = true }, { "isLowerCase" })
end

--[=[
	Require lowercase string content.
	Combining with `isUpperCase` later will resolve to the latest rule.
	@return A new string schema.
]=]
local function isLowerCase(self: StringSchema): StringSchema
	return withMetadata(self, { isLowerCase = true }, { "isUpperCase" })
end

--[=[
	Add a post-parse mutator that trims surrounding whitespace.
	Apply this when consumers should receive canonical trimmed values.
	@return A new string schema.
]=]
local function trimWhitespace(self: StringSchema): StringSchema
	return withMetadata(self, { addMutator = "trimWhitespace" })
end

--[=[
	Add a post-parse mutator that uppercases the parsed string.
	Useful for canonical keys, codes, and case-insensitive identifiers.
	@return A new string schema.
]=]
local function toUpperCase(self: StringSchema): StringSchema
	return withMetadata(self, { addMutator = "toUpperCase" })
end

--[=[
	Add a post-parse mutator that lowercases the parsed string.
	Useful for normalized identifiers and case-insensitive matching pipelines.
	@return A new string schema.
]=]
local function toLowerCase(self: StringSchema): StringSchema
	return withMetadata(self, { addMutator = "toLowerCase" })
end

--[=[
	Create a string schema.
	By default, this accepts any runtime string and applies no additional
	constraints until modifiers are chained.
	@reexportonly
	@param metadata Internal metadata snapshot used when deriving chained schemas.
	@return A string schema.
]=]
function schema.string(metadata: StringMetadata?): StringSchema
	return {
		_type = {
			inhabits = nil :: any,
			type = "string",
			metadata = metadata or defaultMetadata(),
		},
		validate = validateString,
		parse = parseString,
		maxLen = maxLen,
		minLen = minLen,
		length = length,
		match = match,
		regex = regex,
		startsWith = startsWith,
		endsWith = endsWith,
		includes = includes,
		isUpperCase = isUpperCase,
		isLowerCase = isLowerCase,
		trimWhitespace = trimWhitespace,
		toUpperCase = toUpperCase,
		toLowerCase = toLowerCase,
	}
end

return table.freeze(schema)
