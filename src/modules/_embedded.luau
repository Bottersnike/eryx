--[=[
	Access to read-only Luau sources baked into embedded or hybrid builds.

	This module intentionally returns strings rather than File handles; embedded
	sources are not real filesystem files.
]=]

local embedded = {}

--- Reads an embedded source entry by its module-table key.
--- Accepts bare keys like `eryxdoc/theme/style.css` and `@eryx/...` paths.
--- Returns nil when no embedded table is registered or the key is absent.
function embedded.read(path: string): string?
	return nil :: any
end

--- Returns true when an embedded source entry exists.
function embedded.exists(path: string): boolean
	return nil :: any
end

return table.freeze(embedded)
