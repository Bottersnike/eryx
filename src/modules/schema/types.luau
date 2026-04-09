--[=[
	@ignore

	Shared schema type utilities.
	Contains generic schema interfaces and compile-time helper type functions.
]=]
export type function anyNotNil(): type
	return types.negationof(types.singleton(nil))
end

export type Schema<T> = {
	read _type: {
		-- Type carrier for T. Always nil in reality
		read inhabits: T,
		-- Runtime identification for inhabits
		-- read type: "literal" | "number" | "string" | "boolean" | "array" | "table" | "optional" | "union" | "map",
		read type: "literal" | "number" | "string" | "boolean" | "array" | "table" | "optional" | "union" | "map",
		-- Metadata, based on `type`
		read metadata: any,
	},

	read validate: (self: any, object: anyNotNil<>) -> boolean,
	read parse: (self: any, object: anyNotNil<>) -> (boolean, T | string),
}

--[=[
	Extract the child value type from anyOf arguments.
	@param ty Type-level input inspected by this helper.
	@return A value union type for anyOf child schemas/literals.
]=]
export type function extractChildrenFromAnyOfUnion(ty: type): type
	if ty.tag ~= "union" then
		local child = extractSchemaType(ty)
		return child
	end
	local newUnion: { type } = {}
	for _, v in ty:components() do
		local child = extractSchemaType(v)
		table.insert(newUnion, child)
	end
	return types.unionof(table.unpack(newUnion))
end

--[=[
	Extract the value type from a schema-like type.
	@param ty Type-level input inspected by this helper.
	@return The inferred inhabited value type.
]=]
export type function extractSchemaType(ty: type): type -- (Schema<T> | T) -> (T)
	-- If we extend the type, grab the base Schema<>
	if ty:is("intersection") then
		ty = ty:components()[1]
	end

	if ty and ty:is("table") then
		local _type = ty:readproperty(types.singleton("_type"))
		if _type and _type:is("table") then
			local inhabits = _type:readproperty(types.singleton("inhabits"))
			if inhabits then
				return inhabits
			end
		end
	end
	return ty
end

--[=[
	Remove indexer signatures while preserving explicit properties.
	@param ty Type-level input inspected by this helper.
	@return A table type containing only concrete properties.
]=]
export type function stripIndexer(ty: type): type -- ({[any]: any, ...}) -> ({...})
	if ty:is("table") then
		local out = types.newtable({}, nil, ty:metatable())

		for key, rw in ty:properties() do
			local read = extractSchemaType(rw.read)
			local write = extractSchemaType(rw.write)

			if read and read == write then
				out:setproperty(key, read)
			else
				if read then
					out:setreadproperty(key, read)
				end
				if write then
					out:setwriteproperty(key, write)
				end
			end
		end

		return out
	end
	error("expected a table")
end

--[=[
	Extract literal singleton information used by helper overload patterns.
	@param ty Type-level input inspected by this helper.
	@param expect Expected type shape used for narrowing checks.
	@return The narrowed literal type.
]=]
export type function extractLiteralFromMagicUnion(ty: type, expect: type): type -- (T | "magic") -> T
	if ty.tag == "unknown" then
		return expect
	end

	-- Number literals don't exist right now :(
	if ty.tag == "number" then
		return ty
	end

	if ty.tag ~= "singleton" then
		error(`Expected {expect.tag} got {ty.tag}`)
	end
	if expect.tag ~= "any" and typeof(ty:value()) ~= expect.tag then
		error(`Expected {expect.tag} got {typeof(ty:value())}`)
	end
	return ty
end

return {}
