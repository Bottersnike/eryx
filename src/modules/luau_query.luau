local luau = require("@eryx/luau")

type ParseResult = luau.ParseResult

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

local function isLocation(value: any | luau.Location): boolean
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

local function isTraversableNode(value: any | luau.AstNode): boolean
	return type(value) == "table" and not isLocation(value) and not isDenseArray(value)
end

local function appendChildren(into: { luau.AstNode }, value: luau.AstNode)
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

local function collectChildren(node: luau.AstNode): { luau.AstNode }
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

local function visitAll(node: luau.AstNode, callback: (luau.AstNode) -> ())
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

function Query.filter<T>(self: Query<T>, pred: (T) -> boolean): Query<T>
	local out = {}
	for _, node in self.nodes do
		if pred(node) then
			table.insert(out, node)
		end
	end
	return newQuery(out)
end

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

function Query.forEach<T>(self: Query<T>, callback: (T) -> ()): Query<T>
	for _, node in self.nodes do
		callback(node)
	end
	return self
end

function Query.findAll<T, U>(self: Query<T>, fn: (luau.AstNode) -> U?): Query<U>
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

function Query.toArray<T>(self: Query<T>): { T }
	return copyArray(self.nodes)
end

local query = {}

function query.children(node: luau.AstNode): { luau.AstNode }
	return collectChildren(node)
end

function query.query<T>(astOrNode: ParseResult | any, fn: (luau.AstNode) -> T?): Query<T>
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
