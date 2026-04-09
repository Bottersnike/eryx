local capability = {}

local cache: { [string]: { ok: boolean, value: any } } = {}

function capability.optional(moduleName: string): (any?, any?)
	local cached = cache[moduleName]
	if cached ~= nil then
		if cached.ok then
			return cached.value, nil
		end
		return nil, cached.value
	end

	local ok, value = pcall(require, moduleName)
	cache[moduleName] = {
		ok = ok,
		value = value,
	}

	if ok then
		return value, nil
	end
	return nil, value
end

function capability.require(moduleName: string, feature: string, guidance: string?): any
	local value, err = capability.optional(moduleName)
	if value ~= nil then
		return value
	end

	local message = `{feature} requires {moduleName}, which is not available in this build.`
	if guidance ~= nil and guidance ~= "" then
		message ..= " " .. guidance
	end
	if err ~= nil then
		message ..= "\nOriginal error: " .. tostring(err)
	end
	error(message, 2)
end

return table.freeze(capability)
