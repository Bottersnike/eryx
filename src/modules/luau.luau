--[=[
	Luau source code parser, compiler, and type checker.

	Parses Luau source into a structured AST (Abstract Syntax Tree) with
	full type-safety. Also provides bytecode compilation, loading, native
	JIT compilation, bytecode disassembly, full type checking, type
	inference at positions, and autocompletion.

	Every node carries a `type` discriminator string and a `location` with
	1-based line/column positions.

	```luau
	local luau = require("@eryx/luau")

	local result = luau.parse(source, { captureComments = true })
	for _, stat in result.root.body do
	    print(stat.type, stat.location.start.line)
	end

	-- Type check a file
	local checked = luau.check(source, { mode = "strict", annotate = true })
	print(checked.annotated) -- source with type annotations

	-- Query a type at a position
	local ty = luau.typeAt(source, 1, 7)
	print(ty) -- e.g. "number"
	```
]=]

-- Every AST node has its own type for full type-safety.

-- ═══════════════════════════════════════════════════════════════════════════
-- Common
-- ═══════════════════════════════════════════════════════════════════════════

--- A position in source code (1-based line and column).
export type Position = {
	line: number,
	column: number,
}

--- A span in source code, from a start [[Position]] to an end [[Position]].
export type Location = {
	start: Position,
	["end"]: Position,
}

--- A parse error with its location in the source.
export type ParseErrorInfo = {
	message: string,
	location: Location,
}

--- A comment descriptor. Only present when `captureComments` is enabled
--- in the [[ParseOptions]].
export type CommentInfo = {
	type: "Comment" | "BlockComment" | "BrokenComment",
	location: Location,
}

--- Options for [[parse]].
export type ParseOptions = {
	captureComments: boolean?,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Type Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type TypeReference = {
	type: "TypeReference",
	location: Location,
	name: string,
	prefix: string?,
	parameters: { AstType }?,
}

export type TypeTableProp = {
	name: string,
	type: AstType,
	location: Location,
}

export type TypeTableIndexer = {
	indexType: AstType,
	resultType: AstType,
}

export type TypeTable = {
	type: "TypeTable",
	location: Location,
	props: { TypeTableProp },
	indexer: TypeTableIndexer?,
}

export type TypeFunction = {
	type: "TypeFunction",
	location: Location,
	argTypes: { AstType },
	argNames: { string? },
	returnTypes: AstTypePack?,
}

export type TypeTypeof = {
	type: "TypeTypeof",
	location: Location,
	expr: AstExpr,
}

export type TypeOptional = {
	type: "TypeOptional",
	location: Location,
}

export type TypeUnion = {
	type: "TypeUnion",
	location: Location,
	types: { AstType },
}

export type TypeIntersection = {
	type: "TypeIntersection",
	location: Location,
	types: { AstType },
}

export type TypeSingletonBool = {
	type: "TypeSingletonBool",
	location: Location,
	value: boolean,
}

export type TypeSingletonString = {
	type: "TypeSingletonString",
	location: Location,
	value: string,
}

export type TypeGroup = {
	type: "TypeGroup",
	location: Location,
	inner: AstType,
}

export type TypeError = {
	type: "TypeError",
	location: Location,
}

export type TypeUnknown = {
	type: "TypeUnknown",
	location: Location,
}

--- Union of all type annotation nodes.
export type AstType =
	TypeReference
	| TypeTable
	| TypeFunction
	| TypeTypeof
	| TypeOptional
	| TypeUnion
	| TypeIntersection
	| TypeSingletonBool
	| TypeSingletonString
	| TypeGroup
	| TypeError
	| TypeUnknown

-- ═══════════════════════════════════════════════════════════════════════════
-- TypePack Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type TypePackExplicit = {
	type: "TypePackExplicit",
	location: Location,
	types: { AstType },
	tail: AstTypePack?,
}

export type TypePackVariadic = {
	type: "TypePackVariadic",
	location: Location,
	variadicType: AstType,
}

export type TypePackGeneric = {
	type: "TypePackGeneric",
	location: Location,
	name: string,
}

export type TypePackUnknown = {
	type: "TypePackUnknown",
	location: Location,
}

--- Union of all type-pack nodes (used for return types and variadic packs).
export type AstTypePack = TypePackExplicit | TypePackVariadic | TypePackGeneric | TypePackUnknown

-- ═══════════════════════════════════════════════════════════════════════════
-- AstLocal
-- ═══════════════════════════════════════════════════════════════════════════

export type AstLocal = {
	name: string,
	location: Location,
	annotation: AstType?,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Expression Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type ExprGroup = {
	type: "ExprGroup",
	location: Location,
	expr: AstExpr,
}

export type ExprConstantNil = {
	type: "ExprConstantNil",
	location: Location,
}

export type ExprConstantBool = {
	type: "ExprConstantBool",
	location: Location,
	value: boolean,
}

export type ExprConstantNumber = {
	type: "ExprConstantNumber",
	location: Location,
	value: number,
}

export type ExprConstantString = {
	type: "ExprConstantString",
	location: Location,
	value: string,
}

export type ExprLocal = {
	type: "ExprLocal",
	location: Location,
	["local"]: AstLocal,
	upvalue: boolean,
}

export type ExprGlobal = {
	type: "ExprGlobal",
	location: Location,
	name: string,
}

export type ExprVarargs = {
	type: "ExprVarargs",
	location: Location,
}

export type ExprCall = {
	type: "ExprCall",
	location: Location,
	func: AstExpr,
	args: { AstExpr },
	self: boolean,
}

export type ExprIndexName = {
	type: "ExprIndexName",
	location: Location,
	expr: AstExpr,
	index: string,
	op: string,
}

export type ExprIndexExpr = {
	type: "ExprIndexExpr",
	location: Location,
	expr: AstExpr,
	index: AstExpr,
}

export type ExprFunction = {
	type: "ExprFunction",
	location: Location,
	debugname: string?,
	args: { AstLocal },
	vararg: boolean,
	varargAnnotation: AstTypePack?,
	returnAnnotation: AstTypePack?,
	self: AstLocal?,
	body: Block,
}

export type ExprTableItem = {
	kind: "List" | "Record" | "General",
	key: AstExpr?,
	value: AstExpr,
}

export type ExprTable = {
	type: "ExprTable",
	location: Location,
	items: { ExprTableItem },
}

export type ExprUnary = {
	type: "ExprUnary",
	location: Location,
	op: string,
	expr: AstExpr,
}

export type ExprBinary = {
	type: "ExprBinary",
	location: Location,
	op: string,
	left: AstExpr,
	right: AstExpr,
}

export type ExprTypeAssertion = {
	type: "ExprTypeAssertion",
	location: Location,
	expr: AstExpr,
	annotation: AstType,
}

export type ExprIfElse = {
	type: "ExprIfElse",
	location: Location,
	condition: AstExpr,
	trueExpr: AstExpr,
	falseExpr: AstExpr,
}

export type ExprInterpString = {
	type: "ExprInterpString",
	location: Location,
	strings: { string },
	expressions: { AstExpr },
}

export type ExprError = {
	type: "ExprError",
	location: Location,
}

export type ExprUnknown = {
	type: "ExprUnknown",
	location: Location,
}

--- Union of all expression nodes.
export type AstExpr =
	ExprGroup
	| ExprConstantNil
	| ExprConstantBool
	| ExprConstantNumber
	| ExprConstantString
	| ExprLocal
	| ExprGlobal
	| ExprVarargs
	| ExprCall
	| ExprIndexName
	| ExprIndexExpr
	| ExprFunction
	| ExprTable
	| ExprUnary
	| ExprBinary
	| ExprTypeAssertion
	| ExprIfElse
	| ExprInterpString
	| ExprError
	| ExprUnknown

-- ═══════════════════════════════════════════════════════════════════════════
-- Statement Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type Block = {
	type: "Block",
	location: Location,
	body: { AstStat },
}

export type StatIf = {
	type: "StatIf",
	location: Location,
	condition: AstExpr,
	thenBody: Block,
	elseBody: (Block | StatIf)?,
}

export type StatWhile = {
	type: "StatWhile",
	location: Location,
	condition: AstExpr,
	body: Block,
}

export type StatRepeat = {
	type: "StatRepeat",
	location: Location,
	condition: AstExpr,
	body: Block,
}

export type StatBreak = {
	type: "StatBreak",
	location: Location,
}

export type StatContinue = {
	type: "StatContinue",
	location: Location,
}

export type StatReturn = {
	type: "StatReturn",
	location: Location,
	list: { AstExpr },
}

export type StatExpr = {
	type: "StatExpr",
	location: Location,
	expr: AstExpr,
}

export type StatLocal = {
	type: "StatLocal",
	location: Location,
	vars: { AstLocal },
	values: { AstExpr },
}

export type StatFor = {
	type: "StatFor",
	location: Location,
	var: AstLocal,
	from: AstExpr,
	to: AstExpr,
	step: AstExpr?,
	body: Block,
}

export type StatForIn = {
	type: "StatForIn",
	location: Location,
	vars: { AstLocal },
	values: { AstExpr },
	body: Block,
}

export type StatAssign = {
	type: "StatAssign",
	location: Location,
	vars: { AstExpr },
	values: { AstExpr },
}

export type StatCompoundAssign = {
	type: "StatCompoundAssign",
	location: Location,
	op: string,
	var: AstExpr,
	value: AstExpr,
}

export type StatFunction = {
	type: "StatFunction",
	location: Location,
	name: AstExpr,
	func: ExprFunction,
}

export type StatLocalFunction = {
	type: "StatLocalFunction",
	location: Location,
	name: AstLocal,
	func: ExprFunction,
}

export type StatTypeAlias = {
	type: "StatTypeAlias",
	location: Location,
	name: string,
	exported: boolean,
	aliasedType: AstType,
	generics: { string }?,
}

export type StatDeclareGlobal = {
	type: "StatDeclareGlobal",
	location: Location,
	name: string,
	declaredType: AstType,
}

export type StatDeclareFunction = {
	type: "StatDeclareFunction",
	location: Location,
	name: string,
}

export type StatDeclareExternType = {
	type: "StatDeclareExternType",
	location: Location,
	name: string,
}

export type StatError = {
	type: "StatError",
	location: Location,
}

export type StatUnknown = {
	type: "StatUnknown",
	location: Location,
}

--- Union of all statement nodes.
export type AstStat =
	Block
	| StatIf
	| StatWhile
	| StatRepeat
	| StatBreak
	| StatContinue
	| StatReturn
	| StatExpr
	| StatLocal
	| StatFor
	| StatForIn
	| StatAssign
	| StatCompoundAssign
	| StatFunction
	| StatLocalFunction
	| StatTypeAlias
	| StatDeclareGlobal
	| StatDeclareFunction
	| StatDeclareExternType
	| StatError
	| StatUnknown

--- Any AST node (statement, expression, or type annotation).
export type AstNode = AstStat | AstExpr | AstType

-- ═══════════════════════════════════════════════════════════════════════════
-- Parse Result
-- ═══════════════════════════════════════════════════════════════════════════

--- The result returned by [[parse]].
export type ParseResult = {
	root: Block,
	errors: { ParseErrorInfo },
	comments: { CommentInfo }?,
	lines: number,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Compiler Options
-- ═══════════════════════════════════════════════════════════════════════════

--- Options for [[compile]].
export type CompileOptions = {
	optimizationLevel: number?,
	debugLevel: number?,
	coverageLevel: number?,
	typeInfoLevel: number?,
}

--- Options for [[disassemble]].
export type DisassembleOptions = {
	optimizationLevel: number?,
	debugLevel: number?,
	showLocals: boolean?,
	showRemarks: boolean?,
	showTypes: boolean?,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Type Checker
-- ═══════════════════════════════════════════════════════════════════════════

--[=[
	A definition source for loading type definitions.
	Can be a plain string (the definition source text) or a table with
	a `source` field and optional `name` (package name, e.g. `"@mygame"`).
]=]
export type DefinitionSource = string | {
	--- The definition file source text.
	source: string,
	--- Optional package name (e.g. `"@mygame"`). Defaults to `"@def<N>"`.
	name: string?,
}

--- Options for [[check]]
export type CheckOptions = {
	--[=[
		Type-checking mode: `"strict"` for full checking, `"nonstrict"` (default)
		for lenient checking, `"nocheck"` for no type checking.
	]=]
	mode: ("strict" | "nonstrict" | "nocheck")?,
	--[=[
		If `true`, the result includes an `annotated` field with the source
		rewritten to include inferred type annotations.
	]=]
	annotate: boolean?,
	--[=[
		Additional type definition sources to load before type checking.
		These are `.d.luau`-style definition strings that declare global
		types and functions available in the checked source.
	]=]
	definitions: { DefinitionSource }?,
	--[=[
		Absolute file path of the source being checked. When provided,
		`require()` calls in the source are resolved relative to this path,
		and `.luaurc` alias configs are discovered by walking up from it.
	]=]
	filePath: string?,
}

--- A type error from the type checker.
export type TypeErrorInfo = {
	--- Human-readable error message.
	message: string,
	--- Source location of the error.
	location: Location,
	--- Error category: `"TypeError"` or `"SyntaxError"`.
	category: "TypeError" | "SyntaxError",
}

--- The result returned by [[check]].
export type CheckResult = {
	--- Type errors found during checking (empty array if none).
	errors: { TypeErrorInfo },
	--- The source code with inferred type annotations attached.
	--- Only present when `options.annotate` is `true`.
	annotated: string?,
}

--- Options for [[typeAt]].
export type TypeAtOptions = {
	--- Type-checking mode. Defaults to `"strict"` for best inference.
	mode: ("strict" | "nonstrict" | "nocheck")?,
	--- Additional type definition sources to load before inference.
	definitions: { DefinitionSource }?,
	--- Absolute file path of the source. Enables require() resolution.
	filePath: string?,
}

--- Options for [[autocomplete]].
export type AutocompleteOptions = {
	--- Type-checking mode. Defaults to `"strict"` for best results.
	mode: ("strict" | "nonstrict")?,
	--- Additional type definition sources to load before completion.
	definitions: { DefinitionSource }?,
	--- Absolute file path of the source. Enables require() resolution.
	filePath: string?,
}

--- An autocompletion entry.
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
	--- The inferred type of this entry (absent for keywords).
	type: string?,
	--- Whether this entry is deprecated.
	deprecated: boolean?,
	--- Whether this entry's type matches what's expected at the cursor.
	typeCorrect: ("Correct" | "CorrectFunctionResult")?,
	--- Suggested text to insert.
	insertText: string?,
	--- Parentheses recommendation: `"CursorAfter"` means add `()` with
	--- cursor after, `"CursorInside"` means add `()` with cursor between.
	parens: ("CursorAfter" | "CursorInside")?,
}

--- The result returned by [[autocomplete]].
export type AutocompleteResult = {
	--- The autocomplete context at the cursor position.
	context: "Expression" | "Statement" | "Property" | "Type" | "Keyword" | "String" | "Unknown",
	--- Map of completion name to entry details.
	entries: { [string]: AutocompleteEntry },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Module
-- ═══════════════════════════════════════════════════════════════════════════

local luau = {}

--[=[
	Parses Luau source code and returns a structured AST.

	The returned `root` is a [[Block]] node whose `body` contains an array
	of statement nodes. Every node carries a `type` string discriminator
	and a `location` with 1-based line/column positions.

	Pass `{ captureComments = true }` to include a `comments` array in
	the result.

	```luau
	local result = luau.parse(source, { captureComments = true })
	print("Lines:", result.lines)
	print("Errors:", #result.errors)
	print("Top-level statements:", #result.root.body)
	```

	@param source The Luau source code string to parse.
	@param options Parse options (e.g. comment capture).
	@return ParseResult -- The parse result containing the AST root, errors, and optional comments.
]=]
function luau.parse(source: string, options: ParseOptions?): ParseResult
	return nil :: any
end

--[=[
	Pretty-prints Luau source code by round-tripping through the parser.

	@param source The Luau source code to format.
	@return string -- The reformatted source code.
]=]
function luau.prettyPrint(source: string): string
	return nil :: any
end

--[=[
	Compiles Luau source code to bytecode.

	The returned bytecode blob can be passed to [[load]] or cached for
	later use.  If the source has syntax errors the bytecode will contain
	an encoded error that [[load]] will surface.

	```luau
	local bytecode = luau.compile(source, { optimizationLevel = 2 })
	local fn = luau.load(bytecode, "=cached")
	fn()
	```

	@param source The Luau source code to compile.
	@param options Compiler options (optimization, debug, coverage levels).
	@return string -- The compiled bytecode blob.
]=]
function luau.compile(source: string, options: CompileOptions?): string
	return nil :: any
end

--[=[
	Loads Luau source code or pre-compiled bytecode as a callable function.

	Accepts either a source string (which will be compiled automatically)
	or a bytecode blob previously returned by [[compile]].  This is the
	equivalent of `loadstring` in standard Lua.

	```luau
	local fn = luau.load("return 1 + 2", "=example")
	print(fn()) -- 3
	```

	@param sourceOrBytecode Luau source code or compiled bytecode.
	@param chunkname Optional name for the chunk (shown in errors/stack traces, defaults to `"=load"`).
	@return (...any) -> ...any -- The loaded function.
]=]
function luau.load(sourceOrBytecode: string, chunkname: string?): (...any) -> ...any
	return nil :: any
end

--[=[
	Returns a human-readable bytecode listing for the given source.

	Compiles the source and returns a formatted disassembly string showing
	every function's bytecode instructions, optionally with source lines,
	local variable info, compiler remarks, and type annotations.

	```luau
	local listing = luau.disassemble(source, {
	    showLocals  = true,
	    showRemarks = true,
	})
	print(listing)
	```

	@param source The Luau source code to disassemble.
	@param options Disassembly options controlling output detail.
	@return string -- The formatted bytecode listing.
]=]
function luau.disassemble(source: string, options: DisassembleOptions?): string
	return nil :: any
end

--[=[
	Runs the Luau type checker on a source string.

	Returns a [[CheckResult]] containing any type errors found. When
	`options.annotate` is `true`, also returns the source code rewritten
	with inferred type annotations attached to every binding and
	expression.

	```luau
	local result = luau.check(source, { mode = "strict", annotate = true })
	for _, err in result.errors do
	    print(err.message, err.location.start.line)
	end
	if result.annotated then
	    print(result.annotated)
	end
	```

	@param source The Luau source code to type-check.
	@param options Type-checking options.
	@return CheckResult -- The type-check result.
]=]
function luau.check(source: string, options: CheckOptions?): CheckResult
	return nil :: any
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
	local ty = luau.typeAt(source, 1, 7)  -- position of 'x'
	print(ty)  -- "number"
	```

	@param source The Luau source code.
	@param line 1-based line number.
	@param column 1-based column number.
	@param options Type inference options.
	@return string? -- The inferred type as a string, or nil.
]=]
function luau.typeAt(source: string, line: number, column: number, options: TypeAtOptions?): string?
	return nil :: any
end

--[=[
	Computes autocompletion entries at a cursor position.

	Runs type checking and returns contextual completions, including
	property names, local bindings, keywords, and types — along with
	their inferred types where available. This is the same engine
	used by Luau language servers.

	```luau
	local source = 'local t = {foo = 1, bar = "hi"}\nt.'
	local result = luau.autocomplete(source, 2, 3)  -- after "t."
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
function luau.autocomplete(
	source: string,
	line: number,
	column: number,
	options: AutocompleteOptions?
): AutocompleteResult
	return nil :: any
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
	local target = luau.resolve("C:/project/src/main.luau", "./utils")
	print(target)  -- "C:\\project\\src\\utils.luau"
	```

	@param filePath Absolute path of the source file containing the require.
	@param requirePath The require string to resolve.
	@return string? -- Absolute path to the resolved file, or nil.
]=]
function luau.resolve(filePath: string, requirePath: string): string?
	return nil :: any
end

return luau
