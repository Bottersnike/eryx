local fs = require("@eryx/fs")
local hex = require("@eryx/encoding/hex")
local json = require("@eryx/encoding/json")
local random = require("@eryx/crypto/random")
local sqlite3 = require("@eryx/sqlite3")

--[=[
	Server-side session helpers for [[http.App]].

	Provides middleware plus pluggable stores for:

	- in-memory sessions
	- filesystem-backed sessions
	- SQLite-backed sessions
	- user-provided store implementations
]=]
local ServerSession = {}

export type SessionRecord = {
	data: { [string]: any },
	expiresAt: number?,
}

export type SessionStore = {
	get: (self: SessionStore, id: string) -> SessionRecord?,
	set: (self: SessionStore, id: string, data: { [string]: any }, expiresAt: number?) -> (),
	delete: (self: SessionStore, id: string) -> (),
	touch: ((self: SessionStore, id: string, expiresAt: number?) -> ())?,
}

export type SessionCookieOptions = {
	path: string?,
	domain: string?,
	secure: boolean?,
	httpOnly: boolean?,
	sameSite: "Strict" | "Lax" | "None"?,
}

export type SessionOptions = {
	store: SessionStore?,
	cookieName: string?,
	ttl: number?,
	rolling: boolean?,
	cookie: SessionCookieOptions?,
}

export type Session = {
	id: string?,
	data: { [string]: any },
	isNew: boolean,
	destroyed: boolean,
	--- Returns a value from the session data table.
	get: (self: Session, key: string) -> any,
	--- Sets a value and marks the session dirty for persistence.
	set: (self: Session, key: string, value: any) -> (),
	--- Removes a value and marks the session dirty.
	delete: (self: Session, key: string) -> (),
	--- Clears all session data.
	clear: (self: Session) -> (),
	--- Assigns a fresh session id and preserves the current data.
	regenerate: (self: Session) -> string,
	--- Deletes the session from the backing store and clears the cookie.
	destroy: (self: Session) -> (),
}

type MemoryStore = SessionStore & {
	_data: { [string]: SessionRecord },
}

type FileStore = SessionStore & {
	_dir: string,
}

type SqliteStore = SessionStore & {
	_db: sqlite3.Database,
	_table: string,
}

local SessionMethods = {}
local SessionMetatable = {
	__index = SessionMethods,
}

local MemoryStoreMethods = {}
local MemoryStoreMetatable = {
	__index = MemoryStoreMethods,
}

local FileStoreMethods = {}
local FileStoreMetatable = {
	__index = FileStoreMethods,
}

local SqliteStoreMethods = {}
local SqliteStoreMetatable = {
	__index = SqliteStoreMethods,
}

local function generateSessionId(): string
	return hex.encode(random.bytes(24))
end

function SessionMethods.get(self: Session, key: string): any
	return self.data[key]
end

function SessionMethods.set(self: Session, key: string, value: any)
	if self.id == nil then
		self.id = generateSessionId()
		self.isNew = true
	end
	self.data[key] = value;
	(self :: any)._changed = true
end

function SessionMethods.delete(self: Session, key: string)
	if self.id == nil then
		return
	end
	self.data[key] = nil
	(self :: any)._changed = true
end

function SessionMethods.clear(self: Session)
	if self.id == nil then
		self.id = generateSessionId()
		self.isNew = true
	end
	for key in self.data do
		self.data[key] = nil
	end
	(self :: any)._changed = true
end

function SessionMethods.regenerate(self: Session): string
	local previousId = self.id
	self.id = generateSessionId()
	self.isNew = true
	(self :: any)._changed = true
	(self :: any)._previousId = previousId
	return self.id
end

function SessionMethods.destroy(self: Session)
	self.destroyed = true
	(self :: any)._changed = false
	(self :: any)._destroyedId = self.id
	for key in self.data do
		self.data[key] = nil
	end
	self.id = nil
end

local function newSession(record: SessionRecord?, sessionId: string?): Session
	return setmetatable({
		id = sessionId,
		data = if record ~= nil then table.clone(record.data) else {},
		isNew = record == nil,
		destroyed = false,
		_changed = false,
		_previousId = nil :: string?,
		_destroyedId = nil :: string?,
	}, SessionMetatable) :: any
end

function MemoryStoreMethods.get(self: MemoryStore, id: string): SessionRecord?
	local record = self._data[id]
	if record == nil then
		return nil
	end
	if record.expiresAt ~= nil and record.expiresAt <= os.time() then
		self._data[id] = nil
		return nil
	end
	return {
		data = table.clone(record.data),
		expiresAt = record.expiresAt,
	}
end

function MemoryStoreMethods.set(self: MemoryStore, id: string, data: { [string]: any }, expiresAt: number?)
	self._data[id] = {
		data = table.clone(data),
		expiresAt = expiresAt,
	}
end

function MemoryStoreMethods.delete(self: MemoryStore, id: string)
	self._data[id] = nil
end

function MemoryStoreMethods.touch(self: MemoryStore, id: string, expiresAt: number?)
	local record = self._data[id]
	if record ~= nil then
		record.expiresAt = expiresAt
	end
end

function FileStoreMethods._pathFor(self: FileStore, id: string): string
	return fs.path.join(self._dir, id .. ".json")
end

function FileStoreMethods.get(self: FileStore, id: string): SessionRecord?
	local path = self:_pathFor(id)
	if not fs.isFile(path) then
		return nil
	end

	local file = fs.openSync(path, "r")
	local body = file:readSync()
	file:closeSync()
	local decoded = json.decode(body)
	if decoded.expiresAt ~= nil and decoded.expiresAt <= os.time() then
		pcall(fs.remove, path)
		return nil
	end
	return {
		data = decoded.data or {},
		expiresAt = decoded.expiresAt,
	}
end

function FileStoreMethods.set(self: FileStore, id: string, data: { [string]: any }, expiresAt: number?)
	fs.mkdir(self._dir)
	local path = self:_pathFor(id)
	local file = fs.openSync(path, "w")
	file:writeSync(json.encode({
		data = data,
		expiresAt = expiresAt,
	}))
	file:closeSync()
end

function FileStoreMethods.delete(self: FileStore, id: string)
	local path = self:_pathFor(id)
	if fs.exists(path) then
		pcall(fs.remove, path)
	end
end

function FileStoreMethods.touch(self: FileStore, id: string, expiresAt: number?)
	local existing = self:get(id)
	if existing ~= nil then
		self:set(id, existing.data, expiresAt)
	end
end

local function ensureSqliteSchema(db: sqlite3.Database, tableName: string)
	db:exec(
		"CREATE TABLE IF NOT EXISTS "
			.. tableName
			.. " (id TEXT PRIMARY KEY, payload TEXT NOT NULL, expires_at INTEGER)"
	)
end

function SqliteStoreMethods.get(self: SqliteStore, id: string): SessionRecord?
	local rows = self._db:query(`SELECT payload, expires_at FROM {self._table} WHERE id = ?`, id)
	local row = rows[1]
	if row == nil then
		return nil
	end
	local expiresAt = row.expires_at :: number?
	if expiresAt ~= nil and expiresAt <= os.time() then
		self:delete(id)
		return nil
	end
	return {
		data = json.decode(row.payload :: string),
		expiresAt = expiresAt,
	}
end

function SqliteStoreMethods.set(self: SqliteStore, id: string, data: { [string]: any }, expiresAt: number?)
	self._db:exec(
		"INSERT INTO "
			.. self._table
			.. " (id, payload, expires_at) VALUES (?, ?, ?) "
			.. "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, expires_at = excluded.expires_at",
		id,
		json.encode(data),
		expiresAt
	)
end

function SqliteStoreMethods.delete(self: SqliteStore, id: string)
	self._db:exec("DELETE FROM " .. self._table .. " WHERE id = ?", id)
end

function SqliteStoreMethods.touch(self: SqliteStore, id: string, expiresAt: number?)
	self._db:exec("UPDATE " .. self._table .. " SET expires_at = ? WHERE id = ?", expiresAt, id)
end

--[=[
	Creates an in-memory session store.

	@return SessionStore
]=]
function ServerSession.memoryStore(): SessionStore
	return setmetatable({
		_data = {},
	}, MemoryStoreMetatable) :: any
end

--[=[
	Creates a filesystem-backed session store where each session is stored as JSON.

	@param directory Directory used for session files.
	@return SessionStore
]=]
function ServerSession.fileStore(directory: string): SessionStore
	local dir = if fs.exists(directory) then fs.path.canonicalize(directory) else directory
	return setmetatable({
		_dir = dir,
	}, FileStoreMetatable) :: any
end

--[=[
	Creates an SQLite-backed session store.

	@param database Either a path string or an open `@eryx/sqlite3` database.
	@param tableName Optional table name. Defaults to `"http_sessions"`.
	@return SessionStore
]=]
function ServerSession.sqliteStore(database: string | sqlite3.Database, tableName: string?): SessionStore
	local db = if type(database) == "string" then sqlite3.open(database) else database
	local name = tableName or "http_sessions"
	ensureSqliteSchema(db, name)
	return setmetatable({
		_db = db,
		_table = name,
	}, SqliteStoreMetatable) :: any
end

local function mergedCookieOptions(options: SessionOptions, expiresAt: number?): { [string]: any }
	local cookie = if options.cookie ~= nil then table.clone(options.cookie :: any) else {}
	if cookie.path == nil then
		cookie.path = "/"
	end
	if cookie.httpOnly == nil then
		cookie.httpOnly = true
	end
	if cookie.sameSite == nil then
		cookie.sameSite = "Lax"
	end
	if expiresAt ~= nil then
		cookie.expires = expiresAt
		cookie.maxAge = math.max(0, expiresAt - os.time())
	end
	return cookie
end

--[=[
	Creates app middleware that attaches a server-side session to `ctx.session`.

	The middleware loads the session from a cookie before the handler runs and
	persists it back to the configured store after the handler completes.

	@param options Session configuration and backing store.
	@return (ctx: any, next: () -> any) -> any
]=]
function ServerSession.middleware(options: SessionOptions?): (ctx: any, next: () -> any) -> any
	local opts = options or {}
	local store = opts.store or ServerSession.memoryStore()
	local cookieName = opts.cookieName or "session_id"
	local ttl = if opts.ttl ~= nil then opts.ttl else 7 * 24 * 60 * 60
	local rolling = if opts.rolling == true then true else false

	return function(ctx, next)
		local sessionId = ctx:cookie(cookieName)
		local record = if sessionId ~= nil then store:get(sessionId) else nil
		local session = newSession(record, if record ~= nil then sessionId else nil)
		ctx.session = session

		local result = table.pack(next())
		local now = os.time()

		if session.destroyed then
			local doomedId = (session :: any)._destroyedId
			if doomedId ~= nil then
				store:delete(doomedId)
			end
			ctx:clearCookie(cookieName, mergedCookieOptions(opts, 0))
			return table.unpack(result, 1, result.n)
		end

		local previousId = (session :: any)._previousId
		if previousId ~= nil and previousId ~= session.id then
			store:delete(previousId)
		end

		if session.id ~= nil then
			local expiresAt = if ttl ~= nil then now + ttl else nil
			local changed = (session :: any)._changed == true
			if changed or rolling then
				store:set(session.id, session.data, expiresAt)
				ctx:setCookie(cookieName, session.id, mergedCookieOptions(opts, expiresAt))
			elseif expiresAt ~= nil and store.touch ~= nil then
				(store.touch :: any)(store, session.id, expiresAt)
			end
		end

		return table.unpack(result, 1, result.n)
	end
end

return table.freeze(ServerSession)
