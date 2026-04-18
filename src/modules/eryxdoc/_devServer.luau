--- @ignore

--[[
	In-memory dev server for eryxdoc.

	Instead of building to disk, this server renders each page on demand
	when a request comes in. File watchers trigger a content refresh
	(re-collecting modules and articles), but nothing is ever written
	to the output directory.
]]

local fs = require("@eryx/fs")
local http = require("@eryx/http")
local logging = require("@eryx/logging")
local fsWatch = require("@eryx/fs_watch")
local task = require("@eryx/task")
local pathlib = require("@eryx/path")
local websocket = require("@eryx/websocket")
local yaml = require("@eryx/encoding/yaml")
local modulesApi = require("./content/modules")
local Article = require("./content/article")
local Renderer = require("./render/renderer")
local buildWarnings = require("./warnings")

local eryxdoc = require("@eryx/eryxdoc")
local exception = require("@eryx/exception")
type Config = eryxdoc.Config

local log = logging.getLogger("eryxdoc.dev")

-- ── MIME map (for static assets) ─────────────────────────────────────────

local MIME: { [string]: string } = {
	[".html"] = "text/html; charset=utf-8",
	[".css"] = "text/css; charset=utf-8",
	[".js"] = "application/javascript; charset=utf-8",
	[".mjs"] = "application/javascript; charset=utf-8",
	[".json"] = "application/json; charset=utf-8",
	[".svg"] = "image/svg+xml",
	[".png"] = "image/png",
	[".jpg"] = "image/jpeg",
	[".jpeg"] = "image/jpeg",
	[".gif"] = "image/gif",
	[".ico"] = "image/x-icon",
	[".webp"] = "image/webp",
	[".woff"] = "font/woff",
	[".woff2"] = "font/woff2",
	[".ttf"] = "font/ttf",
	[".otf"] = "font/otf",
	[".txt"] = "text/plain; charset=utf-8",
	[".xml"] = "application/xml; charset=utf-8",
	[".webmanifest"] = "application/manifest+json",
}

-- ── Helpers ──────────────────────────────────────────────────────────────

local function sanitize(url_path: string): string
	local path = string.match(url_path, "^([^?#]*)") or "/"
	local parts: { string } = {}
	for segment in string.gmatch(path, "[^/]+") do
		if segment == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif segment ~= "." then
			table.insert(parts, segment)
		end
	end
	return table.concat(parts, "/")
end

local function parseMeta(path: string): { children: { string }?, title: string? }
	if not fs.isFile(path) then
		return {}
	end
	local content = fs.openSync(path):readSync()
	local ok, data = pcall(yaml.decode, content)
	if not ok or type(data) ~= "table" then
		return {}
	end
	local result: { children: { string }?, title: string? } = {}
	if type(data.children) == "table" then
		result.children = data.children
	end
	if type(data.title) == "string" then
		result.title = data.title
	end
	return result
end

local function collectFolderTitles(path: string): ({ [string]: string }, { [string]: string }, { [string]: number })
	local sectionTitles: { [string]: string } = {}
	local folderTitles: { [string]: string } = {}
	local folderOrder: { [string]: number } = {}

	local function walk(dir: string, prefix: string?, isTopLevel: boolean)
		if not fs.isDirectory(dir) then
			return
		end
		local currentMeta = parseMeta(dir .. "/.meta")
		if currentMeta.children then
			for i, child in currentMeta.children :: { string } do
				local key = if prefix then prefix .. "/" .. child else child
				folderOrder[key] = i
			end
		end
		for _, entry in fs.listDir(dir) do
			local fullPath = dir .. "/" .. entry
			if not fs.isDirectory(fullPath) then
				continue
			end
			local meta = parseMeta(fullPath .. "/.meta")
			local key = if prefix then prefix .. "/" .. entry else entry
			if meta.title then
				if isTopLevel then
					sectionTitles[entry] = meta.title
				end
				folderTitles[key] = meta.title
			end
			walk(fullPath, key, false)
		end
	end

	walk(path, nil, true)
	return sectionTitles, folderTitles, folderOrder
end

local function formatFolderTitle(prefix: string?, metaTitle: string?): string
	if metaTitle then
		return metaTitle
	end
	if not prefix then
		return "Home"
	end
	local stem = prefix:match("[^/]+$") or prefix
	return stem:gsub("%-", " "):gsub("(%a)([%w]*)", function(first: string, rest: string)
		return first:upper() .. rest
	end)
end

local function collectArticles(path: string, prefix: string?): { { name: string, article: Article.Article } }
	local articles = {}
	if not fs.isDirectory(path) then
		return {}
	end

	local meta = parseMeta(path .. "/.meta")
	local entries = fs.listDir(path)
	local hasIndexArticle = false
	local generatedSectionPages: { Article.GeneratedSectionPage } = {}

	if meta.children then
		local childOrder: { [string]: number } = {}
		for i, child in meta.children :: { string } do
			childOrder[child] = i
		end

		local function entryOrder(entry: string)
			local stem = entry:match("^(.+)%.[^.]+$") or entry
			local candidates = {
				stem,
				entry,
				entry .. "/index",
				entry .. "/index.md",
				entry .. "/index.mdx",
			}
			for _, c in candidates do
				if childOrder[c] then
					return childOrder[c]
				end
			end
			return 9999
		end

		table.sort(entries, function(a: string, b: string)
			local orderA = entryOrder(a)
			local orderB = entryOrder(b)
			if orderA ~= orderB then
				return orderA < orderB
			end
			return a < b
		end)
	else
		table.sort(entries)
	end

	for _, entry in entries do
		if entry == ".meta" then
			continue
		end
		local fullPath = path .. "/" .. entry
		if fs.isDirectory(fullPath) then
			local subPrefix = if prefix then prefix .. "/" .. entry else entry
			local sub = collectArticles(fullPath, subPrefix)
			for _, a in sub do
				table.insert(articles, a)
				if a.name == subPrefix then
					table.insert(generatedSectionPages, {
						title = a.article.title,
						article = a.article,
					})
				end
			end
			continue
		end
		if not entry:match("%.md$") and not entry:match("%.txt$") then
			continue
		end
		local stem = pathlib.stem(fullPath)
		local name: string
		if stem == "index" and prefix then
			name = prefix
		else
			name = if prefix then prefix .. "/" .. stem else stem
		end
		local article = Article.fromFile(fullPath)
		table.insert(articles, { name = name, article = article })
		if stem == "index" then
			hasIndexArticle = true
		else
			table.insert(generatedSectionPages, {
				title = article.title,
				article = article,
			})
		end
	end

	if not hasIndexArticle and #generatedSectionPages > 0 then
		local name = prefix or "index"
		table.insert(articles, 1, {
			name = name,
			article = Article.generated(
				formatFolderTitle(prefix, meta.title),
				path .. "/index.md",
				"",
				"Overview for this section.",
				generatedSectionPages
			),
		})
	end

	return articles
end

-- ── Content state ────────────────────────────────────────────────────────

type DevState = {
	renderer: Renderer.Renderer,
	allModules: { any },
	allArticles: { { name: string, article: Article.Article } },
	hasCustomIndex: boolean,
	cfg: Config,
	themeDir: string,
	staticDir: string?,
	siteRoot: string,
	exportMode: "flat" | "directory",
}

local function buildState(cfg: Config): DevState
	local MODULE_PREFIX = cfg.prefix or "@eryx"
	local SITE_ROOT = cfg.siteRoot or "/"
	local EXPORT_MODE: "flat" | "directory" = cfg.exportMode or "directory"
	local SITE_TITLE = cfg.title or "API Docs"
	local THEME_DIR = cfg.theme or tostring(pathlib.join(_DIR, "/theme"))
	local STATIC_DIR = cfg.static
	local NO_MODULES = cfg.noModules or false

	if SITE_ROOT:sub(-1) ~= "/" then
		SITE_ROOT = SITE_ROOT .. "/"
	end

	local TEMPLATES = {
		article = THEME_DIR .. "/templates/article_page.html",
		api = THEME_DIR .. "/templates/api_page.html",
		index = THEME_DIR .. "/templates/index_page.html",
		notFound = THEME_DIR .. "/templates/404_page.html",
	}

	local allModules = if NO_MODULES or not cfg.modules
		then {}
		else modulesApi.collectModules(cfg.modules, MODULE_PREFIX, "")
	local allArticles = if cfg.articles then collectArticles(cfg.articles) else {}
	local sectionTitles, folderTitles, folderOrder =
		if cfg.articles then collectFolderTitles(cfg.articles) else {}, {}, {}

	-- Populate last-updated dates from git
	if cfg.showLastUpdated then
		local os = require("@eryx/os")
		for _, articleEntry in allArticles do
			local result = os.exec("git", {
				"log",
				"-1",
				"--format=%aI",
				"--",
				articleEntry.article.sourceFilename,
			})
			if result.ok and result.stdout and #result.stdout > 0 then
				local date = result.stdout:match("(%d%d%d%d%-%d%d%-%d%d)")
				if date then
					articleEntry.article.lastUpdated = date
				end
			end
		end
	end

	local faviconHref: string? = nil
	if cfg.favicon and fs.isFile(cfg.favicon) then
		local faviconName = cfg.favicon:match("[^/\\]+$") or "favicon.ico"
		faviconHref = SITE_ROOT .. faviconName
	end

	-- Inject dev-only live-reload script if provided by the theme
	local devScriptTag = ""
	if fs.isFile(THEME_DIR .. "/eryxdoc-live-reload.js") then
		devScriptTag = string.format('<script src="%seryxdoc-live-reload.js"></script>', SITE_ROOT)
	end

	local renderer = Renderer.new(SITE_TITLE, SITE_ROOT .. "style.css", TEMPLATES, {
		siteRoot = SITE_ROOT,
		exportMode = EXPORT_MODE,
		modulePrefix = MODULE_PREFIX,
		favicon = faviconHref,
		extraHead = cfg.extraHead,
		extraScripts = (cfg.extraScripts or "") .. devScriptTag,
		announcement = cfg.announcement,
		openGraph = cfg.openGraph,
		articleMetaGenerator = cfg.articleMetaGenerator,
		apiMetaGenerator = cfg.apiMetaGenerator,
		customFilters = cfg.customFilters,
		customGlobals = cfg.customGlobals,
		sectionTitles = sectionTitles,
		folderTitles = folderTitles,
		folderOrder = folderOrder,
	})

	for _, article in allArticles do
		renderer:registerArticle(article.article, article.name)
	end
	for _, mod in allModules do
		renderer:registerModule(mod)
	end

	local hasCustomIndex = false
	for _, article in allArticles do
		if article.name == "index" then
			hasCustomIndex = true
			break
		end
	end

	local warns = buildWarnings.summary()
	if #warns > 0 then
		log:warning(string.format("%d warning(s) during content collection", #warns))
		for _, w in warns do
			log:warning("    " .. w)
		end
	end
	buildWarnings.clear()

	log:info(string.format("Loaded %d modules, %d articles", #allModules, #allArticles))

	return {
		renderer = renderer,
		allModules = allModules,
		allArticles = allArticles,
		hasCustomIndex = hasCustomIndex,
		cfg = cfg,
		themeDir = THEME_DIR,
		staticDir = STATIC_DIR,
		siteRoot = SITE_ROOT,
		exportMode = EXPORT_MODE,
	}
end

-- ── Routing ──────────────────────────────────────────────────────────────

local function tryServeStatic(state: DevState, safePath: string): (number?, string?, string?)
	-- style.css
	if safePath == "style.css" then
		local stylePath = state.themeDir .. "/style.css"
		if fs.isFile(stylePath) then
			return 200, fs.openSync(stylePath):readSync(), "text/css; charset=utf-8"
		end
	end

	-- favicon
	if state.cfg.favicon and fs.isFile(state.cfg.favicon) then
		local faviconName = state.cfg.favicon:match("[^/\\]+$") or "favicon.ico"
		if safePath == faviconName then
			local ext = string.lower(pathlib.extension(state.cfg.favicon) or "")
			local mime = MIME[ext] or "application/octet-stream"
			return 200, fs.openSync(state.cfg.favicon):readSync(), mime
		end
	end

	-- Static assets directory
	if state.staticDir and safePath:sub(1, 7) == "static/" then
		local assetPath = state.staticDir .. "/" .. safePath:sub(8)
		if fs.isFile(assetPath) then
			local ext = string.lower(pathlib.extension(assetPath) or "")
			local mime = MIME[ext] or "application/octet-stream"
			return 200, fs.openSync(assetPath):readSync(), mime
		end
	end

	-- Theme-supplied dev client script
	if safePath == "eryxdoc-live-reload.js" then
		local themePath = state.themeDir .. "/eryxdoc-live-reload.js"
		if fs.isFile(themePath) then
			return 200, fs.openSync(themePath):readSync(), "application/javascript; charset=utf-8"
		end
	end

	return nil, nil, nil
end

local function handleRequest(state: DevState, reqPath: string): (number, string, string)
	local siteRoot = state.siteRoot
	local renderer = state.renderer

	-- Strip the site root prefix from the request path
	local safePath = sanitize(reqPath)
	if siteRoot ~= "/" then
		local prefix = siteRoot:sub(2) -- remove leading /
		if prefix:sub(-1) == "/" then
			prefix = prefix:sub(1, -2)
		end
		if safePath:sub(1, #prefix) == prefix then
			safePath = safePath:sub(#prefix + 1)
			if safePath:sub(1, 1) == "/" then
				safePath = safePath:sub(2)
			end
		end
	end

	-- Try static assets first
	local staticStatus, staticBody, staticMime = tryServeStatic(state, safePath)
	if staticStatus then
		return staticStatus, staticBody :: string, staticMime :: string
	end

	-- search.json
	if safePath == "search.json" then
		local content = renderer:generateSearchIndex()
		return 200, content, "application/json; charset=utf-8"
	end

	-- sitemap.xml
	if safePath == "sitemap.xml" and state.cfg.baseUrl then
		local content = renderer:generateSitemap(state.cfg.baseUrl)
		return 200, content, "application/xml; charset=utf-8"
	end

	-- versions.json (empty array in dev mode)
	if safePath == "versions.json" then
		return 200, "[]", "application/json; charset=utf-8"
	end

	-- ── Page routing ─────────────────────────────────────────────────────

	-- Index page
	if safePath == "" or safePath == "index.html" then
		local ok, content = pcall(function()
			if state.hasCustomIndex then
				return renderer:renderArticle("index")
			else
				return renderer:renderIndex()
			end
		end)
		if ok then
			return 200, content, "text/html; charset=utf-8"
		end
		log:error(string.format("Error rendering index: %s", tostring(content)))
		return 500, `<h1>500 — Render Error</h1><pre>{content}</pre>`, "text/html; charset=utf-8"
	end

	-- 404 page
	if safePath == "404.html" then
		local ok, content = pcall(renderer.render404, renderer)
		if ok and content then
			return 200, content, "text/html; charset=utf-8"
		end
		return 404, "<h1>404</h1>", "text/html; charset=utf-8"
	end

	-- Module pages: api/<qualifiedName>/index.html or api/<qualifiedName>/api.json
	if safePath:sub(1, 4) == "api/" then
		local rest = safePath:sub(5) -- after "api/"

		-- Check for JSON export: api/<name>/api.json
		local jsonName = rest:match("^(.+)/api%.json$")
		if jsonName then
			for _, mod in state.allModules do
				if mod.qualifiedName == jsonName then
					local ok, content = pcall(renderer.moduleToJSON, renderer, mod)
					if ok then
						return 200, content, "application/json; charset=utf-8"
					end
					return 500, `\{"error": "{content}"\}`, "application/json; charset=utf-8"
				end
			end
		end

		-- Module HTML: api/<name>/index.html or api/<name>/ or api/<name>
		local modName = rest:match("^(.+)/index%.html$") or rest:match("^(.+)/$") or rest
		if modName and modName ~= "" then
			-- Check if it's a known module
			for _, mod in state.allModules do
				if mod.qualifiedName == modName then
					local ok, content = pcall(renderer.renderModule, renderer, mod.qualifiedName)

					if ok then
						return 200, content, "text/html; charset=utf-8"
					end
					log:error(string.format("Error rendering module %s: %s", mod.qualifiedName, tostring(content)))
					return 500, `<h1>500 — Render Error</h1><pre>{content}</pre>`, "text/html; charset=utf-8"
				end
			end
		end
	end

	-- Article pages: <name>/index.html or <name>/ or <name>
	-- Also handle flat mode: <name>.html
	local articleName: string? = nil

	if state.exportMode == "directory" then
		articleName = safePath:match("^(.+)/index%.html$") or safePath:match("^(.+)/$") or safePath
	else
		articleName = safePath:match("^(.+)%.html$")
		if articleName then
			articleName = articleName:gsub("_", "/")
		end
	end

	if articleName and articleName ~= "" then
		for _, article in state.allArticles do
			if article.name == articleName then
				local ok, content = pcall(renderer.renderArticle, renderer, article.name)
				if ok then
					return 200, content, "text/html; charset=utf-8"
				end
				log:error(string.format("Error rendering article %s: %s", article.name, exception.format(content)))
				return 500,
					`<h1>500 — Render Error</h1><pre>{exception.format(content)}</pre>`,
					"text/html; charset=utf-8"
			end
		end
	end

	-- Nothing matched — try 404 page
	local ok404, page404 = pcall(renderer.render404, renderer)
	if ok404 and page404 then
		return 404, page404, "text/html; charset=utf-8"
	end
	return 404, "<html><body><h1>404 Not Found</h1></body></html>", "text/html; charset=utf-8"
end

-- ── Public API ───────────────────────────────────────────────────────────

export type DevHandle = {
	refresh: () -> (),
}

local function start(cfg: Config, host: string, port: number): DevHandle
	log:info("=== Dev server (in-memory) ===")
	local state = buildState(cfg)

	local watchers: { any } = {}
	local wsClients: { any } = {}
	local WATCH_DEBOUNCE_DEFAULT = 0.6 -- seconds (heavier debounce to avoid loops)
	local debounceSec = (cfg.watchDebounce or WATCH_DEBOUNCE_DEFAULT)
	local pendingRefreshTimer: thread? = nil
	local refreshInProgress = false
	local refreshRequestedWhileRunning = false
	local pendingRefreshCount = 0
	local lastRefreshTrigger = "manual"

	local function notifyReloadClients()
		for i = #wsClients, 1, -1 do
			local ws = wsClients[i]
			local ok = pcall(function()
				ws:send("reload")
			end)
			if not ok then
				table.remove(wsClients, i)
			end
		end
	end

	local function performRefresh(trigger: string)
		if refreshInProgress then
			refreshRequestedWhileRunning = true
			lastRefreshTrigger = trigger
			return
		end
		refreshInProgress = true
		log:info(
			string.format(
				"Refreshing content... (%s, %d queued change%s)",
				trigger,
				pendingRefreshCount,
				if pendingRefreshCount == 1 then "" else "s"
			)
		)
		pendingRefreshCount = 0
		lastRefreshTrigger = trigger

		local ok, newState = pcall(buildState, cfg)
		if ok then
			state = newState :: DevState
			notifyReloadClients()
		else
			log:error(string.format("Refresh failed (%s): %s", trigger, exception.format(newState)))
		end

		refreshInProgress = false
		if refreshRequestedWhileRunning then
			refreshRequestedWhileRunning = false
			-- Ensure we don't miss a trailing burst that arrived during refresh.
			pendingRefreshCount += 1
			if pendingRefreshTimer then
				pcall(task.cancel, pendingRefreshTimer)
				pendingRefreshTimer = nil
			end
			pendingRefreshTimer = task.delay(debounceSec, function()
				pendingRefreshTimer = nil
				performRefresh(lastRefreshTrigger .. " (post-refresh)")
			end)
		end
	end

	local function scheduleRefresh(trigger: string)
		pendingRefreshCount += 1
		lastRefreshTrigger = trigger
		if pendingRefreshTimer then
			pcall(task.cancel, pendingRefreshTimer)
		end
		pendingRefreshTimer = task.delay(debounceSec, function()
			pendingRefreshTimer = nil
			performRefresh(lastRefreshTrigger)
		end)
	end

	local handle: DevHandle = {
		refresh = function()
			performRefresh("manual")
		end,
	}

	-- Helper to add directory watchers and wire to refresh
	local function addDirWatcher(path: string, desc: string, filter: ((string) -> boolean)?)
		if not path or not fs.isDirectory(path) then
			return
		end
		local w = fsWatch.watchDir(path, { recursive = true, debounce = debounceSec })
		w.changed:connect(function(filename: string, eventType: string)
			if filter and not filter(filename) then
				return
			end
			log:info(string.format("Watcher (%s) changed: %s (%s)", desc, filename, eventType))
			scheduleRefresh(string.format("%s: %s (%s)", desc, filename, eventType))
		end)
		table.insert(watchers, w)
	end

	-- Watch modules (Luau files)
	if not cfg.noModules and cfg.modules and fs.isDirectory(cfg.modules) then
		addDirWatcher(cfg.modules, "modules", function(fn)
			return fn:match("%.luau$") and not fn:match("%.test%.luau$")
		end)
	end

	-- Watch articles (markdown / txt / .meta)
	if cfg.articles and fs.isDirectory(cfg.articles) then
		addDirWatcher(cfg.articles, "articles", function(fn)
			return fn:match("%.md$") or fn:match("%.txt$") or fn == ".meta"
		end)
	end

	-- Watch theme templates and style
	if state.themeDir and fs.isDirectory(state.themeDir) then
		addDirWatcher(state.themeDir, "theme")
	end

	-- Watch static assets
	if state.staticDir and fs.isDirectory(state.staticDir) then
		addDirWatcher(state.staticDir, "static")
	end

	local server = http.HttpServer.new(function(req, res)
		-- Handle WebSocket upgrade for live-reload on reserved path
		if req.path == "/__eryxdoc_ws" then
			local ws = websocket.upgrade(req, res)
			if ws then
				-- register client
				table.insert(wsClients, ws)
				-- spawn a listener to remove client on disconnect
				task.spawn(function()
					while true do
						local msg = ws:receive()
						if not msg then
							break
						end
						-- ignore inbound messages
					end
					for i = #wsClients, 1, -1 do
						if wsClients[i] == ws then
							table.remove(wsClients, i)
							break
						end
					end
				end)
				return
			end
		end

		local startTime = os.clock()
		local status, body, contentType = handleRequest(state, req.path)
		local elapsed = math.floor((os.clock() - startTime) * 1000)

		log:info(string.format("  %d %s (%dms)", status, req.path, elapsed))

		res:status(status):header("content-type", contentType):header("cache-control", "no-cache"):finish(body)
	end, { port = port, host = host })

	server:listen(function(host_, port_)
		log:info(string.format("  Serving docs at http://%s:%d/", host_, port_))
	end)

	-- Stop method to cleanup watchers and close server
	local origStop = handle.stop or function() end
	function handle.stop()
		if pendingRefreshTimer then
			pcall(task.cancel, pendingRefreshTimer)
			pendingRefreshTimer = nil
		end
		for _, w in watchers do
			pcall(function()
				w:stop()
			end)
		end
		watchers = {}
		-- Close any websocket clients
		for _, ws in wsClients do
			pcall(function()
				ws:close()
			end)
		end
		wsClients = {}
		pcall(function()
			server:close()
		end)
		origStop()
	end

	return handle
end

return { start = start }
