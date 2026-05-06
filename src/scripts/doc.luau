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
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")

local eryxdoc = require("@eryx/eryxdoc")
local devServer = require("@eryx/eryxdoc/_devServer")

local parser = argparse.Parser.new(
	"eryx doc",
	"Build and serve API documentation",
	"Examples:\n"
		.. "  eryx doc --config eryxdoc.config.luau\n"
		.. "  eryx doc --output build-docs --modules src/modules --articles docs --prefix @mylib\n"
		.. "  eryx doc --dev --output build-docs --modules src/modules\n"
		.. "  eryx doc create-theme ./eryxdoc-theme"
)
local createTheme = parser:addSubCommand("create-theme", "Copy the bundled default theme into a directory")
createTheme:addPositional("directory", "string", nil, true, "Directory to write theme files into")

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
parser:addOption("static-mount", nil, "string", nil, false, "Site-relative mount path for static assets")
parser:addOption("base-url", nil, "string", nil, false, "Absolute base URL for sitemap (e.g. https://docs.example.com)")
parser:addOption("version", nil, "string", nil, false, "Version name for versioned builds (e.g. v2.0, latest)")
parser:addOption("version-label", nil, "string", nil, false, "Display label for the version (defaults to version name)")
parser:addFlag("version-default", nil, "Mark this version as the default (copies to output root)")
parser:addFlag("dev", nil, "Run a local dev server, rather than running a build")
parser:addFlag("no-modules", nil, "Skip module scanning (articles-only mode)")
parser:addFlag("clean", nil, "Wipe the output directory before building")
parser:addFlag("last-updated", nil, "Show last-updated dates on articles (from git)")

local args = parser:parse()

local function copyDefaultTheme(outputDir: string)
	local ok, result = pcall(eryxdoc.copyDefaultTheme, outputDir)
	if not ok then
		stdio.writeerr(string.format("eryx doc create-theme: %s\n", tostring(result)))
		os.exit(2)
	end

	print(string.format("Default theme copied to %s", result.output))
end

if args["create-theme"] then
	copyDefaultTheme(args["create-theme"].directory)
	os.exit(0)
end

-- ── Config file ───────────────────────────────────────────────────────────

local fileConfig: eryxdoc.Config = {} :: any
local configPath: string? = args["config"]
local loadedConfigPath: string? = nil
if not configPath and fs.isFile("eryxdoc.config.luau") then
	configPath = "eryxdoc.config.luau"
end
if configPath then
	if not fs.isFile(configPath :: string) then
		stdio.writeerr(string.format("eryx doc: config file not found: %s\n", configPath :: string))
		os.exit(2)
	end

	local luau = require("@eryx/luau/vm")
	local ok, result = pcall(function()
		local fn = luau.load(fs.openSync(configPath :: string):readSync(), `={configPath}`)
		return fn()
	end)
	if ok and type(result) == "table" then
		fileConfig = result :: eryxdoc.Config
		loadedConfigPath = configPath
		print(string.format("Loaded config from %s", configPath))
	elseif not ok then
		stdio.writeerr(
			string.format("eryx doc: failed to load config file %s: %s\n", configPath :: string, tostring(result))
		)
		os.exit(2)
	else
		stdio.writeerr(string.format("eryx doc: config file %s must return a table\n", configPath :: string))
		os.exit(2)
	end
end

-- ── Merge: CLI flags > config file > defaults ─────────────────────────────

local function resolve(cliKey: string, configVal: any): any
	if args[cliKey] ~= nil then
		return args[cliKey]
	end
	return configVal
end

local defaultTheme = eryxdoc.getDefaultTheme()
local resolvedTheme = resolve("theme", fileConfig.theme)

local cfg: eryxdoc.Config = {
	output = resolve("output", fileConfig.output),
	modules = resolve("modules", fileConfig.modules),
	articles = resolve("articles", fileConfig.articles),
	prefix = resolve("prefix", fileConfig.prefix),
	title = resolve("title", fileConfig.title),
	siteRoot = resolve("site-root", fileConfig.siteRoot),
	exportMode = resolve("export-mode", fileConfig.exportMode),
	theme = resolvedTheme,
	static = resolve("static", fileConfig.static),
	staticMount = resolve("static-mount", fileConfig.staticMount),
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
	head = fileConfig.head,
	extraHead = fileConfig.extraHead,
	extraScripts = fileConfig.extraScripts,
}

local IS_DEV: boolean = if args["dev"] ~= nil then not not args["dev"] else false
local PORT: number = resolve("port", (fileConfig :: any).port) or 8080
local HOST: string = resolve("host", (fileConfig :: any).host) or "0.0.0.0"

local function isBlank(value: any): boolean
	return type(value) ~= "string" or value == ""
end

local function validateConfig(config: eryxdoc.Config): { string }
	local errors: { string } = {}

	if isBlank(config.output) then
		table.insert(
			errors,
			"Missing required output directory. Set `output` in eryxdoc.config.luau or pass --output <dir>."
		)
	end

	if config.exportMode ~= nil and config.exportMode ~= "flat" and config.exportMode ~= "directory" then
		table.insert(errors, "Invalid export mode. Use --export-mode flat or --export-mode directory.")
	end

	local version = (config :: any).version
	if version ~= nil and (type(version) ~= "table" or isBlank(version.name)) then
		table.insert(errors, "Versioned builds require a non-empty version name.")
	end

	if config.theme ~= nil and config.theme ~= defaultTheme then
		if isBlank(config.theme) then
			table.insert(errors, "Theme directory must be a non-empty string.")
		elseif not fs.isDirectory(config.theme) then
			table.insert(errors, string.format("Theme directory does not exist: %s", config.theme))
		else
			if not fs.isDirectory(config.theme .. "/templates") then
				table.insert(errors, string.format("Theme directory is missing templates/: %s", config.theme))
			end
			if not fs.isFile(config.theme .. "/style.css") then
				table.insert(errors, string.format("Theme directory is missing style.css: %s", config.theme))
			end
		end
	end

	if config.static ~= nil and isBlank(config.static) then
		table.insert(errors, "Static assets directory must be a non-empty string.")
	elseif config.static ~= nil and not fs.isDirectory(config.static) then
		table.insert(errors, string.format("Static assets directory does not exist: %s", config.static))
	end

	local hasModules = not isBlank(config.modules)
	local hasArticles = not isBlank(config.articles)
	if not hasModules and not hasArticles then
		table.insert(
			errors,
			"Missing documentation sources. Set `modules` and/or `articles` in eryxdoc.config.luau, or pass --modules <dir> and/or --articles <dir>."
		)
	end

	if config.noModules and not hasArticles then
		table.insert(
			errors,
			"Articles-only mode requires an articles directory. Set `articles` or pass --articles <dir>."
		)
	end

	if hasModules and not config.noModules and not fs.isDirectory(config.modules :: string) then
		table.insert(errors, string.format("Modules directory does not exist: %s", config.modules :: string))
	end

	if hasArticles and not fs.isDirectory(config.articles :: string) then
		table.insert(errors, string.format("Articles directory does not exist: %s", config.articles :: string))
	end

	return errors
end

local validationErrors = validateConfig(cfg)
if #validationErrors > 0 then
	if not loadedConfigPath then
		stdio.writeerr("eryx doc: no config file found (looked for eryxdoc.config.luau).\n")
	end
	stdio.writeerr("eryx doc: cannot build documentation:\n")
	for _, message in validationErrors do
		stdio.writeerr("  - " .. message .. "\n")
	end
	stdio.writeerr("\n" .. parser:generateHelp() .. "\n")
	os.exit(2)
end

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
