-- Type stubs for the Luau AST shape produced by src/modules/luau/native.cpp.

--- A 1-based source position in the original input.
export type Position = {
	-- The 1-based source line number.
	line: number,
	-- The 1-based source column number.
	column: number,
}

--- A 1-based, half-open source span in the original input.
export type Location = {
	-- The 1-based line where the span begins.
	beginline: number,
	-- The 1-based column where the span begins.
	begincolumn: number,
	-- The 1-based line where the span ends.
	endline: number,
	-- The 1-based column where the span ends.
	endcolumn: number,
}

--- A concrete syntax token captured from the CST.
export type CstToken<Text> = {
	-- Identifies this table as a concrete syntax token.
	type: "token",
	-- The exact source text of the token, including raw literal spelling such as 0x10.
	text: Text,
	-- The span of the token itself, excluding leading and trailing trivia.
	location: Location,
	-- Trivia immediately before this token, such as whitespace and comments.
	leadingText: string,
	-- Trivia immediately after this token, such as whitespace and comments.
	trailingText: string,
}

--- Shared fields present on every serialized AST node.
export type AstNode<Category, Type> = {
	-- The broad AST family this node belongs to.
	category: Category,
	-- The specific node kind within the category.
	type: Type,
	-- The source span covered by the AST node.
	location: Location,
}

--- Shared fields present on every statement node.
export type AstStatNode<Type> = AstNode<"stat", Type> & {
	-- True when the statement was terminated by an explicit semicolon.
	hasSemicolon: boolean,
	-- The trailing semicolon token after this statement, when one was present.
	semicolonToken: CstToken<";">?,
}

--- Shared fields present on every expression node.
export type AstExprNode<Type> = AstNode<"expr", Type>

--- Shared fields present on every type node.
export type AstTypeNode<Type> = AstNode<"type", Type>

--- Shared fields present on every type-pack node.
export type AstTypePackNode<Type> = AstNode<"typePack", Type>

--- Shared fields present on every generic declaration node.
export type AstGenericNode<Type> = AstNode<"generic", Type>

--- Shared fields present on every attribute node.
export type AstAttrNode<Type> = AstNode<"attr", Type>

--- The read/write access qualifier for table and extern type entries.
export type TableAccess = "Read" | "Write" | "ReadWrite"

--- A local binding referenced by declarations and local expressions.
export type AstLocal = AstNode<"", "local"> & {
	-- The local variable name.
	name: string,
	-- The identifier token that introduced or referenced this local.
	nameToken: CstToken<string>?,
	-- The source span of the local identifier.
	location: Location,
	-- The local declaration shadowed by this local, if one exists.
	shadows: AstLocal?,
	-- The function nesting depth where the local is declared.
	functionDepth: number,
	-- The loop nesting depth where the local is declared.
	loopDepth: number,
	-- True when the local is const.
	isConst: boolean,
	-- True when this local came from an exported declaration.
	isExported: boolean,
	-- The type annotation attached to the local declaration.
	annotation: AstType?,
}

--- A type argument item that can be either a type, a type pack, or an absent placeholder.
export type TypeOrPack = { kind: "Type", value: AstType } | { kind: "TypePack", value: AstTypePack } | { kind: "None" }

--- A list of types with an optional trailing type pack.
export type TypeList = {
	-- Positional type entries.
	types: { AstType },
	-- The trailing type pack, when the list ends with one.
	tail: AstTypePack?,
}

--- The optional source name for a function parameter type.
export type ArgumentName = {
	-- The parameter name text.
	name: string,
	-- The source span of the parameter name.
	location: Location,
}

--- A table indexer type, such as {[K]: V}.
export type TableIndexer = {
	-- The type used as the index key.
	indexType: AstType,
	-- The type produced by the indexer.
	resultType: AstType,
	-- The full source span of the indexer entry.
	location: Location,
	-- The optional read/write access mode.
	access: TableAccess,
	-- The source span of the access qualifier, when present.
	accessLocation: Location?,
}

--- A function or declaration attribute such as @native or @deprecated.
export type AstAttr = AstAttrNode<"attribute"> & {
	-- The normalized attribute kind.
	attrType: "Checked" | "Native" | "Deprecated" | "DebugNoinline" | "Unknown",
	-- The attribute name without the @ prefix.
	name: string,
	-- The attribute name token after @.
	nameToken: CstToken<string>,
	-- Attribute argument expressions inside the argument list.
	args: { AstExpr },
	-- Parsed @deprecated payload, when available.
	deprecatedInfo: {
		-- True when the attribute marks a deprecated declaration.
		deprecated: boolean,
		-- The suggested replacement text.
		use: string?,
		-- The deprecation reason text.
		reason: string?,
	}?,
}

--- A named generic type parameter.
export type AstGenericType = AstGenericNode<"type"> & {
	-- The generic parameter name.
	name: string,
	-- The generic parameter identifier token.
	nameToken: CstToken<string>,
	-- The default type after =, when present.
	default: AstType?,
	-- The = token before the default type.
	defaultEqualsToken: CstToken<"=">?,
}

--- A named generic type-pack parameter.
export type AstGenericTypePack = AstGenericNode<"typePack"> & {
	-- The generic pack parameter name.
	name: string,
	-- The generic pack identifier token.
	nameToken: CstToken<string>,
	-- The ... token that marks this generic as a type pack.
	ellipsisToken: CstToken<"...">?,
	-- The default type pack after =, when present.
	default: AstTypePack?,
	-- The = token before the default type pack.
	defaultEqualsToken: CstToken<"=">?,
}

--- A parenthesized expression.
export type AstExprGroup = AstExprNode<"group"> & {
	-- The opening ( token.
	openParenToken: CstToken<"(">,
	-- The expression inside the parentheses.
	expr: AstExpr,
	-- The closing ) token.
	closeParenToken: CstToken<")">,
}

--- The nil literal expression.
export type AstExprConstantNil = AstExprNode<"constantNil"> & {
	-- The nil keyword token.
	token: CstToken<"nil">,
}

--- A boolean literal expression.
export type AstExprConstantBool = AstExprNode<"constantBool"> & {
	-- The parsed boolean value.
	value: boolean,
	-- The true or false keyword token.
	token: CstToken<"true" | "false">,
}

--- A floating point number literal expression.
export type AstExprConstantNumber = AstExprNode<"constantNumber"> & {
	-- The parsed numeric value.
	value: number,
	-- The exact number literal token, preserving raw spelling.
	token: CstToken<string>,
}

--- An integer literal expression.
export type AstExprConstantInteger = AstExprNode<"constantInteger"> & {
	-- The parsed integer value.
	value: number,
	-- The exact integer literal token, preserving raw spelling.
	token: CstToken<string>,
}

--- A string literal expression.
export type AstExprConstantString = AstExprNode<"constantString"> & {
	-- The decoded string value.
	value: string,
	-- The serializer's description of the source quote style.
	quoteStyle: "simple" | "single" | "raw" | "unquoted" | "unknown",
	-- True when the literal was written with quotes in source.
	isQuoted: boolean,
	-- The exact string literal token, preserving raw spelling.
	token: CstToken<string>,
}

--- A reference to a local binding.
export type AstExprLocal = AstExprNode<"local"> & {
	-- The local binding object being referenced.
	["local"]: AstLocal,
	-- True when the referenced local is captured from an outer function.
	upvalue: boolean,
	-- The identifier token at this reference site.
	nameToken: CstToken<string>,
}

--- A reference to a global binding.
export type AstExprGlobal = AstExprNode<"global"> & {
	-- The global name.
	name: string,
	-- The global identifier token.
	nameToken: CstToken<string>,
}

--- A vararg expression.
export type AstExprVarargs = AstExprNode<"varargs"> & {
	-- The ... token.
	token: CstToken<"...">,
}

--- A function or method call expression.
export type AstExprCall = AstExprNode<"call"> & {
	-- The expression being called.
	func: AstExpr,
	-- Explicit type arguments passed with <<...>>.
	typeArguments: { TypeOrPack },
	-- Runtime argument expressions.
	args: { AstExpr },
	-- True when this is a method-style self call.
	self: boolean,
	-- The source span covering the argument syntax.
	argLocation: Location,
	-- The first < token in an explicit << type argument list.
	leftArrow1Token: CstToken<"<">?,
	-- The second < token in an explicit << type argument list.
	leftArrow2Token: CstToken<"<">?,
	-- The first > token in an explicit >> type argument list.
	rightArrow1Token: CstToken<">">?,
	-- The second > token in an explicit >> type argument list.
	rightArrow2Token: CstToken<">">?,
	-- The opening ( token for parenthesized call arguments.
	openParenToken: CstToken<"(">?,
	-- The closing ) token for parenthesized call arguments.
	closeParenToken: CstToken<")">?,
	-- Dynamic CST token fields such as type argument commas and argument commas.
	[string]: any,
}

--- A field or method-name indexing expression, such as a.b or a:b.
export type AstExprIndexName = AstExprNode<"indexName"> & {
	-- The table or object expression being indexed.
	expr: AstExpr,
	-- The field or method name.
	index: string,
	-- The source span of the field or method name.
	indexLocation: Location,
	-- The source position of the . or : operator.
	opPosition: Position,
	-- The . or : token.
	opToken: CstToken<"." | ":">,
	-- The identifier token after the . or : operator.
	indexToken: CstToken<string>,
}

--- A bracket indexing expression, such as a[b].
export type AstExprIndexExpr = AstExprNode<"indexExpr"> & {
	-- The table or object expression being indexed.
	expr: AstExpr,
	-- The expression inside the brackets.
	index: AstExpr,
	-- The opening [ token.
	openBracketToken: CstToken<"[">,
	-- The closing ] token.
	closeBracketToken: CstToken<"]">,
}

--- A function expression.
export type AstExprFunction = AstExprNode<"function"> & {
	-- Attributes applied to the function.
	attributes: { AstAttr },
	-- Generic type parameters.
	generics: { AstGenericType },
	-- Generic type-pack parameters.
	genericPacks: { AstGenericTypePack },
	-- The implicit self local for method functions.
	self: AstLocal?,
	-- Function parameter locals.
	args: { AstLocal },
	-- The annotated return type pack.
	returnAnnotation: AstTypePack?,
	-- True when the function accepts varargs.
	vararg: boolean,
	-- The source span of the vararg marker.
	varargLocation: Location,
	-- The annotated vararg type pack.
	varargAnnotation: AstTypePack?,
	-- The function body block.
	body: AstStatBlock,
	-- The function nesting depth.
	functionDepth: number,
	-- The debug name inferred by the parser.
	debugname: string,
	-- The source span of the parameter list.
	argLocation: Location?,
	-- The function keyword token for full function expressions and declarations.
	functionKeywordToken: CstToken<"function">?,
	-- The opening < token for generic parameters.
	openGenericsToken: CstToken<"<">?,
	-- The closing > token for generic parameters.
	closeGenericsToken: CstToken<">">?,
	-- The opening ( token for the parameter list.
	openParenToken: CstToken<"(">?,
	-- The closing ) token for the parameter list.
	closeParenToken: CstToken<")">?,
	-- The ... token for vararg parameters.
	varargToken: CstToken<"...">?,
	-- The : token before the return annotation.
	returnColonToken: CstToken<":">?,
	-- The end keyword token closing the function body.
	endKeywordToken: CstToken<"end">,
	-- Dynamic CST token fields such as parameter commas and generic commas.
	[string]: any,
}

--- An item inside a table constructor.
export type AstExprTableItem = {
	-- The table item form: array item, name record, or bracketed key record.
	kind: "list" | "record" | "general",
	-- The key expression for keyed entries.
	key: AstExpr?,
	-- The value expression stored in the table.
	value: AstExpr,
}

--- A table constructor expression.
export type AstExprTable = AstExprNode<"table"> & {
	-- Table entries in source order.
	items: { AstExprTableItem },
	-- The opening { token.
	openBraceToken: CstToken<"{">,
	-- The closing } token.
	closeBraceToken: CstToken<"}">,
	-- Dynamic CST token fields such as item separators, [ and ], and = tokens.
	[string]: any,
}

--- A unary operator expression.
export type AstExprUnary = AstExprNode<"unary"> & {
	-- The normalized unary operator name.
	op: string,
	-- The operand expression.
	expr: AstExpr,
	-- The unary operator token, such as not, -, or #.
	opToken: CstToken<string>,
}

--- A binary operator expression.
export type AstExprBinary = AstExprNode<"binary"> & {
	-- The normalized binary operator name.
	op: string,
	-- The left operand.
	left: AstExpr,
	-- The right operand.
	right: AstExpr,
	-- The binary operator token, such as +, and, or ==.
	opToken: CstToken<string>,
}

--- A type assertion expression.
export type AstExprTypeAssertion = AstExprNode<"typeAssertion"> & {
	-- The expression being asserted.
	expr: AstExpr,
	-- The asserted type annotation.
	annotation: AstType,
	-- The :: token.
	opToken: CstToken<"::">,
}

--- An if expression.
export type AstExprIfElse = AstExprNode<"ifElse"> & {
	-- The condition expression.
	condition: AstExpr,
	-- The expression after then.
	thenExpr: AstExpr?,
	-- The expression after else.
	elseExpr: AstExpr?,
	-- The if token, or elseif token for chained branches represented as nested nodes.
	ifKeywordToken: CstToken<"if" | "elseif">?,
	-- The then keyword token.
	thenKeywordToken: CstToken<"then">?,
	-- The else or elseif keyword token.
	elseKeywordToken: CstToken<"else" | "elseif">?,
}

--- An interpolated string expression.
export type AstExprInterpString = AstExprNode<"interpString"> & {
	-- Literal string segments between interpolation holes.
	strings: { string },
	-- Expressions inside interpolation holes.
	expressions: { AstExpr },
	-- Dynamic CST token fields for interpolation delimiters and segment tokens.
	[string]: any,
}

--- An expression with explicit type instantiation.
export type AstExprInstantiate = AstExprNode<"instantiate"> & {
	-- The expression being instantiated.
	expr: AstExpr,
	-- The explicit type and type-pack arguments.
	typeArguments: { TypeOrPack },
	-- The first < token in the opening <<.
	leftArrow1Token: CstToken<"<">,
	-- The second < token in the opening <<.
	leftArrow2Token: CstToken<"<">,
	-- The first > token in the closing >>.
	rightArrow1Token: CstToken<">">,
	-- The second > token in the closing >>.
	rightArrow2Token: CstToken<">">,
	-- Dynamic CST token fields such as type argument commas.
	[string]: any,
}

--- An expression placeholder produced for parse errors.
export type AstExprError = AstExprNode<"error"> & {
	-- Child expressions retained by the parser around the error.
	expressions: { AstExpr },
	-- Index into the parser error list for the associated diagnostic.
	messageIndex: number,
	-- The concrete source span token synthesized for the error range.
	spanToken: CstToken<string>,
}

--- A statement block.
export type AstStatBlock = AstStatNode<"block"> & {
	-- Statements in the block.
	body: { AstStat },
	-- The zero-width end-of-file token for the root block, when emitted.
	eofToken: CstToken<"">?,
}

--- An if statement.
export type AstStatIf = AstStatNode<"if"> & {
	-- The condition expression.
	condition: AstExpr,
	-- The block executed when the condition is truthy.
	thenBody: AstStatBlock,
	-- The else or elseif block.
	elseBody: AstStatBlock?,
	-- The source span of the then keyword.
	thenLocation: Location?,
	-- The source span of the else keyword.
	elseLocation: Location?,
	-- The if keyword token. Nested elseif nodes omit this because their parent owns the elseif token.
	ifKeywordToken: CstToken<"if">?,
	-- The then keyword token.
	thenKeywordToken: CstToken<"then">?,
	-- The else or elseif keyword token.
	elseKeywordToken: CstToken<"else" | "elseif">?,
	-- The end keyword token closing the statement.
	endKeywordToken: CstToken<"end">,
}

--- A while loop statement.
export type AstStatWhile = AstStatNode<"while"> & {
	-- The loop condition expression.
	condition: AstExpr,
	-- The loop body block.
	body: AstStatBlock,
	-- The source span of the do keyword.
	doLocation: Location?,
	-- The while keyword token.
	whileKeywordToken: CstToken<"while">,
	-- The do keyword token.
	doKeywordToken: CstToken<"do">?,
	-- The end keyword token closing the loop.
	endKeywordToken: CstToken<"end">,
}

--- A repeat-until loop statement.
export type AstStatRepeat = AstStatNode<"repeat"> & {
	-- The repeated body block.
	body: AstStatBlock,
	-- The condition expression after until.
	condition: AstExpr,
	-- The repeat keyword token.
	repeatKeywordToken: CstToken<"repeat">,
	-- The until keyword token.
	untilKeywordToken: CstToken<"until">,
}

--- A break statement.
export type AstStatBreak = AstStatNode<"break"> & {
	-- The break keyword token.
	breakKeywordToken: CstToken<"break">,
}

--- A continue statement.
export type AstStatContinue = AstStatNode<"continue"> & {
	-- The continue keyword token.
	continueKeywordToken: CstToken<"continue">,
}

--- A return statement.
export type AstStatReturn = AstStatNode<"return"> & {
	-- Returned expression list.
	list: { AstExpr },
	-- The return keyword token.
	returnKeywordToken: CstToken<"return">,
	-- Dynamic CST token fields such as expression list commas.
	[string]: any,
}

--- A statement that consists of a single expression.
export type AstStatExpr = AstStatNode<"expr"> & {
	-- The expression being used as a statement.
	expr: AstExpr,
}

--- A local variable declaration statement.
export type AstStatLocal = AstStatNode<"local"> & {
	-- Declared local bindings.
	vars: { AstLocal },
	-- Initializer expressions after =.
	values: { AstExpr },
	-- True when the declaration uses const.
	isConst: boolean,
	-- The source span of the = token.
	equalsSignLocation: Location?,
	-- The local or const declaration keyword token.
	localKeywordToken: CstToken<"local" | "const">,
	-- The = token before initializer expressions.
	equalsToken: CstToken<"=">?,
	-- Dynamic CST token fields such as local-name commas and initializer commas.
	[string]: any,
}

--- A numeric for loop statement.
export type AstStatFor = AstStatNode<"for"> & {
	-- The loop variable local.
	var: AstLocal,
	-- The initial value expression.
	from: AstExpr,
	-- The limit value expression.
	to: AstExpr,
	-- The optional step expression.
	step: AstExpr?,
	-- The loop body block.
	body: AstStatBlock,
	-- The source span of the do keyword.
	doLocation: Location?,
	-- The for keyword token.
	forKeywordToken: CstToken<"for">,
	-- The = token after the loop variable.
	equalsToken: CstToken<"=">,
	-- The comma token between the initial and limit expressions.
	endCommaToken: CstToken<",">,
	-- The comma token before the step expression.
	stepCommaToken: CstToken<",">?,
	-- The do keyword token.
	doKeywordToken: CstToken<"do">?,
	-- The end keyword token closing the loop.
	endKeywordToken: CstToken<"end">,
}

--- A generic for-in loop statement.
export type AstStatForIn = AstStatNode<"forIn"> & {
	-- Loop variable locals.
	vars: { AstLocal },
	-- Iterator expressions after in.
	values: { AstExpr },
	-- The loop body block.
	body: AstStatBlock,
	-- The source span of the in keyword.
	inLocation: Location?,
	-- The source span of the do keyword.
	doLocation: Location?,
	-- The for keyword token.
	forKeywordToken: CstToken<"for">,
	-- The in keyword token.
	inKeywordToken: CstToken<"in">?,
	-- The do keyword token.
	doKeywordToken: CstToken<"do">?,
	-- The end keyword token closing the loop.
	endKeywordToken: CstToken<"end">,
	-- Dynamic CST token fields such as variable and iterator commas.
	[string]: any,
}

--- An assignment statement.
export type AstStatAssign = AstStatNode<"assign"> & {
	-- Assignment target expressions.
	vars: { AstExpr },
	-- Value expressions.
	values: { AstExpr },
	-- The = token between targets and values.
	equalsToken: CstToken<"=">,
	-- Dynamic CST token fields such as target and value commas.
	[string]: any,
}

--- A compound assignment statement.
export type AstStatCompoundAssign = AstStatNode<"compoundAssign"> & {
	-- The normalized compound operator name.
	op: string,
	-- The assignment target expression.
	var: AstExpr,
	-- The value expression.
	value: AstExpr,
	-- The compound assignment operator token, such as += or ..=.
	opToken: CstToken<string>,
}

--- A global or table function declaration statement.
export type AstStatFunction = AstStatNode<"function"> & {
	-- The function name expression.
	name: AstExpr,
	-- The function body expression node.
	func: AstExprFunction,
	-- The function keyword token that starts the declaration.
	functionKeywordToken: CstToken<"function">,
}

--- A local function declaration statement.
export type AstStatLocalFunction = AstStatNode<"localFunction"> & {
	-- The declared local function binding.
	name: AstLocal,
	-- The function body expression node.
	func: AstExprFunction,
	-- True when the local function declaration is const.
	isConst: boolean,
	-- The local keyword token.
	localKeywordToken: CstToken<"local">,
	-- The function keyword token.
	functionKeywordToken: CstToken<"function">,
	-- The local function name identifier token.
	nameToken: CstToken<string>,
}

--- A type alias declaration statement.
export type AstStatTypeAlias = AstStatNode<"typeAlias"> & {
	-- The alias name.
	name: string,
	-- The source span of the alias name.
	nameLocation: Location,
	-- Generic type parameters.
	generics: { AstGenericType },
	-- Generic type-pack parameters.
	genericPacks: { AstGenericTypePack },
	-- The aliased type.
	aliasedType: AstType,
	-- True when this is an exported type alias.
	exported: boolean,
	-- The export keyword token.
	exportKeywordToken: CstToken<"export">?,
	-- The type keyword token.
	typeKeywordToken: CstToken<"type">,
	-- The alias name identifier token.
	nameToken: CstToken<string>,
	-- The = token before the aliased type.
	equalsToken: CstToken<"=">,
}

--- A type function declaration statement.
export type AstStatTypeFunction = AstStatNode<"typeFunction"> & {
	-- The type function name.
	name: string,
	-- The source span of the type function name.
	nameLocation: Location,
	-- The function body, when the parser produced one.
	body: AstExprFunction?,
	-- True when this is an exported type function.
	exported: boolean,
	-- True when the parser reported errors inside this declaration.
	hasErrors: boolean,
	-- The export keyword token.
	exportKeywordToken: CstToken<"export">?,
	-- The type keyword token.
	typeKeywordToken: CstToken<"type">,
	-- The function keyword token.
	functionKeywordToken: CstToken<"function">,
	-- The type function name identifier token.
	nameToken: CstToken<string>,
}

--- A member entry in a class declaration.
export type AstClassMember =
	{
		-- Identifies a class property member.
		kind: "property",
		-- The source span of an optional access qualifier.
		qualifierLocation: Location?,
		-- The property name.
		name: string,
		-- The source span of the property name.
		nameLocation: Location,
		-- The source span of the : before the property type.
		typeColonLocation: Location?,
		-- The property type annotation.
		type: AstType?,
	}
	| {
		-- Identifies a class method member.
		kind: "method",
		-- The source span of an optional access qualifier.
		qualifierLocation: Location?,
		-- The source span of the method keyword.
		keywordLocation: Location,
		-- The method name.
		name: string,
		-- The source span of the method name.
		nameLocation: Location,
		-- The function expression implementing the method.
		["function"]: AstExprFunction,
	}

--- A class declaration statement.
export type AstStatClass = AstStatNode<"class"> & {
	-- The class local binding.
	name: AstLocal,
	-- Class property and method members.
	members: { AstClassMember },
	-- True when this is an exported class declaration.
	exported: boolean,
	-- The export keyword token.
	exportKeywordToken: CstToken<"export">?,
	-- The class keyword token.
	classKeywordToken: CstToken<"class">?,
	-- The class name identifier token.
	nameToken: CstToken<string>,
	-- The end keyword token closing the class declaration.
	endKeywordToken: CstToken<"end">,
	-- Dynamic CST token fields for class member punctuation.
	[string]: any,
}

--- A declare global statement.
export type AstStatDeclareGlobal = AstStatNode<"declareGlobal"> & {
	-- The declared global name.
	name: string,
	-- The source span of the global name.
	nameLocation: Location,
	-- The declared global type.
	declaredType: AstType,
	-- The declare keyword token.
	declareKeywordToken: CstToken<"declare">,
	-- The global name identifier token.
	nameToken: CstToken<string>,
	-- The : token before the declared type.
	colonToken: CstToken<":">?,
}

--- A declare function statement.
export type AstStatDeclareFunction = AstStatNode<"declareFunction"> & {
	-- Attributes applied to the declaration.
	attributes: { AstAttr },
	-- The declared function name.
	name: string,
	-- The source span of the declared function name.
	nameLocation: Location,
	-- Generic type parameters.
	generics: { AstGenericType },
	-- Generic type-pack parameters.
	genericPacks: { AstGenericTypePack },
	-- Parameter types.
	params: TypeList,
	-- Optional parameter names.
	paramNames: { ArgumentName },
	-- True when the declaration accepts varargs.
	vararg: boolean,
	-- The source span of the vararg marker.
	varargLocation: Location,
	-- Return type pack.
	returnTypes: AstTypePack?,
	-- The declare keyword token.
	declareKeywordToken: CstToken<"declare">,
	-- The function keyword token.
	functionKeywordToken: CstToken<"function">?,
	-- The function name identifier token.
	nameToken: CstToken<string>,
}

--- A property inside a declared extern type.
export type DeclaredExternTypeProperty = {
	-- The extern property name.
	name: string,
	-- The source span of the property name.
	nameLocation: Location,
	-- The property type.
	type: AstType?,
	-- True when the property is declared as a method.
	isMethod: boolean,
	-- The optional read/write access mode.
	access: TableAccess,
	-- The full source span of the property declaration.
	location: Location,
}

--- A declare extern type statement.
export type AstStatDeclareExternType = AstStatNode<"declareExternType"> & {
	-- The declared extern type name.
	name: string,
	-- The optional supertype name.
	superName: string?,
	-- Declared properties.
	props: { DeclaredExternTypeProperty },
	-- Optional indexer declaration.
	indexer: TableIndexer?,
	-- The declare keyword token.
	declareKeywordToken: CstToken<"declare">,
	-- The end keyword token closing the extern type.
	endKeywordToken: CstToken<"end">,
}

--- A statement placeholder produced for parse errors.
export type AstStatError = AstStatNode<"error"> & {
	-- Child expressions retained by the parser around the error.
	expressions: { AstExpr },
	-- Child statements retained by the parser around the error.
	statements: { AstStat },
	-- Index into the parser error list for the associated diagnostic.
	messageIndex: number,
	-- The concrete source span token synthesized for the error range.
	spanToken: CstToken<string>,
}

--- A named type reference, optionally with a prefix and type arguments.
export type AstTypeReference = AstTypeNode<"reference"> & {
	-- True when source explicitly included a parameter list.
	hasParameterList: boolean,
	-- The referenced type name.
	name: string,
	-- The source span of the referenced type name.
	nameLocation: Location,
	-- The optional prefix before a dot.
	prefix: string?,
	-- The source span of the optional prefix.
	prefixLocation: Location?,
	-- Type and type-pack arguments inside <...>.
	parameters: { TypeOrPack }?,
	-- The prefix identifier token before the dot.
	prefixToken: CstToken<string>?,
	-- The . token between prefix and name.
	prefixDotToken: CstToken<".">?,
	-- The referenced type name identifier token.
	nameToken: CstToken<string>,
	-- The opening < token for type parameters.
	openParametersToken: CstToken<"<">?,
	-- The closing > token for type parameters.
	closeParametersToken: CstToken<">">?,
	-- Dynamic CST token fields such as type parameter commas.
	[string]: any,
}

--- A named property inside a table type.
export type AstTypeTableProp = {
	-- The property name.
	name: string,
	-- The property type.
	type: AstType,
	-- The full source span of the property entry.
	location: Location,
	-- The optional read/write access mode.
	access: TableAccess,
	-- The source span of the access qualifier, when present.
	accessLocation: Location?,
}

--- A table type.
export type AstTypeTable = AstTypeNode<"table"> & {
	-- Named property entries.
	props: { AstTypeTableProp },
	-- Optional indexer entry.
	indexer: TableIndexer?,
	-- The opening { token.
	openBraceToken: CstToken<"{">,
	-- The closing } token.
	closeBraceToken: CstToken<"}">,
	-- Dynamic CST token fields such as property separators, [, ], and : tokens.
	[string]: any,
}

--- A function type.
export type AstTypeFunction = AstTypeNode<"function"> & {
	-- Attributes applied to the function type.
	attributes: { AstAttr },
	-- Generic type parameters.
	generics: { AstGenericType },
	-- Generic type-pack parameters.
	genericPacks: { AstGenericTypePack },
	-- Argument type list.
	argTypes: TypeList,
	-- Optional argument names paired with argument types.
	argNames: { ArgumentName? },
	-- Return type pack after ->.
	returnTypes: AstTypePack?,
	-- The opening < token for generic parameters.
	openGenericsToken: CstToken<"<">?,
	-- The closing > token for generic parameters.
	closeGenericsToken: CstToken<">">?,
	-- The opening ( token for argument types.
	openArgsToken: CstToken<"(">?,
	-- The closing ) token for argument types.
	closeArgsToken: CstToken<")">?,
	-- The -> token before return types.
	returnArrowToken: CstToken<"->">?,
	-- Dynamic CST token fields such as argument names, colons, and commas.
	[string]: any,
}

--- A typeof type expression.
export type AstTypeTypeof = AstTypeNode<"typeof"> & {
	-- The expression inside typeof(...).
	expr: AstExpr,
	-- The typeof keyword token.
	typeofKeywordToken: CstToken<"typeof">,
	-- The opening ( token.
	openParenToken: CstToken<"(">?,
	-- The closing ) token.
	closeParenToken: CstToken<")">?,
}

--- An optional type, such as T?.
export type AstTypeOptional = AstTypeNode<"optional"> & {
	-- The ? token after the base type.
	token: CstToken<"?">,
}

--- A union type.
export type AstTypeUnion = AstTypeNode<"union"> & {
	-- Type branches in the union.
	types: { AstType },
	-- A leading | token when the union starts with one.
	leadingSeparatorToken: CstToken<"|">?,
	-- Dynamic CST token fields such as separator | tokens between branches.
	[string]: any,
}

--- An intersection type.
export type AstTypeIntersection = AstTypeNode<"intersection"> & {
	-- Type branches in the intersection.
	types: { AstType },
	-- A leading & token when the intersection starts with one.
	leadingSeparatorToken: CstToken<"&">?,
	-- Dynamic CST token fields such as separator & tokens between branches.
	[string]: any,
}

--- A type placeholder produced for parse errors.
export type AstTypeError = AstTypeNode<"error"> & {
	-- Child types retained by the parser around the error.
	types: { AstType },
	-- True when the type node represents a missing type.
	isMissing: boolean,
	-- Index into the parser error list for the associated diagnostic.
	messageIndex: number,
	-- The concrete source span token synthesized for the error range.
	spanToken: CstToken<string>,
}

--- A singleton boolean type.
export type AstTypeSingletonBool = AstTypeNode<"singletonBool"> & {
	-- The parsed boolean value.
	value: boolean,
	-- The true or false token.
	token: CstToken<"true" | "false">,
}

--- A singleton string type.
export type AstTypeSingletonString = AstTypeNode<"singletonString"> & {
	-- The decoded string value.
	value: string,
	-- The exact string literal token, preserving raw spelling.
	token: CstToken<string>,
}

--- A parenthesized type.
export type AstTypeGroup = AstTypeNode<"group"> & {
	-- The type inside the parentheses.
	innerType: AstType,
	-- The opening ( token.
	openParenToken: CstToken<"(">,
	-- The closing ) token.
	closeParenToken: CstToken<")">,
}

--- An explicit type pack.
export type AstTypePackExplicit = AstTypePackNode<"explicit"> & {
	-- The contained type list.
	typeList: TypeList,
	-- The opening ( token around the pack.
	openParenToken: CstToken<"(">?,
	-- The closing ) token around the pack.
	closeParenToken: CstToken<")">?,
	-- Dynamic CST token fields such as type-list commas.
	[string]: any,
}

--- A variadic type pack.
export type AstTypePackVariadic = AstTypePackNode<"variadic"> & {
	-- The repeated type.
	variadicType: AstType,
	-- The ... token before or after the variadic type, depending on source form.
	ellipsisToken: CstToken<"...">,
}

--- A generic type-pack reference.
export type AstTypePackGeneric = AstTypePackNode<"generic"> & {
	-- The generic pack name.
	name: string,
	-- The generic pack identifier token.
	nameToken: CstToken<string>,
	-- The ... token associated with the generic pack spelling.
	ellipsisToken: CstToken<"...">?,
}

--- An unknown type-pack placeholder.
export type AstTypePackUnknown = AstTypePackNode<"unknown"> & {
	-- The token that produced the unknown type pack.
	token: CstToken<string>,
}

--- An unknown type placeholder.
export type AstTypeUnknown = AstTypeNode<"unknown"> & {
	-- The token that produced the unknown type.
	token: CstToken<string>,
}

--- Any expression node emitted by the serializer.
export type AstExpr =
	AstExprGroup
	| AstExprConstantNil
	| AstExprConstantBool
	| AstExprConstantNumber
	| AstExprConstantInteger
	| AstExprConstantString
	| AstExprLocal
	| AstExprGlobal
	| AstExprVarargs
	| AstExprCall
	| AstExprIndexName
	| AstExprIndexExpr
	| AstExprFunction
	| AstExprTable
	| AstExprUnary
	| AstExprBinary
	| AstExprTypeAssertion
	| AstExprIfElse
	| AstExprInterpString
	| AstExprInstantiate
	| AstExprError

--- Any statement node emitted by the serializer.
export type AstStat =
	AstStatBlock
	| AstStatIf
	| AstStatWhile
	| AstStatRepeat
	| AstStatBreak
	| AstStatContinue
	| AstStatReturn
	| AstStatExpr
	| AstStatLocal
	| AstStatFor
	| AstStatForIn
	| AstStatAssign
	| AstStatCompoundAssign
	| AstStatFunction
	| AstStatLocalFunction
	| AstStatTypeAlias
	| AstStatTypeFunction
	| AstStatClass
	| AstStatDeclareGlobal
	| AstStatDeclareFunction
	| AstStatDeclareExternType
	| AstStatError

--- Any type node emitted by the serializer.
export type AstType =
	AstTypeReference
	| AstTypeTable
	| AstTypeFunction
	| AstTypeTypeof
	| AstTypeOptional
	| AstTypeUnion
	| AstTypeIntersection
	| AstTypeError
	| AstTypeSingletonBool
	| AstTypeSingletonString
	| AstTypeGroup
	| AstTypeUnknown

--- Any type-pack node emitted by the serializer.
export type AstTypePack = AstTypePackExplicit | AstTypePackVariadic | AstTypePackGeneric | AstTypePackUnknown

--- Any AST payload node emitted by the serializer.
export type AstAny = AstExpr | AstStat | AstType | AstTypePack | AstGenericType | AstGenericTypePack | AstAttr

return nil
