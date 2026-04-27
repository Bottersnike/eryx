local types = require("@self/../types")

local sources: { types.Source } = {
	require("@self/repo"),
	require("@self/git"),
	require("@self/url"),
	require("@self/local"),
	require("@self/path"),
}

return sources
