--[=[
	Queue data structures.

	This module provides three small queue-shaped containers:
	- `Queue` for ordinary FIFO usage
	- `Deque` for pushing/popping at both ends
	- `PriorityQueue` for heap-backed min/max priority scheduling

	`PriorityQueue` is implemented as a proper class-style heap queue rather
	than as raw heap-list helpers. Linear-time heapify constructors are
	provided for priorities, plain items with a priority extractor, and
	explicit `(item, priority)` entries.
]=]

local queue = {}

local Queue = {}
Queue.__index = Queue

local Deque = {}
Deque.__index = Deque

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

type ArrayIterator<T> = (items: { T }, index: number?) -> (number?, T)

type QueueMethods<T> = {
	enqueue: (self: Queue<T>, item: T) -> Queue<T>,
	dequeue: (self: Queue<T>) -> T,
	peek: (self: Queue<T>) -> T,
	isEmpty: (self: Queue<T>) -> boolean,
	clear: (self: Queue<T>) -> (),
	toArray: (self: Queue<T>) -> { T },
	clone: (self: Queue<T>) -> Queue<T>,
	__iter: (self: Queue<T>) -> (ArrayIterator<T>, { T }, number?),
}

type DequeMethods<T> = {
	pushFront: (self: Deque<T>, item: T) -> Deque<T>,
	pushBack: (self: Deque<T>, item: T) -> Deque<T>,
	popFront: (self: Deque<T>) -> T,
	popBack: (self: Deque<T>) -> T,
	peekFront: (self: Deque<T>) -> T,
	peekBack: (self: Deque<T>) -> T,
	isEmpty: (self: Deque<T>) -> boolean,
	clear: (self: Deque<T>) -> (),
	toArray: (self: Deque<T>) -> { T },
	clone: (self: Deque<T>) -> Deque<T>,
	__iter: (self: Deque<T>) -> (ArrayIterator<T>, { T }, number?),
}

export type Queue<T> = QueueMethods<T> & {
	_head: number,
	_tail: number,
	read _items: { [number]: T },
	size: number,
}

export type Deque<T> = DequeMethods<T> & {
	_head: number,
	_tail: number,
	read _items: { [number]: T },
	size: number,
}

export type PriorityQueueOrder = "min" | "max"

export type PriorityQueueEntry<T, P> = {
	item: T,
	priority: P,
}

export type PriorityQueueOptions<T, P> = {
	order: PriorityQueueOrder?,
	less: ((a: P, b: P) -> boolean)?,
	stable: boolean?,
}

export type PriorityQueueNewOptions<T, P> = {
	order: PriorityQueueOrder?,
	less: ((a: P, b: P) -> boolean)?,
	stable: boolean?,
	priority: ((item: T) -> P)?,
}

type PriorityQueueHeapEntry<T, P> = {
	read item: T,
	read priority: P,
	read sequence: number,
}

type PriorityQueueMethods<T, P> = {
	push: (self: PriorityQueue<T, P>, item: T, priority: P?) -> PriorityQueue<T, P>,
	pop: (self: PriorityQueue<T, P>) -> T,
	popEntry: (self: PriorityQueue<T, P>) -> PriorityQueueEntry<T, P>,
	peek: (self: PriorityQueue<T, P>) -> T,
	peekEntry: (self: PriorityQueue<T, P>) -> PriorityQueueEntry<T, P>,
	pushPop: (self: PriorityQueue<T, P>, item: T, priority: P?) -> T,
	replace: (self: PriorityQueue<T, P>, item: T, priority: P?) -> T,
	isEmpty: (self: PriorityQueue<T, P>) -> boolean,
	clear: (self: PriorityQueue<T, P>) -> (),
	toHeapArray: (self: PriorityQueue<T, P>) -> { T },
	toHeapEntries: (self: PriorityQueue<T, P>) -> { PriorityQueueEntry<T, P> },
	toSortedArray: (self: PriorityQueue<T, P>) -> { T },
	toSortedEntries: (self: PriorityQueue<T, P>) -> { PriorityQueueEntry<T, P> },
	clone: (self: PriorityQueue<T, P>) -> PriorityQueue<T, P>,
}

export type PriorityQueue<T, P> = PriorityQueueMethods<T, P> & {
	_heap: { PriorityQueueHeapEntry<T, P> },
	_order: PriorityQueueOrder,
	_priority: ((item: T) -> P)?,
	_less: ((a: P, b: P) -> boolean)?,
	_stable: boolean,
	_sequence: number,
	size: number,
}

local function fail(message: string): never
	error(message, 2)
end

local function arrayIter<T>(items: { T }, index: number?): (number?, T)
	local nextIndex = (index or 0) + 1
	local value = items[nextIndex]
	if value == nil then
		return nil, nil
	end
	return nextIndex, value
end

local function resetLinearState<T>(self: Queue<T> | Deque<T>)
	self._head = 0
	self._tail = -1
	self.size = 0
end

local function initLinearState<T>(items: { T }): (number, number, { [number]: T })
	local storage: { [number]: T } = table.create(#items)
	for index, item in items do
		if item == nil then
			fail("queue items cannot be nil")
		end
		storage[index - 1] = item
	end
	if #items == 0 then
		return 0, -1, storage
	end
	return 0, #items - 1, storage
end

local function defaultPriorityLess<P>(a: P, b: P): boolean
	return (a :: any) < (b :: any)
end

local function priorityBefore<T, P>(self: PriorityQueue<T, P>, a: P, b: P): boolean
	local less = self._less or defaultPriorityLess
	if self._order == "max" then
		return less(b, a)
	end
	return less(a, b)
end

local function entryBefore<T, P>(
	self: PriorityQueue<T, P>,
	a: PriorityQueueHeapEntry<T, P>,
	b: PriorityQueueHeapEntry<T, P>
): boolean
	if priorityBefore(self, a.priority, b.priority) then
		return true
	end
	if priorityBefore(self, b.priority, a.priority) then
		return false
	end
	if self._stable then
		return a.sequence < b.sequence
	end
	return false
end

local function swapHeap<T, P>(heap: { PriorityQueueHeapEntry<T, P> }, left: number, right: number)
	heap[left], heap[right] = heap[right], heap[left]
end

local function siftUp<T, P>(self: PriorityQueue<T, P>, index: number)
	local heap = self._heap
	while index > 1 do
		local parent = math.floor(index / 2)
		if not entryBefore(self, heap[index], heap[parent]) then
			break
		end
		swapHeap(heap, index, parent)
		index = parent
	end
end

local function siftDown<T, P>(self: PriorityQueue<T, P>, index: number)
	local heap = self._heap
	local count = #heap
	while true do
		local left = index * 2
		local right = left + 1
		local best = index

		if left <= count and entryBefore(self, heap[left], heap[best]) then
			best = left
		end
		if right <= count and entryBefore(self, heap[right], heap[best]) then
			best = right
		end
		if best == index then
			break
		end

		swapHeap(heap, index, best)
		index = best
	end
end

local function heapify<T, P>(self: PriorityQueue<T, P>)
	for index = math.floor(#self._heap / 2), 1, -1 do
		siftDown(self, index)
	end
end

local function publicEntry<T, P>(entry: PriorityQueueHeapEntry<T, P>): PriorityQueueEntry<T, P>
	return {
		item = entry.item,
		priority = entry.priority,
	}
end

local function nextPriority<T, P>(self: PriorityQueue<T, P>, item: T, priority: P?): P
	if priority ~= nil then
		return priority
	end
	if self._priority then
		local derived = self._priority(item)
		if derived == nil then
			fail("priority queue priority extractor returned nil")
		end
		return derived
	end
	return item
end

local function makePriorityQueue<T, P>(options: PriorityQueueNewOptions<T, P>?): PriorityQueue<T, P>
	local opts = options
	local self = {
		_heap = {} :: { PriorityQueueHeapEntry<T, P> },
		_order = if opts and opts.order ~= nil then opts.order else "min",
		_priority = if opts then opts.priority else nil,
		_less = if opts then opts.less else nil,
		_stable = if opts then opts.stable == true else false,
		_sequence = 0,
		size = 0,
	}
	return (setmetatable(self, PriorityQueue) :: any) :: PriorityQueue<T, P>
end

local function pushEntry<T, P>(self: PriorityQueue<T, P>, item: T, priority: P): PriorityQueue<T, P>
	if item == nil then
		fail("priority queue items cannot be nil")
	end
	if priority == nil then
		fail("priority queue priorities cannot be nil")
	end

	local sequence = self._sequence + 1
	self._sequence = sequence

	local entry: PriorityQueueHeapEntry<T, P> = {
		item = item,
		priority = priority,
		sequence = sequence,
	}
	table.insert(self._heap, entry)
	self.size = #self._heap
	siftUp(self, #self._heap)
	return self
end

local function popHeapEntry<T, P>(self: PriorityQueue<T, P>): PriorityQueueHeapEntry<T, P>
	local heap = self._heap
	local count = #heap
	if count == 0 then
		fail("priority queue is empty")
	end

	local top = heap[1]
	local last = table.remove(heap) :: PriorityQueueHeapEntry<T, P>
	if count > 1 then
		heap[1] = last
		siftDown(self, 1)
	end

	self.size = #heap
	return top
end

--[=[
	Creates a FIFO queue.

	@param items Optional initial values in dequeue order.
	@return Queue<T> A new queue instance.
]=]
function Queue.new<T>(items: { T }?): Queue<T>
	local source = items or {}
	local head, tail, storage = initLinearState(source)
	return (
		setmetatable({
			_head = head,
			_tail = tail,
			_items = storage,
			size = #source,
		}, Queue) :: any
	) :: Queue<T>
end

--[=[
	Builds a FIFO queue from an array.

	@param items Initial values in dequeue order.
	@return Queue<T> A new queue instance.
]=]
function Queue.from<T>(items: { T }): Queue<T>
	return Queue.new(items)
end

--- @param item Value to append at the back.
--- @return Queue<T> Enables chaining.
function Queue.enqueue<T>(self: Queue<T>, item: T): Queue<T>
	if item == nil then
		fail("queue items cannot be nil")
	end

	local nextTail = self._tail + 1
	self._items[nextTail] = item
	self._tail = nextTail
	if self.size == 0 then
		self._head = nextTail
	end
	self.size += 1
	return self
end

--[=[
	Removes and returns the front item.

	Errors when the queue is empty.

	@return T The removed item.
]=]
function Queue.dequeue<T>(self: Queue<T>): T
	if self.size == 0 then
		fail("queue is empty")
	end

	local head = self._head
	local item = self._items[head]
	self._items[head] = nil
	self.size -= 1

	if self.size == 0 then
		resetLinearState(self)
	else
		self._head = head + 1
	end

	return item :: T
end

--[=[
	Returns the front item without removing it.

	Errors when the queue is empty.

	@return T The next item.
]=]
function Queue.peek<T>(self: Queue<T>): T
	if self.size == 0 then
		fail("queue is empty")
	end
	return self._items[self._head] :: T
end

--- @return boolean `true` when the queue has no items.
function Queue.isEmpty<T>(self: Queue<T>): boolean
	return self.size == 0
end

--- Removes all items from the queue.
function Queue.clear<T>(self: Queue<T>): ()
	table.clear(self._items)
	resetLinearState(self)
end

--- @return { T } A shallow array snapshot in dequeue order.
function Queue.toArray<T>(self: Queue<T>): { T }
	local out = table.create(self.size)
	for offset = 0, self.size - 1 do
		out[offset + 1] = self._items[self._head + offset] :: T
	end
	return out
end

--- @return Queue<T> A shallow copy of this queue.
function Queue.clone<T>(self: Queue<T>): Queue<T>
	return Queue.from(self:toArray())
end

--[=[
	Returns the generalized-iteration triple for front-to-back traversal.

	@return generator, state, index Triple consumed by Luau's `for ... in` protocol.
]=]
function Queue.__iter<T>(self: Queue<T>): (ArrayIterator<T>, { T }, number?)
	return arrayIter, self:toArray(), nil
end

--[=[
	Creates a double-ended queue.

	@param items Optional initial values from front to back.
	@return Deque<T> A new deque instance.
]=]
function Deque.new<T>(items: { T }?): Deque<T>
	local source = items or {}
	local head, tail, storage = initLinearState(source)
	return (
		setmetatable({
			_head = head,
			_tail = tail,
			_items = storage,
			size = #source,
		}, Deque) :: any
	) :: Deque<T>
end

--[=[
	Builds a deque from an array.

	@param items Initial values from front to back.
	@return Deque<T> A new deque instance.
]=]
function Deque.from<T>(items: { T }): Deque<T>
	return Deque.new(items)
end

--- @param item Value to prepend at the front.
--- @return Deque<T> Enables chaining.
function Deque.pushFront<T>(self: Deque<T>, item: T): Deque<T>
	if item == nil then
		fail("deque items cannot be nil")
	end

	if self.size == 0 then
		self._items[0] = item
		self._head = 0
		self._tail = 0
	else
		local nextHead = self._head - 1
		self._items[nextHead] = item
		self._head = nextHead
	end

	self.size += 1
	return self
end

--- @param item Value to append at the back.
--- @return Deque<T> Enables chaining.
function Deque.pushBack<T>(self: Deque<T>, item: T): Deque<T>
	if item == nil then
		fail("deque items cannot be nil")
	end

	local nextTail = self._tail + 1
	self._items[nextTail] = item
	self._tail = nextTail
	if self.size == 0 then
		self._head = nextTail
	end
	self.size += 1
	return self
end

--[=[
	Removes and returns the front item.

	Errors when the deque is empty.

	@return T The removed item.
]=]
function Deque.popFront<T>(self: Deque<T>): T
	if self.size == 0 then
		fail("deque is empty")
	end

	local head = self._head
	local item = self._items[head]
	self._items[head] = nil
	self.size -= 1

	if self.size == 0 then
		resetLinearState(self)
	else
		self._head = head + 1
	end

	return item :: T
end

--[=[
	Removes and returns the back item.

	Errors when the deque is empty.

	@return T The removed item.
]=]
function Deque.popBack<T>(self: Deque<T>): T
	if self.size == 0 then
		fail("deque is empty")
	end

	local tail = self._tail
	local item = self._items[tail]
	self._items[tail] = nil
	self.size -= 1

	if self.size == 0 then
		resetLinearState(self)
	else
		self._tail = tail - 1
	end

	return item :: T
end

--[=[
	Returns the front item without removing it.

	Errors when the deque is empty.

	@return T The next front item.
]=]
function Deque.peekFront<T>(self: Deque<T>): T
	if self.size == 0 then
		fail("deque is empty")
	end
	return self._items[self._head] :: T
end

--[=[
	Returns the back item without removing it.

	Errors when the deque is empty.

	@return T The next back item.
]=]
function Deque.peekBack<T>(self: Deque<T>): T
	if self.size == 0 then
		fail("deque is empty")
	end
	return self._items[self._tail] :: T
end

--- @return boolean `true` when the deque has no items.
function Deque.isEmpty<T>(self: Deque<T>): boolean
	return self.size == 0
end

--- Removes all items from the deque.
function Deque.clear<T>(self: Deque<T>): ()
	table.clear(self._items)
	resetLinearState(self)
end

--- @return { T } A shallow array snapshot from front to back.
function Deque.toArray<T>(self: Deque<T>): { T }
	local out = table.create(self.size)
	for offset = 0, self.size - 1 do
		out[offset + 1] = self._items[self._head + offset] :: T
	end
	return out
end

--- @return Deque<T> A shallow copy of this deque.
function Deque.clone<T>(self: Deque<T>): Deque<T>
	return Deque.from(self:toArray())
end

--[=[
	Returns the generalized-iteration triple for front-to-back traversal.

	@return generator, state, index Triple consumed by Luau's `for ... in` protocol.
]=]
function Deque.__iter<T>(self: Deque<T>): (ArrayIterator<T>, { T }, number?)
	return arrayIter, self:toArray(), nil
end

--[=[
	Creates a heap-backed priority queue.

	By default this behaves as a min-priority queue. Callers may either:
	- push `(item, priority)` pairs directly, or
	- configure a default priority extractor for future `push(item)` calls

	@param options Optional ordering, comparison, stability, and default priority extraction.
	@return PriorityQueue<T, P> A new empty priority queue.
]=]
function PriorityQueue.new<T, P>(options: PriorityQueueNewOptions<T, P>?): PriorityQueue<T, P>
	return makePriorityQueue(options)
end

--[=[
	Builds a priority queue from an array of raw priority values in linear time.

	@param priorities Initial priorities to heapify.
	@param options Optional ordering, comparison, and stability hooks.
	@return PriorityQueue<P, P> A heapified queue.
]=]
function PriorityQueue.fromPriorities<P>(priorities: { P }, options: PriorityQueueOptions<P, P>?): PriorityQueue<P, P>
	local self = makePriorityQueue(options :: PriorityQueueNewOptions<P, P>?) :: PriorityQueue<P, P>
	local heap = table.create(#priorities) :: { PriorityQueueHeapEntry<P, P> }

	for index, priority in priorities do
		if priority == nil then
			fail("priority queue priorities cannot be nil")
		end
		heap[index] = {
			item = priority,
			priority = priority,
			sequence = index,
		}
	end

	self._heap = heap
	self.size = #heap
	self._sequence = #heap
	heapify(self)
	return self
end

--[=[
	Builds a priority queue from an array of items in linear time.

	@param items Initial items to heapify.
	@param priority Extracts a priority from each item.
	@param options Optional ordering, comparison, and stability hooks.
	@return PriorityQueue<T, P> A heapified queue.
]=]
function PriorityQueue.from<T, P>(
	items: { T },
	priority: (item: T) -> P,
	options: PriorityQueueOptions<T, P>?
): PriorityQueue<T, P>
	local self = makePriorityQueue({
		order = if options then options.order else nil,
		less = if options then options.less else nil,
		stable = if options then options.stable else nil,
		priority = priority,
	} :: PriorityQueueNewOptions<T, P>)
	local heap = table.create(#items) :: { PriorityQueueHeapEntry<T, P> }

	for index, item in items do
		if item == nil then
			fail("priority queue items cannot be nil")
		end
		local derived = priority(item)
		if derived == nil then
			fail("priority queue priority extractor returned nil")
		end
		heap[index] = {
			item = item,
			priority = derived,
			sequence = index,
		}
	end

	self._heap = heap
	self.size = #heap
	self._sequence = #heap
	heapify(self)
	return self
end

--[=[
	Builds a priority queue from explicit `(item, priority)` entries in
	linear time.

	@param entries Initial entries to heapify.
	@param options Optional ordering, comparison, and stability hooks.
	@return PriorityQueue<T, P> A heapified queue.
]=]
function PriorityQueue.fromEntries<T, P>(
	entries: { PriorityQueueEntry<T, P> },
	options: PriorityQueueOptions<T, P>?
): PriorityQueue<T, P>
	local self = makePriorityQueue(options :: PriorityQueueNewOptions<T, P>?) :: PriorityQueue<T, P>
	local heap = table.create(#entries) :: { PriorityQueueHeapEntry<T, P> }

	for index, entry in entries do
		if entry == nil then
			fail("priority queue entries cannot be nil")
		end
		if entry.item == nil then
			fail("priority queue items cannot be nil")
		end
		if entry.priority == nil then
			fail("priority queue priorities cannot be nil")
		end
		heap[index] = {
			item = entry.item,
			priority = entry.priority,
			sequence = index,
		}
	end

	self._heap = heap
	self.size = #heap
	self._sequence = #heap
	heapify(self)
	return self
end

--- @param item Value to enqueue.
--- @param priority Optional explicit priority override for this item.
--- @return PriorityQueue<T, P> Enables chaining.
function PriorityQueue.push<T, P>(self: PriorityQueue<T, P>, item: T, priority: P?): PriorityQueue<T, P>
	return pushEntry(self, item, nextPriority(self, item, priority))
end

--[=[
	Removes and returns the next item by priority.

	Errors when the queue is empty.

	@return T The removed item.
]=]
function PriorityQueue.pop<T, P>(self: PriorityQueue<T, P>): T
	return popHeapEntry(self).item
end

--[=[
	Removes and returns the next `(item, priority)` entry.

	Errors when the queue is empty.

	@return PriorityQueueEntry<T, P> The removed entry.
]=]
function PriorityQueue.popEntry<T, P>(self: PriorityQueue<T, P>): PriorityQueueEntry<T, P>
	return publicEntry(popHeapEntry(self))
end

--[=[
	Returns the next item by priority without removing it.

	Errors when the queue is empty.

	@return T The next item.
]=]
function PriorityQueue.peek<T, P>(self: PriorityQueue<T, P>): T
	local first = self._heap[1]
	if first == nil then
		fail("priority queue is empty")
	end
	return first.item
end

--[=[
	Returns the next `(item, priority)` entry without removing it.

	Errors when the queue is empty.

	@return PriorityQueueEntry<T, P> The next entry.
]=]
function PriorityQueue.peekEntry<T, P>(self: PriorityQueue<T, P>): PriorityQueueEntry<T, P>
	local first = self._heap[1]
	if first == nil then
		fail("priority queue is empty")
	end
	return publicEntry(first)
end

--[=[
	Pushes a new item, then pops and returns the next item by priority.

	When the queue is empty, this returns the pushed item.

	@param item Value to enqueue.
	@param priority Optional explicit priority override for this item.
	@return T The item that was removed.
]=]
function PriorityQueue.pushPop<T, P>(self: PriorityQueue<T, P>, item: T, priority: P?): T
	local resolved = nextPriority(self, item, priority)
	if self.size == 0 then
		return item
	end

	local first = self._heap[1]
	local incoming = {
		item = item,
		priority = resolved,
		sequence = self._sequence + 1,
	}

	if entryBefore(self, incoming, first) then
		self._sequence += 1
		return item
	end

	self._sequence += 1
	self._heap[1] = incoming
	siftDown(self, 1)
	return first.item
end

--[=[
	Pops the current next item by priority, then inserts the replacement.
	This is the queue-shaped equivalent of Python's `heapreplace`.

	Errors when the queue is empty.

	@param item Replacement value to enqueue.
	@param priority Optional explicit priority override for the replacement.
	@return T The item that was removed.
]=]
function PriorityQueue.replace<T, P>(self: PriorityQueue<T, P>, item: T, priority: P?): T
	local resolved = nextPriority(self, item, priority)
	local first = self._heap[1]
	if first == nil then
		fail("priority queue is empty")
	end
	if item == nil then
		fail("priority queue items cannot be nil")
	end

	local sequence = self._sequence + 1
	self._sequence = sequence
	self._heap[1] = {
		item = item,
		priority = resolved,
		sequence = sequence,
	}
	siftDown(self, 1)
	return first.item
end

--- @return boolean `true` when the priority queue has no items.
function PriorityQueue.isEmpty<T, P>(self: PriorityQueue<T, P>): boolean
	return self.size == 0
end

--- Removes all items from the priority queue.
function PriorityQueue.clear<T, P>(self: PriorityQueue<T, P>): ()
	table.clear(self._heap)
	self.size = 0
end

--[=[
	Returns a shallow snapshot of items in internal heap layout.

	This result is not priority-sorted; it reflects heap structure only.

	@return { T } A shallow item snapshot in heap order.
]=]
function PriorityQueue.toHeapArray<T, P>(self: PriorityQueue<T, P>): { T }
	local out = table.create(#self._heap)
	for index, entry in self._heap do
		out[index] = entry.item
	end
	return out
end

--[=[
	Returns a shallow snapshot of entries in internal heap layout.

	This result is not priority-sorted; it reflects heap structure only.
	Hidden stability bookkeeping such as insertion sequence is not exposed.

	@return { PriorityQueueEntry<T, P> } A shallow entry snapshot in heap order.
]=]
function PriorityQueue.toHeapEntries<T, P>(self: PriorityQueue<T, P>): { PriorityQueueEntry<T, P> }
	local out: { PriorityQueueEntry<T, P> } = {}
	for index, entry in self._heap do
		out[index] = publicEntry(entry)
	end
	return out
end

--[=[
	Returns items in pop order without mutating the original queue.

	@return { T } A shallow item snapshot in priority-sorted order.
]=]
function PriorityQueue.toSortedArray<T, P>(self: PriorityQueue<T, P>): { T }
	local copy = self:clone()
	local out = table.create(copy.size)
	local index = 0
	while copy.size > 0 do
		index += 1
		out[index] = copy:pop()
	end
	return out
end

--[=[
	Returns entries in pop order without mutating the original queue.

	Hidden stability bookkeeping such as insertion sequence is not exposed.

	@return { PriorityQueueEntry<T, P> } A shallow entry snapshot in priority-sorted order.
]=]
function PriorityQueue.toSortedEntries<T, P>(self: PriorityQueue<T, P>): { PriorityQueueEntry<T, P> }
	local copy = self:clone()
	local out: { PriorityQueueEntry<T, P> } = {}
	local index = 0
	while copy.size > 0 do
		index += 1
		out[index] = copy:popEntry()
	end
	return out
end

--[=[
	Returns a shallow copy of this priority queue.

	When stability is enabled, cloned queues preserve insertion-order
	tiebreak behavior.

	@return PriorityQueue<T, P> A shallow copy of this priority queue.
]=]
function PriorityQueue.clone<T, P>(self: PriorityQueue<T, P>): PriorityQueue<T, P>
	local copy = makePriorityQueue({
		order = self._order,
		less = self._less,
		stable = self._stable,
		priority = self._priority,
	} :: PriorityQueueNewOptions<T, P>)
	local heap = table.create(#self._heap) :: { PriorityQueueHeapEntry<T, P> }
	for index, entry in self._heap do
		heap[index] = {
			item = entry.item,
			priority = entry.priority,
			sequence = entry.sequence,
		}
	end
	copy._heap = heap
	copy.size = #heap
	copy._sequence = self._sequence
	return copy
end

queue.Queue = table.freeze(Queue)
queue.Deque = table.freeze(Deque)
queue.PriorityQueue = table.freeze(PriorityQueue)

return table.freeze(queue)
