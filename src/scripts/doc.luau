--[[
	Documentation generator CLI with optional live-reload dev server.

	Usage:
	  eryx eryxdoc/main.luau [options]             -- build + watch + serve
	  eryx eryxdoc/main.luau --no-serve            -- build + watch only
	  eryx eryxdoc/main.luau --no-watch --no-serve -- one-shot build

	Run with --help for full option list.

	For programmatic usage, require("./eryxdoc") instead — it exposes the
	build engine as a module you can call from your own scripts.
]]

local fs = require("@eryx/fs")
local argparse = require("@eryx/argparse")
local fsWatch = require("@eryx/fs_watch")

local eryxdoc = require("@eryx/eryxdoc")
local devServer = require("@eryx/eryxdoc/_devServer")

local parser = argparse.Parser.new("eryxdoc", "Build and serve API documentation")
parser:addOption("config", "c", "string", nil, false, "Path to config file (Luau module returning a table)")
parser:addOption("port", "p", "number", nil, false, "Port for the dev server")
parser:addOption("host", nil, "string", nil, false, "Hostname to bind the dev server to")
parser:addOption("output", "o", "string", nil, false, "Output directory")
parser:addOption("modules", "m", "string", nil, false, "Modules source directory")
parser:addOption("articles", nil, "string", nil, false, "Articles directory")
parser:addOption("site-root", nil, "string", nil, false, "Site root path prefix for links")
parser:addOption("export-mode", nil, "string", nil, false, "Export mode: 'flat' or 'directory'")
parser:addOption("prefix", nil, "string", nil, false, "Module prefix (e.g. @mylib)")
parser:addOption("title", nil, "string", nil, false, "Site title")
parser:addOption(
	"theme",
	nil,
	"string",
	nil,
	false,
	"Path to custom theme directory (must contain templates/ and style.css)"
)
parser:addOption("static", nil, "string", nil, false, "Static assets directory to copy into output")
parser:addOption("base-url", nil, "string", nil, false, "Absolute base URL for sitemap (e.g. https://docs.example.com)")
parser:addOption("version", nil, "string", nil, false, "Version name for versioned builds (e.g. v2.0, latest)")
parser:addOption("version-label", nil, "string", nil, false, "Display label for the version (defaults to version name)")
parser:addFlag("version-default", nil, "Mark this version as the default (copies to output root)")
parser:addFlag("dev", nil, "Run a local dev server, rather than running a build")
parser:addFlag("no-modules", nil, "Skip module scanning (articles-only mode)")
parser:addFlag("clean", nil, "Wipe the output directory before building")
parser:addFlag("last-updated", nil, "Show last-updated dates on articles (from git)")

local args = parser:parse()

-- ── Config file ───────────────────────────────────────────────────────────

local fileConfig: eryxdoc.Config = {} :: any
local configPath: string? = args["config"]
if not configPath and fs.isFile("eryxdoc.config.luau") then
	configPath = "eryxdoc.config.luau"
end
if configPath then
	local luau = require("@eryx/luau")
	local ok, result = pcall(function()
		local fn = luau.load(fs.openSync(configPath :: string):readSync(), `={configPath}`)
		return fn()
	end)
	if ok and type(result) == "table" then
		fileConfig = result :: eryxdoc.Config
		print(string.format("Loaded config from %s", configPath))
	elseif not ok then
		error(string.format("Failed to load config file %s: %s", configPath :: string, tostring(result)))
	end
end

-- ── Merge: CLI flags > config file > defaults ─────────────────────────────

local function resolve(cliKey: string, configVal: any): any
	if args[cliKey] ~= nil then
		return args[cliKey]
	end
	return configVal
end

local cfg: eryxdoc.Config = {
	output = resolve("output", fileConfig.output),
	modules = resolve("modules", fileConfig.modules),
	articles = resolve("articles", fileConfig.articles),
	prefix = resolve("prefix", fileConfig.prefix),
	title = resolve("title", fileConfig.title),
	siteRoot = resolve("site-root", fileConfig.siteRoot),
	exportMode = resolve("export-mode", fileConfig.exportMode),
	theme = resolve("theme", fileConfig.theme) or eryxdoc.getDefaultTheme(),
	static = resolve("static", fileConfig.static),
	noModules = args["no-modules"] or fileConfig.noModules,
	clean = args["clean"] or fileConfig.clean,
	showLastUpdated = args["last-updated"] or (fileConfig :: any).showLastUpdated,
	baseUrl = resolve("base-url", fileConfig.baseUrl),
	version = if args["version"]
		then {
			name = args["version"] :: string,
			label = (args["version-label"] or args["version"]) :: string?,
			isDefault = if args["version-default"] then true else nil,
		}
		elseif (fileConfig :: any).version then (fileConfig :: any).version
		else nil,
	favicon = fileConfig.favicon,
	extraHead = fileConfig.extraHead,
	extraScripts = fileConfig.extraScripts,
}

local IS_DEV: boolean = if args["dev"] ~= nil then not not args["dev"] else false
local PORT: number = resolve("port", (fileConfig :: any).port) or 8080
local HOST: string = resolve("host", (fileConfig :: any).host) or "0.0.0.0"

-- ── Dev mode ──────────────────────────────────────────────────────────────

if IS_DEV then
	local dev = devServer.start(cfg, HOST, PORT)

	if not cfg.noModules and cfg.modules then
		local moduleWatcher = fsWatch.watchDir(cfg.modules, { recursive = true, debounce = 0.1 })
		print(string.format("Watching %s for changes...", cfg.modules))

		moduleWatcher.changed:connect(function(filename: string, eventType: string)
			if not filename:match("%.luau$") or filename:match("%.test%.luau$") then
				return
			end
			print(string.format("[watch] Module changed: %s — refreshing", filename))
			dev.refresh()
		end)
	end

	if cfg.articles and fs.isDirectory(cfg.articles) then
		local articleWatcher = fsWatch.watchDir(cfg.articles, { recursive = true, debounce = 0.1 })
		print(string.format("Watching %s for article changes...", cfg.articles))

		articleWatcher.changed:connect(function(filename: string, eventType: string)
			if not filename:match("%.md$") and not filename:match("%.txt$") then
				return
			end
			print(string.format("[watch] Article changed: %s — refreshing", filename))
			dev.refresh()
		end)
	end
else
	-- ── Build ─────────────────────────────────────────────────────────────
	eryxdoc.build(cfg)
	print("Build complete.")
end
