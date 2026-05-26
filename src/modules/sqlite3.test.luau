local test = require("@eryx/test")

local sqliteOk, sqlite3 = pcall(require, "@eryx/sqlite3")

local suite = test.Suite.new("sqlite3")

local function openMemory()
	test.skipIf(not sqliteOk, "sqlite3 unavailable")
	return sqlite3.open(":memory:")
end

suite:test("version returns a version string", function()
	test.skipIf(not sqliteOk, "sqlite3 unavailable")

	test.expect(sqlite3.version()):toMatch("^%d+%.%d+%.%d+")
end)

suite:test("database open close tostring and isOpen", function()
	local db = openMemory()

	test.expect(db:isOpen()):toBeTrue()
	test.expect(tostring(db)):toContain("SqliteDatabase")

	db:close()
	test.expect(db:isOpen()):toBeFalse()
	test.expect(tostring(db)):toBe("SqliteDatabase(closed)")

	db:close()
	test.expect(db:isOpen()):toBeFalse()
end)

suite:test("exec and query support parameters and row values", function()
	local db = openMemory()

	db:exec("CREATE TABLE values_test (id INTEGER PRIMARY KEY, name TEXT, amount REAL, data BLOB, missing TEXT)")
	db:exec(
		"INSERT INTO values_test (name, amount, data, missing) VALUES (?, ?, ?, ?)",
		"Ada",
		1.25,
		buffer.fromstring("blob"),
		nil
	)

	local rows = db:query("SELECT id, name, amount, data, missing FROM values_test WHERE name = ?", "Ada")
	test.expect(#rows):toBe(1)
	test.expect(rows[1].id):toBe(1)
	test.expect(rows[1].name):toBe("Ada")
	test.expect(rows[1].amount):toBe(1.25)
	test.expect(buffer.tostring(rows[1].data :: buffer)):toBe("blob")
	test.expect(rows[1].missing):toBeNil()
	test.expect(db:lastInsertId()):toBe(1)
	test.expect(db:changes()):toBe(1)

	db:close()
end)

suite:test("query returns all matching rows", function()
	local db = openMemory()

	db:exec("CREATE TABLE users (name TEXT, age INTEGER)")
	db:exec("INSERT INTO users VALUES ('Ada', 36)")
	db:exec("INSERT INTO users VALUES ('Grace', 85)")
	db:exec("INSERT INTO users VALUES ('Katherine', 101)")

	local rows = db:query("SELECT name FROM users WHERE age > ? ORDER BY name", 80)
	test.expect(#rows):toBe(2)
	test.expect(rows[1].name):toBe("Grace")
	test.expect(rows[2].name):toBe("Katherine")

	db:close()
end)

suite:test("prepare bind step reset and iterator yield rows", function()
	local db = openMemory()

	db:exec("CREATE TABLE users (name TEXT, age INTEGER)")
	db:exec("INSERT INTO users VALUES ('Ada', 36)")
	db:exec("INSERT INTO users VALUES ('Grace', 85)")

	local stmt = db:prepare("SELECT name FROM users WHERE age >= ? ORDER BY name")
	test.expect(tostring(stmt)):toContain("SqliteStatement")
	test.expect(stmt:bind(36)):toBe(stmt)

	local first = stmt:step()
	test.expect(first.name):toBe("Ada")
	local second = stmt:step()
	test.expect(second.name):toBe("Grace")
	test.expect(stmt:step()):toBeNil()

	test.expect(stmt:reset()):toBe(stmt)
	local names = {}
	for row in stmt do
		table.insert(names, row.name)
	end
	test.expect(table.concat(names, ",")):toBe("Ada,Grace")

	db:close()
end)

suite:test("statement all resets binds and returns rows", function()
	local db = openMemory()

	db:exec("CREATE TABLE users (name TEXT, age INTEGER)")
	db:exec("INSERT INTO users VALUES ('Ada', 36)")
	db:exec("INSERT INTO users VALUES ('Grace', 85)")
	db:exec("INSERT INTO users VALUES ('Katherine', 101)")

	local stmt = db:prepare("SELECT name FROM users WHERE age > ? ORDER BY age")
	local rows = stmt:all(80)
	test.expect(#rows):toBe(2)
	test.expect(rows[1].name):toBe("Grace")
	test.expect(rows[2].name):toBe("Katherine")

	local younger = stmt:all(90)
	test.expect(#younger):toBe(1)
	test.expect(younger[1].name):toBe("Katherine")

	db:close()
end)

suite:test("statement run resets binds and changes rows", function()
	local db = openMemory()

	db:exec("CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER)")
	local insert = db:prepare("INSERT INTO counters VALUES (?, ?)")
	insert:run("hits", 1)
	test.expect(db:changes()):toBe(1)

	local update = db:prepare("UPDATE counters SET value = value + ? WHERE name = ?")
	update:run(4, "hits")
	test.expect(db:query("SELECT value FROM counters WHERE name = 'hits'")[1].value):toBe(5)

	db:close()
end)

suite:test("transaction commits results and rolls back errors", function()
	local db = openMemory()

	db:exec("CREATE TABLE events (name TEXT)")
	local a, b = db:transaction(function(tx)
		tx:exec("INSERT INTO events VALUES ('commit')")
		return "ok", 2
	end)
	test.expect(a, b):toBe("ok", 2)
	test.expect(#db:query("SELECT name FROM events")):toBe(1)

	test.expect(function()
		db:transaction(function(tx)
			tx:exec("INSERT INTO events VALUES ('rollback')")
			error("boom")
		end)
	end):toError("boom")

	local rows = db:query("SELECT name FROM events ORDER BY name")
	test.expect(#rows):toBe(1)
	test.expect(rows[1].name):toBe("commit")

	db:close()
end)

suite:test("invalid SQL and closed handles throw", function()
	local db = openMemory()

	test.expect(function()
		db:exec("SELECT * FROM")
	end):toError("sqlite3 prepare error")

	db:close()

	test.expect(function()
		db:query("SELECT 1")
	end):toError("closed database")

	test.expect(function()
		db:prepare("SELECT 1")
	end):toError("closed database")
end)

return suite
