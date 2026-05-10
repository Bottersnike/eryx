--[=[
	Small in-memory cache primitives.

	- bounded key/value caches
	- TTL-based expiration
	- memoization built on top of those caches

	Higher-level policy such as HTTP cache semantics should live in the
	consumer modules rather than here.
]=]

local NIL_VALUE = newproxy(false)
local NIL_KEY = newproxy(false)
local ZERO_ARG_KEY = newproxy(false)

local Cache = {}
Cache.__index = Cache

export type EvictReason = "expired" | "capacity" | "delete" | "clear" | "replace"
export type Clock = () -> number

export type CacheOptions<K, V> = {
	maxEntries: number?,
	ttl: number?,
	touchOnGet: boolean?,
	clock: Clock?,
	onEvict: ((key: K, value: V, reason: EvictReason) -> ())?,
}

type InternalKey<K> = K | typeof(NIL_KEY)
type PackedValue<V> = V | typeof(NIL_VALUE)

type Node<K, V> = {
	lookupKey: InternalKey<K>,
	publicKey: K,
	value: PackedValue<V>,
	expiresAt: number?,
	prev: Node<K, V>?,
	next: Node<K, V>?,
}

type CacheMethods<K, V> = {
	get: (self: Cache<K, V>, key: K) -> (V, boolean),
	set: (self: Cache<K, V>, key: K, value: V) -> Cache<K, V>,
	has: (self: Cache<K, V>, key: K) -> boolean,
	delete: (self: Cache<K, V>, key: K) -> boolean,
	clear: (self: Cache<K, V>) -> (),
	size: (self: Cache<K, V>) -> number,
	prune: (self: Cache<K, V>) -> number,
}

export type Cache<K, V> = CacheMethods<K, V>

type InternalCache<K, V> = CacheMethods<K, V> & {
	_entries: { [InternalKey<K>]: Node<K, V> },
	_head: Node<K, V>?,
	_tail: Node<K, V>?,
	_count: number,
	_maxEntries: number?,
	_ttl: number?,
	_touchOnGet: boolean,
	_clock: Clock,
	_onEvict: ((key: K, value: V, reason: EvictReason) -> ())?,
}

export type MemoizeOptions<K, V, T...> = {
	maxEntries: number?,
	ttl: number?,
	touchOnGet: boolean?,
	clock: Clock?,
	onEvict: ((key: K, value: V, reason: EvictReason) -> ())?,
	cache: Cache<K, V>?,
	keyFn: ((T...) -> K)?,
}

local caching = {}

local function fail(message: string): never
	error(message, 2)
end

local function packValue<V>(value: V): PackedValue<V>
	if value == nil then
		return NIL_VALUE :: typeof(NIL_VALUE)
	end
	return value
end

local function unpackValue<V>(value: PackedValue<V>): V
	if value == NIL_VALUE then
		return nil :: any
	end
	return value
end

local function normalizeKey<K>(key: K): InternalKey<K>
	if key == nil then
		return NIL_KEY :: typeof(NIL_KEY)
	end
	return key
end

local function unlinkNode<K, V>(self: InternalCache<K, V>, node: Node<K, V>)
	local prev = node.prev
	local next = node.next

	if prev ~= nil then
		prev.next = next
	else
		self._head = next
	end

	if next ~= nil then
		next.prev = prev
	else
		self._tail = prev
	end

	node.prev = nil
	node.next = nil
end

local function appendNode<K, V>(self: InternalCache<K, V>, node: Node<K, V>)
	node.prev = self._tail
	node.next = nil

	if self._tail ~= nil then
		self._tail.next = node
	else
		self._head = node
	end

	self._tail = node
end

local function touchNode<K, V>(self: InternalCache<K, V>, node: Node<K, V>)
	if self._tail == node then
		return
	end

	unlinkNode(self, node)
	appendNode(self, node)
end

local function isExpired<K, V>(node: Node<K, V>, now: number): boolean
	return node.expiresAt ~= nil and node.expiresAt <= now
end

local function evictNode<K, V>(self: InternalCache<K, V>, node: Node<K, V>, reason: EvictReason)
	unlinkNode(self, node)
	self._entries[node.lookupKey] = nil
	self._count -= 1

	if self._onEvict ~= nil then
		self._onEvict(node.publicKey, unpackValue(node.value), reason)
	end
end

local function pruneExpired<K, V>(self: InternalCache<K, V>, now: number?): number
	if self._ttl == nil then
		return 0
	end

	now = now or self._clock()
	local removed = 0

	for _, node in self._entries do
		if isExpired(node, now :: number) then
			evictNode(self, node, "expired")
			removed += 1
		end
	end

	return removed
end

local function ensureCapacity<K, V>(self: InternalCache<K, V>)
	local maxEntries = self._maxEntries
	if maxEntries == nil then
		return
	end

	while self._count > maxEntries do
		local oldest = self._head
		if oldest == nil then
			return
		end
		evictNode(self, oldest, "capacity")
	end
end

local function validateMaxEntries(maxEntries: number?): number?
	if maxEntries == nil then
		return nil
	end
	if type(maxEntries) ~= "number" or maxEntries < 0 or maxEntries % 1 ~= 0 then
		fail("cache maxEntries must be a non-negative integer")
	end
	return maxEntries
end

local function validateTtl(ttl: number?): number?
	if ttl == nil then
		return nil
	end
	if type(ttl) ~= "number" or ttl < 0 then
		fail("cache ttl must be a non-negative number")
	end
	return ttl
end

local function newCache<K, V>(options: CacheOptions<K, V>?): InternalCache<K, V>
	options = options or {} :: CacheOptions<K, V>

	local clock = options.clock
	if clock ~= nil and type(clock) ~= "function" then
		fail("cache clock must be a function")
	end
	if options.touchOnGet ~= nil and type(options.touchOnGet) ~= "boolean" then
		fail("cache touchOnGet must be a boolean")
	end
	if options.onEvict ~= nil and type(options.onEvict) ~= "function" then
		fail("cache onEvict must be a function")
	end

	return setmetatable({
		_entries = {},
		_head = nil,
		_tail = nil,
		_count = 0,
		_maxEntries = validateMaxEntries(options.maxEntries),
		_ttl = validateTtl(options.ttl),
		_touchOnGet = options.touchOnGet == true,
		_clock = clock or os.clock,
		_onEvict = options.onEvict,
	}, Cache) :: InternalCache<K, V>
end

function Cache.get<K, V>(self: InternalCache<K, V>, key: K): (V, boolean)
	local now = self._clock()
	pruneExpired(self, now)

	local node = self._entries[normalizeKey(key)]
	if node == nil then
		return nil :: any, false
	end

	touchNode(self, node)
	if self._touchOnGet and self._ttl ~= nil then
		node.expiresAt = now + self._ttl
	end

	return unpackValue(node.value), true
end

function Cache.set<K, V>(self: InternalCache<K, V>, key: K, value: V): Cache<K, V>
	local now = self._clock()
	pruneExpired(self, now)

	local lookupKey = normalizeKey(key)
	local node = self._entries[lookupKey]
	local expiresAt = if self._ttl ~= nil then now + self._ttl else nil

	if node ~= nil then
		node.value = packValue(value)
		node.expiresAt = expiresAt
		touchNode(self, node)
		return self
	end

	local newNode: Node<K, V> = {
		lookupKey = lookupKey,
		publicKey = key,
		value = packValue(value),
		expiresAt = expiresAt,
		prev = nil,
		next = nil,
	}

	self._entries[lookupKey] = newNode
	self._count += 1
	appendNode(self, newNode)
	ensureCapacity(self)

	return self
end

function Cache.has<K, V>(self: InternalCache<K, V>, key: K): boolean
	pruneExpired(self)
	return self._entries[normalizeKey(key)] ~= nil
end

function Cache.delete<K, V>(self: InternalCache<K, V>, key: K): boolean
	pruneExpired(self)

	local node = self._entries[normalizeKey(key)]
	if node == nil then
		return false
	end

	evictNode(self, node, "delete")
	return true
end

function Cache.clear<K, V>(self: InternalCache<K, V>)
	while self._head ~= nil do
		evictNode(self, self._head, "clear")
	end
end

function Cache.size<K, V>(self: InternalCache<K, V>): number
	pruneExpired(self)
	return self._count
end

function Cache.prune<K, V>(self: InternalCache<K, V>): number
	return pruneExpired(self)
end

function caching.lru<K, V>(options: CacheOptions<K, V>?): Cache<K, V>
	local opts: CacheOptions<K, V> = if options ~= nil then table.clone(options) else {}
	if opts.maxEntries == nil then
		opts.maxEntries = 128
	end
	return newCache(opts)
end

function caching.ttl<K, V>(options: CacheOptions<K, V>?): Cache<K, V>
	if options == nil or options.ttl == nil then
		fail("cache.ttl requires a ttl option")
	end
	return newCache(options)
end

local function defaultMemoKey(...: any): any
	local argc = select("#", ...)
	if argc == 0 then
		return ZERO_ARG_KEY
	end
	return select(1, ...)
end

function caching.memoize<K, V, T...>(
	fn: (T...) -> V,
	options: {
		maxEntries: number?,
		ttl: number?,
		touchOnGet: boolean?,
		clock: Clock?,
		onEvict: ((key: K, value: V, reason: EvictReason) -> ())?,
		cache: Cache<K, V>?,
		keyFn: ((T...) -> K)?,
	}?
): (T...) -> V
	if type(fn) ~= "function" then
		fail("cache.memoize requires a function")
	end

	options = options or {} :: MemoizeOptions<K, V, T...>
	local keyFn: (T...) -> K
	if options.keyFn ~= nil then
		keyFn = options.keyFn
	else
		keyFn = defaultMemoKey :: (T...) -> K
	end

	local store: Cache<K, V>
	if options.cache ~= nil then
		store = options.cache
	elseif options.ttl ~= nil then
		store = newCache(options)
	else
		local lruOptions: CacheOptions<K, V> = table.clone(options)
		if lruOptions.maxEntries == nil then
			lruOptions.maxEntries = 128
		end
		store = newCache(lruOptions)
	end

	return function(...: T...)
		local key = keyFn(...)
		local cachedValue, found = store:get(key)
		if found then
			return cachedValue
		end

		local value = fn(...)
		store:set(key, value)
		return value
	end
end

return table.freeze(caching)
