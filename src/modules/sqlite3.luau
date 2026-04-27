--[=[
SQLite3 module – embedded relational database.

Wraps the SQLite3 C library to provide full SQL database access from Luau.

## Availability
This module is a typed facade over an optional native backend. In builds
without SQLite support, `require("@eryx/sqlite3")` fails immediately
with a clear capability error.

## Quick start
```luau
local sqlite3 = require("@eryx/sqlite3")
local db = sqlite3.open(":memory:")
db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
db:exec("INSERT INTO users VALUES (1, 'Alice', 30)")

local rows = db:query("SELECT * FROM users WHERE age > ?", 25)
for _, row in rows do
    print(row.name, row.age)
end

-- Prepared statements for repeated queries
local stmt = db:prepare("INSERT INTO users VALUES (?, ?, ?)")
stmt:run(2, "Bob", 25)
stmt:run(3, "Charlie", 35)

-- Transactions: all-or-nothing batch operations
db:transaction(function(db)
    db:exec("INSERT INTO users VALUES (?, ?, ?)", 4, "Diana", 28)
    db:exec("INSERT INTO users VALUES (?, ?, ?)", 5, "Eve", 32)
end)

db:close()
```
]=]

local capability = require("@eryx/capability")
local path = require("@eryx/path")
local sqlite3 = {}

type PathLike = path.PathLike

--- A row returned from a query. Keys are column names, values are the
--- corresponding column values (number, string, buffer, or nil).
export type Row = { [string]: number | string | buffer | boolean | nil }

--[=[
	A prepared SQL statement.

	Statements are compiled once and can be executed multiple times with
	different parameters. They are automatically finalized by the garbage
	collector.
]=]
export type Statement = setmetatable<
	{
		--- Resets the statement and binds new parameters (positional).
		--- Returns the statement for chaining.
		bind: (self: Statement, ...any) -> Statement,

		--- Fetches the next result row, or `nil` when no more rows remain.
		step: (self: Statement) -> Row?,

		--- Resets the statement so it can be stepped again from the
		--- beginning (without changing bindings).
		reset: (self: Statement) -> Statement,

		--- Convenience: resets, binds parameters, and returns all result
		--- rows as an array of [[Row]] tables.
		all: (self: Statement, ...any) -> { Row },

		--- Convenience: resets, binds parameters, and executes the
		--- statement discarding any results.  Use for INSERT/UPDATE/DELETE.
		run: (self: Statement, ...any) -> (),
	},
	{
		__tostring: (self: Statement) -> string,
	}
>

--[=[
	An open SQLite database connection.

	The connection holds a file lock (or memory) and should be closed when
	no longer needed. It is also closed automatically by the garbage
	collector, but explicit `Close()` is recommended to release the file
	lock promptly.
]=]
export type Database = setmetatable<
	{
		--[=[
		Executes one or more SQL statements that return no results
		(DDL, INSERT, UPDATE, DELETE, etc.).  Multiple statements
		separated by `;` are supported.
		]=]
		exec: (self: Database, sql: string, ...any) -> (),

		--[=[
		Executes a SQL query with optional positional parameters and
		returns all result rows as an array of [[Row]] tables.
		]=]
		query: (self: Database, sql: string, ...any) -> { Row },

		--- Compiles a SQL string into a reusable prepared [[Statement]].
		prepare: (self: Database, sql: string) -> Statement,

		--- Explicitly closes the database connection.  Safe to call multiple times.
		close: (self: Database) -> (),

		--- Returns `true` if the database connection is still open.
		isOpen: (self: Database) -> boolean,

		--- Returns the rowid of the last successful INSERT.
		lastInsertId: (self: Database) -> number,

		--- Returns the number of rows changed by the last INSERT, UPDATE, or DELETE statement.
		changes: (self: Database) -> number,

		--[=[
		Wraps a function in a SQL transaction (BEGIN/COMMIT).

		If `fn` succeeds, the transaction is committed and its return
		values are forwarded.  If `fn` throws, the transaction is rolled
		back and the error is re-raised.

		```luau
		db:transaction(function(db)
		    db:exec("INSERT INTO users VALUES (?, ?)", 1, "Alice")
		    db:exec("INSERT INTO users VALUES (?, ?)", 2, "Bob")
		end)
		```
		]=]
		transaction: <T...>(self: Database, fn: (db: Database) -> T...) -> T...,
	},
	{
		__tostring: (self: Database) -> string,
	}
>

-- ── Constructors ──────────────────────────────────────────────────────────────

--[=[
	Opens (or creates) a SQLite database at the given path.
	Use `":memory:"` for an in-memory database.
	@error Throws if the database cannot be opened.
]=]
function sqlite3.open(path: PathLike): Database
	return nil :: any
end

--- Returns the SQLite library version string (e.g. `"3.52.0"`).
function sqlite3.version(): string
	return nil :: any
end

return capability.require(
	"@eryx/_native/sqlite3",
	"SQLite database support",
	"Enable sqlite support to use @eryx/sqlite3."
) :: typeof(sqlite3)
