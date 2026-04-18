local native = {}

--[=[
	Resolves a path to an absolute canonical form via the filesystem.

	This is a low-level native helper consumed by `@eryx/path`.

	@param input Path string or path-like object to canonicalize.
	@return string -- Canonical absolute path string.
]=]
function native.canonicalize(input: any): string
	return nil :: any
end

return table.freeze(native)
