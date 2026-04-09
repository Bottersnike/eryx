--- @ignore

-- Simple build warnings collector.
-- Modules call warn() during the build; main.luau calls summary() at the end.

local logging = require("@eryx/logging")

local log = logging.getLogger("eryxdoc.warnings")

local warnings: { string } = {}

local function warn(msg: string)
	table.insert(warnings, msg)
	log:warning(msg)
end

local function summary(): { string }
	return warnings
end

local function clear()
	table.clear(warnings)
end

return {
	warn = warn,
	summary = summary,
	clear = clear,
}
