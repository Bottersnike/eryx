local CookieJar = require("./CookieJar")
local HttpConnection = require("./HttpConnection")
local request = require("./request")
local os = require("@eryx/os")
local util = require("./util")

--[=[
	A pooled HTTP client session.

	Sessions reuse keep-alive connections per origin, share a cookie jar
	across requests by default, and support both buffered and streamed
	requests.
]=]
local Session = {}
Session.__index = Session

type PoolEntry = {
	conn: HttpConnection.HttpConnection,
	lastUsed: number,
}

type SessionFields = {
	_pool: { [string]: { PoolEntry } },
	_cookies: CookieJar.CookieJar,
	_timeout: number?,
	_connectTimeout: number?,
	_readTimeout: number?,
	_writeTimeout: number?,
	_verifySsl: boolean?,
	_maxRedirects: number?,
	_decompress: boolean?,
	_idleTimeout: number?,
	_maxConnectionsPerHost: number,
}

export type Session = typeof(setmetatable({} :: SessionFields, Session))

--[=[
	Options for creating a [[Session]].
]=]
export type SessionOptions = {
	--- Applies one timeout to connect, read, and write phases when the
	--- more specific timeout fields are omitted.
	timeout: number?,
	--- Default timeout used while opening new pooled connections.
	connectTimeout: number?,
	--- Default timeout used while waiting for response bytes.
	readTimeout: number?,
	--- Default timeout used while sending request bytes.
	writeTimeout: number?,
	verifySsl: boolean?,
	maxRedirects: number?,
	decompress: boolean?,
	idleTimeout: number?,
	--- Maximum number of pooled connections per scheme/host/port.
	maxConnectionsPerHost: number?,
	--- Shared cookie jar used when requests do not override it.
	cookies: CookieJar.CookieJar?,
}

local function poolKey(parsedUrl: { scheme: string, host: string, port: number }): string
	return `{parsedUrl.scheme}://{parsedUrl.host}:{parsedUrl.port}`
end

local function isRetryableMethod(method: string): boolean
	local upper = string.upper(method)
	return upper == "GET" or upper == "HEAD" or upper == "OPTIONS"
end

local function isRetryableError(err: any): boolean
	local message = if typeof(err) == "Exception" then (err :: any).message else tostring(err)
	return string.find(message, "Connection closed before receiving HTTP response", 1, true) ~= nil
end

--[=[
	Creates a new pooled HTTP client session.

	@param options Session-wide defaults for requests and pooling.
	@return Session -- The new session.
]=]
function Session.new(options: SessionOptions?): Session
	local opts = options or {}
	return setmetatable({
		_pool = {},
		_cookies = opts.cookies or CookieJar.new(),
		_timeout = opts.timeout,
		_connectTimeout = opts.connectTimeout,
		_readTimeout = opts.readTimeout,
		_writeTimeout = opts.writeTimeout,
		_verifySsl = opts.verifySsl,
		_maxRedirects = opts.maxRedirects,
		_decompress = opts.decompress,
		_idleTimeout = opts.idleTimeout,
		_maxConnectionsPerHost = opts.maxConnectionsPerHost or 2,
	}, Session)
end

local function touchEntry(entry: PoolEntry)
	entry.lastUsed = os.clock()
end

function Session._prunePoolEntries(self: Session, key: string): { PoolEntry }
	local entries = self._pool[key]
	if entries == nil then
		return {}
	end

	local kept = {}
	local now = os.clock()
	for _, entry in entries do
		local activeStream = entry.conn._activeResponseStream
		local isBusy = activeStream ~= nil and not activeStream._closed
		local isExpired = self._idleTimeout ~= nil
			and not isBusy
			and (now - entry.lastUsed) > (self._idleTimeout :: number)
		if isExpired then
			entry.conn:close()
		else
			table.insert(kept, entry)
		end
	end

	if #kept == 0 then
		self._pool[key] = nil
	else
		self._pool[key] = kept
	end
	return kept
end

function Session._getConnection(
	self: Session,
	parsedUrl: { scheme: string, host: string, port: number },
	timeouts: HttpConnection.TimeoutOptions?,
	verifySsl: boolean?
): HttpConnection.HttpConnection
	local key = poolKey(parsedUrl)
	local entries = self:_prunePoolEntries(key)

	local bestIdle: PoolEntry? = nil
	for _, entry in entries do
		local activeStream = entry.conn._activeResponseStream
		if activeStream == nil or activeStream._closed then
			if bestIdle == nil or entry.lastUsed > (bestIdle :: PoolEntry).lastUsed then
				bestIdle = entry
			end
		end
	end

	if bestIdle ~= nil then
		(bestIdle :: PoolEntry).conn:setTimeouts(timeouts)
		touchEntry(bestIdle :: PoolEntry)
		return (bestIdle :: PoolEntry).conn
	end

	if #entries < self._maxConnectionsPerHost then
		local entry = {
			conn = HttpConnection.new(
				parsedUrl.host,
				parsedUrl.port,
				timeouts,
				parsedUrl.scheme,
				if verifySsl ~= nil then verifySsl else self._verifySsl
			),
			lastUsed = os.clock(),
		}
		table.insert(entries, entry)
		self._pool[key] = entries
		return entry.conn
	end

	error(`No available pooled HTTP connections for {key}`)
end

function Session._discardConnection(
	self: Session,
	parsedUrl: { scheme: string, host: string, port: number },
	targetConn: HttpConnection.HttpConnection?
)
	local key = poolKey(parsedUrl)
	local entries = self._pool[key]
	if entries == nil then
		return
	end

	local kept = {}
	for _, entry in entries do
		if targetConn == nil or entry.conn == targetConn then
			entry.conn:close()
		else
			table.insert(kept, entry)
		end
	end

	if #kept == 0 then
		self._pool[key] = nil
	else
		self._pool[key] = kept
	end
end

--[=[
	Evicts pooled connections from the session.

	When `url` is provided, only the pool entry for that origin is
	removed. When omitted, all pooled connections are closed.

	@param url Optional URL whose origin should be evicted.
]=]
function Session.evict(self: Session, url: string?)
	if url == nil then
		self:close()
		return
	end

	local parsedUrl = util.parseUrl(url)
	self:_discardConnection(parsedUrl)
end

function Session._resolveOptions(self: Session, options: request.RequestOptions?): request.RequestOptions
	local opts = if options then table.clone(options :: any) else {} :: request.RequestOptions
	if opts.cookies == nil then
		opts.cookies = self._cookies
	end
	if opts.timeout == nil then
		opts.timeout = self._timeout
	end
	if opts.connectTimeout == nil then
		opts.connectTimeout = self._connectTimeout
	end
	if opts.readTimeout == nil then
		opts.readTimeout = self._readTimeout
	end
	if opts.writeTimeout == nil then
		opts.writeTimeout = self._writeTimeout
	end
	if opts.verifySsl == nil then
		opts.verifySsl = self._verifySsl
	end
	if opts.maxRedirects == nil then
		opts.maxRedirects = self._maxRedirects
	end
	if opts.decompress == nil then
		opts.decompress = self._decompress
	end
	opts.headers = if opts.headers then table.clone(opts.headers) else {}
	if opts.headers["Connection"] == nil and opts.headers["connection"] == nil then
		opts.headers["Connection"] = "keep-alive"
	end
	return opts
end

--[=[
	Makes a buffered HTTP request using the session's pooled connections.

	Safe requests may be retried once when a reused keep-alive socket has
	gone stale before any response is received.

	@param method The HTTP method.
	@param url The absolute URL to request.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response.
]=]
function Session.request(
	self: Session,
	method: string,
	url: string,
	options: request.RequestOptions?
): HttpConnection.HttpResponse
	local opts = self:_resolveOptions(options)
	local parsedUrl = util.parseUrl(util.appendQuery(url, opts.query))

	local function execute()
		return (request :: any)._execute(method, url, opts, function(nextParsedUrl)
			return self:_getConnection(nextParsedUrl, {
				connect = if opts.connectTimeout ~= nil then opts.connectTimeout else opts.timeout,
				read = if opts.readTimeout ~= nil then opts.readTimeout else opts.timeout,
				write = if opts.writeTimeout ~= nil then opts.writeTimeout else opts.timeout,
			}, opts.verifySsl)
		end, false)
	end

	local ok, result = pcall(execute)
	if ok then
		return result :: HttpConnection.HttpResponse
	end

	if isRetryableMethod(method) and opts.body == nil and opts.bodyStream == nil and isRetryableError(result) then
		self:_discardConnection(parsedUrl)
		return execute()
	end

	error(result :: any)
end

--[=[
	Makes a streamed HTTP request using the session's pooled connections.

	The returned response must be fully consumed or explicitly closed
	before its connection can be reused.

	@param method The HTTP method.
	@param url The absolute URL to request.
	@param options Optional per-request overrides.
	@return HttpResponseStream -- The streamed response.
]=]
function Session.stream(
	self: Session,
	method: string,
	url: string,
	options: request.RequestOptions?
): HttpConnection.HttpResponseStream
	local opts = self:_resolveOptions(options)
	local parsedUrl = util.parseUrl(util.appendQuery(url, opts.query))

	local function execute()
		return (request :: any)._executeStream(method, url, opts, function(nextParsedUrl)
			return self:_getConnection(nextParsedUrl, {
				connect = if opts.connectTimeout ~= nil then opts.connectTimeout else opts.timeout,
				read = if opts.readTimeout ~= nil then opts.readTimeout else opts.timeout,
				write = if opts.writeTimeout ~= nil then opts.writeTimeout else opts.timeout,
			}, opts.verifySsl)
		end, false)
	end

	local ok, result = pcall(execute)
	if ok then
		return result :: HttpConnection.HttpResponseStream
	end

	if isRetryableMethod(method) and opts.body == nil and opts.bodyStream == nil and isRetryableError(result) then
		self:_discardConnection(parsedUrl)
		return execute()
	end

	error(result :: any)
end

--[=[
	Convenience wrapper for `GET`.

	@param url The absolute URL to request.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response.
]=]
function Session.get(self: Session, url: string, options: request.RequestOptions?): HttpConnection.HttpResponse
	return self:request("GET", url, options)
end

--[=[
	Convenience wrapper for `POST`.

	@param url The absolute URL to request.
	@param body Optional raw request body.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response.
]=]
function Session.post(
	self: Session,
	url: string,
	body: string?,
	options: request.RequestOptions?
): HttpConnection.HttpResponse
	local opts = if options then table.clone(options :: any) else {} :: request.RequestOptions
	opts.body = body or opts.body
	return self:request("POST", url, opts)
end

--[=[
	Convenience wrapper for `PUT`.

	@param url The absolute URL to request.
	@param body Optional raw request body.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response.
]=]
function Session.put(
	self: Session,
	url: string,
	body: string?,
	options: request.RequestOptions?
): HttpConnection.HttpResponse
	local opts = if options then table.clone(options :: any) else {} :: request.RequestOptions
	opts.body = body or opts.body
	return self:request("PUT", url, opts)
end

--[=[
	Convenience wrapper for `DELETE`.

	@param url The absolute URL to request.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response.
]=]
function Session.delete(self: Session, url: string, options: request.RequestOptions?): HttpConnection.HttpResponse
	return self:request("DELETE", url, options)
end

--[=[
	Convenience wrapper for `HEAD`.

	@param url The absolute URL to request.
	@param options Optional per-request overrides.
	@return HttpResponse -- The buffered response (body is empty).
]=]
function Session.head(self: Session, url: string, options: request.RequestOptions?): HttpConnection.HttpResponse
	return self:request("HEAD", url, options)
end

--[=[
	Closes every pooled connection and empties the session pool.
]=]
function Session.close(self: Session)
	for key, entries in self._pool do
		for _, entry in entries do
			entry.conn:close()
		end
		self._pool[key] = nil
	end
end

return table.freeze(Session)
