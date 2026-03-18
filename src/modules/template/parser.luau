local fs = require("@eryx/fs")
--[=[
	Template Parser.

	A recursive-descent parser that tokenises and parses a Jinja-style
	template string into an abstract syntax tree (AST). The AST is a flat
	array of nodes that the template evaluator walks to produce rendered
	output.

	Delimiter types recognised by the parser:

	| Delimiter      | Purpose                                                |
	|----------------|--------------------------------------------------------|
	| `{{ expr }}`   | Expression - evaluated and interpolated into output     |
	| `{% stmt %}`   | Statement - control flow, macros, slots, includes       |
	| `{# … #}`      | Comment - discarded entirely, produces no AST node      |

	Statement keywords: `if`, `elseif`, `else`, `for`, `end`, `macro`,
	`use`, `slot`, `fill`, `include`.

	Expression values may be identifiers (`name`), dotted paths
	(`user.email`), numeric literals (`42`, `3.14`), double-quoted string
	literals (`"hello\n"`) with escape support, boolean constants (`true`,
	`false`), or subscripted lookups (`tbl[expr]`). Any expression may be
	prefixed with the unary `not` operator.

	Everything outside these delimiters is emitted as a literal text node.
]=]

--[=[
	A single link in a condition chain.

	`lhs` is always present; `cond`/`rhs` are present for comparisons;
	`chain` links to the next condition via `"and"` or `"or"`.
]=]
export type TCondition = { lhs: AstExpression, cond: string?, rhs: AstExpression?, chain: ("or" | "and")? }

--[=[
	A structured error thrown by the parser and evaluator.

	Contains the human-readable `message` and the source location
	(`line`, `col`) where the error occurred, plus the optional `filepath`
	of the template file that produced the error.
]=]
export type TemplateError = {
	message: string,
	line: number,
	col: number,
	filepath: string?,
}

-- ── AST Node Types ──────────────────────────────────────────────────────────
-- Every node carries source-map fields (`line`, `col`, `filepath`) so that
-- the evaluator can report meaningful locations when errors occur at runtime.

--[=[
	End-of-file sentinel.
]=]
export type AstEof = {
	type: "eof",
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	Raw text between template delimiters.
]=]
export type AstLiteral = {
	type: "literal",
	value: string,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	An interpolated expression: `{{ value }}` or `{{ value | filter }}`.

	`value` is either an array of path segments (e.g. `{"user", "name"}`)
	for dotted variable access, a number literal, or a double-quoted
	string literal (with `\n`, `\t`, `\r`, `\\`, `\"` escapes).
]=]
export type AstExpression = {
	type: "expression",
	-- Path values are arrays of segments: strings for `.key` access,
	-- or `{ dyn: AstExpression }` tables for `[expr]` subscript access.
	value: { string | { dyn: AstExpression } } | { group: { TCondition } } | number | string | boolean,
	negate: boolean?,
	filters: { string },
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	Marks the end of a control-flow block (`{% end %}`).
]=]
export type AstStatementEnd = {
	type: "end",
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	The fallback branch of an if/elseif chain (`{% else %}`).
]=]
export type AstStatementElse = {
	type: "else",
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	An `{% elseif cond then %}` branch, with its own condition and body.
]=]
export type AstStatementElseIf = {
	type: "elseif",
	conditionChain: { TCondition },
	body: AstSuite,
	next: AstStatementElseIf | AstStatementElse | AstStatementEnd,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	The opening `{% if cond then %}` of a conditional chain.
]=]
export type AstStatementIf = {
	type: "if",
	conditionChain: { TCondition },
	body: AstSuite,
	next: AstStatementElseIf | AstStatementElse | AstStatementEnd,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	A key/value for-in loop: `{% for k, v in expr do %}`.
]=]
export type AstStatementForTable = {
	type: "forTable",
	var1: string,
	var2: string,
	items: AstExpression,
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	A numeric for loop: `{% for i = start, end do %}`.
]=]
export type AstStatementForNumber = {
	type: "forNumber",
	var: string,
	start: AstExpression,
	end_: AstExpression,
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}

--[=[
	A macro definition: `{% macro name(arg1, arg2) %} body {% end %}`.

	Declares a reusable template block. The macro is registered in the
	evaluation context and can be invoked via [[AstMacroCall]].
]=]
export type AstMacro = {
	type: "macro",
	name: string,
	args: { string },
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	A macro invocation: `{% use name(expr, ...) %} body {% end %}`.

	Calls a previously defined macro. Positional arguments are evaluated
	and bound to the macro's parameter names. The body between `{% use %}`
	and `{% end %}` is rendered and made available to the macro as the
	`"default"` slot.
]=]
export type AstMacroCall = {
	type: "macroCall",
	name: string,
	args: { AstExpression },
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	A slot placeholder inside a macro body: `{% slot name %} default {% end %}`.

	When the macro is called, the slot is replaced by the caller's
	corresponding `{% fill name %}` content. If no fill is provided, the
	slot's own body is rendered as a default. The name `"default"` is
	reserved for the caller's top-level body.
]=]
export type AstSlot = {
	type: "slot",
	name: string,
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	A slot fill inside a macro call: `{% fill name %} content {% end %}`.

	Provides content for the named [[AstSlot]] in the invoked macro.
]=]
export type AstSlotAssign = {
	type: "slotAssign",
	name: string,
	body: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}
--[=[
	An inlined template file: `{% include "path" %}`.

	At parse time the referenced file is read and recursively parsed.
	The resolved AST is stored in `body`. The path is resolved relative
	to the directory of the file currently being parsed.
]=]
export type AstIncluded = {
	type: "included",
	path: string,
	body: AstSuite,
	passed: AstSuite,
	line: number,
	col: number,
	filepath: string?,
}

export type AstSet = {
	type: "set",
	name: string,
	value: AstExpression,
}

--[=[
	Union of all possible AST node types the parser can produce.
]=]
export type AstNode =
	AstLiteral
	| AstExpression
	| AstStatementIf
	| AstStatementElseIf
	| AstStatementElse
	| AstStatementEnd
	| AstStatementForTable
	| AstStatementForNumber
	| AstMacro
	| AstMacroCall
	| AstSlot
	| AstSlotAssign
	| AstIncluded
	| AstSet
	| AstEof
export type AstSuite = { AstNode }

-- ── Character Classification Helpers ────────────────────────────────────────

local function _isName(lexeme: string): boolean
	return lexeme == "_" or ((string.byte(lexeme) - 97) % 256) < 26 or ((string.byte(lexeme) - 65) % 256) < 26
end
local function _isDigit(lexeme: string): boolean
	return ((string.byte(lexeme) - 48) % 256) < 10
end

-- ── Parser Class ────────────────────────────────────────────────────────────

local Parser = {}
Parser.__index = Parser
type Parser = setmetatable<{
	cursor: number,
	line: number,
	source: string,
	filepath: string?,
}, typeof(Parser)>

--[=[
	Creates a new Parser for the given template source string.

	@param source The template source to parse.
	@param filepath Optional file path of the template, used for resolving `{% include %}` paths.
	@return Parser -- A new parser instance.
]=]
function Parser.new(source: string, filepath: string?): Parser
	local this = {}
	this.cursor = 1
	this.line = 1
	this.source = source
	this.filepath = filepath

	return setmetatable(this, Parser)
end
function Parser.Cur(self: Parser, n: number?): string
	return self.source:sub(self.cursor, self.cursor + if n then n else 0)
end
function Parser.TryConsume(self: Parser, match: string): boolean
	if self:Cur(#match - 1) ~= match then
		return false
	end
	self.cursor += #match
	return true
end
function Parser.Consume(self: Parser, match: string)
	if self:Cur(#match - 1) ~= match then
		local line, col = self:Pos()
		error({ message = "Expected '" .. match .. "'", line = line, col = col, filepath = self.filepath })
	end
	self.cursor += #match
end
function Parser.SkipWhitespace(self: Parser): ()
	repeat
		local c = self:Cur()
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			self.cursor += 1
		else
			break
		end
	until false
end
--[=[
	Returns the `(line, col)` of the current cursor position by scanning
	from the start of the source string.

	O(n) in the number of characters consumed so far. Only called when
	creating AST nodes or when an error is about to be raised, so the
	cost is negligible in practice.
]=]
function Parser.Pos(self: Parser): (number, number)
	local line = 1
	local col = 1
	for i = 1, self.cursor - 1 do
		if string.byte(self.source, i) == 10 then -- '\n'
			line += 1
			col = 1
		else
			col += 1
		end
	end
	return line, col
end
function Parser.ConsumeName(self: Parser): string
	if not _isName(self:Cur()) then
		local line, col = self:Pos()
		error({
			message = "Expected a name but got '" .. self:Cur() .. "'",
			line = line,
			col = col,
			filepath = self.filepath,
		})
	end

	local name = self:Cur()
	self.cursor += 1

	while _isName(self:Cur()) or _isDigit(self:Cur()) do
		name ..= self:Cur()
		self.cursor += 1
	end
	return name
end
--[=[
	Consumes an expression: either a numeric literal (integer or decimal)
	or a dotted identifier path (e.g. `user.profile.name`), optionally
	followed by one or more pipe-separated filter names.

	@return AstExpression -- The parsed expression node.
]=]
function Parser.ConsumeExpr(self: Parser): AstExpression
	self:SkipWhitespace()
	local line, col = self:Pos()

	-- Detect unary `not` operator (only when not followed by a name/digit char).
	local negate = false
	do
		local peek = self.source:sub(self.cursor, self.cursor + 2)
		if peek == "not" then
			local after = self.source:sub(self.cursor + 3, self.cursor + 3)
			if after == "" or not (_isName(after) or _isDigit(after)) then
				negate = true
				self.cursor += 3
				self:SkipWhitespace()
			end
		end
	end

	local value: boolean | number | string | { string | { dyn: AstExpression } } | { group: { TCondition } }

	if _isDigit(self:Cur()) then
		local num: string = ""
		repeat
			num ..= self:Cur()
			self.cursor += 1
		until not _isDigit(self:Cur())
		if self:TryConsume(".") then
			num ..= "."
			if not _isDigit(self:Cur()) then
				local el, ec = self:Pos()
				error({
					message = "Expected digit after decimal point in '" .. num .. "'",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			repeat
				num ..= self:Cur()
				self.cursor += 1
			until not _isDigit(self:Cur())
		end
		value = tonumber(num) :: number
		self:SkipWhitespace()
	elseif self:TryConsume('"') then
		local buf = {}
		while self.cursor <= #self.source do
			local c = self:Cur()
			if c == '"' then
				break
			elseif c == "\\" then
				self.cursor += 1
				local esc = self:Cur()
				if esc == "n" then
					table.insert(buf, "\n")
				elseif esc == "t" then
					table.insert(buf, "\t")
				elseif esc == "r" then
					table.insert(buf, "\r")
				elseif esc == "\\" then
					table.insert(buf, "\\")
				elseif esc == '"' then
					table.insert(buf, '"')
				else
					local el, ec = self:Pos()
					error({
						message = "Unknown string escape sequence: '\\" .. esc .. "'",
						line = el,
						col = ec,
						filepath = self.filepath,
					})
				end
			else
				table.insert(buf, c)
			end
			self.cursor += 1
		end
		if self.cursor > #self.source then
			local el, ec = self:Pos()
			error({ message = "Unterminated string literal", line = el, col = ec, filepath = self.filepath })
		end
		self:Consume('"')
		value = table.concat(buf)
	elseif self:TryConsume("(") then
		self:SkipWhitespace()
		local innerChain = self:ConsumeCondition()
		self:SkipWhitespace()
		self:Consume(")")
		self:SkipWhitespace()
		value = { group = innerChain }
	else
		local firstName = self:ConsumeName()
		if firstName == "true" then
			value = true
			self:SkipWhitespace()
		elseif firstName == "false" then
			value = false
			self:SkipWhitespace()
		else
			-- Build a path that may contain static keys (`.key`) and dynamic
			-- subscripts (`[expr]`), represented as `{ dyn = <AstExpression> }`.
			local path: { string | { dyn: AstExpression } } = { firstName }
			self:SkipWhitespace()
			while true do
				if self:TryConsume(".") then
					table.insert(path, self:ConsumeName())
					self:SkipWhitespace()
				elseif self:TryConsume("[") then
					self:SkipWhitespace()
					local indexExpr = self:ConsumeExpr()
					self:SkipWhitespace()
					self:Consume("]")
					self:SkipWhitespace()
					table.insert(path, { dyn = indexExpr })
				else
					break
				end
			end
			value = path
		end
	end

	local filters: { string } = {}
	while self:TryConsume("|") do
		self:SkipWhitespace()
		table.insert(filters, self:ConsumeName())
		self:SkipWhitespace()
	end

	return {
		type = "expression",
		value = value,
		negate = if negate then true else nil,
		filters = filters,
		line = line,
		col = col,
		filepath = self.filepath,
	}
end

--[=[
	Consumes a full condition chain used in `{% if %}` / `{% elseif %}`.

	Each link is an expression optionally compared to another via a
	relational operator (`==`, `~=`, `<`, `>`, `<=`, `>=`), and links
	are joined by `and` or `or`.

	@return { TCondition } -- The parsed condition chain.
]=]
function Parser.ConsumeCondition(self: Parser): { TCondition }
	local chain: { TCondition } = {}

	while true do
		if not _isName(self:Cur()) and self:Cur() ~= "(" then
			break
		end

		local lhs = self:ConsumeExpr()

		local rhs: AstExpression? = nil
		local cond: string? = nil

		local cur2 = self:Cur(1)
		local cur1 = self:Cur(0)
		if cur2 == "==" or cur2 == "~=" or cur2 == "<=" or cur2 == ">=" then
			cond = cur2
			self.cursor += 2
			rhs = self:ConsumeExpr()
		elseif cur1 == "<" or cur1 == ">" then
			cond = cur1
			self.cursor += 1
			rhs = self:ConsumeExpr()
		end

		local bool: ("or" | "and")? = nil
		if self:Cur(2) == "or " then
			bool = "or"
			self.cursor += 3
		elseif self:Cur(3) == "and " then
			bool = "and"
			self.cursor += 4
		end

		table.insert(chain, { lhs = lhs, cond = cond, rhs = rhs, chain = bool })

		if not bool then
			break
		end
	end

	if #chain == 0 then
		local line, col = self:Pos()
		error({
			message = "Empty condition - expected an expression",
			line = line,
			col = col,
			filepath = self.filepath,
		})
	end

	return chain
end
--[=[
	Consumes a statement block opened by `{%`.

	Dispatches to the appropriate handler based on the keyword:
	`if`, `elseif`, `else`, `for`, `end`, `macro`, `use`, `slot`,
	`fill`, or `include`.

	@return AstNode -- The parsed statement node.
]=]
function Parser.ConsumeStmt(self: Parser): AstNode
	self:SkipWhitespace()
	local line, col = self:Pos()
	local key = self:ConsumeName()
	self:SkipWhitespace()

	if key == "if" then
		local condition = self:ConsumeCondition()
		if self:ConsumeName() ~= "then" then
			local el, ec = self:Pos()
			error({ message = "Expected 'then' after if condition", line = el, col = ec, filepath = self.filepath })
		end
		self:SkipWhitespace()

		if self:Cur(1) ~= "%}" then
			local el, ec = self:Pos()
			error({ message = "Expected '%}' to close {% if %} tag", line = el, col = ec, filepath = self.filepath })
		end
		self.cursor += 2

		while true do
			local body, terminate = self:ConsumeUntil({ "elseif", "else", "end" })
			return {
				type = "if",
				conditionChain = condition,
				body = body,
				next = terminate :: AstStatementElseIf | AstStatementElse | AstStatementEnd,
				line = line,
				col = col,
				filepath = self.filepath,
			}
		end
	elseif key == "elseif" then
		local condition = self:ConsumeCondition()
		if self:ConsumeName() ~= "then" then
			local el, ec = self:Pos()
			error({ message = "Expected 'then' after elseif condition", line = el, col = ec, filepath = self.filepath })
		end
		self:SkipWhitespace()
		if self:Cur(1) ~= "%}" then
			local el, ec = self:Pos()
			error({ message = "Expected '%}' to close {% elseif %} tag", line = el, col = ec, filepath = self.filepath })
		end
		self.cursor += 2
		local body, terminate = self:ConsumeUntil({ "elseif", "else", "end" })
		return {
			type = "elseif",
			conditionChain = condition,
			body = body,
			next = terminate :: AstStatementElseIf | AstStatementElse | AstStatementEnd,
			line = line,
			col = col,
			filepath = self.filepath,
		}
	elseif key == "else" then
		if self:Cur(1) ~= "%}" then
			local el, ec = self:Pos()
			error({ message = "Expected '%}' to close {% else %} tag", line = el, col = ec, filepath = self.filepath })
		end
		self.cursor += 2
		local body = self:ConsumeUntil({ "end" })
		return { type = "else", body = body, line = line, col = col, filepath = self.filepath }
	elseif key == "for" then
		local itera = self:ConsumeName()
		self:SkipWhitespace()
		if self:Cur() == "," then
			self.cursor += 1
			self:SkipWhitespace()
			local iterb = self:ConsumeName()
			self:SkipWhitespace()
			if self:ConsumeName() ~= "in" then
				local el, ec = self:Pos()
				error({ message = "Expected 'in' in for-in loop", line = el, col = ec, filepath = self.filepath })
			end
			self:SkipWhitespace()
			local iterval = self:ConsumeExpr()
			if self:ConsumeName() ~= "do" then
				local el, ec = self:Pos()
				error({
					message = "Expected 'do' at end of for-in loop header",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			self:SkipWhitespace()

			if self:Cur(1) ~= "%}" then
				local el, ec = self:Pos()
				error({
					message = "Expected '%}' to close {% for %} tag",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			self.cursor += 2

			return {
				type = "forTable",
				var1 = itera,
				var2 = iterb,
				items = iterval,
				body = (self:ConsumeUntil({ "end" })),
				line = line,
				col = col,
				filepath = self.filepath,
			}
		elseif self:Cur() == "=" then
			self.cursor += 1
			self:SkipWhitespace()
			local start = self:ConsumeExpr()
			self:SkipWhitespace()
			if self:Cur() ~= "," then
				local el, ec = self:Pos()
				error({
					message = "Expected ',' between start and end in numeric for loop",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			self.cursor += 1
			self:SkipWhitespace()
			local end_ = self:ConsumeExpr()
			if self:ConsumeName() ~= "do" then
				local el, ec = self:Pos()
				error({
					message = "Expected 'do' at end of numeric for loop header",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			self:SkipWhitespace()

			if self:Cur(1) ~= "%}" then
				local el, ec = self:Pos()
				error({
					message = "Expected '%}' to close {% for %} tag",
					line = el,
					col = ec,
					filepath = self.filepath,
				})
			end
			self.cursor += 2

			return {
				type = "forNumber",
				var = itera,
				start = start,
				end_ = end_,
				body = (self:ConsumeUntil({ "end" })),
				line = line,
				col = col,
				filepath = self.filepath,
			}
		else
			local el, ec = self:Pos()
			error({
				message = "Malformed for loop - expected ',' (for-in) or '=' (numeric for) after loop variable",
				line = el,
				col = ec,
				filepath = self.filepath,
			})
		end
	elseif key == "end" then
		self.cursor += 2
		return { type = "end", line = line, col = col, filepath = self.filepath }
	elseif key == "macro" then
		local macroName = self:ConsumeName()
		self:SkipWhitespace()
		local args = {}
		if self:TryConsume("(") then
			self:SkipWhitespace()
			if not self:TryConsume(")") then
				self:SkipWhitespace()
				table.insert(args, self:ConsumeName())
				while self:TryConsume(",") do
					self:SkipWhitespace()
					table.insert(args, self:ConsumeName())
				end
				self:SkipWhitespace()
				self:Consume(")")
			end
		end
		self:SkipWhitespace()
		self:Consume("%}")
		return {
			type = "macro",
			name = macroName,
			args = args,
			body = (self:ConsumeUntil({ "end" })),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	elseif key == "use" then
		local macroName = self:ConsumeName()
		self:SkipWhitespace()
		local args: { AstExpression } = {}
		if self:TryConsume("(") then
			self:SkipWhitespace()
			if not self:TryConsume(")") then
				self:SkipWhitespace()
				table.insert(args, self:ConsumeExpr())
				while self:TryConsume(",") do
					self:SkipWhitespace()
					table.insert(args, self:ConsumeExpr())
				end
				self:SkipWhitespace()
				self:Consume(")")
			end
		end
		self:SkipWhitespace()
		self:Consume("%}")
		return {
			type = "macroCall",
			name = macroName,
			args = args,
			body = (self:ConsumeUntil({ "end" })),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	elseif key == "slot" then
		local slotName = self:ConsumeName()
		-- if slotName == "default" then
		-- 	error({ message = "Slot name 'default' is reserved", line = line, col = col, filepath = self.filepath })
		-- end
		self:SkipWhitespace()
		self:Consume("%}")
		return {
			type = "slot",
			name = slotName,
			body = (self:ConsumeUntil({ "end" })),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	elseif key == "fill" then
		local slotName = self:ConsumeName()
		if slotName == "default" then
			error({ message = "Slot name 'default' is reserved", line = line, col = col, filepath = self.filepath })
		end
		self:SkipWhitespace()
		self:Consume("%}")
		return {
			type = "slotAssign",
			name = slotName,
			body = (self:ConsumeUntil({ "end" })),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	elseif key == "set" then
		self:SkipWhitespace()
		local name = self:ConsumeName()
		self:SkipWhitespace()
		self:Consume("=")
		self:SkipWhitespace()
		local value = self:ConsumeExpr()
		self:SkipWhitespace()
		self:Consume("%}")
		return {
			type = "set",
			name = name,
			value = value,
		}
	elseif key == "include" then
		self:SkipWhitespace()
		local path = self:ConsumeExpr().value
		self:SkipWhitespace()
		if typeof(path) ~= "string" then
			error({
				message = "{% include %} path must be a string literal",
				line = line,
				col = col,
				filepath = self.filepath,
			})
		end
		self:Consume("%}")

		if not self.filepath then
			error({
				message = "{% include %} requires a file path to be provided to the parser",
				line = line,
				col = col,
				filepath = self.filepath,
			})
		end

		local dir = fs.dirname(self.filepath)
		local fullFile = fs.join(dir, path)
		if not fs.isFile(fullFile) then
			error({
				message = "{% include %} could not find '" .. path .. "' (tried: " .. fullFile .. ")",
				line = line,
				col = col,
				filepath = self.filepath,
			})
		end
		local content = fs.readFile(fullFile)

		local subFile = (Parser.new(content, fullFile):ConsumeUntil({ "eof" }))

		return {
			type = "included",
			path = fullFile,
			body = subFile,
			passed = self:ConsumeUntil({ "end" }),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	end

	error({ message = "Unknown statement keyword '" .. key .. "'", line = line, col = col, filepath = self.filepath })
end
--[=[
	Consumes a comment block (`{# ... #}`).

	Advances the cursor past the closing `#}` and returns `nil` (no AST
	node is produced).
]=]
function Parser.ConsumeComment(self: Parser): nil
	local commendEnd = self.source:find("#}", self.cursor, true)

	if not commendEnd then
		local line, col = self:Pos()
		error({
			message = "Unterminated comment - missing closing '#}'",
			line = line,
			col = col,
			filepath = self.filepath,
		})
	end

	-- Just skip right over the comment
	self.cursor = commendEnd + 2

	-- And don't return an AST node
	return nil
end
--[=[
	Parses nodes until a node whose type is in `match` is encountered.

	Returns the collected body nodes and the terminating node. Errors if
	EOF is reached before finding a match.

	@param match An array of node type strings to stop at.
	@return AstSuite -- The body nodes collected before the match.
	@return AstNode -- The terminating node.
]=]
function Parser.ConsumeUntil(self: Parser, match: { string }): (AstSuite, AstNode)
	local nodes = {}
	while true do
		local node = self:Next()
		if not node then
			continue
		end
		if table.find(match, node.type :: string) then
			return nodes, node
		end
		if node.type == "eof" then
			local line, col = self:Pos()
			error({
				message = "Unexpected end of template - expected one of: " .. table.concat(match, ", "),
				line = line,
				col = col,
				filepath = self.filepath,
			})
		end
		table.insert(nodes, node)
	end
end
--[=[
	Produces the next AST node from the source.

	Determines whether the next significant token is an expression
	(`{{`), statement (`{%`), comment (`{#`), or plain literal text,
	and delegates accordingly.

	@return AstNode? -- The next node, or `nil` for comments.
]=]
function Parser.Next(self: Parser): AstNode?
	-- End of string
	if self.cursor > #self.source then
		local line, col = self:Pos()
		return { type = "eof", line = line, col = col, filepath = self.filepath }
	end

	-- Find the next significant symbol
	local nextExpr = self.source:find("{{", self.cursor, true) or 1 / 0
	local nextStmt = self.source:find("{%", self.cursor, true) or 1 / 0
	local nextComment = self.source:find("{#", self.cursor, true) or 1 / 0

	local nextMin = math.min(nextExpr, nextStmt, nextComment)

	-- If we've got nothing left in this file, return a literal
	if math.isinf(nextMin) then
		local line, col = self:Pos()
		local oldCur = self.cursor
		self.cursor = #self.source + 1

		return {
			type = "literal",
			value = self.source:sub(oldCur),
			line = line,
			col = col,
			filepath = self.filepath,
		}
	end

	-- Whatever is coming up next is still a bit away
	if (nextMin - self.cursor) ~= 0 then
		local line, col = self:Pos()
		local literalChunk: AstLiteral = {
			type = "literal",
			value = self.source:sub(self.cursor, nextMin - 1),
			line = line,
			col = col,
			filepath = self.filepath,
		}
		self.cursor = nextMin
		return literalChunk
	end

	if (nextExpr - self.cursor) == 0 then
		self.cursor += 2
		local expr = self:ConsumeExpr()
		if self:Cur(1) ~= "}}" then
			local line, col = self:Pos()
			error({
				message = "Unterminated expression - missing closing '}}'",
				line = line,
				col = col,
				filepath = self.filepath,
			})
		end
		self.cursor += 2
		return expr
	elseif (nextStmt - self.cursor) == 0 then
		self.cursor += 2
		return self:ConsumeStmt()
	elseif (nextComment - self.cursor) == 0 then
		self.cursor += 2
		return self:ConsumeComment()
	else
		assert(false, "Impossible parser code path")
	end
end

return Parser
