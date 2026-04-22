--[=[
	Luau source code parser, compiler, type checker, and AST query library.

	This is the unified `@eryx/luau` facade. It re-exports all sub-modules
	under a single table:

	- `luau.parse`    — Parse source into an AST, extract comments, and pretty-print.
	- `luau.analysis` — Type checking, type inference, autocompletion, and config resolution.
	- `luau.vm`       — Bytecode compilation, loading, and disassembly.
	- `luau.query`    — Walk and query AST nodes with a chainable `Query` API.
	- `luau.ast`      — Shared AST type definitions (mostly for type imports).

	Sub-modules can also be required individually as `@eryx/luau/parse`,
	`@eryx/luau/analysis`, etc.

	```luau
	local luau = require("@eryx/luau")

	-- Parse source into an AST
	local result = luau.parse.parse(source, { captureComments = true })
	for _, stat in result.root.body do
	    print(stat.type, stat.location.beginline)
	end

	-- Type check
	local checked = luau.analysis.check(source, { mode = "strict", annotate = true })
	print(checked.annotated)

	-- Compile and run
	local fn = luau.vm.load(source, "=example")
	fn()
	```
]=]
local analysis = require("@self/analysis")
local ast = require("@self/ast")
local parse = require("@self/parse")
local query = require("@self/query")
local vm = require("@self/vm")

local luau = {}

luau.analysis = analysis
luau.ast = ast
luau.parse = parse
luau.query = query
luau.vm = vm

return table.freeze(luau)
