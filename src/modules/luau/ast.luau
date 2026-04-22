--[=[
	Shared Luau AST and parse-result type definitions.

	This module is intended for type imports by the split `@eryx/luau/*`
	libraries. At runtime it returns an empty frozen table.
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

--- A span in source code with 1-based line and column coordinates.
export type Location = {
	beginline: number,
	begincolumn: number,
	endline: number,
	endcolumn: number,
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

export type SurroundingText = {
	leading: string?,
	trailing: string?,
}

--- Options for [[parse]].
export type ParseOptions = {
	captureComments: boolean?,
	collectSurroundingText: boolean?,
}

export type TableAccess = "Read" | "Write" | "ReadWrite"

export type AttrType = "Checked" | "Native" | "Deprecated" | "Unknown"

export type AstAttr = {
	type: AttrType,
	location: Location,
	name: string?,
	args: { AstExpr },
	deprecatedInfo: {
		deprecated: boolean,
		use: string?,
		reason: string?,
	}?,
}

export type AstGenericType = {
	name: string,
	location: Location,
	default: AstType?,
}

export type AstGenericTypePack = {
	name: string,
	location: Location,
	default: AstTypePack?,
}

export type AstTypeOrPack = {
	kind: "Type" | "TypePack" | "Unknown",
	value: AstType | AstTypePack?,
}

export type AstTypeName = {
	name: string,
	location: Location,
}

export type AstTypeList = {
	types: { AstType },
	tail: AstTypePack?,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Type Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type TypeReference = {
	type: "TypeReference",
	location: Location,
	hasParameterList: boolean,
	name: string,
	nameLocation: Location,
	prefix: string?,
	prefixLocation: Location?,
	parameters: { AstTypeOrPack }?,
}

export type TypeTableProp = {
	name: string,
	type: AstType,
	location: Location,
	access: TableAccess,
	accessLocation: Location?,
}

export type TypeTableIndexer = {
	indexType: AstType,
	resultType: AstType,
	location: Location,
	access: TableAccess,
	accessLocation: Location?,
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
	attributes: { AstAttr }?,
	generics: { AstGenericType }?,
	genericPacks: { AstGenericTypePack }?,
	argTypes: AstTypeList,
	argNames: { AstTypeName? },
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
	types: { AstType },
	isMissing: boolean,
	messageIndex: number,
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
	functionDepth: number,
	loopDepth: number,
	isConst: boolean,
	shadow: {
		name: string,
		location: Location,
	}?,
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
	parseResult: "Ok" | "Imprecise" | "Malformed" | "BinOverflow" | "HexOverflow" | "Unknown",
}

export type ExprConstantString = {
	type: "ExprConstantString",
	location: Location,
	value: string,
	quoteStyle: "QuotedSimple" | "QuotedSingle" | "QuotedRaw" | "Unquoted" | "Unknown",
	isQuoted: boolean,
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
	typeArguments: { AstTypeOrPack }?,
	args: { AstExpr },
	self: boolean,
	argLocation: Location,
}

export type ExprIndexName = {
	type: "ExprIndexName",
	location: Location,
	expr: AstExpr,
	index: string,
	indexLocation: Location,
	opPosition: Position,
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
	attributes: { AstAttr }?,
	debugname: string?,
	generics: { AstGenericType }?,
	genericPacks: { AstGenericTypePack }?,
	args: { AstLocal },
	vararg: boolean,
	varargLocation: Location?,
	varargAnnotation: AstTypePack?,
	returnAnnotation: AstTypePack?,
	self: AstLocal?,
	argLocation: Location?,
	functionDepth: number,
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
	hasThen: boolean,
	trueExpr: AstExpr,
	hasElse: boolean,
	falseExpr: AstExpr,
}

export type ExprInterpString = {
	type: "ExprInterpString",
	location: Location,
	strings: { string },
	expressions: { AstExpr },
}

export type ExprInstantiate = {
	type: "ExprInstantiate",
	location: Location,
	expr: AstExpr,
	typeArguments: { AstTypeOrPack },
}

export type ExprError = {
	type: "ExprError",
	location: Location,
	expressions: { AstExpr },
	messageIndex: number,
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
	| ExprInstantiate
	| ExprError
	| ExprUnknown

-- ═══════════════════════════════════════════════════════════════════════════
-- Statement Nodes
-- ═══════════════════════════════════════════════════════════════════════════

export type Block = {
	type: "Block",
	location: Location,
	hasSemicolon: boolean,
	body: { AstStat },
	hasEnd: boolean,
}

export type StatIf = {
	type: "StatIf",
	location: Location,
	hasSemicolon: boolean,
	condition: AstExpr,
	thenBody: Block,
	elseBody: (Block | StatIf)?,
	thenLocation: Location?,
	elseLocation: Location?,
}

export type StatWhile = {
	type: "StatWhile",
	location: Location,
	hasSemicolon: boolean,
	condition: AstExpr,
	body: Block,
	hasDo: boolean,
	doLocation: Location,
}

export type StatRepeat = {
	type: "StatRepeat",
	location: Location,
	hasSemicolon: boolean,
	condition: AstExpr,
	body: Block,
	hasUntil: boolean,
}

export type StatBreak = {
	type: "StatBreak",
	location: Location,
	hasSemicolon: boolean,
}

export type StatContinue = {
	type: "StatContinue",
	location: Location,
	hasSemicolon: boolean,
}

export type StatReturn = {
	type: "StatReturn",
	location: Location,
	hasSemicolon: boolean,
	list: { AstExpr },
}

export type StatExpr = {
	type: "StatExpr",
	location: Location,
	hasSemicolon: boolean,
	expr: AstExpr,
}

export type StatLocal = {
	type: "StatLocal",
	location: Location,
	hasSemicolon: boolean,
	vars: { AstLocal },
	values: { AstExpr },
	equalsSignLocation: Location?,
}

export type StatFor = {
	type: "StatFor",
	location: Location,
	hasSemicolon: boolean,
	var: AstLocal,
	from: AstExpr,
	to: AstExpr,
	step: AstExpr?,
	body: Block,
	hasDo: boolean,
	doLocation: Location,
}

export type StatForIn = {
	type: "StatForIn",
	location: Location,
	hasSemicolon: boolean,
	vars: { AstLocal },
	values: { AstExpr },
	body: Block,
	hasIn: boolean,
	inLocation: Location,
	hasDo: boolean,
	doLocation: Location,
}

export type StatAssign = {
	type: "StatAssign",
	location: Location,
	hasSemicolon: boolean,
	vars: { AstExpr },
	values: { AstExpr },
}

export type StatCompoundAssign = {
	type: "StatCompoundAssign",
	location: Location,
	hasSemicolon: boolean,
	op: string,
	var: AstExpr,
	value: AstExpr,
}

export type StatFunction = {
	type: "StatFunction",
	location: Location,
	hasSemicolon: boolean,
	name: AstExpr,
	func: ExprFunction,
}

export type StatLocalFunction = {
	type: "StatLocalFunction",
	location: Location,
	hasSemicolon: boolean,
	name: AstLocal,
	func: ExprFunction,
}

export type StatTypeAlias = {
	type: "StatTypeAlias",
	location: Location,
	hasSemicolon: boolean,
	name: string,
	nameLocation: Location,
	exported: boolean,
	aliasedType: AstType,
	generics: { AstGenericType }?,
	genericPacks: { AstGenericTypePack }?,
}

export type StatTypeFunction = {
	type: "StatTypeFunction",
	location: Location,
	hasSemicolon: boolean,
	name: string,
	nameLocation: Location,
	body: ExprFunction,
	exported: boolean,
	hasErrors: boolean,
}

export type StatDeclareGlobal = {
	type: "StatDeclareGlobal",
	location: Location,
	hasSemicolon: boolean,
	name: string,
	nameLocation: Location,
	declaredType: AstType,
}

export type AstParamName = {
	name: string,
	location: Location,
}

export type StatDeclareFunction = {
	type: "StatDeclareFunction",
	location: Location,
	hasSemicolon: boolean,
	attributes: { AstAttr }?,
	name: string,
	nameLocation: Location,
	generics: { AstGenericType }?,
	genericPacks: { AstGenericTypePack }?,
	params: AstTypeList,
	paramNames: { AstParamName },
	vararg: boolean,
	varargLocation: Location,
	returnTypes: AstTypePack,
}

export type AstDeclaredExternTypeProperty = {
	name: string,
	nameLocation: Location,
	type: AstType,
	isMethod: boolean,
	location: Location,
}

export type StatDeclareExternType = {
	type: "StatDeclareExternType",
	location: Location,
	hasSemicolon: boolean,
	name: string,
	superName: string?,
	props: { AstDeclaredExternTypeProperty },
	indexer: TypeTableIndexer?,
}

export type StatError = {
	type: "StatError",
	location: Location,
	hasSemicolon: boolean,
	expressions: { AstExpr },
	statements: { AstStat },
	messageIndex: number,
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
	| StatTypeFunction
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
	surroundingText: { [AstNode]: SurroundingText }?,
	lines: number,
}

return table.freeze({})
