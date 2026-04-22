--[=[
	Chainable AST query and traversal utilities for Luau parse results.

	`query.query` walks a parse result or any AST node recursively and
	collects matching nodes into a `Query<T>` value. The returned object
	supports chainable operations — `filter`, `map`, `flatMap`, `findAll`,
	`forEach`, and `toArray` — for transforming and extracting data.

	`query.children` returns the direct child nodes of a single node
	without recursing further.

	```luau
	local query = require("@eryx/luau/query")
	local parse = require("@eryx/luau/parse")

	local result = parse.parse(source)

	-- Collect all function call expressions
	local calls = query.query(result, function(node)
	    if node.type == "ExprCall" then
	        return node
	    end
	end)

	for _, call in calls:toArray() do
	    print(call.location.beginline)
	end
	```
]=]
local ast = require("@eryx/luau/ast")
local parse = require("@eryx/luau/parse")

type ParseResult = parse.ParseResult

local Query = {}
Query.__index = Query

export type Query<T = any> = setmetatable<{
	nodes: { T },
}, typeof(Query)>

local function copyArray<T>(items: { T }): { T }
	local out = table.create(#items)
	for i, item in items do
		out[i] = item
	end
	return out
end

local function isLocation(value: any | ast.Location): boolean
	return type(value) == "table"
		and type(value.beginline) == "number"
		and type(value.begincolumn) == "number"
		and type(value.endline) == "number"
		and type(value.endcolumn) == "number"
end

local function isDenseArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end

	local count = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end

	return count == #value
end

local function isTraversableNode(value: any | ast.AstNode): boolean
	return type(value) == "table" and not isLocation(value) and not isDenseArray(value)
end

local function appendChildren(into: { ast.AstNode }, value: ast.AstNode)
	if type(value) ~= "table" or isLocation(value) then
		return
	end

	if isDenseArray(value) then
		for _, item in value do
			if isTraversableNode(item) then
				table.insert(into, item)
			end
		end
		return
	end

	table.insert(into, value)
end

local function collectChildren(node: ast.AstNode): { ast.AstNode }
	local out = {}
	if type(node) ~= "table" then
		return out
	end

	for key, value in node do
		if key ~= "location" then
			appendChildren(out, value)
		end
	end

	return out
end

local function visitAll(node: ast.AstNode, callback: (ast.AstNode) -> ())
	if not isTraversableNode(node) then
		return
	end

	callback(node)
	for _, child in collectChildren(node) do
		visitAll(child, callback)
	end
end

local function newQuery<T>(nodes: { T }): Query<T>
	return setmetatable({
		nodes = nodes,
	}, Query)
end

local function rootOf(astOrNode: ParseResult | any): any
	if type(astOrNode) == "table" and type(astOrNode.root) == "table" then
		return astOrNode.root
	end

	return astOrNode
end

--[=[
	Returns a new `Query` containing only the nodes for which `pred` returns `true`.

	@param pred Predicate function called with each node.
	@return Query<T> -- A new query with the filtered nodes.
]=]
function Query.filter<T>(self: Query<T>, pred: (T) -> boolean): Query<T>
	local out = {}
	for _, node in self.nodes do
		if pred(node) then
			table.insert(out, node)
		end
	end
	return newQuery(out)
end

--[=[
	Transforms each node by calling `fn` and collects non-nil results into a new `Query`.

	@param fn Mapping function. Return `nil` to exclude a node from the result.
	@return Query<U> -- A new query with the mapped values.
]=]
function Query.map<T, U>(self: Query<T>, fn: (T) -> U?): Query<U>
	local out = {}
	for _, node in self.nodes do
		local mapped = fn(node)
		if mapped ~= nil then
			table.insert(out, mapped)
		end
	end
	return newQuery(out)
end

--[=[
	Transforms each node into an array via `fn` and flattens all results into a new `Query`.

	@param fn Mapping function that returns an array of values for each node.
	@return Query<U> -- A new query with all flattened values.
]=]
function Query.flatMap<T, U>(self: Query<T>, fn: (T) -> { U }): Query<U>
	local out = {}
	for _, node in self.nodes do
		local mapped = fn(node)
		for _, item in mapped do
			table.insert(out, item)
		end
	end
	return newQuery(out)
end

--[=[
	Calls `callback` for each node in the query. Returns `self` to allow chaining.

	@param callback Function called with each node.
	@return Query<T> -- The same query, for chaining.
]=]
function Query.forEach<T>(self: Query<T>, callback: (T) -> ()): Query<T>
	for _, node in self.nodes do
		callback(node)
	end
	return self
end

--[=[
	Recursively walks every node in the query and collects non-nil results of `fn`
	into a new `Query`. Unlike `map`, this descends into all descendants of each
	node, not just the top-level nodes.

	@param fn Selector function. Return a non-nil value to include a descendant node.
	@return Query<U> -- A new query with all matched descendants.
]=]
function Query.findAll<T, U>(self: Query<T>, fn: (ast.AstNode) -> U?): Query<U>
	local out = {}
	for _, start in self.nodes do
		visitAll(start, function(node)
			local selected = fn(node)
			if selected ~= nil then
				table.insert(out, selected)
			end
		end)
	end
	return newQuery(out)
end

--[=[
	Returns a shallow copy of the underlying nodes as a plain array.

	@return { T } -- Array of all nodes in the query.
]=]
function Query.toArray<T>(self: Query<T>): { T }
	return copyArray(self.nodes)
end

local query = {}

--[=[
	Returns the direct child nodes of `node` without recursing further.
	Location spans and dense arrays are unwrapped but not themselves returned
	as children.

	@param node The AST node whose direct children to collect.
	@return { AstNode } -- Array of direct child nodes.
]=]
function query.children(node: ast.AstNode): { ast.AstNode }
	return collectChildren(node)
end

--[=[
	Recursively walks all nodes in a parse result or AST node and collects
	non-nil results of `fn` into a chainable `Query<T>`.

	Pass a `ParseResult` to start from the root block, or any `AstNode` to
	start from that node directly.

	```luau
	local calls = query.query(result, function(node)
	    if node.type == "ExprCall" then
	        return node
	    end
	end)
	for _, call in calls:toArray() do
	    print(call.location.beginline)
	end
	```

	@param astOrNode A `ParseResult` or any AST node to traverse.
	@param fn Selector function. Return a non-nil value to include a node.
	@return Query<T> -- A chainable query containing all matched nodes.
]=]
function query.query<T>(astOrNode: ParseResult | any, fn: (ast.AstNode) -> T?): Query<T>
	local root = rootOf(astOrNode)
	local out = {}

	visitAll(root, function(node)
		local selected = fn(node)
		if selected ~= nil then
			table.insert(out, selected)
		end
	end)

	return newQuery(out)
end

return table.freeze(query)
