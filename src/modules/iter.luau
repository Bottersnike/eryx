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

The `iter.Iterable<T, any>` type can be used to describe any iterable
sequence that results in items of type `T`. `iter.SimpleIterator<T>` on the
other hand describes the iterator types returned by these functions.

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

return table.freeze(iter)
