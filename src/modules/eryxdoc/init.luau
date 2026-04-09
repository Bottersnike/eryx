--[[
	Docgen build engine — the programmatic API.

	Use this module when you want to drive eryxdoc from your own script
	instead of going through main.luau's CLI.

	```luau
	local eryxdoc = require("./eryxdoc")

	eryxdoc.build({
		title = "My Docs",
		modules = "./src/modules",
		articles = "./docs",
		output = "./site",
		prefix = "@mylib",
	})
	```
]]

local fs = require("@eryx/fs")
local logging = require("@eryx/logging")
local yaml = require("@eryx/encoding/yaml")
local modulesApi = require("@self/content/modules")
local Article = require("@self/content/article")
local Renderer = require("@self/render/renderer")
local buildWarnings = require("@self/warnings")

local log = logging.getLogger("eryxdoc.build")

-- ── Types ─────────────────────────────────────────────────────────────────

-- Metadata for a single page, used for <meta> tags and OpenGraph.
-- Returned by metaGenerator or built from defaults.
export type PageMeta = {
	description: string?,
	image: string?,
	imageAlt: string?,
	canonicalUrl: string?,
	type: string?, -- og:type, defaults to "article"
	[string]: string?, -- any extra og: or meta properties
}

-- Context passed to the metaGenerator callback so it can decide per-page meta.
export type PageContext = {
	kind: "module" | "article" | "index",
	name: string?, -- article name or module qualifiedName
	title: string?, -- page display title
	path: string?, -- site-relative URL path
	summary: string?, -- article summary or module first paragraph
}

export type OpenGraphConfig = {
	siteName: string?, -- og:site_name
	image: string?, -- default og:image URL
	imageAlt: string?, -- default og:image:alt
	description: string?, -- default meta description / og:description
	type: string?, -- default og:type (default: "article")
	locale: string?, -- og:locale (e.g. "en_US")
}

export type Config = {
	-- Required
	output: string,

	-- Content sources
	modules: string?,
	articles: string?,
	prefix: string?,
	noModules: boolean?,

	-- Site settings
	title: string?,
	siteRoot: string?,
	baseUrl: string?, -- absolute base URL for sitemap/canonical links (e.g. "https://docs.example.com")
	exportMode: ("flat" | "directory")?,

	-- Theming
	theme: string?, -- path to theme dir (must contain templates/ and style.css)
	static: string?, -- path to static assets dir

	-- HTML injections
	favicon: string?,
	extraHead: string?,
	extraScripts: string?,
	announcement: string?, -- HTML string shown as a dismissible banner at the top

	-- OpenGraph / SEO
	openGraph: OpenGraphConfig?,
	-- Optional callbacks that return per-page meta for each page type.
	-- Overrides global openGraph defaults for that page.
	-- Return nil fields to fall back to the global defaults.
	articleMetaGenerator: ((context: PageContext) -> PageMeta)?,
	apiMetaGenerator: ((context: PageContext) -> PageMeta)?,

	-- Template customisation
	customFilters: { [string]: (any, { [string]: any }) -> any }?,
	customGlobals: { [string]: any }?,

	-- Versioning
	-- When set, the build output goes into output/{version.name}/ and a
	-- versions.json manifest is written/updated at the output root.
	-- The version picker in the header reads this manifest.
	version: {
		name: string, -- e.g. "v2.0", "latest"
		label: string?, -- display label (defaults to name)
		isDefault: boolean?, -- if true, also written to output root
	}?,

	-- Redirects
	-- Each entry generates an HTML redirect stub at the "from" path.
	-- Useful when pages are moved to keep old URLs working.
	redirects: { { from: string, to: string } }?,

	-- Build hooks
	-- Callbacks invoked at key points during the build. All are optional.
	hooks: {
		-- Called once at the start of a build, before any content is collected.
		onBuildStart: ((cfg: Config) -> ())?,
		-- Called after each page is rendered, before it's written to disk.
		-- Receives the rendered HTML and page info; must return the (possibly modified) HTML.
		onPageRender: ((
			html: string,
			page: {
				kind: "article" | "module" | "index" | "404",
				name: string?,
				path: string,
			}
		) -> string)?,
		-- Called once after all pages have been written.
		onBuildComplete: ((result: { moduleCount: number, articleCount: number, outputDir: string }) -> ())?,
	}?,

	-- Build options
	clean: boolean?,
	showLastUpdated: boolean?, -- show "Last updated" date on pages (from git)
}

-- ── Helpers ───────────────────────────────────────────────────────────────

local function parseMeta(path: string): { children: { string }?, title: string? }
	if not fs.isFile(path) then
		return {}
	end
	local content = fs.openSync(path):readSync()
	local ok, data = pcall(yaml.decode, content)
	if not ok or type(data) ~= "table" then
		buildWarnings.warn("Failed to parse .meta at " .. path)
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

-- Collect display titles from .meta files for all directories under `path`.
-- Returns two maps:
--   sectionTitles: top-level folder name → display title (for sidebar section headings)
--   folderTitles:  nested path key → display title (for sub-directory labels)
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
			-- Try several candidate keys that authors might use in .meta:
			-- bare stem, full entry (with extension), and directory index variants.
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
		local stem = fs.path.stem(fullPath)
		local name: string
		if stem == "index" and prefix then
			name = prefix
		else
			name = if prefix then prefix .. "/" .. stem else stem
		end
		log:info(string.format("  article: %s", name))
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
		log:info(string.format("  article: %s (generated)", name))
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

local function writeFileMkdir(path: string, content: string)
	local dir = path:match("^(.+)/[^/]*$")
	if dir then
		fs.mkdir(dir)
	end
	fs.openSync(path, "w"):writeSync(content)
end

local function copyDirRecursive(src: string, dest: string)
	if not fs.isDirectory(src) then
		return
	end
	fs.mkdir(dest)
	for _, entry in fs.listDir(src) do
		local srcPath = src .. "/" .. entry
		local destPath = dest .. "/" .. entry
		if fs.isDirectory(srcPath) then
			copyDirRecursive(srcPath, destPath)
		else
			fs.openSync(destPath, "w"):writeSync(fs.openSync(srcPath):readSync())
		end
	end
end

-- ── Build ─────────────────────────────────────────────────────────────────

local eryxdoc = {}

--[=[
	Runs a full documentation build.

	@param cfg The build configuration.
	@return { warnings: { string }, moduleCount: number, articleCount: number }
]=]
function eryxdoc.build(cfg: Config): { warnings: { string }, moduleCount: number, articleCount: number }
	local BASE_OUTPUT_DIR = cfg.output
	local MODULES_DIR = cfg.modules
	local ARTICLES_DIR = cfg.articles
	local MODULE_PREFIX = cfg.prefix or "@eryx"
	local SITE_ROOT = cfg.siteRoot or "/"
	local EXPORT_MODE: "flat" | "directory" = cfg.exportMode or "directory"
	local SITE_TITLE = cfg.title or "API Docs"
	local THEME_DIR = cfg.theme or (fs.path.join(_DIR, "/theme"))
	local STATIC_DIR = cfg.static
	local NO_MODULES = cfg.noModules or false

	if SITE_ROOT:sub(-1) ~= "/" then
		SITE_ROOT = SITE_ROOT .. "/"
	end

	-- Versioning: output into a subdirectory, adjust siteRoot
	local OUTPUT_DIR = BASE_OUTPUT_DIR
	local versionInfo = cfg.version
	if versionInfo then
		OUTPUT_DIR = BASE_OUTPUT_DIR .. "/" .. versionInfo.name
		SITE_ROOT = SITE_ROOT .. versionInfo.name .. "/"
	end

	local TEMPLATES = {
		article = THEME_DIR .. "/templates/article_page.html",
		api = THEME_DIR .. "/templates/api_page.html",
		index = THEME_DIR .. "/templates/index_page.html",
		notFound = THEME_DIR .. "/templates/404_page.html",
	}
	local STYLE_PATH = THEME_DIR .. "/style.css"

	local hooks = cfg.hooks

	log:info("\n=== Full build ===")

	if hooks and hooks.onBuildStart then
		hooks.onBuildStart(cfg)
	end

	if cfg.clean and fs.isDirectory(OUTPUT_DIR) then
		fs.rmdir(OUTPUT_DIR)
	end
	fs.mkdir(OUTPUT_DIR)

	-- Helper: run onPageRender hook if present
	local function applyPageHook(content: string, kind: string, name: string?, path: string): string
		if hooks and hooks.onPageRender then
			return hooks.onPageRender(content, { kind = kind :: any, name = name, path = path })
		end
		return content
	end

	-- Copy styles
	fs.openSync(OUTPUT_DIR .. "/style.css", "w"):writeSync(fs.openSync(STYLE_PATH):readSync())

	-- Copy static assets
	if STATIC_DIR and fs.isDirectory(STATIC_DIR) then
		log:info(string.format("  Copying static assets from %s", STATIC_DIR))
		copyDirRecursive(STATIC_DIR, OUTPUT_DIR .. "/static")
	end

	-- Collect content
	local allModules = if NO_MODULES or not MODULES_DIR
		then {}
		else modulesApi.collectModules(MODULES_DIR, MODULE_PREFIX, "")
	local allArticles = if ARTICLES_DIR then collectArticles(ARTICLES_DIR) else {}
	local sectionTitles, folderTitles, folderOrder =
		if ARTICLES_DIR then collectFolderTitles(ARTICLES_DIR) else {}, {}, {}

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
				-- Trim whitespace, take just the date portion (YYYY-MM-DD)
				local date = result.stdout:match("(%d%d%d%d%-%d%d%-%d%d)")
				if date then
					articleEntry.article.lastUpdated = date
				end
			end
		end
	end

	-- Copy favicon if configured
	local faviconHref: string? = nil
	if cfg.favicon and fs.isFile(cfg.favicon) then
		local faviconName = cfg.favicon:match("[^/\\]+$") or "favicon.ico"
		fs.openSync(OUTPUT_DIR .. "/" .. faviconName, "w"):writeSync(fs.openSync(cfg.favicon):readSync())
		faviconHref = SITE_ROOT .. faviconName
	end

	local renderer = Renderer.new(SITE_TITLE, SITE_ROOT .. "style.css", TEMPLATES, {
		siteRoot = SITE_ROOT,
		exportMode = EXPORT_MODE,
		modulePrefix = MODULE_PREFIX,
		favicon = faviconHref,
		extraHead = cfg.extraHead,
		extraScripts = cfg.extraScripts,
		announcement = cfg.announcement,
		openGraph = cfg.openGraph,
		articleMetaGenerator = cfg.articleMetaGenerator,
		apiMetaGenerator = cfg.apiMetaGenerator,
		customFilters = cfg.customFilters,
		customGlobals = cfg.customGlobals,
		versionName = if versionInfo then versionInfo.name else nil,
		versionLabel = if versionInfo then (versionInfo.label or versionInfo.name) else nil,
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

	for _, mod in allModules do
		local modPath = renderer:getPath(mod)
		local page = applyPageHook(renderer:renderModule(mod.qualifiedName), "module", mod.qualifiedName, modPath)
		writeFileMkdir(OUTPUT_DIR .. "/" .. modPath, page)

		local jsonContent = renderer:moduleToJSON(mod)
		writeFileMkdir(OUTPUT_DIR .. "/" .. renderer:getJSONPath(mod), jsonContent)
	end

	local hasCustomIndex = false
	local indexPath = renderer:getPath(nil)
	for _, article in allArticles do
		if article.name == "index" then
			hasCustomIndex = true
			local page = applyPageHook(renderer:renderArticle("index"), "article", "index", indexPath)
			writeFileMkdir(OUTPUT_DIR .. "/" .. indexPath, page)
		else
			local articlePath = renderer:getPath(article.article)
			local page = applyPageHook(renderer:renderArticle(article.name), "article", article.name, articlePath)
			writeFileMkdir(OUTPUT_DIR .. "/" .. articlePath, page)
		end
	end
	if not hasCustomIndex then
		local page = applyPageHook(renderer:renderIndex(), "index", nil, indexPath)
		writeFileMkdir(OUTPUT_DIR .. "/" .. indexPath, page)
	end

	-- Generate redirects
	if cfg.redirects then
		for _, redirect in cfg.redirects do
			local redirectHtml = string.format(
				'<!DOCTYPE html><html><head><meta charset="UTF-8">'
					.. '<meta http-equiv="refresh" content="0;url=%s">'
					.. '<link rel="canonical" href="%s">'
					.. '</head><body>Redirecting to <a href="%s">%s</a></body></html>',
				redirect.to,
				redirect.to,
				redirect.to,
				redirect.to
			)
			-- Ensure the path ends with .html or index.html
			local fromPath = redirect.from
			if not fromPath:match("%.html$") then
				if fromPath:sub(-1) ~= "/" then
					fromPath = fromPath .. "/"
				end
				fromPath = fromPath .. "index.html"
			end
			writeFileMkdir(OUTPUT_DIR .. "/" .. fromPath, redirectHtml)
		end
	end

	-- Generate 404 page
	local notFoundPage = renderer:render404()
	if notFoundPage then
		notFoundPage = applyPageHook(notFoundPage, "404", nil, "404.html")
		writeFileMkdir(OUTPUT_DIR .. "/404.html", notFoundPage)
	end

	-- Generate search index
	local searchIndex = renderer:generateSearchIndex()
	writeFileMkdir(OUTPUT_DIR .. "/search.json", searchIndex)

	-- Generate sitemap
	if cfg.baseUrl then
		local sitemap = renderer:generateSitemap(cfg.baseUrl)
		writeFileMkdir(OUTPUT_DIR .. "/sitemap.xml", sitemap)
	end

	-- Versioning: update versions.json manifest and copy default version
	if versionInfo then
		local json = require("@eryx/encoding/json")
		local manifestPath = BASE_OUTPUT_DIR .. "/versions.json"
		local versions: { { name: string, label: string, isDefault: boolean? } } = {}

		-- Load existing manifest
		if fs.isFile(manifestPath) then
			local ok, existing = pcall(function()
				return json.decode(fs.openSync(manifestPath):readSync())
			end)
			if ok and type(existing) == "table" then
				versions = existing :: any
			end
		end

		-- Upsert this version
		local found = false
		for i, v in versions do
			if v.name == versionInfo.name then
				versions[i] = {
					name = versionInfo.name,
					label = versionInfo.label or versionInfo.name,
					isDefault = versionInfo.isDefault,
				}
				found = true
				break
			end
		end
		if not found then
			table.insert(versions, {
				name = versionInfo.name,
				label = versionInfo.label or versionInfo.name,
				isDefault = versionInfo.isDefault,
			})
		end

		writeFileMkdir(manifestPath, json.encode(versions))

		-- If this is the default version, copy it to the output root too
		if versionInfo.isDefault then
			copyDirRecursive(OUTPUT_DIR, BASE_OUTPUT_DIR .. "/_default_staging")
			-- Copy staged files to root (without clobbering version dirs)
			for _, entry in fs.listDir(BASE_OUTPUT_DIR .. "/_default_staging") do
				local src = BASE_OUTPUT_DIR .. "/_default_staging/" .. entry
				local dest = BASE_OUTPUT_DIR .. "/" .. entry
				if fs.isDirectory(src) then
					copyDirRecursive(src, dest)
				else
					fs.openSync(dest, "w"):writeSync(fs.openSync(src):readSync())
				end
			end
			fs.rmdir(BASE_OUTPUT_DIR .. "/_default_staging")
		end
	end

	-- Collect warnings
	local warns = buildWarnings.summary()
	if #warns > 0 then
		log:warning(string.format("\n=== Build warnings (%d) ===", #warns))
		for _, w in warns do
			log:warning("  " .. w)
		end
		log:warning("")
	end
	local result = { warnings = warns, moduleCount = #allModules, articleCount = #allArticles }
	buildWarnings.clear()

	log:info(string.format("=== Built %d modules, %d articles ===\n", #allModules, #allArticles))

	if hooks and hooks.onBuildComplete then
		hooks.onBuildComplete({ moduleCount = #allModules, articleCount = #allArticles, outputDir = OUTPUT_DIR })
	end

	return result
end

function eryxdoc.getDefaultTheme(): string
	return fs.path.join(_DIR, "theme")
end

return eryxdoc
