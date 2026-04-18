local HttpServer = require("./HttpServer")
local ServerResponse = require("./ServerResponse")
local fs = require("@eryx/fs")
local json = require("@eryx/encoding/json")
local mime = require("@eryx/mime")
local urlEncoding = require("@eryx/encoding/url")
local util = require("./util")

type QueryTable = { [string]: string | { string } }
type Headers = { [string]: string }
type Params = { [string]: string }

type Route = {
	method: string,
	path: string,
	segments: { Segment },
	handler: RouteHandler,
	name: string?,
	middleware: { Middleware }?,
	websocketHandler: WebSocketHandler?,
	websocketOptions: any?,
}

type Mount = {
	prefix: string,
	app: App,
}

type MatchResult = {
	route: Route?,
	params: Params,
	pathMatched: boolean,
	allowedMethods: { string },
}

type Segment = {
	kind: "static" | "param" | "splat",
	value: string,
}

export type ResponseSpec = {
	status: number?,
	headers: Headers?,
	contentType: string?,
	body: any?,
	text: string?,
	html: string?,
	json: any?,
	location: string?,
}

--[=[
	Optional metadata for route registration helpers like [[App.get]].
]=]
export type RouteOptions = {
	name: string?,
	--- Route-local middleware that runs inside app/group middleware but before the handler.
	middleware: { Middleware }?,
	--- WebSocket upgrade options, used by [[App.websocket]].
	websocket: any?,
}

--[=[
	Options for [[App.static]].
]=]
export type StaticOptions = {
	indexFile: string?,
	fallthrough: boolean?,
	headers: Headers?,
}

--[=[
	Options for [[AppContext.sendFile]].
]=]
export type SendFileOptions = {
	contentType: string?,
	filename: string?,
	headers: Headers?,
	status: number?,
}

--[=[
	Options for setting response cookies from the app layer.
]=]
export type CookieOptions = {
	path: string?,
	domain: string?,
	expires: number?,
	maxAge: number?,
	secure: boolean?,
	httpOnly: boolean?,
	sameSite: "Strict" | "Lax" | "None"?,
}

export type AppContext = {
	app: App,
	request: HttpServer.ServerRequest,
	response: ServerResponse.ServerResponse,
	params: Params,
	query: QueryTable,
	--- Parsed request cookies from the `Cookie` header.
	cookies: { [string]: string | { string } },
	session: any?,
	state: { [string]: any },
	route: { method: string, path: string }?,
	mountPath: string?,
	pathWithinMount: string,
	originalPath: string,
	errorStatus: number?,
	errorData: { [string]: any }?,
	json: (self: AppContext) -> any,
	form: (self: AppContext) -> QueryTable?,
	multipart: (self: AppContext) -> { any }?,
	--- Returns the first parsed request cookie value by name.
	cookie: (self: AppContext, name: string) -> string?,
	send: (self: AppContext, status: number, body: string?, headers: Headers?) -> (),
	text: (self: AppContext, body: string, status: number?, headers: Headers?) -> (),
	html: (self: AppContext, body: string, status: number?, headers: Headers?) -> (),
	jsonResponse: (self: AppContext, data: any, status: number?, headers: Headers?) -> (),
	redirect: (self: AppContext, location: string, status: number?, headers: Headers?) -> (),
	--- Appends a `Set-Cookie` response header.
	setCookie: (self: AppContext, name: string, value: string, options: CookieOptions?) -> (),
	--- Clears a cookie with an expired `Set-Cookie` response header.
	clearCookie: (self: AppContext, name: string, options: CookieOptions?) -> (),
	--- Streams a file as the response body.
	sendFile: (self: AppContext, path: string, options: SendFileOptions?) -> (),
}

export type RouteHandler = (ctx: AppContext) -> any
export type Middleware = (ctx: AppContext, next: () -> any) -> any
export type ExceptionHandler = (ctx: AppContext, err: any) -> any
export type WebSocketHandler = (ctx: AppContext, ws: any) -> any

local App = {}
App.__index = App

type AppFields = {
	_routes: { Route },
	_mounts: { Mount },
	_middleware: { Middleware },
	_statusHandlers: { [number]: RouteHandler },
	_exceptionHandler: ExceptionHandler?,
	_serverOptions: HttpServer.HttpServerOptions?,
	_server: HttpServer.HttpServer?,
	state: { [string]: any },
}

export type App = typeof(setmetatable({} :: AppFields, App))

local AppContextMethods = {}
local AppContextMetatable = {
	__index = function(self, key)
		local method = (AppContextMethods :: any)[key]
		if method ~= nil then
			return method
		end
		return nil
	end,
}

local function normalizeMethod(method: string): string
	return string.upper(method)
end

local function splitPath(path: string): { string }
	if path == "" or path == "/" then
		return {}
	end

	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

local function normalizePrefix(prefix: string): string
	assert(prefix ~= "", "Mount prefixes cannot be empty")
	assert(string.sub(prefix, 1, 1) == "/", "Mount prefixes must start with '/'")
	if prefix ~= "/" and string.sub(prefix, -1) == "/" then
		return string.sub(prefix, 1, -2)
	end
	return prefix
end

local function startsWithPath(path: string, prefix: string): boolean
	path = string.gsub(path, "\\", "/")
	prefix = string.gsub(prefix, "\\", "/")
	if prefix == path then
		return true
	end
	if prefix == "/" then
		return true
	end
	return string.sub(path, 1, #prefix + 1) == prefix .. "/"
end

local function joinPaths(prefix: string, path: string): string
	local normalizedPrefix = normalizePrefix(prefix)
	if normalizedPrefix == "/" then
		return path
	end
	if path == "/" then
		return normalizedPrefix
	end
	return normalizedPrefix .. path
end

local function splitMountedPath(prefix: string, pathname: string): string?
	local normalizedPrefix = normalizePrefix(prefix)
	if normalizedPrefix == "/" then
		return pathname
	end
	if pathname == normalizedPrefix then
		return "/"
	end
	local candidatePrefix = normalizedPrefix .. "/"
	if string.sub(pathname, 1, #candidatePrefix) == candidatePrefix then
		return string.sub(pathname, #normalizedPrefix + 1)
	end
	return nil
end

local function compilePath(path: string): { Segment }
	assert(string.sub(path, 1, 1) == "/", "Route paths must start with '/'")

	local parts = splitPath(path)
	local segments = {}
	for index, part in parts do
		if string.sub(part, 1, 1) == ":" then
			local name = string.sub(part, 2)
			assert(name ~= "", "Named parameters cannot be empty")
			table.insert(segments, {
				kind = "param",
				value = name,
			})
		elseif string.sub(part, 1, 1) == "*" then
			assert(index == #parts, "Splat parameters must be the final segment")
			local name = string.sub(part, 2)
			table.insert(segments, {
				kind = "splat",
				value = if name ~= "" then name else "splat",
			})
		else
			table.insert(segments, {
				kind = "static",
				value = part,
			})
		end
	end

	return segments
end

local function matchesMethod(routeMethod: string, requestMethod: string): boolean
	return routeMethod == "ANY" or routeMethod == requestMethod or (requestMethod == "HEAD" and routeMethod == "GET")
end

local function routeMatches(route: Route, pathname: string): Params?
	local parts = splitPath(pathname)
	local params: Params = {}
	local routeSegments = route.segments
	local pathIndex = 1

	for routeIndex, segment in routeSegments do
		local part = parts[pathIndex]
		if segment.kind == "splat" then
			local remaining = {}
			for i = pathIndex, #parts do
				table.insert(remaining, parts[i])
			end
			params[segment.value] = urlEncoding.decode(table.concat(remaining, "/"), false)
			return params
		end

		if part == nil then
			return nil
		end

		if segment.kind == "static" then
			if part ~= segment.value then
				return nil
			end
		else
			params[segment.value] = urlEncoding.decode(part, false)
		end

		pathIndex = routeIndex + 1
	end

	if pathIndex <= #parts then
		return nil
	end

	return params
end

local function encodePathParam(value: any): string
	return urlEncoding.encode(tostring(value), false)
end

local function appendSetCookieHeader(response: ServerResponse.ServerResponse, value: string)
	local existing = response._headers["set-cookie"]
	if existing ~= nil and existing ~= "" then
		response:header("set-cookie", existing .. "\n" .. value)
	else
		response:header("set-cookie", value)
	end
end

local function formatHttpDate(timestamp: number): string
	return os.date("!%a, %d %b %Y %H:%M:%S GMT", timestamp)
end

local function serializeCookie(name: string, value: string, options: CookieOptions?): string
	local parts = { `{name}={value}` }
	local opts = options or {}
	if opts.path ~= nil then
		table.insert(parts, "Path=" .. opts.path)
	end
	if opts.domain ~= nil then
		table.insert(parts, "Domain=" .. opts.domain)
	end
	if opts.expires ~= nil then
		table.insert(parts, "Expires=" .. formatHttpDate(opts.expires))
	end
	if opts.maxAge ~= nil then
		table.insert(parts, "Max-Age=" .. tostring(opts.maxAge))
	end
	if opts.secure == true then
		table.insert(parts, "Secure")
	end
	if opts.httpOnly == true then
		table.insert(parts, "HttpOnly")
	end
	if opts.sameSite ~= nil then
		table.insert(parts, "SameSite=" .. opts.sameSite)
	end
	return table.concat(parts, "; ")
end

local function parseRequestCookies(headerValue: string?): { [string]: string | { string } }
	local parsed = {}
	if headerValue == nil or headerValue == "" then
		return parsed
	end

	for part in string.gmatch(headerValue, "([^;]+)") do
		local trimmed = util.trim(part)
		local eq = string.find(trimmed, "=", 1, true)
		if eq ~= nil then
			local name = util.trim(string.sub(trimmed, 1, eq - 1))
			local value = util.trim(string.sub(trimmed, eq + 1))
			if name ~= "" then
				local existing = parsed[name]
				if existing == nil then
					parsed[name] = value
				elseif type(existing) == "table" then
					table.insert(existing, value)
				else
					parsed[name] = { existing, value }
				end
			end
		end
	end

	return parsed
end

local function sendFileResponse(response: ServerResponse.ServerResponse, path: string, options: SendFileOptions?)
	local opts = options or {} :: SendFileOptions
	local canonicalPath = fs.path.canonicalize(path)
	assert(fs.isFile(canonicalPath), `File not found: {canonicalPath}`)

	local stat = fs.stat(canonicalPath)
	local headers = if opts.headers then table.clone(opts.headers) else {}
	local function headerExists(name: string): boolean
		local wanted = string.lower(name)
		for key in headers do
			if string.lower(key) == wanted then
				return true
			end
		end
		return false
	end

	if not headerExists("content-type") then
		headers["content-type"] = opts.contentType
			or mime.fromExtension(fs.path.extension(canonicalPath))
			or "application/octet-stream"
	end
	if opts.filename ~= nil and not headerExists("content-disposition") then
		headers["content-disposition"] = `attachment; filename="{opts.filename}"`
	end
	if stat.mtime ~= nil and not headerExists("last-modified") then
		headers["last-modified"] = formatHttpDate(stat.mtime :: number)
	end

	local handle = fs.openSync(canonicalPath, "r")
	response:status(opts.status or 200)
	response:headers(headers)
	response:sendStream({
		read = function(self, size)
			local chunk = handle:readSync(size)
			return chunk
		end,
		close = function(self)
			handle:closeSync()
		end,
	}, stat.size)
end

local function buildRoutePath(route: Route, params: { [string]: any }?): string
	local parts = {}
	for _, segment in route.segments do
		if segment.kind == "static" then
			table.insert(parts, segment.value)
		else
			local paramValue = if params ~= nil then params[segment.value] else nil
			assert(paramValue ~= nil, `Missing route parameter '{segment.value}'`)
			if segment.kind == "splat" then
				local pathParts = {}
				for part in string.gmatch(tostring(paramValue), "[^/]+") do
					table.insert(pathParts, encodePathParam(part))
				end
				table.insert(parts, table.concat(pathParts, "/"))
			else
				table.insert(parts, encodePathParam(paramValue))
			end
		end
	end

	if #parts == 0 then
		return "/"
	end

	return "/" .. table.concat(parts, "/")
end

local function splitRelativePath(path: string): { string }
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == "." or part == ".." then
			error("Static paths cannot contain '.' or '..' segments")
		end
		table.insert(parts, part)
	end
	return parts
end

local function pushUnique(list: { string }, value: string)
	for _, existing in list do
		if existing == value then
			return
		end
	end
	table.insert(list, value)
end

local function mergeHeaders(base: Headers?, extra: Headers?): Headers?
	if base == nil and extra == nil then
		return nil
	end

	local merged = if base ~= nil then table.clone(base) else {}
	if extra ~= nil then
		for key, value in extra do
			merged[key] = value
		end
	end
	return merged
end

local function applyHeaders(response: ServerResponse.ServerResponse, headers: Headers?)
	if headers == nil then
		return
	end
	response:headers(headers)
end

local function hasHeader(headers: Headers?, name: string): boolean
	if headers == nil then
		return false
	end

	local wanted = string.lower(name)
	for key in headers do
		if string.lower(key) == wanted then
			return true
		end
	end
	return false
end

local function hasResponseHeader(response: ServerResponse.ServerResponse, name: string): boolean
	local wanted = string.lower(name)
	for key in response._headers do
		if string.lower(key) == wanted then
			return true
		end
	end
	return false
end

function AppContextMethods.json(self: AppContext): any
	if rawget(self, "_jsonLoaded") then
		return rawget(self, "_json")
	end

	local body = self.request.body
	local decoded = if body == "" then nil else json.decode(body)
	rawset(self, "_json", decoded)
	rawset(self, "_jsonLoaded", true)
	return decoded
end

function AppContextMethods.form(self: AppContext): QueryTable?
	return self.request.form
end

function AppContextMethods.multipart(self: AppContext): { any }?
	return self.request.multipart
end

--- Returns the first parsed request cookie value for the given cookie name.
--- @param name Cookie name.
--- @return string?
function AppContextMethods.cookie(self: AppContext, name: string): string?
	local value = self.cookies[name]
	if type(value) == "table" then
		return value[1]
	end
	return value
end

function AppContextMethods.send(self: AppContext, status: number, body: string?, headers: Headers?)
	self.response:send(status, body, headers)
end

function AppContextMethods.text(self: AppContext, body: string, status: number?, headers: Headers?)
	local merged = headers
	if not hasHeader(headers, "content-type") and not hasResponseHeader(self.response, "content-type") then
		merged = mergeHeaders(headers, {
			["content-type"] = "text/plain; charset=utf-8",
		})
	end
	self.response:send(status or 200, body, merged)
end

function AppContextMethods.html(self: AppContext, body: string, status: number?, headers: Headers?)
	local merged = headers
	if not hasHeader(headers, "content-type") and not hasResponseHeader(self.response, "content-type") then
		merged = mergeHeaders(headers, {
			["content-type"] = "text/html; charset=utf-8",
		})
	end
	self.response:send(status or 200, body, merged)
end

function AppContextMethods.jsonResponse(self: AppContext, data: any, status: number?, headers: Headers?)
	local merged = headers
	if not hasHeader(headers, "content-type") and not hasResponseHeader(self.response, "content-type") then
		merged = mergeHeaders(headers, {
			["content-type"] = "application/json",
		})
	end
	self.response:send(status or 200, json.encode(data), merged)
end

function AppContextMethods.redirect(self: AppContext, location: string, status: number?, headers: Headers?)
	local merged = mergeHeaders(headers, {
		["location"] = location,
	})
	self.response:send(status or 302, "", merged)
end

--- Appends a `Set-Cookie` response header.
--- @param name Cookie name.
--- @param value Cookie value.
--- @param options Cookie attributes.
function AppContextMethods.setCookie(self: AppContext, name: string, value: string, options: CookieOptions?)
	appendSetCookieHeader(self.response, serializeCookie(name, value, options))
end

--- Clears a cookie by setting it to an empty value with an expired timestamp.
--- @param name Cookie name.
--- @param options Cookie attributes such as `path` or `domain` to target the existing cookie.
function AppContextMethods.clearCookie(self: AppContext, name: string, options: CookieOptions?)
	local opts = if options ~= nil then table.clone(options :: any) else {}
	opts.expires = 0
	opts.maxAge = 0
	if opts.path == nil then
		opts.path = "/"
	end
	appendSetCookieHeader(self.response, serializeCookie(name, "", opts))
end

--- Streams a file as the HTTP response body.
--- @param path Filesystem path to the file.
--- @param options Optional response overrides.
function AppContextMethods.sendFile(self: AppContext, path: string, options: SendFileOptions?)
	sendFileResponse(self.response, path, options)
end

local function createContext(
	app: App,
	request: HttpServer.ServerRequest,
	response: ServerResponse.ServerResponse,
	route: Route?,
	params: Params,
	sharedState: { [string]: any },
	mountPath: string?,
	pathWithinMount: string,
	errorStatus: number?,
	errorData: { [string]: any }?
): AppContext
	return setmetatable({
		app = app,
		request = request,
		response = response,
		params = params,
		query = request.query,
		cookies = parseRequestCookies(request.headers["cookie"]),
		state = sharedState,
		route = if route ~= nil then { method = route.method, path = route.path } else nil,
		mountPath = mountPath,
		pathWithinMount = pathWithinMount,
		originalPath = request.pathname,
		errorStatus = errorStatus,
		errorData = errorData,
	}, AppContextMetatable) :: AppContext
end

local function applyResult(ctx: AppContext, ...: any)
	if ctx.response._finished then
		return
	end

	local results = table.pack(...)
	if results.n == 0 then
		return
	end

	local first = results[1]
	if first == nil then
		return
	end

	local kind = type(first)
	if kind == "number" then
		local status = first :: number
		local body = results[2]
		local headers = results[3]
		if body == nil then
			applyHeaders(ctx.response, headers)
			ctx.response:status(status)
			ctx.response:finish()
		elseif type(body) == "table" then
			ctx:jsonResponse(body, status, headers)
		else
			ctx:text(tostring(body), status, headers)
		end
		return
	end

	if kind == "string" then
		ctx:text(first :: string)
		return
	end

	if kind == "boolean" then
		ctx:text(if first then "true" else "false")
		return
	end

	if kind ~= "table" then
		ctx:text(tostring(first))
		return
	end

	local spec = first :: ResponseSpec
	local looksLikeResponse = spec.status ~= nil
		or spec.headers ~= nil
		or spec.contentType ~= nil
		or spec.body ~= nil
		or spec.text ~= nil
		or spec.html ~= nil
		or spec.json ~= nil
		or spec.location ~= nil

	if not looksLikeResponse then
		ctx:jsonResponse(first)
		return
	end

	local status = spec.status or 200
	local headers = spec.headers
	if spec.contentType ~= nil then
		headers = mergeHeaders(headers, {
			["content-type"] = spec.contentType,
		})
	end

	if spec.location ~= nil then
		ctx:redirect(spec.location, status, headers)
	elseif spec.json ~= nil then
		ctx:jsonResponse(spec.json, status, headers)
	elseif spec.html ~= nil then
		ctx:html(spec.html, status, headers)
	elseif spec.text ~= nil then
		ctx:text(spec.text, status, headers)
	elseif spec.body == nil then
		applyHeaders(ctx.response, headers)
		ctx.response:status(status)
		ctx.response:finish()
	elseif type(spec.body) == "table" and not hasHeader(headers, "content-type") then
		ctx:jsonResponse(spec.body, status, headers)
	else
		local body = spec.body
		applyHeaders(ctx.response, headers)
		ctx.response:status(status)
		ctx.response:finish(if body == nil then nil else tostring(body))
	end
end

local function methodNotAllowedResult(match: MatchResult): ResponseSpec
	local allowed = table.clone(match.allowedMethods)
	table.sort(allowed)
	return {
		status = 405,
		text = "Method Not Allowed",
		headers = {
			["allow"] = table.concat(allowed, ", "),
		},
	}
end

local function findNamedRoute(self: App, name: string, prefix: string?): (Route?, string?)
	for _, route in self._routes do
		if route.name == name then
			return route, prefix
		end
	end

	for _, mount in self._mounts do
		local route, routePrefix =
			findNamedRoute(mount.app, name, if prefix ~= nil then joinPaths(prefix, mount.prefix) else mount.prefix)
		if route ~= nil then
			return route, routePrefix
		end
	end

	return nil, nil
end

--[=[
	A higher-level HTTP app/router layer built on top of [[HttpServer]].

	Use [[App.get]], [[App.post]], middleware, groups, and mounts to build
	Flask/FastAPI-style request routing without dropping to the low-level
	request-handler callback for every endpoint.
]=]
function App.new(options: HttpServer.HttpServerOptions?): App
	return setmetatable({
		_routes = {},
		_mounts = {},
		_middleware = {},
		_statusHandlers = {},
		_exceptionHandler = nil,
		_serverOptions = if options ~= nil then table.clone(options :: any) else nil,
		_server = nil :: HttpServer.HttpServer?,
		state = {},
	}, App)
end

--[=[
	Registers a route handler for a method/path pair.

	@param method HTTP method such as `"GET"` or `"POST"`.
	@param path Route pattern beginning with `/`. Supports `:param` and trailing `*splat`.
	@param handler Request handler for matching requests.
	@param options Optional route metadata such as a route name or route-local middleware.
	@return App -- Self, for chaining.
]=]
function App.route(self: App, method: string, path: string, handler: RouteHandler, options: RouteOptions?): App
	table.insert(self._routes, {
		method = normalizeMethod(method),
		path = path,
		segments = compilePath(path),
		handler = handler,
		name = if options ~= nil then options.name else nil,
		middleware = if options ~= nil then options.middleware else nil,
		websocketHandler = nil,
		websocketOptions = if options ~= nil then options.websocket else nil,
	})
	return self
end

--- Registers middleware that wraps every route and mounted child app.
--- @param middleware Middleware callback receiving `(ctx, next)`.
--- @return App
function App.use(self: App, middleware: Middleware): App
	table.insert(self._middleware, middleware)
	return self
end

--- Registers server-side session middleware and exposes `ctx.session`.
--- @param options Session middleware options.
--- @return App
function App.useSessions(self: App, options: any?): App
	local serverSession = require("./ServerSession")
	return self:use(serverSession.middleware(options))
end

--- Registers a handler for framework-generated status responses such as `404` or `405`.
--- @param status HTTP status code to intercept.
--- @param handler Handler that returns the replacement response.
--- @return App
function App.error(self: App, status: number, handler: RouteHandler): App
	self._statusHandlers[status] = handler
	return self
end

--- Registers a catch-all exception handler for uncaught route or middleware errors.
--- @param handler Recovery handler receiving `(ctx, err)`.
--- @return App
function App.onError(self: App, handler: ExceptionHandler): App
	self._exceptionHandler = handler
	return self
end

--[=[
	Mounts another app or router under a URL prefix.

	Parent middleware runs before child middleware, and child routes see
	`ctx.mountPath` / `ctx.pathWithinMount`.

	@param prefix URL prefix such as `"/api"`.
	@param child Child app/router to mount.
	@return App
]=]
function App.mount(self: App, prefix: string, child: App): App
	table.insert(self._mounts, {
		prefix = normalizePrefix(prefix),
		app = child,
	})
	return self
end

--[=[
	Creates and mounts a child router under a prefix, then optionally configures it.

	@param prefix URL prefix such as `"/api"`.
	@param configure Optional callback invoked with the new child router.
	@return App -- The new child router.
]=]
function App.group(self: App, prefix: string, configure: ((group: App) -> ())?): App
	local child = App.new()
	self:mount(prefix, child)
	if configure ~= nil then
		configure(child)
	end
	return child
end

--[=[
	Builds a URL for a named route.

	@param name Route name registered through `options.name`.
	@param params Optional path parameters to substitute into the route.
	@param query Optional query-string parameters to append.
	@return string -- The generated relative URL.
]=]
function App.urlFor(
	self: App,
	name: string,
	params: { [string]: any }?,
	query: { [string]: string | number | boolean | { string | number | boolean } }?
): string
	local route, prefix = findNamedRoute(self, name, nil)
	assert(route ~= nil, `Unknown route '{name}'`)
	local path = buildRoutePath(route :: Route, params)
	if prefix ~= nil then
		path = joinPaths(prefix, path)
	end
	return util.appendQuery(path, query)
end

--[=[
	Mounts a static directory under a URL prefix.

	Files are served for `GET`/`HEAD` requests only. Requests that attempt
	path traversal are rejected. When `fallthrough` is true, missing files
	continue to later routes instead of immediately returning `404`.

	@param prefix URL prefix such as `"/assets"`.
	@param directory Filesystem directory to expose.
	@param options Static file options.
	@return App
]=]
function App.static(self: App, prefix: string, directory: string, options: StaticOptions?): App
	local opts = options or {}
	local root = fs.path.canonicalize(directory)
	local indexFile = opts.indexFile
	local fallthrough = if opts.fallthrough == true then true else false
	local extraHeaders = opts.headers

	local child = App.new()
	child:get("/*path", function(ctx)
		local relative = ctx.params.path
		if relative == "" then
			if indexFile == nil then
				if fallthrough then
					return nil
				end
				return {
					status = 404,
					text = "Not Found",
				}
			end
			relative = indexFile
		end

		local ok, partsOrErr = pcall(splitRelativePath, relative)
		if not ok then
			return {
				status = 403,
				text = "Forbidden",
			}
		end

		local target = root
		for _, part in partsOrErr do
			target = fs.path.join(target, part)
		end

		local targetOk, canonicalTarget = pcall(fs.path.canonicalize, target)
		if not targetOk then
			if fallthrough then
				return nil
			end
			return {
				status = 404,
				text = "Not Found",
			}
		end

		if not startsWithPath(canonicalTarget, root) or not fs.isFile(canonicalTarget) then
			if fallthrough then
				return nil
			end
			return {
				status = 404,
				text = "Not Found",
			}
		end

		ctx:sendFile(canonicalTarget, {
			headers = extraHeaders,
		})
	end, {
		name = if prefix ~= "/" then prefix .. ".__static__" else "__static__",
	})

	return self:mount(prefix, child)
end

--- Registers a `GET` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.get(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("GET", path, handler, options)
end

--- Registers a `POST` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.post(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("POST", path, handler, options)
end

--- Registers a `PUT` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.put(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("PUT", path, handler, options)
end

--- Registers a `DELETE` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.delete(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("DELETE", path, handler, options)
end

--- Registers a `PATCH` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.patch(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("PATCH", path, handler, options)
end

--- Registers a `HEAD` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.head(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("HEAD", path, handler, options)
end

--- Registers an `OPTIONS` route.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.options(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("OPTIONS", path, handler, options)
end

--- Registers a route that matches any method.
--- @param path Route pattern beginning with `/`.
--- @param handler Handler for matching requests.
--- @param options Optional route metadata.
--- @return App
function App.any(self: App, path: string, handler: RouteHandler, options: RouteOptions?): App
	return self:route("ANY", path, handler, options)
end

--[=[
	Registers a WebSocket endpoint.

	@param path Route pattern beginning with `/`.
	@param handler Handler receiving `(ctx, ws)` after a successful upgrade.
	@param options Optional route metadata.
	@return App
]=]
function App.websocket(self: App, path: string, handler: WebSocketHandler, options: RouteOptions?): App
	table.insert(self._routes, {
		method = "GET",
		path = path,
		segments = compilePath(path),
		handler = function()
			return nil
		end,
		name = if options ~= nil then options.name else nil,
		middleware = if options ~= nil then options.middleware else nil,
		websocketHandler = handler,
		websocketOptions = if options ~= nil then options.websocket else nil,
	})
	return self
end

function App._match(self: App, requestMethod: string, pathname: string): MatchResult
	local matchedPath = false
	local allowedMethods = {}

	for _, route in self._routes do
		local params = routeMatches(route, pathname)
		if params ~= nil then
			matchedPath = true
			pushUnique(allowedMethods, route.method)
			if route.method == "GET" then
				pushUnique(allowedMethods, "HEAD")
			end
			if matchesMethod(route.method, requestMethod) then
				return {
					route = route,
					params = params,
					pathMatched = true,
					allowedMethods = allowedMethods,
				}
			end
		end
	end

	return {
		route = nil,
		params = {},
		pathMatched = matchedPath,
		allowedMethods = allowedMethods,
	}
end

function App._execute(
	self: App,
	request: HttpServer.ServerRequest,
	response: ServerResponse.ServerResponse,
	pathname: string,
	sharedState: { [string]: any },
	mountPath: string?
): (AppContext, { [number]: any, n: number })
	local match = self:_match(request.method, pathname)
	local ctx =
		createContext(self, request, response, match.route, match.params, sharedState, mountPath, pathname, nil, nil)

	local function executeStatusHandler(status: number, errorData: { [string]: any }?, defaultResult: any): any
		local handler = self._statusHandlers[status]
		if handler == nil then
			return defaultResult
		end

		local errorCtx =
			createContext(self, request, response, nil, {}, sharedState, mountPath, pathname, status, errorData)
		return handler(errorCtx)
	end

	local function runHandler(): any
		if match.route ~= nil then
			local route = match.route :: Route
			local routeMiddleware = route.middleware
			local function invokeRouteHandler(): any
				if route.websocketHandler ~= nil then
					local websocket = require("@eryx/websocket")
					local ws = websocket.upgrade(ctx.request, ctx.response, route.websocketOptions)
					if ws == nil then
						return {
							status = 426,
							text = "Upgrade Required",
							headers = {
								["upgrade"] = "websocket",
							},
						}
					end
					return (route.websocketHandler :: WebSocketHandler)(ctx, ws)
				end
				return route.handler(ctx)
			end

			if routeMiddleware == nil or #routeMiddleware == 0 then
				return invokeRouteHandler()
			end

			local function dispatchRoute(index: number): any
				local middleware = routeMiddleware[index]
				if middleware == nil then
					return invokeRouteHandler()
				end

				local calledNext = false
				return middleware(ctx, function()
					assert(not calledNext, "next() can only be called once")
					calledNext = true
					return dispatchRoute(index + 1)
				end)
			end

			return dispatchRoute(1)
		end

		for _, mount in self._mounts do
			local childPath = splitMountedPath(mount.prefix, pathname)
			if childPath ~= nil then
				local nextMountPath = if mountPath ~= nil then joinPaths(mountPath, mount.prefix) else mount.prefix
				local _, childResults = mount.app:_execute(request, response, childPath, sharedState, nextMountPath)
				return table.unpack(childResults, 1, childResults.n)
			end
		end

		if match.pathMatched then
			return executeStatusHandler(405, {
				allowedMethods = table.clone(match.allowedMethods),
			}, methodNotAllowedResult(match))
		end
		return executeStatusHandler(404, nil, {
			status = 404,
			text = "Not Found",
		})
	end

	local function dispatch(index: number): any
		local middleware = self._middleware[index]
		if middleware == nil then
			return runHandler()
		end

		local calledNext = false
		return middleware(ctx, function()
			assert(not calledNext, "next() can only be called once")
			calledNext = true
			return dispatch(index + 1)
		end)
	end

	local ok, resultOrErr, extra1, extra2, extra3, extra4 = pcall(dispatch, 1)
	if ok then
		return ctx, table.pack(resultOrErr, extra1, extra2, extra3, extra4)
	end

	if self._exceptionHandler ~= nil then
		local recoveryCtx = createContext(
			self,
			request,
			response,
			match.route,
			match.params,
			sharedState,
			mountPath,
			pathname,
			nil,
			nil
		)
		return recoveryCtx, table.pack((self._exceptionHandler :: ExceptionHandler)(recoveryCtx, resultOrErr))
	end

	error(resultOrErr)
end

function App._handle(self: App, request: HttpServer.ServerRequest, response: ServerResponse.ServerResponse)
	local ctx, results = self:_execute(request, response, request.pathname, {}, nil)
	applyResult(ctx, table.unpack(results, 1, results.n))
end

--- Returns a low-level `HttpServer`-compatible handler for this app.
--- @return (HttpServer.ServerRequest, ServerResponse.ServerResponse) -> ()
function App.handler(self: App): (HttpServer.ServerRequest, ServerResponse.ServerResponse) -> ()
	return function(request, response)
		self:_handle(request, response)
	end
end

local function mergeServerOptions(
	base: HttpServer.HttpServerOptions?,
	override: HttpServer.HttpServerOptions?
): HttpServer.HttpServerOptions?
	if base == nil and override == nil then
		return nil
	end

	local merged = if base ~= nil then table.clone(base :: any) else {}
	if override ~= nil then
		for key, value in override :: any do
			merged[key] = value
		end
	end
	return merged
end

--- Creates a low-level [[HttpServer]] that dispatches through this app.
--- @param options Optional server options overriding app defaults.
--- @return HttpServer
function App.createServer(self: App, options: HttpServer.HttpServerOptions?): HttpServer.HttpServer
	return HttpServer.new(self:handler(), mergeServerOptions(self._serverOptions, options))
end

--[=[
	Starts listening with this app's handler.

	This is a convenience wrapper around [[App.createServer]] followed by
	[[HttpServer.listen]].

	@param callback Optional listener-ready callback receiving `(host, port)`.
	@param options Optional server options overriding app defaults.
]=]
function App.listen(self: App, callback: ((host: string, port: number) -> ())?, options: HttpServer.HttpServerOptions?)
	assert(self._server == nil, "App is already listening")
	local server = self:createServer(options)
	self._server = server

	local ok, err = pcall(function()
		server:listen(callback)
	end)

	self._server = nil
	if not ok then
		error(err)
	end
end

--- Closes the underlying server if this app is currently listening.
function App.close(self: App)
	if self._server ~= nil then
		self._server:close()
	end
end

return table.freeze(App)
