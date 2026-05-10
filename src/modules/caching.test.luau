local cache = require("@eryx/caching")
local test = require("@eryx/test")

local suite = test.Suite.new("cache")

suite:test("lru stores false and nil values without ambiguity", function()
	local c = cache.lru<<string, boolean?>>({ maxEntries = 4 })

	c:set("false", false)
	c:set("nil", nil)

	local falseValue, falseFound = c:get("false")
	test.expect(falseFound):toBeTrue()
	test.expect(falseValue):toBe(false)

	local nilValue, nilFound = c:get("nil")
	test.expect(nilFound):toBeTrue()
	test.expect(nilValue):toBeNil()
	test.expect(c:has("nil")):toBeTrue()
	test.expect(c:size()):toBe(2)
end)

suite:test("lru evicts the least recently used entry", function()
	local c = cache.lru<<string, number>>({ maxEntries = 2 })

	c:set("a", 1)
	c:set("b", 2)
	test.expect((c:get("a"))):toBe(1)

	c:set("c", 3)

	test.expect(c:has("a")):toBeTrue()
	test.expect(c:has("b")):toBeFalse()
	test.expect(c:has("c")):toBeTrue()
	test.expect(c:size()):toBe(2)
end)

suite:test("ttl cache expires entries lazily", function()
	local now = 100
	local c = cache.ttl<<string, string>>({
		ttl = 5,
		clock = function()
			return now
		end,
	})

	c:set("a", "value")
	test.expect((c:get("a"))):toBe("value")

	now = 104.9
	test.expect(c:has("a")):toBeTrue()

	now = 105
	local value, found = c:get("a")
	test.expect(found):toBeFalse()
	test.expect(value):toBeNil()
	test.expect(c:size()):toBe(0)
end)

suite:test("ttl touchOnGet extends expiry", function()
	local now = 0
	local c = cache.ttl<<string, number>>({
		ttl = 10,
		touchOnGet = true,
		clock = function()
			return now
		end,
	})

	c:set("a", 1)

	now = 9
	test.expect((c:get("a"))):toBe(1)

	now = 18
	test.expect(c:has("a")):toBeTrue()

	now = 18.9
	test.expect((c:get("a"))):toBe(1)

	now = 29
	local value, found = c:get("a")
	test.expect(found):toBeFalse()
	test.expect(value):toBeNil()
end)

suite:test("delete clear and nil keys behave consistently", function()
	local c = cache.lru<<string?, string | number>>({ maxEntries = 3 })

	c:set(nil, "nothing")
	test.expect(c:has(nil)):toBeTrue()
	test.expect((c:get(nil))):toBe("nothing")
	test.expect(c:delete(nil)):toBeTrue()
	test.expect(c:delete(nil)):toBeFalse()

	c:set("a", 1):set("b", 2)
	c:clear()
	test.expect(c:size()):toBe(0)
	test.expect(c:has("a")):toBeFalse()
	test.expect(c:has("b")):toBeFalse()
end)

suite:test("memoize reuses cached results and supports key functions", function()
	type Record = {
		left: number,
		right: number,
	}

	local calls = 0
	local options: cache.MemoizeOptions<string, number, Record> = {
		keyFn = function(record: Record): string
			return `{record.left}:{record.right}`
		end,
		maxEntries = 8,
	}
	local fn = cache.memoize(function(record: Record): number
		calls += 1
		return record.left + record.right
	end, options)

	test.expect(fn({ left = 2, right = 3 })):toBe(5)
	test.expect(fn({ left = 2, right = 3 })):toBe(5)
	test.expect(fn({ left = 1, right = 4 })):toBe(5)
	test.expect(calls):toBe(2)
end)

suite:test("memoize caches nil results", function()
	local calls = 0
	local options: cache.MemoizeOptions<string, string?, string> = { maxEntries = 4 }
	local fn = cache.memoize(function(value: string): string?
		calls += 1
		if value == "miss" then
			return nil
		end
		return string.upper(value)
	end, options)

	test.expect(fn("miss")):toBeNil()
	test.expect(fn("miss")):toBeNil()
	test.expect(fn("hit")):toBe("HIT")
	test.expect(fn("hit")):toBe("HIT")
	test.expect(calls):toBe(2)
end)

return suite
