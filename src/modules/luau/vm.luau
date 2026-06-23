--[=[
	Luau bytecode compiler, loader, and disassembler.

	Wraps the native Luau VM to compile source code to bytecode,
	load source or pre-compiled bytecode as callable functions, and
	produce human-readable bytecode disassembly listings.

	```luau
	local vm = require("@eryx/luau/vm")

	-- Compile once, run many times
	local bytecode = vm.compile(source, { optimizationLevel = 2 })
	local fn = vm.load(bytecode, "=cached")
	fn()

	-- Inspect compiled code
	print(vm.disassemble(source, { showLocals = true }))
	```
]=]
local native = require("@eryx/luau/_vm_native")

export type CompileOptions = {
	--- Optimization level (0-2). Higher levels enable more aggressive inlining and dead-code elimination. Default is 1.
	optimizationLevel: number?,
	--- Debug info level (0-2). 0 = none, 1 = line numbers only (default), 2 = line numbers + local/upvalue names.
	debugLevel: number?,
	--- Coverage instrumentation level (0-2). 0 = none (default), 1 = statement coverage, 2 = expression coverage.
	coverageLevel: number?,
	--- Type info annotation level (0-1). When 1, tags locals and upvalues with type info for native codegen. Default is 0.
	typeInfoLevel: number?,
	--- Luau fast-flag overrides applied before compilation. Values may be booleans, numbers, or their string representations.
	flags: { [string]: boolean | number | string }?,
}

export type LoadOptions = {
	--- Luau fast-flag overrides applied before loading/compiling. Values may be booleans, numbers, or their string representations.
	flags: { [string]: boolean | number | string }?,
}

export type DisassembleOptions = {
	--- Optimization level used when compiling before disassembly (0-2). Default is 1.
	optimizationLevel: number?,
	--- Debug info level used when compiling (0-2). Default is 1.
	debugLevel: number?,
	--- If true, include local variable liveness ranges in the listing.
	showLocals: boolean?,
	--- If true, include compiler remarks (e.g. inlining decisions) in the listing.
	showRemarks: boolean?,
	--- If true, include type annotation info for tagged locals in the listing.
	showTypes: boolean?,
	--- Luau fast-flag overrides applied before compilation. Values may be booleans, numbers, or their string representations.
	flags: { [string]: boolean | number | string }?,
}

local vm = {}

--[=[
	Compiles Luau source code to bytecode.

	The returned bytecode blob can be passed to [[load]] or cached for
	later use.  If the source has syntax errors the bytecode will contain
	an encoded error that [[load]] will surface.

	```luau
	local bytecode = vm.compile(source, { optimizationLevel = 2 })
	local fn = vm.load(bytecode, "=cached")
	fn()
	```

	@param source The Luau source code to compile.
	@param options Compiler options (optimization, debug, coverage levels).
	@return string -- The compiled bytecode blob.
]=]
function vm.compile(source: string, options: CompileOptions?): string
	return native.compile(source, options)
end

--[=[
	Loads Luau source code or pre-compiled bytecode as a callable function.

	Accepts either a source string (which will be compiled automatically)
	or a bytecode blob previously returned by [[compile]].  This is the
	equivalent of `loadstring` in standard Lua.

	The optional `options` table may be passed as the second argument
	(omitting `chunkname`) or as the third argument after `chunkname`.

	```luau
	local fn = vm.load("return 1 + 2", "=example")
	print(fn()) -- 3
	```

	@param sourceOrBytecode Luau source code or compiled bytecode.
	@param chunkname Optional name for the chunk (shown in errors/stack traces, defaults to `"=load"`). May be omitted when passing options.
	@param options Optional load options (e.g. fast-flag overrides).
	@return (...any) -> ...any -- The loaded function.
]=]
function vm.load(sourceOrBytecode: string, chunkname: string?, options: LoadOptions?): (...any) -> ...any
	return native.load(sourceOrBytecode, chunkname, options)
end

--[=[
	Returns a human-readable bytecode listing for the given source.

	Compiles the source and returns a formatted disassembly string showing
	every function's bytecode instructions, optionally with source lines,
	local variable info, compiler remarks, and type annotations.

	```luau
	local listing = vm.disassemble(source, {
	    showLocals  = true,
	    showRemarks = true,
	})
	print(listing)
	```

	@param source The Luau source code to disassemble.
	@param options Disassembly options controlling output detail.
	@return string -- The formatted bytecode listing.
]=]
function vm.disassemble(source: string, options: DisassembleOptions?): string
	return native.disassemble(source, options)
end

return table.freeze(vm)
