--[=[
SQLite3 module – embedded relational database.

Wraps the SQLite3 C library to provide full SQL database access from Luau.

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

db:close()
```
]=]

local sqlite3 = {}

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
		bun: (self: Statement, ...any) -> (),
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
function sqlite3.open(path: string): Database
	return nil :: any
end

--- Returns the SQLite library version string (e.g. `"3.52.0"`).
function sqlite3.version(): string
	return nil :: any
end

return table.freeze(sqlite3)
