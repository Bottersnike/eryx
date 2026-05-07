local queue = require("@eryx/queue")
local test = require("@eryx/test")

local suite = test.Suite.new("queue")

local function expectArrayEquals<T>(actual: { T }, expected: { T })
	test.expect(#actual):toBe(#expected)
	for index = 1, #expected do
		test.expect(actual[index]):toBe(expected[index])
	end
end

local function expectEntryArrayEquals<T, P>(
	actual: { queue.PriorityQueueEntry<T, P> },
	expected: { queue.PriorityQueueEntry<T, P> }
)
	test.expect(#actual):toBe(#expected)
	for index = 1, #expected do
		local actualEntry = actual[index]
		local expectedEntry = expected[index]
		test.expect(actualEntry.item):toBe(expectedEntry.item)
		test.expect(actualEntry.priority):toBe(expectedEntry.priority)
	end
end

local function collectIteration<T>(iterable: any): { { number | T } }
	local out = {}
	for index, value in iterable do
		table.insert(out, { index, value })
	end
	return out
end

local function expectIteration<T>(iterable: any, expected: { { number | T } })
	local actual = collectIteration(iterable)
	test.expect(#actual):toBe(#expected)
	for index = 1, #expected do
		test.expect(actual[index][1]):toBe(expected[index][1])
		test.expect(actual[index][2]):toBe(expected[index][2])
	end
end

suite:test("Queue.new creates an empty queue with expected defaults", function()
	local q = queue.Queue.new()

	test.expect(q.size):toBe(0)
	test.expect(q:isEmpty()):toBeTrue()
	expectArrayEquals(q:toArray(), {})
	expectIteration(q, {})
end)

suite:test("Queue.new and Queue.from preserve dequeue order", function()
	local q = queue.Queue.new({ "a", "b", "c" })
	local from = queue.Queue.from({ "x", "y", "z" })

	expectArrayEquals(q:toArray(), { "a", "b", "c" })
	expectArrayEquals(from:toArray(), { "x", "y", "z" })
	test.expect(q:peek()):toBe("a")
	test.expect(from:peek()):toBe("x")
	expectIteration(q, {
		{ 1, "a" },
		{ 2, "b" },
		{ 3, "c" },
	})
end)

suite:test("Queue supports enqueue dequeue peek size and false values", function()
	local q = queue.Queue.new<<boolean | string>>({ false, "tail" })

	test.expect(q.size):toBe(2)
	test.expect(q:peek()):toBe(false)
	test.expect(q:dequeue()):toBe(false)
	test.expect(q.size):toBe(1)
	test.expect(q:peek()):toBe("tail")
	q:enqueue(false):enqueue("done")
	expectArrayEquals(q:toArray(), { "tail", false, "done" })
	test.expect(q:dequeue()):toBe("tail")
	test.expect(q:dequeue()):toBe(false)
	test.expect(q:dequeue()):toBe("done")
	test.expect(q.size):toBe(0)
	test.expect(q:isEmpty()):toBeTrue()
end)

suite:test("Queue.clone returns an independent shallow copy", function()
	local q = queue.Queue.from({ 1, 2, 3 })
	local clone = q:clone()

	test.expect(clone):toNotBe(q)
	expectArrayEquals(clone:toArray(), { 1, 2, 3 })

	test.expect(q:dequeue()):toBe(1)
	clone:enqueue(4)

	expectArrayEquals(q:toArray(), { 2, 3 })
	expectArrayEquals(clone:toArray(), { 1, 2, 3, 4 })
end)

suite:test("Queue.clear empties the queue and allows reuse", function()
	local q = queue.Queue.from({ 1, 2, 3 })

	q:clear()
	test.expect(q.size):toBe(0)
	test.expect(q:isEmpty()):toBeTrue()
	expectArrayEquals(q:toArray(), {})
	expectIteration(q, {})

	q:enqueue(10):enqueue(20)
	expectArrayEquals(q:toArray(), { 10, 20 })
	test.expect(q:dequeue()):toBe(10)
	test.expect(q:dequeue()):toBe(20)
end)

suite:test("Queue errors on empty operations and nil insertion", function()
	local q = queue.Queue.new<<number>>()

	test.expect(function()
		q:dequeue()
	end):toError("queue is empty")
	test.expect(function()
		q:peek()
	end):toError("queue is empty")
	test.expect(function()
		(q :: any):enqueue(nil)
	end):toError("queue items cannot be nil")
end)

suite:test("Deque.new creates an empty deque with expected defaults", function()
	local dq = queue.Deque.new()

	test.expect(dq.size):toBe(0)
	test.expect(dq:isEmpty()):toBeTrue()
	expectArrayEquals(dq:toArray(), {})
	expectIteration(dq, {})
end)

suite:test("Deque.new and Deque.from preserve front-to-back order", function()
	local dq = queue.Deque.new({ "a", "b", "c" })
	local from = queue.Deque.from({ "x", "y", "z" })

	expectArrayEquals(dq:toArray(), { "a", "b", "c" })
	expectArrayEquals(from:toArray(), { "x", "y", "z" })
	test.expect(dq:peekFront()):toBe("a")
	test.expect(dq:peekBack()):toBe("c")
	expectIteration(dq, {
		{ 1, "a" },
		{ 2, "b" },
		{ 3, "c" },
	})
end)

suite:test("Deque supports pushing and popping at both ends with false values", function()
	local dq = queue.Deque.new<<boolean | string>>()

	dq:pushBack("middle")
	dq:pushFront(false)
	dq:pushBack("end")
	dq:pushFront("start")

	expectArrayEquals(dq:toArray(), { "start", false, "middle", "end" })
	test.expect(dq:peekFront()):toBe("start")
	test.expect(dq:peekBack()):toBe("end")
	test.expect(dq:popFront()):toBe("start")
	test.expect(dq:popFront()):toBe(false)
	test.expect(dq:popBack()):toBe("end")
	test.expect(dq:popBack()):toBe("middle")
	test.expect(dq.size):toBe(0)
	test.expect(dq:isEmpty()):toBeTrue()
end)

suite:test("Deque.clone returns an independent shallow copy", function()
	local dq = queue.Deque.from({ 1, 2, 3 })
	local clone = dq:clone()

	test.expect(clone):toNotBe(dq)
	expectArrayEquals(clone:toArray(), { 1, 2, 3 })

	test.expect(dq:popFront()):toBe(1)
	clone:pushFront(0):pushBack(4)

	expectArrayEquals(dq:toArray(), { 2, 3 })
	expectArrayEquals(clone:toArray(), { 0, 1, 2, 3, 4 })
end)

suite:test("Deque.clear empties the deque and allows reuse", function()
	local dq = queue.Deque.from({ 1, 2, 3 })

	dq:clear()
	test.expect(dq.size):toBe(0)
	test.expect(dq:isEmpty()):toBeTrue()
	expectArrayEquals(dq:toArray(), {})
	expectIteration(dq, {})

	dq:pushFront(2):pushBack(3):pushFront(1)
	expectArrayEquals(dq:toArray(), { 1, 2, 3 })
end)

suite:test("Deque errors on empty operations and nil insertion", function()
	local dq = queue.Deque.new<<number>>()

	test.expect(function()
		dq:popFront()
	end):toError("deque is empty")
	test.expect(function()
		dq:popBack()
	end):toError("deque is empty")
	test.expect(function()
		dq:peekFront()
	end):toError("deque is empty")
	test.expect(function()
		dq:peekBack()
	end):toError("deque is empty")
	test.expect(function()
		(dq :: any):pushFront(nil)
	end):toError("deque items cannot be nil")
	test.expect(function()
		(dq :: any):pushBack(nil)
	end):toError("deque items cannot be nil")
end)

suite:test("PriorityQueue.new starts empty and supports raw-priority push/pop", function()
	local pq = queue.PriorityQueue.new<<number, number>>()

	test.expect(pq.size):toBe(0)
	test.expect(pq:isEmpty()):toBeTrue()

	pq:push(5):push(2):push(9):push(1)
	test.expect(pq.size):toBe(4)
	test.expect(pq:peek()):toBe(1)
	test.expect(pq:pop()):toBe(1)
	test.expect(pq:pop()):toBe(2)
	test.expect(pq:pop()):toBe(5)
	test.expect(pq:pop()):toBe(9)
	test.expect(pq:isEmpty()):toBeTrue()
end)

suite:test("PriorityQueue supports explicit priorities and entry inspection", function()
	local pq = queue.PriorityQueue.new<<string, number>>()
	pq:push("slow", 10):push("fast", 1):push("medium", 5)

	local peeked = pq:peekEntry()
	test.expect(peeked.item):toBe("fast")
	test.expect(peeked.priority):toBe(1)

	local popped = pq:popEntry()
	test.expect(popped.item):toBe("fast")
	test.expect(popped.priority):toBe(1)
	expectArrayEquals(pq:toSortedArray(), { "medium", "slow" })
end)

suite:test("PriorityQueue max order reverses pop order", function()
	local pq = queue.PriorityQueue.new<<number, number>>({ order = "max" })
	pq:push(5):push(2):push(9):push(1)

	expectArrayEquals(pq:toSortedArray(), { 9, 5, 2, 1 })
	test.expect(pq:pop()):toBe(9)
	test.expect(pq:pop()):toBe(5)
end)

suite:test("PriorityQueue default priority extractor supports push(item) without explicit priority", function()
	local pq = queue.PriorityQueue.new<<{ name: string, score: number }, number>>({
		priority = function(item)
			return item.score
		end,
	})

	local a = { name = "a", score = 30 }
	local b = { name = "b", score = 10 }
	local c = { name = "c", score = 20 }

	pq:push(a):push(b):push(c)
	test.expect(pq:peek()):toBe(b)
	expectArrayEquals(pq:toSortedArray(), { b, c, a })
end)

suite:test("PriorityQueue.fromPriorities heapifies values in linear-build constructor", function()
	local pq = queue.PriorityQueue.fromPriorities({ 7, 3, 5, 1, 9 })

	expectArrayEquals(pq:toSortedArray(), { 1, 3, 5, 7, 9 })
	test.expect(pq.size):toBe(5)
end)

suite:test("PriorityQueue.from heapifies items using explicit extractor", function()
	local low = { name = "low", score = 1 }
	local high = { name = "high", score = 9 }
	local mid = { name = "mid", score = 5 }

	local pq = queue.PriorityQueue.from({ high, low, mid }, function(item)
		return item.score
	end)

	expectArrayEquals(pq:toSortedArray(), { low, mid, high })
end)

suite:test("PriorityQueue.fromEntries heapifies explicit entries", function()
	local pq = queue.PriorityQueue.fromEntries({
		{ item = "late", priority = 10 },
		{ item = "first", priority = 1 },
		{ item = "middle", priority = 5 },
	})

	expectEntryArrayEquals(pq:toSortedEntries(), {
		{ item = "first", priority = 1 },
		{ item = "middle", priority = 5 },
		{ item = "late", priority = 10 },
	})
end)

suite:test("PriorityQueue stable ordering preserves insertion order for equal priorities", function()
	local pq = queue.PriorityQueue.new<<string, number>>({ stable = true })

	pq:push("first", 1)
	pq:push("second", 1)
	pq:push("third", 1)

	expectArrayEquals(pq:toSortedArray(), { "first", "second", "third" })
	test.expect(pq:pop()):toBe("first")
	test.expect(pq:pop()):toBe("second")
	test.expect(pq:pop()):toBe("third")
end)

suite:test("PriorityQueue clone preserves stable tie-break sequencing independently", function()
	local pq = queue.PriorityQueue.new<<string, number>>({ stable = true })
	pq:push("a", 1):push("b", 1)

	local clone = pq:clone()
	pq:push("c", 1)
	clone:push("d", 1)

	expectArrayEquals(pq:toSortedArray(), { "a", "b", "c" })
	expectArrayEquals(clone:toSortedArray(), { "a", "b", "d" })
end)

suite:test("PriorityQueue custom less works and order max reverses the comparator", function()
	local items: { { label: string, weight: number } } = {
		{ label = "bbb", weight = 3 },
		{ label = "a", weight = 1 },
		{ label = "cc", weight = 2 },
	}
	local minOptions: queue.PriorityQueueOptions<{ label: string, weight: number }, string> = {
		less = function(a: string, b: string): boolean
			return #a < #b
		end,
	}
	local maxOptions: queue.PriorityQueueOptions<{ label: string, weight: number }, string> = {
		order = "max",
		less = function(a: string, b: string): boolean
			return #a < #b
		end,
	}

	local minQueue = queue.PriorityQueue.from(items, function(item: { label: string, weight: number }): string
		return item.label
	end, minOptions)

	local maxQueue = queue.PriorityQueue.from(items, function(item: { label: string, weight: number }): string
		return item.label
	end, maxOptions)

	expectArrayEquals(minQueue:toSortedArray(), { items[2], items[3], items[1] })
	expectArrayEquals(maxQueue:toSortedArray(), { items[1], items[3], items[2] })
end)

suite:test("PriorityQueue pushPop matches heap push-pop semantics", function()
	local pq = queue.PriorityQueue.fromPriorities({ 3, 5, 7 })

	test.expect(pq:pushPop(2)):toBe(2)
	expectArrayEquals(pq:toSortedArray(), { 3, 5, 7 })

	test.expect(pq:pushPop(6)):toBe(3)
	expectArrayEquals(pq:toSortedArray(), { 5, 6, 7 })
end)

suite:test("PriorityQueue pushPop on an empty queue returns the item and keeps queue empty", function()
	local pq = queue.PriorityQueue.new<<number, number>>()

	test.expect(pq:pushPop(10)):toBe(10)
	test.expect(pq.size):toBe(0)
	test.expect(pq:isEmpty()):toBeTrue()
end)

suite:test("PriorityQueue replace swaps the head and errors when empty", function()
	local pq = queue.PriorityQueue.fromPriorities({ 2, 4, 6 })

	test.expect(pq:replace(5)):toBe(2)
	expectArrayEquals(pq:toSortedArray(), { 4, 5, 6 })

	local empty = queue.PriorityQueue.new<<number, number>>()
	test.expect(function()
		empty:replace(1)
	end):toError("priority queue is empty")
end)

suite:test("PriorityQueue clear empties the queue and allows reuse", function()
	local pq = queue.PriorityQueue.fromEntries({
		{ item = "b", priority = 2 },
		{ item = "a", priority = 1 },
	})

	pq:clear()
	test.expect(pq.size):toBe(0)
	test.expect(pq:isEmpty()):toBeTrue()
	expectArrayEquals(pq:toHeapArray(), {})
	expectEntryArrayEquals(pq:toHeapEntries(), {})

	pq:push("c", 3):push("b", 2):push("a", 1)
	expectArrayEquals(pq:toSortedArray(), { "a", "b", "c" })
end)

suite:test("PriorityQueue heap snapshots are heap-ordered and sorted snapshots are non-mutating", function()
	local pq = queue.PriorityQueue.fromEntries({
		{ item = "slow", priority = 10 },
		{ item = "fast", priority = 1 },
		{ item = "medium", priority = 5 },
		{ item = "medium2", priority = 6 },
	})

	local heapItems = pq:toHeapArray()
	local heapEntries = pq:toHeapEntries()
	local sortedItems = pq:toSortedArray()
	local sortedEntries = pq:toSortedEntries()

	test.expect(heapItems[1]):toBe("fast")
	test.expect(heapEntries[1].item):toBe("fast")
	test.expect(heapEntries[1].priority):toBe(1)
	test.expect((heapEntries[1] :: any).sequence):toBeNil()

	expectArrayEquals(sortedItems, { "fast", "medium", "medium2", "slow" })
	expectEntryArrayEquals(sortedEntries, {
		{ item = "fast", priority = 1 },
		{ item = "medium", priority = 5 },
		{ item = "medium2", priority = 6 },
		{ item = "slow", priority = 10 },
	})

	test.expect(pq.size):toBe(4)
	test.expect(pq:peek()):toBe("fast")
end)

suite:test("PriorityQueue pop and peek operations error on empty queues", function()
	local pq = queue.PriorityQueue.new<<number, number>>()

	test.expect(function()
		pq:pop()
	end):toError("priority queue is empty")
	test.expect(function()
		pq:popEntry()
	end):toError("priority queue is empty")
	test.expect(function()
		pq:peek()
	end):toError("priority queue is empty")
	test.expect(function()
		pq:peekEntry()
	end):toError("priority queue is empty")
end)

suite:test("PriorityQueue validates nil items, nil priorities, and nil extractor results", function()
	local pq = queue.PriorityQueue.new<<string, number>>()
	local withExtractor = queue.PriorityQueue.new<<string, number>>({
		priority = function(item: string)
			if item == "bad" then
				return nil :: any
			end
			return #item
		end,
	})

	test.expect(function()
		(pq :: any):push(nil, 1)
	end):toError("priority queue items cannot be nil")
	test.expect(function()
		(pq :: any):push("x", nil)
	end):toNotError()
	local rawPriorityPq = queue.PriorityQueue.new<<{ value: string }, number>>()
	test.expect(function()
		rawPriorityPq:push({ value = "x" })
		rawPriorityPq:push({ value = "y" })
	end):toError()
	test.expect(function()
		withExtractor:push("bad")
	end):toError("priority extractor returned nil")
	test.expect(function()
		queue.PriorityQueue.from({ "ok", "bad" } :: { string }, function(item: string)
			if item == "bad" then
				return nil :: any
			end
			return #item
		end)
	end):toError("priority extractor returned nil")
	test.expect(function()
		local missingItem: any = { priority = 2 }
		queue.PriorityQueue.fromEntries({
			{ item = "ok", priority = 1 },
			missingItem,
		} :: any)
	end):toError("priority queue items cannot be nil")
	test.expect(function()
		local missingPriority: any = { item = "bad" }
		queue.PriorityQueue.fromEntries({
			{ item = "ok", priority = 1 },
			missingPriority,
		} :: any)
	end):toError("priority queue priorities cannot be nil")
end)

return suite
