--[=[
	Luau type checker, type inference, autocomplete, and config resolution.

	Wraps the native Luau analysis engine to provide full type checking,
	per-position type inference, module-level type-pack queries,
	autocompletion, `.luaurc` config discovery, and `require()` path
	resolution.

	```luau
	local analysis = require("@eryx/luau/analysis")

	-- Type-check a source string
	local result = analysis.check(source, { mode = "strict", annotate = true })
	for _, err in result.errors do
	    print(err.message, err.location.beginline)
	end

	-- Query the type at a position
	local ty = analysis.typeAt(source, 1, 7)
	print(ty) -- e.g. "number"

	-- Autocomplete after "t."
	local completions = analysis.autocomplete('local t = {x=1}\nt.', 2, 3)
	for name, entry in completions.entries do
	    print(name, entry.type)
	end
	```
]=]
local path = require("@eryx/path")
local ast = require("@eryx/luau/ast")
local native = require("@eryx/luau/_analysis_native")

type PathLike = path.PathLike

export type Location = ast.Location

export type DefinitionSource = string | {
	--- The definition file source text.
	source: string,
	--- Optional package name (e.g. `"@mygame"`). Defaults to `"@def<N>"`.
	name: string?,
}

export type CheckOptions = {
	--- Type-checking strictness. `"strict"` enables full checking, `"nonstrict"` (default) is lenient, `"nocheck"` disables checking.
	mode: ("strict" | "nonstrict" | "nocheck")?,
	--- If true, the result includes an `annotated` field with the source rewritten to include inferred type annotations.
	annotate: boolean?,
	--- Additional `.d.luau`-style definition sources to load before type checking.
	definitions: { DefinitionSource }?,
	--- Absolute path of the source file. Enables `require()` resolution and `.luaurc` discovery.
	filePath: string?,
}

export type TypeErrorInfo = {
	--- Human-readable error message.
	message: string,
	--- Source location of the error.
	location: Location,
	--- Error category: `"TypeError"` for type errors, `"SyntaxError"` for parse errors.
	category: "TypeError" | "SyntaxError",
	--- Human-readable module path that produced the error, when available.
	moduleName: string?,
}

export type LintInfo = {
	--- Lint severity level.
	severity: "error" | "warning",
	--- Numeric lint code.
	code: number,
	--- Stable lint code name (e.g. `"LocalUnused"`).
	name: string,
	--- Human-readable lint message.
	message: string,
	--- Source location for the diagnostic.
	location: Location,
}

export type LintResult = {
	--- Lint diagnostics with `"error"` severity.
	errors: { LintInfo },
	--- Lint diagnostics with `"warning"` severity.
	warnings: { LintInfo },
	--- All lint diagnostics in source order, regardless of severity.
	all: { LintInfo },
}

export type CheckResult = {
	--- Type errors found during checking. Empty when there are none.
	errors: { TypeErrorInfo },
	--- Luau lint diagnostics grouped by severity.
	lints: LintResult,
	--- The source rewritten with inferred type annotations. Only present when `options.annotate` is true.
	annotated: string?,
}

export type AnalysisTypeDetail = {
	--- Human-readable display string for the type.
	display: string,
	--- Internal kind tag (e.g. `"primitive"`, `"table"`, `"function"`).
	kind: string,
	[string]: any,
}

export type AnalysisTypePackDetail = {
	--- Internal kind tag for the type pack.
	kind: string,
	[string]: any,
}

export type TypeAtResult = {
	--- Human-readable type string.
	display: string,
	--- Where the type was found: an expression, a local binding, or a scope binding.
	source: "Expression" | "Binding" | "ScopeBinding",
	--- Structured type detail object.
	type: AnalysisTypeDetail,
}

export type ModuleTypeResult = {
	--- Human-readable type pack string.
	display: string,
	--- Always `"Module"` for module type results.
	source: "Module",
	--- Structured type pack detail object.
	typePack: AnalysisTypePackDetail,
	--- Human-readable module path, when available.
	moduleName: string?,
}

export type TypeAtOptions = {
	--- Type-checking strictness. Defaults to `"strict"` for best inference.
	mode: ("strict" | "nonstrict" | "nocheck")?,
	--- Additional type definition sources to load before inference.
	definitions: { DefinitionSource }?,
	--- Absolute path of the source file. Enables `require()` resolution.
	filePath: string?,
	--- If true, return a structured `TypeAtResult` instead of just a string.
	detailed: boolean?,
}

export type ModuleTypeOptions = {
	--- Type-checking strictness. Defaults to `"strict"` for best inference.
	mode: ("strict" | "nonstrict" | "nocheck")?,
	--- Additional type definition sources to load before inference.
	definitions: { DefinitionSource }?,
	--- Absolute path of the source file. Enables `require()` resolution.
	filePath: string?,
	--- If true, return a structured `ModuleTypeResult` instead of just a string.
	detailed: boolean?,
}

export type AutocompleteOptions = {
	--- Type-checking strictness. Defaults to `"strict"` for best results.
	mode: ("strict" | "nonstrict")?,
	--- Additional type definition sources to load before completion.
	definitions: { DefinitionSource }?,
	--- Absolute path of the source file. Enables `require()` resolution.
	filePath: string?,
	--- If true, include a `typeDetail` field for each typed completion entry.
	detailed: boolean?,
}

export type AutocompleteEntry = {
	--- What kind of completion this is.
	kind: "Property"
		| "Binding"
		| "Keyword"
		| "String"
		| "Type"
		| "Module"
		| "GeneratedFunction"
		| "RequirePath"
		| "Unknown",
	--- Inferred type of this entry. Absent for keywords and untyped entries.
	type: string?,
	--- Structured type metadata. Only present when `options.detailed` is true.
	typeDetail: AnalysisTypeDetail?,
	--- Whether this entry is marked deprecated.
	deprecated: boolean?,
	--- Whether the entry's type matches what is expected at the cursor position.
	typeCorrect: ("Correct" | "CorrectFunctionResult")?,
	--- Suggested text to insert. Falls back to the completion name when absent.
	insertText: string?,
	--- Parentheses hint: `"CursorAfter"` adds `()` with cursor after, `"CursorInside"` adds `()` with cursor between.
	parens: ("CursorAfter" | "CursorInside")?,
}

export type AutocompleteResult = {
	--- The completion context at the cursor position.
	context: "Expression" | "Statement" | "Property" | "Type" | "Keyword" | "String" | "Unknown",
	--- Map of completion name to its entry details.
	entries: { [string]: AutocompleteEntry },
}

export type LuauConfigAlias = {
	--- Absolute filesystem path resolved from the alias target.
	qualified: string,
	--- Directory of the config file that defined this alias.
	configPath: string,
	--- Raw alias target string as written in the config file.
	path: string,
}

export type LuauConfig = {
	--- Whether any config file was discovered during lookup.
	found: boolean,
	--- Directory of the innermost config file that applies to the caller.
	configDir: string,
	--- Active language mode from the merged config chain.
	languageMode: "strict" | "nonstrict" | "nocheck",
	--- Bitmask of enabled lint rule codes.
	enabledLints: number,
	--- Bitmask of lint rule codes treated as fatal.
	fatalLints: number,
	--- Whether lint diagnostics are promoted to errors.
	lintErrors: boolean,
	--- Whether type diagnostics are promoted to errors.
	typeErrors: boolean,
	--- Additional global names declared in the config.
	globals: { string },
	--- Resolved alias map from alias key to alias metadata.
	aliases: { [string]: LuauConfigAlias },
}

local analysis = {}

--[=[
	Runs the Luau type checker on a source string.

	Returns a [[CheckResult]] containing any type errors found. When
	`options.annotate` is `true`, also returns the source code rewritten
	with inferred type annotations attached to every binding and
	expression. The result also includes built-in Luau lints under
	`result.lints`.

	```luau
	local result = analysis.check(source, { mode = "strict", annotate = true })
	for _, err in result.errors do
	    print(err.message, err.location.beginline)
	end
	if result.annotated then
	    print(result.annotated)
	end
	```

	@param source The Luau source code to type-check.
	@param options Type-checking options.
	@return CheckResult -- The type-check result.
]=]
function analysis.check(source: string, options: CheckOptions?): CheckResult
	return native.check(source, options)
end

--[=[
	Infers the type at a specific position in Luau source code.

	Runs the type checker in strict mode (by default) and queries the
	inferred type at the given 1-based line and column. Useful for
	building LSP hover information or type inspection tools.

	Returns `nil` if no type can be determined at that position (e.g.
	whitespace, comments, or if the position is out of range).

	```luau
	local source = "local x = 42\nprint(x)"
	local ty = analysis.typeAt(source, 1, 7)  -- position of 'x'
	print(ty)  -- "number"
	```

	@param source The Luau source code.
	@param line 1-based line number.
	@param column 1-based column number.
	@param options Type inference options.
	@return string? -- The inferred type as a string, or nil.
]=]
function analysis.typeAt(
	source: string,
	line: number,
	column: number,
	options: TypeAtOptions?
): (string | TypeAtResult)?
	return native.typeAt(source, line, column, options)
end

--[=[
	Returns the inferred return type pack for a Luau module.

	This runs the type checker for the provided source and then returns the
	module's exported return pack, i.e. the type-level shape produced by the
	module's top-level `return` statement(s).

	By default this returns a human-readable string. Pass
	`{ detailed = true }` to receive a structured type-pack payload.

	```luau
	local source = "return { answer = 42 }"
	local moduleType = analysis.typeofModule(source)
	print(moduleType) -- "({ answer: number })"
	```

	@param source The Luau module source code.
	@param options Module type inference options.
	@return string? -- The inferred module return pack as a string, or nil.
]=]
function analysis.typeofModule(source: string, options: ModuleTypeOptions?): (string | ModuleTypeResult)?
	return native.typeofModule(source, options)
end

--[=[
	Computes autocompletion entries at a cursor position.

	Runs type checking and returns contextual completions, including
	property names, local bindings, keywords, and types - along with
	their inferred types where available. This is the same engine
	used by Luau language servers.

	```luau
	local source = 'local t = {foo = 1, bar = "hi"}\nt.'
	local result = analysis.autocomplete(source, 2, 3)  -- after "t."
	for name, entry in result.entries do
	    print(name, entry.kind, entry.type)
	end
	-- foo  Property  number
	-- bar  Property  string
	```

	@param source The Luau source code.
	@param line 1-based line number of the cursor.
	@param column 1-based column number of the cursor.
	@param options Autocomplete options.
	@return AutocompleteResult -- The autocomplete result.
]=]
function analysis.autocomplete(
	source: string,
	line: number,
	column: number,
	options: AutocompleteOptions?
): AutocompleteResult
	return native.autocomplete(source, line, column, options)
end

--[=[
	Resolve a `require()` path relative to a source file.

	Given the absolute path of a Luau source file and a require string
	(relative path like `"./foo"`, `"../bar"`, or alias path like
	`"@alias/mod"`), returns the absolute path to the resolved module
	file, or `nil` if no matching file was found.

	Uses the same resolution rules as the type checker:
	- Extension search order: `.luau` -> `.lua` -> `dir/init.luau` -> `dir/init.lua`
	- Alias resolution via `.luaurc` files walking up the directory tree.
	- `init.luau` files resolve relative requires from the parent directory.

	```luau
	local target = analysis.resolve("C:/project/src/main.luau", "./utils")
	print(target)  -- "C:\\project\\src\\utils.luau"
	```

	@param pathLike Absolute path of the source file containing the require.
	@param requirePath The require string to resolve.
	@return string? -- Absolute path to the resolved file, or nil if not found.
	@return string? -- Error message string if resolution failed, otherwise nil.
]=]
function analysis.resolve(pathLike: PathLike, requirePath: string?): (string?, string?)
	return native.resolve(pathLike, requirePath)
end

--[=[
	Returns the active merged Luau config for the current require context.

	Lookup follows the same caller-sensitive rules used by `require`,
	`luau.resolve`, and type-checker file resolution, including VFS/module
	context handling and parent-directory config merging.

	When `folderPath` is provided, lookup starts from that folder path
	instead of the current caller context.

	The returned table includes language mode, lint/type flags, globals,
	and resolved alias metadata.

	```luau
	local cfg = analysis.getconfig()
	if cfg.found then
		print(cfg.languageMode, cfg.configDir)
	end
	for alias, info in cfg.aliases do
		print(alias, info.qualified)
	end
	```

	@param folderPath Optional folder path to start config discovery from.
	@return LuauConfig -- Current merged config state.
]=]
function analysis.getconfig(folderPath: PathLike?): LuauConfig
	return native.getconfig(folderPath)
end

function analysis.parseLuaurc(source: string, path: string, overwriteAliases: boolean?, compat: boolean?): LuauConfig
	return native.parseLuaurc(source, path, overwriteAliases, compat)
end

return table.freeze(analysis)
