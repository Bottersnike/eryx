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
local logging = require("@eryx/logging")
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")
local tempfile = require("@eryx/tempfile")

local eryxdoc = require("../src")
local devServer = require("../src/_devServer")

local okEmbedded, embedded = pcall(require, "@eryx/_embedded")
if not okEmbedded then
	embedded = nil
end

local function normalizeSlashes(path: string): string
	return (path:gsub("\\", "/"))
end

local function joinVirtual(base: string, relative: string): string
	return normalizeSlashes(base):gsub("/+$", "") .. "/" .. normalizeSlashes(relative):gsub("^/+", "")
end

local DEFAULT_THEME_FILES = {
	"style.css",
	"eryxdoc-live-reload.js",
	"templates/404_page.html",
	"templates/api_page.html",
	"templates/article_page.html",
	"templates/index_page.html",
	"templates/_footer.html",
	"templates/_header.html",
	"templates/_layout.html",
	"templates/_sidebar.html",
}

local IS_EMBEDDED = embedded ~= nil and embedded.exists(joinVirtual("eryxdoc/theme", DEFAULT_THEME_FILES[1]))

local parser = argparse.Parser.new(
	"eryx doc",
	"Build and serve API documentation",
	"Examples:\n"
		.. "  eryx doc --config eryxdoc.config.luau\n"
		.. "  eryx doc --output build-docs --modules src/modules --articles docs --prefix @mylib\n"
		.. "  eryx doc --dev --output build-docs --modules src/modules\n"
		.. "  eryx doc create-theme ./eryxdoc-theme\n"
		.. "  eryx doc export-json docs.json --modules src/modules --prefix @mylib"
)
local createTheme = parser:addSubCommand("create-theme", "Copy the bundled default theme into a directory")
createTheme:addPositional("directory", "string", nil, true, "Directory to write theme files into")

local exportJson = parser:addSubCommand("export-json", "Export module documentation data as JSON")
exportJson:addPositional("file", "string", nil, true, "JSON file to write")
exportJson:addOption("config", "c", "string", nil, false, "Path to config file (Luau module returning a table)")
exportJson:addOption("modules", "m", "string", nil, false, "Modules source directory")
exportJson:addOption("prefix", nil, "string", nil, false, "Module prefix (e.g. @mylib)")
exportJson:addFlag("pretty", nil, "Pretty-print JSON")
exportJson:addFlag("quiet", "q", "Suppress logging")

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
parser:addFlag("quiet", "q", "Suppress logging")

local args = parser:parse()

local function writeFileMkdir(path: string, content: string)
	local dir = fs.path.dirname(path)
	if dir and dir ~= "." and not fs.isDirectory(dir) then
		fs.mkdir(dir)
	end
	fs.openSync(path, "w"):writeSync(content)
end

local function copyDefaultThemeFiles(outputDir: string): { fileCount: number, output: string }
	if fs.isFile(outputDir) then
		error(string.format("destination is a file: %s", outputDir))
	end

	fs.mkdir(outputDir)
	local defaultThemePath = eryxdoc.getDefaultTheme()
	for _, relativePath in DEFAULT_THEME_FILES do
		local embeddedPath = joinVirtual("eryxdoc/theme", relativePath)
		local content = if IS_EMBEDDED then embedded.read(embeddedPath) else nil
		if content == nil then
			content = fs.openSync(joinVirtual(defaultThemePath, relativePath)):readSync()
		end
		writeFileMkdir(fs.path.join(outputDir, relativePath), content)
	end
	return {
		fileCount = #DEFAULT_THEME_FILES,
		output = outputDir,
	}
end

local function copyDefaultTheme(outputDir: string)
	local ok, result = pcall(copyDefaultThemeFiles, outputDir)
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

local exportJsonArgs = args["export-json"]
if exportJsonArgs then
	for _, key in { "config", "modules", "prefix", "quiet" } do
		if exportJsonArgs[key] ~= nil then
			args[key] = exportJsonArgs[key]
		end
	end
end

local QUIET: boolean = args["quiet"] == true
local exportJsonFile: string? = if exportJsonArgs then exportJsonArgs.file else nil
local EXPORT_TO_STDOUT = exportJsonFile == "-"
if QUIET or EXPORT_TO_STDOUT then
	logging.config({ level = math.huge })
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
		if not QUIET and not EXPORT_TO_STDOUT then
			print(string.format("Loaded config from %s", configPath))
		end
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

local function validateExportConfig(config: eryxdoc.Config): { string }
	local errors: { string } = {}

	if isBlank(config.modules) then
		table.insert(errors, "Missing modules directory. Set `modules` in config or pass --modules <dir>.")
	elseif not fs.isDirectory(config.modules :: string) then
		table.insert(errors, string.format("Modules directory does not exist: %s", config.modules :: string))
	end

	if isBlank(config.prefix) then
		config.prefix = "@eryx"
	end

	return errors
end

if exportJsonArgs then
	local validationErrors = validateExportConfig(cfg)
	if #validationErrors > 0 then
		if not loadedConfigPath then
			stdio.writeerr("eryx doc export-json: no config file found (looked for eryxdoc.config.luau).\n")
		end
		stdio.writeerr("eryx doc export-json: cannot export module documentation:\n")
		for _, message in validationErrors do
			stdio.writeerr("  - " .. message .. "\n")
		end
		stdio.writeerr("\n" .. exportJson:generateHelp() .. "\n")
		os.exit(2)
	end

	local ok, result = pcall(function()
		return eryxdoc.exportModulesJson(
			{ modules = cfg.modules :: string, prefix = cfg.prefix },
			{ pretty = exportJsonArgs.pretty }
		)
	end)
	if not ok then
		stdio.writeerr(string.format("eryx doc export-json: %s\n", tostring(result)))
		os.exit(1)
	end

	if EXPORT_TO_STDOUT then
		stdio.writeSync(result :: string)
	else
		writeFileMkdir(exportJsonArgs.file, result :: string)
		if not QUIET then
			print(string.format("Exported module documentation JSON to %s", exportJsonArgs.file))
		end
	end
	os.exit(0)
end

local tempThemeDir: any? = nil
local function prepareDefaultTheme(config: eryxdoc.Config)
	if config.theme ~= nil and config.theme ~= defaultTheme then
		return
	end

	tempThemeDir = tempfile.openDir("eryxdoc-theme")
	local ok, result = pcall(copyDefaultThemeFiles, tempThemeDir.path)
	if not ok then
		stdio.writeerr(string.format("eryx doc: failed to prepare default theme: %s\n", tostring(result)))
		pcall(function()
			(tempThemeDir :: any):close()
		end)
		os.exit(2)
	end
	config.theme = tempThemeDir.path
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

if IS_EMBEDDED then
	prepareDefaultTheme(cfg)
end

if IS_DEV then
	local ok, devOrErr = pcall(devServer.start, cfg, HOST, PORT)
	if not ok then
		if tempThemeDir then
			tempThemeDir:close()
		end
		error(devOrErr)
	end
	local dev = devOrErr

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
	local ok, result = pcall(eryxdoc.build, cfg)
	if tempThemeDir then
		tempThemeDir:close()
	end
	if not ok then
		error(result)
	end
	print("Build complete.")
end
