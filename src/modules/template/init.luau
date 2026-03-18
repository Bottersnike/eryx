--[=[
	Jinja-inspired template engine for Luau.

	Compiles template source strings into an AST, then evaluates them
	against a context table to produce rendered output.

	## Template Syntax

	### Expressions - `{{ expr }}`

	Outputs the value of an expression, coerced to a string.

	```
	{{ name }}              -- variable lookup from context
	{{ user.email }}        -- nested/dotted property access
	{{ 42 }}               -- numeric literal (integer or decimal)
	{{ "hello" }}           -- string literal (supports \n \t \r \\ \")
	{{ true }}              -- boolean constant (renders as "true")
	{{ false }}             -- boolean constant (renders as "false")
	{{ not logged_in }}     -- unary not (negates truthiness)
	{{ items[i] }}          -- subscript lookup with a variable key
	{{ data["key"] }}       -- subscript lookup with a string key
	{{ name | length }}     -- pipe a value through a filter
	{{ x | filter1 | f2 }}  -- chain multiple filters left-to-right
	```

	### Comments - `{# ... #}`

	Ignored by the engine; produces no output.

	```
	{# This is a comment #}
	```

	### Conditionals - `{% if … then %}`

	Conditional blocks. The condition is truthy/falsy (`nil` and `false`
	are falsy; everything else is truthy).

	```
	{% if logged_in then %}Welcome!{% end %}

	{% if count == 0 then %}
	  Empty
	{% elseif count < 5 then %}
	  A few
	{% else %}
	  Many
	{% end %}
	```

	Supported comparison operators: `==`, `~=`, `<`, `>`, `<=`, `>=`.

	Conditions can be chained with `and` / `or`:

	```
	{% if role == "admin" and active then %}...{% end %}
	{% if x or y then %}...{% end %}
	```

	A bare expression (no operator) is treated as a truthiness check:

	```
	{% if user then %}...{% end %}
	{% if true then %}...{% end %}
	{% if not logged_in then %}...{% end %}
	```

	### Table For-Loop - `{% for k, v in tbl do %}`

	Iterates over key/value pairs of a table expression. Both loop
	variables are injected into the context and restored after the loop.

	```
	{% for i, item in items do %}
	  {{ i }}: {{ item.name }}
	{% end %}
	```

	### Numeric For-Loop - `{% for i = start, end do %}`

	Counts from `start` to `end` (inclusive). The loop variable is
	injected into the context and restored after the loop.

	```
	{% for i = 1, 5 do %}
	  Row {{ i }}
	{% end %}
	```

	### Macros - `{% macro name(args) %}`

	Defines a reusable template block. Arguments become context variables
	within the macro body.

	```
	{% macro greeting(name, title) %}
	  Hello, {{ title }} {{ name }}!
	{% end %}
	```

	Call a macro with `{% use %}` to provide a body, or `{{ }}` for a
	simple inline call:

	```
	{% use greeting("Alice", "Dr.") %}
	  <p>Extra content here</p>
	{% end %}
	```

	Inside a macro, `{% slot default %}` renders the caller's body.
	Named slots can also be used - see **Slots** below.

	### Slots - `{% slot name %}` / `{% fill name %}`

	Slots define placeholder regions inside a macro body that callers
	can fill with custom content. Each slot has a default body that is
	used when the caller does not provide a `{% fill %}` for it.

	```
	{% macro card(title) %}
	  <div class="card">
	    <h2>{{ title }}</h2>
	    {% slot body %}<p>Default body</p>{% end %}
	    {% slot footer %}<small>Default footer</small>{% end %}
	  </div>
	{% end %}

	{% use card("My Card") %}
	  {% fill body %}<p>Custom body!</p>{% end %}
	  {% fill footer %}<small>Custom footer</small>{% end %}
	{% end %}
	```

	The special slot name `"default"` is reserved and automatically
	receives the caller's top-level body content (anything not inside a
	`{% fill %}`). You cannot explicitly name a slot `"default"`.

	### Includes - `{% include "path" %}`

	Inlines another template file at parse time. The path is resolved
	relative to the directory of the current template file.

	```
	{% include "header.html" %}{% end %}
	<main>Content</main>
	{% include "footer.html" %}{% end %}
	```

	Includes accept a body block between `{% include %}` and `{% end %}`.
	The body content is available to the included file as the `"default"`
	slot, and named slots can be filled with `{% fill %}` - just like
	macro calls.

	```
	{% include "layout.html" %}
	  {% fill sidebar %}<nav>Custom nav</nav>{% end %}
	  {% fill content %}<p>Page body here</p>{% end %}
	{% end %}
	```

	Inside the included file, use `{% slot %}` to define the placeholder
	regions that callers can fill:

	```
	{# layout.html #}
	<div class="sidebar">{% slot sidebar %}<nav>Default nav</nav>{% end %}</div>
	<div class="content">{% slot content %}<p>Default content</p>{% end %}</div>
	```

	:::caution
	A file path must be provided to [[compile]] for includes to work.
	:::

	### Literal Text

	Anything outside `{{ }}`, `{% %}`, and `{# #}` delimiters is emitted
	as-is.

	## Built-in Filters

	| Filter   | Description |
	|----------|-------------|
	| `length` | Returns `#tbl` for tables, or `string.len` for everything else. |

	## Error Handling

	`compile` and `evaluate` are the standard entry points. On failure they
	call `error()` with a human-readable string (e.g. `"3:7: Unknown filter 'foo'"`).

	If you want the structured [[TemplateError]] table instead, call the
	`Raw` variants (`compileRaw` / `evaluateRaw`), which propagate the
	table directly so you can inspect `.message`, `.line`, `.col`, and
	`.filepath` yourself.

	## Example

	```luau
	local template = require("@eryx/template")

	local tmpl = template.compile("Hello, {{ name | length }}!")
	print(template.evaluate(tmpl, { name = "World" })) --> "Hello, 5!"
	```
]=]

local Parser = require("@self/parser")
local json = require("@eryx/encoding/json")

--[=[
	A structured error value thrown by `compileRaw` and `evaluateRaw`.

	Re-exported from the parser so consumers only need to import this
	module when working with structured errors.
]=]
export type TemplateError = Parser.TemplateError

export type Template = Parser.AstSuite

type TContext = {
	variables: { [string]: any },
	filters: { [string]: (any, { [string]: any }) -> any },
	macros: { [string]: Parser.AstMacro },
	slots: { [string]: string },
}

local template = {}

-- Built-in filter functions available in every template.
-- Custom filters passed to `evaluate` are merged on top of these.
-- TODO: Add more builtins
local BUILTIN_FILTERS: { [string]: (any, { [string]: any }) -> any } = {
	length = function(val: any): number
		if val == nil then
			return 0
		end
		local t = type(val)
		if t == "table" then
			return #val
		elseif t == "string" then
			return string.len(val)
		else
			return 0
		end
	end,
}

-- Formats a caught error value into a human-readable string.
-- Handles both TemplateError tables and arbitrary error values.
local function formatError(err: any): string
	if type(err) == "table" and err.message then
		local loc = if err.filepath then `{err.filepath}:{err.line}:{err.col}` else `{err.line}:{err.col}`
		return `{loc}: {err.message}`
	end
	return tostring(err)
end

-- Forward declaration so evaluateExpr can call evaluateCondition for group nodes.
local evaluateCondition: any

local function evaluateExpr(expr: Parser.AstExpression, context: TContext): any
	local value
	if typeof(expr.value) == "number" then
		value = expr.value
	elseif typeof(expr.value) == "string" then
		value = expr.value
	elseif typeof(expr.value) == "boolean" then
		value = expr.value
	else
		local rawValue = expr.value :: any
		if rawValue.group ~= nil then
			-- Parenthesised condition group: evaluate the inner chain to a boolean.
			value = evaluateCondition(rawValue.group, context)
		else
			-- Path traversal: each segment is either a string (static key) or a
			-- `{ dyn = AstExpression }` table (dynamic subscript like `tbl[expr]`).
			local _ctx: any = context.variables
			for _, seg in rawValue :: { any } do
				if _ctx == nil then
					-- Build a readable path string for the error message.
					local pathParts = {}
					for _, s in rawValue :: { any } do
						if typeof(s) == "string" then
							table.insert(pathParts, s)
						else
							table.insert(pathParts, "[...]")
						end
					end
					local segName = if typeof(seg) == "string" then seg else "[...]"
					error({
						message = "Cannot index nil with '" .. segName .. "' (in path '" .. table.concat(
							pathParts,
							"."
						) .. "')",
						line = expr.line,
						col = expr.col,
						filepath = expr.filepath,
					})
				end
				if typeof(seg) == "string" then
					_ctx = _ctx[seg]
				else
					_ctx = _ctx[evaluateExpr((seg :: any).dyn, context)]
				end
			end
			value = _ctx
		end
	end

	for _, i in expr.filters do
		local filter = context.filters[i] or BUILTIN_FILTERS[i]
		if not filter then
			error({
				message = "Unknown filter '" .. i .. "'",
				line = expr.line,
				col = expr.col,
				filepath = expr.filepath,
			})
		end
		value = filter(value, context.variables)
	end

	if expr.negate then
		value = not value
	end

	return value
end
evaluateCondition = function(conditions: { Parser.TCondition }, context: TContext): any
	local val
	local chain: ("and" | "or")? = nil
	for _, i in conditions do
		local lhs = evaluateExpr(i.lhs, context)
		local tmp

		if i.cond and i.rhs then
			local rhs = evaluateExpr(i.rhs, context)
			if i.cond == "==" then
				tmp = lhs == rhs
			elseif i.cond == "~=" then
				tmp = lhs ~= rhs
			elseif i.cond == "<=" then
				tmp = lhs <= rhs
			elseif i.cond == ">=" then
				tmp = lhs >= rhs
			elseif i.cond == "<" then
				tmp = lhs < rhs
			elseif i.cond == ">" then
				tmp = lhs > rhs
			end
		else
			tmp = lhs
		end

		if chain == "and" then
			val = val and tmp
		elseif chain == "or" then
			val = val or tmp
		else
			val = tmp
		end

		if i.chain == "and" and not val then
			return val
		end
		if i.chain == "or" and val then
			return val
		end

		chain = i.chain
	end
	return val
end

local function _evaluate(nodes: Parser.AstSuite, context: TContext): string
	local rendered = {}

	for _, node in nodes do
		if node.type == "literal" then
			table.insert(rendered, node.value)
		elseif node.type == "expression" then
			local val = evaluateExpr(node, context)
			if typeof(val) == "table" then
				table.insert(rendered, json.encode(val))
			elseif val ~= nil then
				table.insert(rendered, tostring(val))
			end
		elseif node.type == "else" then
			table.insert(rendered, _evaluate(node.body, context))
		elseif node.type == "if" or node.type == "elseif" then
			if evaluateCondition(node.conditionChain, context) then
				table.insert(rendered, _evaluate(node.body, context))
			else
				if node.next.type ~= "end" then
					table.insert(rendered, _evaluate({ node.next }, context))
				end
			end
		elseif node.type == "forTable" then
			local originalVar1 = context.variables[node.var1]
			local originalVar2 = context.variables[node.var2]
			for var1, var2 in evaluateExpr(node.items, context) do
				context.variables[node.var1] = var1
				context.variables[node.var2] = var2
				table.insert(rendered, _evaluate(node.body, context))
			end
			context.variables[node.var1] = originalVar1
			context.variables[node.var2] = originalVar2
		elseif node.type == "forNumber" then
			local originalVar = context.variables[node.var]
			for var = evaluateExpr(node.start, context), evaluateExpr(node.end_, context) do
				context.variables[node.var] = var
				table.insert(rendered, _evaluate(node.body, context))
			end
			context.variables[node.var] = originalVar
		elseif node.type == "macro" then
			context.macros[node.name] = node
		elseif node.type == "macroCall" then
			local macro = context.macros[node.name]
			if not macro then
				error({
					message = "Undefined macro '" .. node.name .. "'",
					line = node.line,
					col = node.col,
					filepath = node.filepath,
				})
			end
			if #node.args ~= #macro.args then
				error({
					message = "Wrong number of arguments to macro '"
						.. node.name
						.. "': expected "
						.. #macro.args
						.. " but got "
						.. #node.args,
					line = node.line,
					col = node.col,
					filepath = node.filepath,
				})
			end

			-- Bank old variables
			local originals = {}
			for n, i in macro.args do
				originals[n] = context.variables[i]
				context.variables[i] = evaluateExpr(node.args[n], context)
			end
			-- Save old slots
			local oldSlots = table.clone(context.slots)

			local defaultBody = _evaluate(node.body, context)
			context.slots["default"] = defaultBody

			table.insert(rendered, _evaluate(macro.body, context))
			-- Restore variables
			for n, i in macro.args do
				context.variables[i] = originals[n]
			end
			-- Restore slots
			context.slots = oldSlots
		elseif node.type == "slotAssign" then
			context.slots[node.name] = _evaluate(node.body, context)
		elseif node.type == "slot" then
			if context.slots[node.name] then
				table.insert(rendered, context.slots[node.name])
			else
				table.insert(rendered, _evaluate(node.body, context))
			end
		elseif node.type == "included" then
			-- Save old slots
			local oldSlots = table.clone(context.slots)

			local defaultBody = _evaluate(node.passed, context)
			context.slots["default"] = defaultBody

			table.insert(rendered, _evaluate(node.body, context))

			-- Restore slots
			context.slots = oldSlots
		elseif node.type == "set" then
			context.variables[node.name] = evaluateExpr(node.value, context)
		else
			local n = node :: any
			error({
				message = "Unknown node type '" .. node.type .. "'",
				line = n.line,
				col = n.col,
				filepath = n.filepath,
			})
		end
	end

	return table.concat(rendered, "")
end

-- ── Raw (structured-error) implementations ───────────────────────────────────
-- These functions do the actual work and propagate TemplateError tables via
-- error() so that callers can inspect .message / .line / .col / .filepath.

local function _compileRaw(source: string, filepath: string?): Template
	return (Parser.new(source, filepath):ConsumeUntil({ "eof" }))
end

local function _evaluateRaw(
	nodes: Template,
	ctx: { [string]: any }?,
	filters: { [string]: (any, { [string]: any }) -> any }?
): string
	local context: TContext = {
		variables = if ctx then ctx else {},
		filters = if filters then filters else {},
		macros = {},
		slots = {},
	}
	return _evaluate(nodes, context)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--[=[
	Parses a template source string into a list of AST nodes.

	The returned nodes can be passed to [[evaluate]] one or more times
	with different context tables, avoiding repeated parsing.

	On failure, calls `error()` with a formatted string such as
	`"myfile.html:3:7: Unterminated string literal"`.
	Use [[compileRaw]] if you need the structured [[TemplateError]] table.

	@param source The template source string to compile.
	@param filepath Optional file path of the template, required for `{% include %}` resolution.
	@return AstSuite -- The compiled AST.
]=]
function template.compile(source: string, filepath: string?): Template
	local ok, result = pcall(_compileRaw, source, filepath)
	if not ok then
		error(formatError(result), 0)
	end
	return result :: Template
end

--[=[
	Like [[compile]], but propagates a [[TemplateError]] table via `error()`
	instead of a formatted string. Use this when you want to inspect the
	structured error (`.message`, `.line`, `.col`, `.filepath`) rather than
	wrapping the call in `pcall` yourself just to re-format the message.

	@param source The template source string to compile.
	@param filepath Optional file path of the template.
	@return AstSuite -- The compiled AST.
]=]
function template.compileRaw(source: string, filepath: string?): Template
	return _compileRaw(source, filepath)
end

--[=[
	Renders a compiled template (array of AST nodes) into a string.

	Custom filters can be supplied and will be merged with (and can
	override) the built-in filter set.

	On failure, calls `error()` with a formatted string such as
	`"myfile.html:5:12: Unknown filter 'foo'"`.
	Use [[evaluateRaw]] if you need the structured [[TemplateError]] table.

	```luau
	local nodes = template.compile("Hello, {{ name }}!")
	print(template.evaluate(nodes, { name = "World" })) --> "Hello, World!"
	```

	@param nodes The AST produced by [[compile]].
	@param ctx Optional context table whose keys become template variables.
	@param filters Optional table of custom filter functions.
	@return string -- The fully rendered template output.
]=]
function template.evaluate(
	nodes: Template,
	ctx: { [string]: any }?,
	filters: { [string]: (any, { [string]: any }) -> any }?
): string
	local ok, result = pcall(_evaluateRaw, nodes, ctx, filters)
	if not ok then
		error(formatError(result), 1)
	end
	return result :: string
end

--[=[
	Like [[evaluate]], but propagates a [[TemplateError]] table via `error()`
	instead of a formatted string.

	@param nodes The AST produced by [[compile]] or [[compileRaw]].
	@param ctx Optional context table whose keys become template variables.
	@param filters Optional table of custom filter functions.
	@return string -- The fully rendered template output.
]=]
function template.evaluateRaw(
	nodes: Template,
	ctx: { [string]: any }?,
	filters: { [string]: (any, { [string]: any }) -> any }?
): string
	return _evaluateRaw(nodes, ctx, filters)
end

return template
