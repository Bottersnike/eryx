local iter = require("@eryx/iter")
local test = require("@eryx/test")

local suite = test.Suite.new("iter")

local function expectArrayEquals(actual: { any }, expected: { any })
	test.expect(#actual):toBe(#expected)
	for i = 1, #expected do
		test.expect(actual[i]):toBe(expected[i])
	end
end

local function expectPairsEqual(actual, expected)
	test.expect(#actual):toBe(#expected)
	for i = 1, #expected do
		test.expect(actual[i][1], actual[i][2]):toBe(expected[i][1], expected[i][2])
	end
end

local function collectValues<T>(iterable: iter.Iterable<T, any>): { T }
	local values: { T } = {}
	for _, value in iterable do
		table.insert(values, value)
	end
	return values
end

local function collectPairs<T>(iterable: iter.Iterable<T, any>)
	local pairsOut = {}
	for index, value in iterable do
		table.insert(pairsOut, { index, value })
	end
	return pairsOut
end

local function arrayIterator<T>(values: { T }): () -> (number?, T)
	local index = 0
	return function(): (number?, T)
		index += 1
		local value = values[index]
		if index > #values then
			return nil, nil
		end
		return index, value
	end
end

local function pairIterator<T>(pairsIn: { { number | T } }): () -> (number?, T)
	local index = 0
	return function(): (number?, T)
		index += 1
		local pair = pairsIn[index]
		if not pair then
			return nil, nil
		end
		return pair[1], pair[2]
	end
end

local MetaBox = {}
MetaBox.__index = MetaBox
type MetaBox<T> = setmetatable<{ values: { T } }, {
	__iter: (MetaBox<T>) -> ((values: { T }, control: number?) -> (number?, T), { T }, number),
}>

function MetaBox.new<T>(values: { T }): MetaBox<T>
	return setmetatable({ values = values }, MetaBox)
end

function MetaBox.__iter<T>(self: MetaBox<T>)
	local function gen(values, control: number?): (number?, T)
		local nextIndex = (control or 0) + 1
		local value = values[nextIndex]
		if value == nil and nextIndex > #values then
			return nil, nil
		end
		return nextIndex, value
	end

	return gen, self.values, 0
end

suite:test("map transforms arrays lazily and preserves indices", function()
	local mapped = iter.map({ 1, 2, 3 }, function(value: number)
		return value * 10
	end)

	expectPairsEqual(collectPairs(mapped), {
		{ 1, 10 },
		{ 2, 20 },
		{ 3, 30 },
	})
end)

suite:test("map works with simple iterators that yield custom indices", function()
	local mapped = iter.map(
		pairIterator<<string>>({
			{ 2, "alpha" },
			{ 4, "beta" },
		}),
		function(value)
			return string.upper(value)
		end
	)

	expectPairsEqual(collectPairs(mapped), {
		{ 2, "ALPHA" },
		{ 4, "BETA" },
	})
end)

suite:test("filter on arrays reindexes matching items densely", function()
	local filtered = iter.filter({ 1, 2, 3, 4, 5 }, function(value: number)
		return value % 2 == 1
	end)

	expectPairsEqual(collectPairs(filtered), {
		{ 1, 1 },
		{ 2, 3 },
		{ 3, 5 },
	})
end)

suite:test("filter works with meta iterables and false values using dense indices", function()
	local filtered = iter.filter(MetaBox.new({ false, true, false, true }), function(value)
		return not value
	end)

	expectPairsEqual(collectPairs(filtered), {
		{ 1, false },
		{ 2, false },
	})
end)

suite:test("filter handles all-match, none-match, and single-item cases", function()
	expectPairsEqual(
		collectPairs(iter.filter({ 2, 4, 6 }, function(value: number)
			return value % 2 == 0
		end)),
		{
			{ 1, 2 },
			{ 2, 4 },
			{ 3, 6 },
		}
	)

	expectPairsEqual(
		collectPairs(iter.filter({ 1, 3, 5 }, function(value: number)
			return value % 2 == 0
		end)),
		{}
	)

	expectPairsEqual(
		collectPairs(iter.filter({ 9 }, function(value: number)
			return value == 9
		end)),
		{
			{ 1, 9 },
		}
	)
end)

suite:test("forEach passes value first and index second", function()
	local seen = {}

	iter.forEach({ "a", "b", "c" }, function(value: string, index: number)
		table.insert(seen, { index, value })
	end)

	expectPairsEqual(seen, {
		{ 1, "a" },
		{ 2, "b" },
		{ 3, "c" },
	})
end)

suite:test("flatten returns the same array reference for simple arrays", function()
	local source = { "x", "y", "z" }
	local flattened = iter.flatten(source)

	test.expect(flattened):toBe(source)
	expectArrayEquals(flattened, source)
end)

suite:test("flatten materializes iterator output using yielded indices", function()
	local flattened = iter.flatten(pairIterator({
		{ 2, "two" },
		{ 4, "four" },
		{ 5, "five" },
	}))

	test.expect(flattened[1]):toBeNil()
	test.expect(flattened[2]):toBe("two")
	test.expect(flattened[3]):toBeNil()
	test.expect(flattened[4]):toBe("four")
	test.expect(flattened[5]):toBe("five")
end)

suite:test("flatten preserves sparse and non-1-based numeric iterator keys", function()
	local flattened = iter.flatten(pairIterator({
		{ 3, "three" },
		{ 7, "seven" },
		{ 10, "ten" },
	}))

	test.expect(flattened[1]):toBeNil()
	test.expect(flattened[3]):toBe("three")
	test.expect(flattened[7]):toBe("seven")
	test.expect(flattened[10]):toBe("ten")
end)

suite:test("tableIterator round-trips array contents as a simple iterator", function()
	local values = collectValues(iter.tableIterator({ "red", "green", "blue" }))
	expectArrayEquals(values, { "red", "green", "blue" })
end)

suite:test("plain arrays containing false do not terminate map or tableIterator early", function()
	expectPairsEqual(
		collectPairs(iter.map({ true, false, true }, function(value: boolean)
			return value
		end)),
		{
			{ 1, true },
			{ 2, false },
			{ 3, true },
		}
	)

	expectPairsEqual(collectPairs(iter.tableIterator({ true, false, true })), {
		{ 1, true },
		{ 2, false },
		{ 3, true },
	})
end)

suite:test("reverse clones arrays by default", function()
	local source = { 1, 2, 3, 4 }
	local reversed = iter.reverse(source)

	expectArrayEquals(reversed, { 4, 3, 2, 1 })
	expectArrayEquals(source, { 1, 2, 3, 4 })
	test.expect(reversed):toNotBe(source)
end)

suite:test("reverse can mutate arrays in place", function()
	local source = { "first", "second", "third" }
	local reversed = iter.reverse(source, true)

	test.expect(reversed):toBe(source)
	expectArrayEquals(source, { "third", "second", "first" })
end)

suite:test("reverse materializes simple iterators and meta iterables", function()
	local reversedFromSimple = iter.reverse(arrayIterator({ 10, 20, 30 }))
	local reversedFromMeta = iter.reverse(MetaBox.new({ "left", "middle", "right" }))

	expectArrayEquals(reversedFromSimple, { 30, 20, 10 })
	expectArrayEquals(reversedFromMeta, { "right", "middle", "left" })
end)

suite:test("reverse compacts sparse iterator output into a dense reversed array", function()
	local reversed = iter.reverse(pairIterator({
		{ 3, "three" },
		{ 7, "seven" },
		{ 10, "ten" },
	}))

	expectArrayEquals(reversed, { "ten", "seven", "three" })
end)

suite:test("unique on arrays keeps the first occurrence of each value with dense indices", function()
	local uniqueValues = iter.unique({ "apple", "banana", "apple", "pear", "banana", "pear" })

	expectPairsEqual(collectPairs(uniqueValues), {
		{ 1, "apple" },
		{ 2, "banana" },
		{ 3, "pear" },
	})
end)

suite:test("unique works with iterators and deduplicates false and table values by equality", function()
	local shared = {}
	local uniqueValues = iter.unique(pairIterator<<any>>({
		{ 3, false },
		{ 5, false },
		{ 7, shared },
		{ 8, {} },
		{ 9, shared },
		{ 11, true },
		{ 12, true },
	}))

	local pairsOut = collectPairs(uniqueValues)
	test.expect(#pairsOut):toBe(4)
	test.expect(pairsOut[1][1], pairsOut[1][2]):toBe(1, false)
	test.expect(pairsOut[2][1], pairsOut[2][2]):toBe(2, shared)
	test.expect(pairsOut[3][1]):toBe(3)
	test.expect(type(pairsOut[3][2])):toBe("table")
	test.expect(pairsOut[3][2]):toNotBe(shared)
	test.expect(pairsOut[4][1], pairsOut[4][2]):toBe(4, true)
end)

suite:test("unique handles all-unique, all-identical, and partially consumed iterators", function()
	expectPairsEqual(collectPairs(iter.unique({ "a", "b", "c" })), {
		{ 1, "a" },
		{ 2, "b" },
		{ 3, "c" },
	})

	expectPairsEqual(collectPairs(iter.unique({ "x", "x", "x" })), {
		{ 1, "x" },
	})

	local source = arrayIterator({ "keep", "drop", "keep", "stay", "stay", "last" })
	test.expect(source()):toBe(1, "keep")

	expectPairsEqual(collectPairs(iter.unique(source)), {
		{ 1, "drop" },
		{ 2, "keep" },
		{ 3, "stay" },
		{ 4, "last" },
	})
end)

suite:test("find on iterators returns the first match and consumes the iterator", function()
	local source = arrayIterator({ 4, 7, 9, 12 })

	test.expect(iter.find(source, function(value: number)
		return value % 3 == 0
	end)):toBe(3, 9)

	test.expect(iter.find(source, function()
		return true
	end)):toBe(4, 12)

	test.expect(iter.find(source, function()
		return true
	end)):toBe(nil, nil)
end)

suite:test("find on arrays can match the first element", function()
	test.expect(iter.find({ 8, 2, 4 }, function(value: number)
		return value % 2 == 0
	end)):toBe(1, 8)
end)

suite:test("find on arrays can search past false values", function()
	local values = { true, false, true }

	test.expect(iter.find(values, function(value: boolean)
		return value == false
	end)):toBe(2, false)

	test.expect(iter.find(values, function(value: boolean)
		return value == true
	end, 3)):toBe(3, true)
end)

suite:test("find on arrays can resume from a later start index", function()
	local values = { 1, 4, 7, 10, 13, 16 }

	local firstIndex, firstValue = iter.find(values, function(value: number)
		return value % 2 == 0
	end)
	test.expect(firstIndex, firstValue):toBe(2, 4)

	local secondIndex, secondValue = iter.find(values, function(value: number)
		return value % 2 == 0
	end, (firstIndex :: number) + 1)
	test.expect(secondIndex, secondValue):toBe(4, 10)

	local thirdIndex, thirdValue = iter.find(values, function(value: number)
		return value % 2 == 0
	end, (secondIndex :: number) + 1)
	test.expect(thirdIndex, thirdValue):toBe(6, 16)

	test.expect(iter.find(values, function(value: number)
		return value % 2 == 0
	end, (thirdIndex :: number) + 1)):toBe(nil, nil)
end)

suite:test("reduce folds iterables into a single value", function()
	local sum = iter.reduce(MetaBox.new({ 5, 10, 15 }), function(acc, value)
		return acc + value
	end, 0)

	test.expect(sum):toBe(30)
end)

suite:test("reduce respects partially consumed iterators", function()
	local source = arrayIterator({ 1, 2, 3, 4 })
	test.expect(source()):toBe(1, 1)

	local sum = iter.reduce(source, function(acc: number, value: number)
		return acc + value
	end, 0)

	test.expect(sum):toBe(9)
end)

suite:test("all and any handle both populated and empty iterables", function()
	test.expect(iter.all({ 2, 4, 6 }, function(value: number)
		return value % 2 == 0
	end)):toBeTrue()

	test.expect(iter.all(arrayIterator({ 2, 3, 4 }), function(value: number)
		return value % 2 == 0
	end)):toBeFalse()

	test.expect(iter.any(MetaBox.new({ 1, 3, 5, 8 }), function(value: number)
		return value % 2 == 0
	end)):toBeTrue()

	test.expect(iter.any(arrayIterator({ 1, 3, 5 }), function(value: number)
		return value % 2 == 0
	end)):toBeFalse()

	test.expect(iter.all({}, function()
		return false
	end)):toBeTrue()

	test.expect(iter.any({}, function()
		return true
	end)):toBeFalse()
end)

suite:test("empty iterables stay empty through map filter unique and reverse", function()
	expectArrayEquals(
		collectValues(iter.map({}, function(value: any)
			return value
		end)),
		{}
	)

	expectArrayEquals(
		collectValues(iter.filter(arrayIterator({}), function()
			return true
		end)),
		{}
	)

	expectArrayEquals(collectValues(iter.unique(MetaBox.new({}))), {})
	expectArrayEquals(iter.reverse({}), {})
end)

suite:test("composed iterator pipelines work across iterable kinds", function()
	local mb = MetaBox.new({ "pear", "apple", "fig", "apple", "banana", "pear", "plum" })
	local f = iter.filter(mb, function(value)
		return #value >= 4
	end)

	local pipeline = iter.reverse(iter.unique(iter.map(f, function(value)
		return string.upper(value)
	end)))

	expectArrayEquals(pipeline, { "PLUM", "BANANA", "APPLE", "PEAR" })
end)

suite:test("composed pipelines can be partially consumed before further transforms", function()
	local mapped = iter.map({ 1, 2, 3, 4, 5 }, function(value: number)
		return value * 2
	end)

	test.expect(mapped()):toBe(1, 2)

	local filtered = iter.filter(mapped, function(value)
		return value >= 6
	end)

	expectPairsEqual(collectPairs(filtered), {
		{ 1, 6 },
		{ 2, 8 },
		{ 3, 10 },
	})
end)

suite:test("forEach also works with custom-index iterators", function()
	local seen = {}

	iter.forEach(
		pairIterator({
			{ 2, "alpha" },
			{ 4, "beta" },
		}),
		function(value, index)
			table.insert(seen, { index, value })
		end
	)

	expectPairsEqual(seen, {
		{ 2, "alpha" },
		{ 4, "beta" },
	})
end)

return suite
