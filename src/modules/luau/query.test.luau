local luau = require("@eryx/luau/ast")
local luauParse = require("@eryx/luau/parse")
local luauQuery = require("@eryx/luau/query")
local test = require("@eryx/test")

local suite = test.Suite.new("luau/query")

local function parseOk(source: string): luau.ParseResult
	local result = luauParse.parse(source, { captureComments = true })
	test.expect(#result.errors):toBe(0)
	return result
end

suite:test("query: selects tagged AST nodes from parse result", function()
	local result = parseOk("local x = require('./dep')\nreturn x")
	local nodes = luauQuery
		.query(result, function(node): luau.ExprCall?
			if node.type == "ExprCall" then
				return node
			end
			return nil
		end)
		:toArray()

	test.expect(#nodes):toBe(1)
	test.expect(nodes[1].type):toBe("ExprCall")
end)

suite:test("children: returns direct child tables without locations", function()
	local result = parseOk("local value = 1")
	local children = luauQuery.children(result.root)

	test.expect(#children):toBeGreaterThan(0)
	for _, child in children do
		test.expect(type(child)):toBe("table")
		test.expect((child :: any).beginline):toBeNil()
	end
end)

suite:test("findAll: walks descendants from the current query nodes", function()
	local result = parseOk("local function outer() local y = 1 return y end")
	local functionBodies = luauQuery.query(result.root, function(node): luau.Block?
		if node.type == "ExprFunction" then
			return node.body
		end
		return nil
	end)

	local locals = functionBodies
		:findAll(function(node): luau.StatLocal?
			if node.type == "StatLocal" then
				return node
			end
			return nil
		end)
		:toArray()

	test.expect(#locals):toBe(1)
	test.expect(locals[1].type):toBe("StatLocal")
end)

suite:test("query methods are non-mutating", function()
	local result = parseOk("local a = 1\nlocal b = 2")
	local allStatements = luauQuery.query(result.root, function(node): luau.StatLocal?
		if node.type == "StatLocal" then
			return node
		end
		return nil
	end)

	local firstOnly = allStatements:filter(function(node: luau.StatLocal)
		return node.vars[1].name == "a"
	end)

	test.expect(#allStatements:toArray()):toBe(2)
	test.expect(#firstOnly:toArray()):toBe(1)
end)

suite:test("map and flatMap can project query results", function()
	local result = parseOk("local x = 1\nlocal y = 2")
	local locals = luauQuery.query(result.root, function(node): luau.StatLocal?
		if node.type == "StatLocal" then
			return node
		end
		return nil
	end)

	local names = locals
		:map(function(node: luau.StatLocal)
			return node.vars[1].name
		end)
		:toArray()

	local values = locals
		:flatMap(function(node: luau.StatLocal)
			return node.values
		end)
		:toArray()

	test.expect(#names):toBe(2)
	test.expect(names[1]):toBe("x")
	test.expect(names[2]):toBe("y")
	test.expect(#values):toBe(2)
	test.expect(values[1].type):toBe("ExprConstantNumber")
end)

suite:test("forEach preserves the same query for chaining", function()
	local result = parseOk("local x = 1\nlocal y = 2")
	local seen = {}
	local query = luauQuery.query(result.root, function(node): luau.StatLocal?
		if node.type == "StatLocal" then
			return node
		end
		return nil
	end)

	local chained = query:forEach(function(node: luau.StatLocal)
		table.insert(seen, node.vars[1].name)
	end)

	test.expect(chained):toBe(query)
	test.expect(#seen):toBe(2)
end)

return suite
