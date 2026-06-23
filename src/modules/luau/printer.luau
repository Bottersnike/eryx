--[=[
	Luau AST printer.

	Two modes, selected by `PrintOptions.mode`:

	- "preserve" reproduces the original source by emitting the trivia
	  (`leadingText`/`trailingText`) carried on the CST tokens of the AST. It is a
	  faithful round-trip of whatever tokens are present.
	- "pretty" formats purely from the AST structure and never looks at any token
	  or `text` field. It re-derives all whitespace, indentation, and punctuation,
	  so its output is canonical rather than original.
]=]

local ast = require("@eryx/luau/ast")

export type AstNode = ast.AstAny

export type PrintOptions = {
	mode: ("pretty" | "preserve")?,
}

local printer = {}

local INDENT = "\t"

local function indent(level: number): string
	return string.rep(INDENT, level)
end

local function quoteString(value: string): string
	return string.format("%q", value)
end

local function hasItems(values: any): boolean
	return type(values) == "table" and #values > 0
end

-- Pretty mode renders a statement-terminating `;` (recorded as `hasSemicolon`)
-- at the start of the following statement's line, after its indentation. This
-- keeps load-bearing semicolons -- a line beginning with `(` would otherwise be
-- parsed as a call continuation of the previous line.
local function prefixSemicolon(line: string): string
	local lead = line:match("^[\t ]*") or ""
	return lead .. ";" .. line:sub(#lead + 1)
end

-- ── Pretty mode ─────────────────────────────────────────────────────────────
-- Mutually recursive; forward declared so helpers below can reference them.
local typeToString: (any) -> string
local typePackToString: (any) -> string
local typeOrPackToString: (any) -> string
local exprToString: (any, number) -> string
local statToString: (any, number) -> string
local blockToString: (any, number) -> string
local exprPrecedence: (any) -> number

local binaryPrecedence: { [string]: number } = {
	["or"] = 1,
	["and"] = 2,
	["<"] = 3,
	[">"] = 3,
	["<="] = 3,
	[">="] = 3,
	["~="] = 3,
	["=="] = 3,
	[".."] = 4,
	["+"] = 5,
	["-"] = 5,
	["*"] = 6,
	["/"] = 6,
	["//"] = 6,
	["%"] = 6,
	["^"] = 8,
}

local function parenthesizeIfNeeded(text: string, child: any, parentPrecedence: number): string
	if exprPrecedence(child) < parentPrecedence then
		return "(" .. text .. ")"
	end
	return text
end

-- Wraps a `head` line around an indented block body, closing with `end`.
local function wrapBlock(head: string, body: any, level: number): string
	local rendered = blockToString(body, level + 1)
	local bodyPart = if rendered == "" then "" else "\n" .. rendered
	return head .. bodyPart .. "\n" .. indent(level) .. "end"
end

local function genericsToString(generics: any, genericPacks: any): string
	local parts: { string } = {}
	for _, generic in if type(generics) == "table" then generics else {} do
		local text = tostring(generic.name)
		if generic.default then
			text ..= " = " .. typeToString(generic.default)
		end
		table.insert(parts, text)
	end
	for _, generic in if type(genericPacks) == "table" then genericPacks else {} do
		local text = tostring(generic.name) .. "..."
		if generic.default then
			text ..= " = " .. typeOrPackToString(generic.default)
		end
		table.insert(parts, text)
	end
	if #parts == 0 then
		return ""
	end
	return "<" .. table.concat(parts, ", ") .. ">"
end

-- A function's vararg annotation (`...: T`) is modelled as a variadic type pack
-- whose location is just `T`, with no leading `...`. Render only the type.
local function varargAnnotationToString(pack: any): string
	if type(pack) ~= "table" then
		return ""
	end
	if pack.type == "variadic" then
		return typeToString(pack.variadicType)
	end
	if pack.type == "generic" then
		return tostring(pack.name) .. "..."
	end
	return typePackToString(pack)
end

local function localDeclToString(localNode: any): string
	local text = tostring(if type(localNode) == "table" then localNode.name else "_")
	if type(localNode) == "table" and localNode.annotation then
		text ..= ": " .. typeToString(localNode.annotation)
	end
	return text
end

local function functionParamsToString(func: any): string
	local parts: { string } = {}
	for _, arg in if type(func.args) == "table" then func.args else {} do
		local text = tostring(arg.name)
		if arg.annotation then
			text ..= ": " .. typeToString(arg.annotation)
		end
		table.insert(parts, text)
	end
	if func.vararg then
		local text = "..."
		if func.varargAnnotation then
			text ..= ": " .. varargAnnotationToString(func.varargAnnotation)
		end
		table.insert(parts, text)
	end
	return table.concat(parts, ", ")
end

local function functionReturnToString(func: any): string
	if func.returnAnnotation then
		return ": " .. typePackToString(func.returnAnnotation)
	end
	return ""
end

-- The signature shared by every `function` form: `<generics>(params)` plus an
-- optional return annotation.
local function functionSignature(func: any): string
	return genericsToString(func.generics, func.genericPacks)
		.. "("
		.. functionParamsToString(func)
		.. ")"
		.. functionReturnToString(func)
end

local function typeListWithNames(typeList: any, names: any): string
	local parts: { string } = {}
	local types = if type(typeList) == "table" and type(typeList.types) == "table" then typeList.types else {}
	for i, ty in types do
		local nameInfo = if type(names) == "table" then names[i] else nil
		local prefix = if type(nameInfo) == "table" and nameInfo.name then tostring(nameInfo.name) .. ": " else ""
		table.insert(parts, prefix .. typeToString(ty))
	end
	if type(typeList) == "table" and type(typeList.tail) == "table" then
		table.insert(parts, typePackToString(typeList.tail))
	end
	return table.concat(parts, ", ")
end

local function accessPrefix(access: string?): string
	if access and access ~= "ReadWrite" then
		return string.lower(access) .. " "
	end
	return ""
end

local function tableTypeToString(node: any): string
	local entries: { string } = {}
	for _, prop in if type(node.props) == "table" then node.props else {} do
		table.insert(entries, accessPrefix(prop.access) .. tostring(prop.name) .. ": " .. typeToString(prop.type))
	end
	if type(node.indexer) == "table" then
		local idx = node.indexer
		table.insert(
			entries,
			accessPrefix(idx.access) .. "[" .. typeToString(idx.indexType) .. "]: " .. typeToString(idx.resultType)
		)
	end
	if #entries == 0 then
		return "{}"
	end
	return "{ " .. table.concat(entries, ", ") .. " }"
end

-- A postfix `?` becomes an `optional` member sitting after the type it makes
-- optional, so attach the `?` to the preceding rendered branch.
local function unionToString(node: any): string
	local parts: { string } = {}
	for _, branch in if type(node.types) == "table" then node.types else {} do
		if branch.type == "optional" then
			if #parts > 0 then
				parts[#parts] ..= "?"
			else
				table.insert(parts, "?")
			end
		else
			table.insert(parts, typeToString(branch))
		end
	end
	return table.concat(parts, " | ")
end

typeToString = function(node: any): string
	if type(node) ~= "table" then
		return "any"
	end
	local kind = node.type

	if kind == "reference" then
		local name = if node.prefix then tostring(node.prefix) .. "." .. tostring(node.name) else tostring(node.name)
		if hasItems(node.parameters) then
			local params: { string } = {}
			for _, parameter in node.parameters do
				table.insert(params, typeOrPackToString(parameter))
			end
			name ..= "<" .. table.concat(params, ", ") .. ">"
		end
		return name
	elseif kind == "table" then
		return tableTypeToString(node)
	elseif kind == "function" then
		local ret = if node.returnTypes then typePackToString(node.returnTypes) else "()"
		return genericsToString(node.generics, node.genericPacks)
			.. "("
			.. typeListWithNames(node.argTypes, node.argNames)
			.. ") -> "
			.. ret
	elseif kind == "typeof" then
		return "typeof(" .. exprToString(node.expr, 0) .. ")"
	elseif kind == "optional" then
		return "?"
	elseif kind == "union" then
		return unionToString(node)
	elseif kind == "intersection" then
		local parts: { string } = {}
		for _, branch in if type(node.types) == "table" then node.types else {} do
			table.insert(parts, typeToString(branch))
		end
		return table.concat(parts, " & ")
	elseif kind == "singletonBool" then
		return tostring(node.value)
	elseif kind == "singletonString" then
		return quoteString(tostring(node.value))
	elseif kind == "group" then
		return "(" .. typeToString(node.innerType) .. ")"
	end

	return "any"
end

typePackToString = function(node: any): string
	if type(node) ~= "table" then
		return ""
	end
	local kind = node.type

	if kind == "explicit" then
		local typeList = node.typeList
		local types = if type(typeList) == "table" and type(typeList.types) == "table" then typeList.types else {}
		local tail = if type(typeList) == "table" then typeList.tail else nil
		-- A single type with no tail prints bare (e.g. `-> number`).
		if #types == 1 and tail == nil then
			return typeToString(types[1])
		end
		local parts: { string } = {}
		for _, ty in types do
			table.insert(parts, typeToString(ty))
		end
		if tail then
			table.insert(parts, typePackToString(tail))
		end
		return "(" .. table.concat(parts, ", ") .. ")"
	elseif kind == "variadic" then
		return "..." .. typeToString(node.variadicType)
	elseif kind == "generic" then
		return tostring(node.name) .. "..."
	end

	return ""
end

typeOrPackToString = function(value: any): string
	if type(value) ~= "table" then
		return ""
	end
	if value.kind == "Type" then
		return typeToString(value.value)
	end
	if value.kind == "TypePack" then
		return typePackToString(value.value)
	end
	if value.kind == "None" then
		return ""
	end
	if value.category == "typePack" then
		return typePackToString(value)
	end
	return typeToString(value)
end

local function tableExprToString(node: any, level: number): string
	if not hasItems(node.items) then
		return "{}"
	end
	local parts: { string } = {}
	for _, item in node.items do
		if item.kind == "record" and item.key then
			local keyNode: any = item.key
			local isStringKey = type(keyNode) == "table" and keyNode.type == "constantString"
			local key = if isStringKey then tostring(keyNode.value) else exprToString(keyNode, level)
			table.insert(parts, key .. " = " .. exprToString(item.value, level))
		elseif item.kind == "general" and item.key then
			table.insert(parts, "[" .. exprToString(item.key, level) .. "] = " .. exprToString(item.value, level))
		else
			table.insert(parts, exprToString(item.value, level))
		end
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function callToString(node: any, level: number): string
	local funcText: string
	local target: any = node.func
	-- A method call's `:` is not stored as an `op`; it is implied by `self`.
	local isMethodCall = node.self == true and type(target) == "table" and target.type == "indexName"
	if isMethodCall then
		funcText = parenthesizeIfNeeded(exprToString(target.expr, level), target.expr, 10)
			.. ":"
			.. tostring(target.index)
	else
		funcText = parenthesizeIfNeeded(exprToString(node.func, level), node.func, 10)
	end
	if hasItems(node.typeArguments) then
		local typeArgs: { string } = {}
		for _, typeArg in node.typeArguments do
			table.insert(typeArgs, typeOrPackToString(typeArg))
		end
		funcText ..= "<<" .. table.concat(typeArgs, ", ") .. ">>"
	end
	local args: { string } = {}
	for _, arg in if type(node.args) == "table" then node.args else {} do
		table.insert(args, exprToString(arg, level))
	end
	return funcText .. "(" .. table.concat(args, ", ") .. ")"
end

local function ifElseExprToString(node: any, level: number): string
	local text = "if " .. exprToString(node.condition, level) .. " then " .. exprToString(node.thenExpr, level)
	local current = node
	-- elseif branches are represented as nested ifElse nodes in the else slot.
	while current.elseExpr and type(current.elseExpr) == "table" and current.elseExpr.type == "ifElse" do
		local next_: any = current.elseExpr
		text ..= " elseif " .. exprToString(next_.condition, level) .. " then " .. exprToString(next_.thenExpr, level)
		current = next_
	end
	if current.elseExpr then
		text ..= " else " .. exprToString(current.elseExpr, level)
	end
	return text
end

local function interpStringToString(node: any, level: number): string
	local out = "`"
	local strings = if type(node.strings) == "table" then node.strings else {}
	local expressions = if type(node.expressions) == "table" then node.expressions else {}
	for i, segment in strings do
		out ..= segment
		local expr = expressions[i]
		if expr then
			out ..= "{" .. exprToString(expr, level) .. "}"
		end
	end
	return out .. "`"
end

exprPrecedence = function(node: any): number
	if type(node) ~= "table" then
		return 99
	end
	local kind = node.type
	if kind == "ifElse" then
		return 0
	elseif kind == "binary" then
		return binaryPrecedence[node.op] or 1
	elseif kind == "unary" then
		return 7
	elseif kind == "typeAssertion" then
		return 9
	elseif kind == "call" or kind == "indexName" or kind == "indexExpr" or kind == "instantiate" then
		return 10
	end
	return 11
end

exprToString = function(node: any, level: number): string
	if type(node) ~= "table" then
		return "nil"
	end
	local kind = node.type

	if kind == "group" then
		return "(" .. exprToString(node.expr, level) .. ")"
	elseif kind == "constantNil" then
		return "nil"
	elseif kind == "constantBool" then
		return tostring(node.value)
	elseif kind == "constantNumber" or kind == "constantInteger" then
		return tostring(node.value)
	elseif kind == "constantString" then
		return quoteString(node.value or "")
	elseif kind == "local" then
		local binding = node["local"]
		return tostring(if type(binding) == "table" then binding.name else "_")
	elseif kind == "global" then
		return tostring(node.name)
	elseif kind == "varargs" then
		return "..."
	elseif kind == "call" then
		return callToString(node, level)
	elseif kind == "indexName" then
		return parenthesizeIfNeeded(exprToString(node.expr, level), node.expr, 10) .. "." .. tostring(node.index)
	elseif kind == "indexExpr" then
		return parenthesizeIfNeeded(exprToString(node.expr, level), node.expr, 10)
			.. "["
			.. exprToString(node.index, level)
			.. "]"
	elseif kind == "function" then
		return wrapBlock("function" .. functionSignature(node), node.body, level)
	elseif kind == "table" then
		return tableExprToString(node, level)
	elseif kind == "unary" then
		local gap = if node.op == "not" then " " else ""
		return tostring(node.op) .. gap .. parenthesizeIfNeeded(exprToString(node.expr, level), node.expr, 7)
	elseif kind == "binary" then
		local precedence = exprPrecedence(node)
		local left = parenthesizeIfNeeded(exprToString(node.left, level), node.left, precedence)
		local right = parenthesizeIfNeeded(exprToString(node.right, level), node.right, precedence + 1)
		return left .. " " .. tostring(node.op) .. " " .. right
	elseif kind == "typeAssertion" then
		return parenthesizeIfNeeded(exprToString(node.expr, level), node.expr, 9)
			.. " :: "
			.. typeToString(node.annotation)
	elseif kind == "ifElse" then
		return ifElseExprToString(node, level)
	elseif kind == "interpString" then
		return interpStringToString(node, level)
	elseif kind == "instantiate" then
		local typeArgs: { string } = {}
		for _, typeArg in if type(node.typeArguments) == "table" then node.typeArguments else {} do
			table.insert(typeArgs, typeOrPackToString(typeArg))
		end
		return parenthesizeIfNeeded(exprToString(node.expr, level), node.expr, 10)
			.. "<<"
			.. table.concat(typeArgs, ", ")
			.. ">>"
	end

	return "nil"
end

local function ifStatToString(node: any, level: number): string
	local function section(headLine: string, body: any): string
		local rendered = blockToString(body, level + 1)
		if rendered == "" then
			return headLine
		end
		return headLine .. "\n" .. rendered
	end

	local text = section("if " .. exprToString(node.condition, level) .. " then", node.thenBody)
	local current = node
	-- elseif branches are nested if statements in the else slot.
	while current.elseBody and type(current.elseBody) == "table" and current.elseBody.type == "if" do
		local next_: any = current.elseBody
		text ..= "\n" .. indent(level) .. section(
			"elseif " .. exprToString(next_.condition, level) .. " then",
			next_.thenBody
		)
		current = next_
	end
	if current.elseBody and type(current.elseBody) == "table" then
		text ..= "\n" .. indent(level) .. section("else", current.elseBody)
	end
	return text .. "\n" .. indent(level) .. "end"
end

local function commaExprList(values: any, level: number): string
	local parts: { string } = {}
	for _, value in if type(values) == "table" then values else {} do
		table.insert(parts, exprToString(value, level))
	end
	return table.concat(parts, ", ")
end

local function functionStatName(node: any, level: number): string
	local func = node.func
	local name: any = node.name
	-- A method definition (`function a:b()`) is signalled by `func.self`; the
	-- final name component is a `:` rather than `.`.
	local isMethod = func and func.self and type(name) == "table" and name.type == "indexName"
	if isMethod then
		return exprToString(name.expr, level) .. ":" .. tostring(name.index)
	end
	return exprToString(node.name, level)
end

local function declareExternTypeToString(node: any, level: number): string
	local head = "declare class " .. tostring(node.name)
	if node.superName then
		head ..= " extends " .. tostring(node.superName)
	end
	local lines = { head }
	for _, prop in if type(node.props) == "table" then node.props else {} do
		table.insert(
			lines,
			indent(level + 1) .. accessPrefix(prop.access) .. tostring(prop.name) .. ": " .. typeToString(prop.type)
		)
	end
	if type(node.indexer) == "table" then
		local idx = node.indexer
		table.insert(
			lines,
			indent(level + 1) .. "[" .. typeToString(idx.indexType) .. "]: " .. typeToString(idx.resultType)
		)
	end
	table.insert(lines, indent(level) .. "end")
	return table.concat(lines, "\n")
end

local function classToString(node: any, level: number): string
	local prefix = if node.exported then "export " else ""
	local lines = { prefix .. "class " .. tostring(node.name and node.name.name) }
	for _, member in if type(node.members) == "table" then node.members else {} do
		if member.kind == "method" then
			local func = member["function"]
			table.insert(
				lines,
				indent(level + 1)
					.. wrapBlock("function " .. tostring(member.name) .. functionSignature(func), func.body, level + 1)
			)
		else
			table.insert(lines, indent(level + 1) .. tostring(member.name) .. ": " .. typeToString(member.type))
		end
	end
	table.insert(lines, indent(level) .. "end")
	return table.concat(lines, "\n")
end

statToString = function(node: any, level: number): string
	if type(node) ~= "table" then
		return ""
	end
	local kind = node.type

	if kind == "local" then
		local keyword = if node.isConst then "const" else "local"
		local vars: { string } = {}
		for _, var in if type(node.vars) == "table" then node.vars else {} do
			table.insert(vars, localDeclToString(var))
		end
		local text = keyword .. " " .. table.concat(vars, ", ")
		if hasItems(node.values) then
			text ..= " = " .. commaExprList(node.values, level)
		end
		return text
	elseif kind == "assign" then
		return commaExprList(node.vars, level) .. " = " .. commaExprList(node.values, level)
	elseif kind == "compoundAssign" then
		return exprToString(node.var, level) .. " " .. tostring(node.op) .. "= " .. exprToString(node.value, level)
	elseif kind == "return" then
		if hasItems(node.list) then
			return "return " .. commaExprList(node.list, level)
		end
		return "return"
	elseif kind == "expr" then
		return exprToString(node.expr, level)
	elseif kind == "break" then
		return "break"
	elseif kind == "continue" then
		return "continue"
	elseif kind == "if" then
		return ifStatToString(node, level)
	elseif kind == "while" then
		return wrapBlock("while " .. exprToString(node.condition, level) .. " do", node.body, level)
	elseif kind == "repeat" then
		local rendered = blockToString(node.body, level + 1)
		local bodyPart = if rendered == "" then "" else "\n" .. rendered
		return "repeat" .. bodyPart .. "\n" .. indent(level) .. "until " .. exprToString(node.condition, level)
	elseif kind == "for" then
		local head = "for "
			.. localDeclToString(node.var)
			.. " = "
			.. exprToString(node.from, level)
			.. ", "
			.. exprToString(node.to, level)
		if node.step then
			head ..= ", " .. exprToString(node.step, level)
		end
		return wrapBlock(head .. " do", node.body, level)
	elseif kind == "forIn" then
		local vars: { string } = {}
		for _, var in if type(node.vars) == "table" then node.vars else {} do
			table.insert(vars, localDeclToString(var))
		end
		local head = "for " .. table.concat(vars, ", ") .. " in " .. commaExprList(node.values, level) .. " do"
		return wrapBlock(head, node.body, level)
	elseif kind == "function" then
		local head = "function " .. functionStatName(node, level) .. functionSignature(node.func)
		return wrapBlock(head, node.func.body, level)
	elseif kind == "localFunction" then
		local keyword = if node.isConst then "const" else "local"
		local head = keyword .. " function " .. tostring(node.name and node.name.name) .. functionSignature(node.func)
		return wrapBlock(head, node.func.body, level)
	elseif kind == "typeAlias" then
		local prefix = if node.exported then "export " else ""
		return prefix
			.. "type "
			.. tostring(node.name)
			.. genericsToString(node.generics, node.genericPacks)
			.. " = "
			.. typeToString(node.aliasedType)
	elseif kind == "typeFunction" then
		local prefix = if node.exported then "export " else ""
		if type(node.body) == "table" then
			return wrapBlock(
				prefix .. "type function " .. tostring(node.name) .. functionSignature(node.body),
				node.body.body,
				level
			)
		end
		return prefix .. "type function " .. tostring(node.name)
	elseif kind == "class" then
		return classToString(node, level)
	elseif kind == "declareGlobal" then
		return "declare " .. tostring(node.name) .. ": " .. typeToString(node.declaredType)
	elseif kind == "declareFunction" then
		local head = "declare function "
			.. tostring(node.name)
			.. genericsToString(node.generics, node.genericPacks)
			.. "("
			.. typeListWithNames(node.params, node.paramNames)
		if node.vararg then
			if type(node.params) == "table" and hasItems(node.params.types) then
				head ..= ", "
			end
			head ..= "..."
		end
		head ..= ")"
		if node.returnTypes then
			head ..= ": " .. typePackToString(node.returnTypes)
		end
		return head
	elseif kind == "declareExternType" then
		return declareExternTypeToString(node, level)
	end

	return ""
end

blockToString = function(block: any, level: number): string
	local body = if type(block) == "table" then block.body else nil
	if type(body) ~= "table" then
		return ""
	end
	local lines: { string } = {}
	for i, stat in body do
		local line = indent(level) .. statToString(stat, level)
		-- A preceding statement's `;` is rendered at the start of this line.
		if i > 1 and body[i - 1].hasSemicolon then
			line = prefixSemicolon(line)
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

-- ── Preserve mode ───────────────────────────────────────────────────────────
-- Every inter-token gap in the source is stored exactly once across the tokens'
-- `leadingText`/`trailingText`. Collecting every token, ordering by source
-- position, and concatenating `leadingText .. text .. trailingText` reproduces
-- the original source faithfully.
local function collectTokens(node: any, tokens: { any }, seen: { [any]: boolean })
	if type(node) ~= "table" then
		return
	end
	if seen[node] then
		return
	end
	seen[node] = true
	if node.type == "token" and type(node.text) == "string" and type(node.leadingText) == "string" then
		table.insert(tokens, node)
		return
	end
	for _, value in node do
		collectTokens(value, tokens, seen)
	end
end

local function preservePrint(root: any): string
	local tokens: { any } = {}
	collectTokens(root, tokens, {})
	table.sort(tokens, function(a: any, b: any): boolean
		local la, lb = a.location, b.location
		if la.beginline ~= lb.beginline then
			return la.beginline < lb.beginline
		end
		return la.begincolumn < lb.begincolumn
	end)
	local buf: { string } = {}
	for _, token in tokens do
		table.insert(buf, token.leadingText)
		table.insert(buf, token.text)
		table.insert(buf, token.trailingText)
	end
	return table.concat(buf)
end

-- ── Public API ──────────────────────────────────────────────────────────────
local function isNode(value: any): boolean
	return type(value) == "table" and type(value.type) == "string"
end

local function isParseResult(value: any): boolean
	return type(value) == "table" and isNode(value.root)
end

--[=[
	Prints a parsed AST back to Luau source.

	`mode = "pretty"` (default) formats from AST structure and ignores all token
	text and trivia. `mode = "preserve"` reproduces the original source from the
	CST tokens carried on the AST.

	@param astOrResult A ParseResult or AST node.
	@param options Print options.
	@return string -- Printed Luau source.
]=]
function printer.print(astOrResult: any, options: PrintOptions?): string
	local mode = if options and options.mode then options.mode else "pretty"
	local root = if isParseResult(astOrResult) then (astOrResult :: any).root else astOrResult

	if mode == "preserve" then
		return preservePrint(root)
	end

	if root.type == "block" then
		local text = blockToString(root, 0)
		if text == "" then
			return ""
		end
		return text .. "\n"
	elseif root.category == "stat" then
		return statToString(root, 0)
	elseif root.category == "expr" then
		return exprToString(root, 0)
	elseif root.category == "type" then
		return typeToString(root)
	elseif root.category == "typePack" then
		return typePackToString(root)
	end
	return ""
end

return table.freeze(printer)
