--[=[
Utilities for working with sequence-like data through a small iterator API.

Functions in this library accept three kinds of iterable input:

1. Dense array-like tables such as `{ "a", "b", "c" }`
2. Simple iterator functions of the form `() -> (index?, value)`
3. Tables or userdata with an `__iter` metamethod

Most transforming helpers return a `SimpleIterator`, which is a stateful
iterator function yielding `(index, value)` pairs until it returns `nil`.

Use this library when you want to write code against "something iterable"
without caring whether the source is an array, an iterator callback, or a
custom object with `__iter`.

Sequence-style transforms such as `filter`, `unique`, and `reverse` produce
dense array-like results or dense iterator indices. `flatten`, by contrast,
preserves the yielded numeric keys from the underlying iterable.

```luau
local iter = require("@eryx/iter")

local evens = iter.filter({ 1, 2, 3, 4, 5, 6 }, function(value)
    return value % 2 == 0
end)

for index, value in evens do
    print(index, value) -- 1 2, then 2 4, then 3 6
end
```

```luau
local iter = require("@eryx/iter")

local values = iter.reverse(
    iter.unique(
        iter.map({ "pear", "apple", "pear", "plum" }, string.upper)
    )
)

print(values) -- { "PLUM", "APPLE", "PEAR" }
```
]=]

local iter = {}

--- A stateful iterator function yielding `(index, value)` pairs until it returns `nil`.
export type SimpleIterator<T> = () -> (number?, T)

type IteratorGenFunction<T, Invariant> = (invariant: Invariant?, control: number?) -> (number?, T)
--- Any table that has an `__iter` metamethod
export type MetaIterator<T, Invariant> = setmetatable<{}, {
	__iter: (self: any) -> (IteratorGenFunction<T, Invariant>, Invariant?, number?),
}>
--- An array, a [[SimpleIterator]], or any value with an `__iter` metamethod.
export type Iterable<T, Invariant> = { T } | SimpleIterator<T> | MetaIterator<T, Invariant>

local function isSimpleArray<T, Invariant>(iterable: Iterable<T, Invariant>): boolean
	if type(iterable) ~= "table" then
		return false
	end
	local mt = getmetatable(iterable)
	if mt then
		local _iter = rawget(mt :: any, "__iter")
		if _iter then
			return false
		end
	end

	return true
end

local function wrap<T, Invariant>(iterable: Iterable<T, Invariant>): () -> (number?, T)
	-- Simple iterable
	if type(iterable) == "function" then
		return iterable
	end

	-- Look for an `__iter` method
	if type(iterable) == "table" or type(iterable) == "userdata" then
		local mt = getmetatable(iterable)
		if mt then
			local _iter =
				rawget(mt :: any, "__iter") :: ((any) -> (IteratorGenFunction<T, Invariant>, Invariant, number))?
			if _iter then
				-- Bootstrap the iteration
				local gen, invariant, control = _iter(iterable)

				return function()
					local k, v = gen(invariant, control)
					if not k then
						return nil, nil
					end
					control = k
					return k, v
				end
			end
		end
	end

	-- We just have a basic table
	local index = 0
	return function()
		index += 1
		if iterable[index] == nil then
			return nil, nil
		end
		return index, iterable[index]
	end
end

--- Lazily maps each item in an iterable.
--- @param iterable Iterable source to read from.
--- @param mapper Transform applied to each yielded value.
--- @return Iterator that yields the original index with the mapped value.
function iter.map<T, U, I>(iterable: Iterable<T, I>, mapper: (T) -> U): SimpleIterator<U>
	local next = wrap(iterable)

	return function(): (number?, U)
		local k, v = next()
		if not k then
			return nil, nil
		end
		return k, mapper(v)
	end
end

--- Lazily filters an iterable by predicate.
--- Matching items are reindexed densely from `1`.
--- @param iterable Iterable source to read from.
--- @param filter Predicate used to decide whether an item should be yielded.
--- @return Iterator that yields only items matching `filter`.
function iter.filter<T, I>(iterable: Iterable<T, I>, filter: (T) -> boolean): SimpleIterator<T>
	local next = wrap(iterable)
	local outputIndex = 0

	return function(): (number?, T)
		while true do
			local k, v = next()
			if not k then
				return nil, nil
			end
			if filter(v) then
				outputIndex += 1
				return outputIndex, v
			end
		end
	end
end

--- Calls a function on every item in an iterable
--- @param iterable Iterable source to read from.
--- @param callback Callback called with each yielded value and its index.
function iter.forEach<T, I>(iterable: Iterable<T, I>, callback: (T) -> () | (T, number) -> ()): ()
	for n, i in iterable do
		(callback :: any)(i, n)
	end
end

--- Materializes an iterable into an array.
--- Table inputs are returned directly without cloning.
--- Iterator inputs preserve their yielded numeric keys, which may produce a sparse table.
--- @param iterable Iterable source to flatten.
--- @return Array containing all yielded values, keyed by their yielded indices.
function iter.flatten<T, I>(iterable: Iterable<T, I>): { T }
	if isSimpleArray(iterable) then
		return iterable :: any
	end

	local next = wrap(iterable)

	local array: { T } = {}
	while true do
		local n, i = next()
		if not n then
			break
		end
		array[n] = i
	end
	return array
end

--[=[
Helper for writing `coroutine.yield`-based generators.

For example:

```luau
local function foo()
	return iter.generator(function()
		coroutine.yield(1)
		coroutine.yield(2)
		coroutine.yield(3)
	end)
end
for i in foo() do
	print(i)  -- Prints `1` then `2` then `3`
end
```

@param fn The yield-based generator
@return A Luau-compatible iterator
]=]
function iter.generator<T>(fn: () -> ()): SimpleIterator<T>
	local co = coroutine.create(fn)

	return function()
		local resume = table.pack(coroutine.resume(co))
		local ok = resume[1]
		if not ok then
			error(resume[2])
		end
		if coroutine.status(co) == "dead" then
			return nil, nil
		end
		table.remove(resume, 1)
		return table.unpack(resume :: any)
	end
end

--- Converts an array into a stateful iterator function.
--- @param array Array to iterate over.
--- @return Iterator that yields sequential array indices and values.
function iter.tableIterator<T>(array: { T }): SimpleIterator<T>
	local n = 1
	return function(): (number?, T)
		if array[n] == nil then
			return nil, nil
		end
		n += 1
		return n - 1, array[n - 1]
	end
end

local function iter_reversed<T, I>(iterable: Iterable<T, I>, inPlace: boolean?): { T }
	local reversed: { T }

	if isSimpleArray(iterable) then
		reversed = if inPlace then iterable :: any else table.clone(iterable) :: any
	else
		reversed = {}
		for _, value in iterable do
			table.insert(reversed, value)
		end
	end

	local len = #reversed
	for i = 1, math.floor(len / 2) do
		local j = len - i + 1
		reversed[i], reversed[j] = reversed[j], reversed[i]
	end

	return reversed
end

--- Returns a reversed array.
--- Table inputs may be reversed in place; iterator inputs are collected densely first.
--- @param iterable Iterable source to reverse.
--- @return Reversed array.
iter.reverse = iter_reversed :: ( ---
	(<T, I>(iterable: SimpleIterator<T> | MetaIterator<T, I>, inPlace: false?) -> { T }) ---
	--- When passing a simple array, this function is able to perform an in-place reverse
	--- @param inPlace When `true` reverse the table in place.
	& (<T>(iterable: { T }, inPlace: boolean?) -> { T }) ---
)

--- Lazily yields only the first occurrence of each distinct value.
--- Yielded items are reindexed densely from `1`.
--- Duplicate detection is based on direct Lua equality and table-key semantics.
--- @param iterable Iterable source to deduplicate.
--- @return Iterator that skips values that have already been seen.
function iter.unique<T, I>(iterable: Iterable<T, I>): SimpleIterator<T>
	local seen: { [T]: boolean } = {}
	local next = wrap(iterable)
	local outputIndex = 0

	return function(): (number?, T)
		while true do
			local n, item = next()
			if not n then
				return nil, nil
			end

			if not seen[item] then
				seen[item] = true
				outputIndex += 1
				return outputIndex, item
			end
		end
	end
end

local function iter_find<T, I>(iterable: Iterable<T, I>, match: (T) -> boolean, start: number?): (number?, T)
	if isSimpleArray(iterable) then
		assert(type(iterable) == "table")
		local n = start or 1
		while true do
			local i = iterable[n]
			if i == nil then
				return nil, nil
			end
			if match(i) then
				return n, i
			end
			n += 1
		end
		return nil, nil
	else
		for n, i in iterable do
			if match(i) then
				return n, i
			end
		end
		return nil, nil
	end
end

--- Finds the first item matching a predicate.
--- For table inputs, `start` can be used to resume searching from a later index.
--- For iterator inputs, calling this consumes items until a match is found or the iterator ends.
--- @param iterable Iterable source to search.
--- @param match Predicate used to test each item.
--- @return Matching index and value, or `nil` if no match is found.
iter.find = iter_find :: (
	--- @param start Starting index.
	<T>(iterable: { T }, match: (T) -> boolean, start: number?) -> (number?, T)
	& <T, I>(iterable: SimpleIterator<T> | MetaIterator<T, I>, match: (T) -> boolean) -> (number?, T)
)

--- Reduces an iterable into a single value.
--- @param iterable Iterable source to reduce.
--- @param reducer Accumulator function called with the current reduced value and next item.
--- @param initial Initial accumulator value.
--- @return Final reduced value.
function iter.reduce<T, U, I>(iterable: Iterable<T, I>, reducer: (U, T) -> U, initial: U): U
	local reduced = initial
	for _, i in iterable do
		reduced = reducer(reduced, i)
	end
	return reduced
end

--- Returns whether every item in the iterable matches a predicate.
--- @param iterable Iterable source to test.
--- @param match Predicate used to test each item.
--- @return `true` when all yielded items match, otherwise `false`.
function iter.all<T, I>(iterable: Iterable<T, I>, match: (T) -> boolean): boolean
	for _, i in iterable do
		if not match(i) then
			return false
		end
	end
	return true
end

--- Returns whether any item in the iterable matches a predicate.
--- @param iterable Iterable source to test.
--- @param match Predicate used to test each item.
--- @return `true` when any yielded item matches, otherwise `false`.
function iter.any<T, I>(iterable: Iterable<T, I>, match: (T) -> boolean): boolean
	for _, i in iterable do
		if match(i) then
			return true
		end
	end
	return false
end

--[=[
Yields successive `n`-length permutations of elements from `items`.

Order matters: `{ "a", "b" }` and `{ "b", "a" }` are distinct permutations.
Each yielded value is a new array. When `n` equals `#items` (the default),
every possible ordering of the whole sequence is produced.

```luau
for _, perm in iter.permutations({ "a", "b", "c" }) do
    print(table.concat(perm, ""))
    -- abc, acb, bac, bca, cab, cba
end
```

```luau
for _, perm in iter.permutations({ 1, 2, 3, 4 }, 2) do
    print(table.concat(perm, ""))
    -- 12, 13, 14, 21, 23, 24, 31, 32, 34, 41, 42, 43
end
```

@param items Source array to draw elements from.
@param n Length of each permutation. Defaults to `#items`. Must be non-negative and no greater than `#items`.
@return Iterator that yields `(index, permutation)` pairs until all permutations are exhausted.
]=]
function iter.permutations<T>(items: { T }, n: number?): SimpleIterator<{ T }>
	local len = #items
	local n = n or len

	if n < 0 then
		error("n must be non-negative")
	end

	if n > len then
		return function()
			return nil, nil :: any
		end
	end

	local indices = {}
	for i = 1, len do
		indices[i] = i
	end

	local cycles = {}
	for i = 1, n do
		cycles[i] = len - i + 1
	end

	local function makeResult(): { T }
		local result = {}
		for i = 1, n do
			result[i] = items[indices[i]]
		end
		return result
	end

	return iter.generator<<{ T }>>(function()
		local count = 1
		coroutine.yield(count, makeResult())

		while len > 0 do
			local didYield = false

			for i = n, 1, -1 do
				cycles[i] -= 1

				if cycles[i] == 0 then
					local first = indices[i]
					for j = i, len - 1 do
						indices[j] = indices[j + 1]
					end
					indices[len] = first

					cycles[i] = len - i + 1
				else
					local j = cycles[i]
					local swapIndex = len - j + 1

					indices[i], indices[swapIndex] = indices[swapIndex], indices[i]

					count += 1
					coroutine.yield(count, makeResult())
					didYield = true
					break
				end
			end

			if not didYield then
				return
			end
		end
	end)
end

--[=[
Yields successive `n`-length combinations of elements from `items`, without replacement.

Order does not matter: `{ "a", "b" }` and `{ "b", "a" }` are the same combination and only
the first is yielded. Combinations are emitted in lexicographic order relative to the
position of each element in the source array. Each yielded value is a new array.

```luau
for _, combo in iter.combinations({ "a", "b", "c", "d" }, 2) do
    print(table.concat(combo, ""))
    -- ab, ac, ad, bc, bd, cd
end
```

@param items Source array to draw elements from.
@param n Length of each combination. Must be non-negative and no greater than `#items`.
@return Iterator that yields `(index, combination)` pairs until all combinations are exhausted.
]=]
function iter.combinations<T>(items: { T }, n: number): SimpleIterator<{ T }>
	local len = #items

	if n < 0 then
		error("n must be non-negative")
	end

	if n > len then
		return function()
			return nil, nil :: any
		end
	end

	local indices = {}
	for i = 1, n do
		indices[i] = i
	end

	local function makeResult(): { T }
		local result = {}
		for i = 1, n do
			result[i] = items[indices[i]]
		end
		return result
	end

	return iter.generator<<{ T }>>(function()
		local count = 1
		coroutine.yield(count, makeResult())

		while true do
			local i = n

			while i >= 1 do
				if indices[i] ~= i + len - n then
					break
				end
				i -= 1
			end

			if i == 0 then
				return
			end

			indices[i] += 1

			for j = i + 1, n do
				indices[j] = indices[j - 1] + 1
			end

			count += 1
			coroutine.yield(count, makeResult())
		end
	end)
end

--[=[
Yields the Cartesian product of one or more arrays.

Each yielded tuple contains one element chosen from each input array, in the order the
arrays were passed. The rightmost array advances fastest. If any input array is empty,
no tuples are produced. Each yielded value is a new array.

```luau
for _, pair in iter.product({ "x", "y" }, { 1, 2, 3 }) do
    print(pair[1], pair[2])
    -- x 1, x 2, x 3, y 1, y 2, y 3
end
```

```luau
-- Repeating the same pool simulates combinations with replacement
for _, pair in iter.product({ 1, 2, 3 }, { 1, 2, 3 }) do
    print(pair[1], pair[2])
    -- 1 1, 1 2, 1 3, 2 1, 2 2, 2 3, 3 1, 3 2, 3 3
end
```

@param ... One or more source arrays. All elements must share the same type `T`.
@return Iterator that yields `(index, tuple)` pairs covering every combination across all input arrays.
]=]
function iter.product<T>(...: { T }): SimpleIterator<{ T }>
	local pools = { ... }

	for _, pool in pools do
		if #pool == 0 then
			return function()
				return nil, nil :: any
			end
		end
	end

	local poolCount = #pools
	local indices = {}
	for i = 1, poolCount do
		indices[i] = 1
	end

	local function makeResult(): { T }
		local result = {}
		for i = 1, poolCount do
			result[i] = pools[i][indices[i]]
		end
		return result
	end

	return iter.generator<<{ T }>>(function()
		local count = 1

		if poolCount == 0 then
			coroutine.yield(count, {})
			return
		end

		while true do
			coroutine.yield(count, makeResult())

			local i = poolCount
			while i >= 1 do
				indices[i] += 1

				if indices[i] <= #pools[i] then
					break
				end

				indices[i] = 1
				i -= 1
			end

			if i == 0 then
				return
			end

			count += 1
		end
	end)
end

return table.freeze(iter)
