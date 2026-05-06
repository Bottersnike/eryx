local fs = require("@eryx/fs")

local okEmbedded, embedded = pcall(require, "@eryx/_embedded")
if not okEmbedded then
	embedded = nil
end

local resources = {}

resources.DEFAULT_THEME_FILES = {
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

local function normalizeSlashes(path: string): string
	return path:gsub("\\", "/")
end

local function joinVirtual(base: string, relative: string): string
	return normalizeSlashes(base):gsub("/+$", "") .. "/" .. normalizeSlashes(relative):gsub("^/+", "")
end

local function writeFileMkdir(path: string, content: string)
	local dir = path:match("^(.+)/[^/]*$") or path:match("^(.*)\\[^\\]*$")
	if dir then
		fs.mkdir(dir)
	end
	fs.openSync(path, "w"):writeSync(content)
end

function resources.getDefaultThemePath(): string
	return normalizeSlashes(_DIR):gsub("/+$", "") .. "/theme"
end

function resources.readEmbedded(path: string): string?
	if not embedded then
		return nil
	end
	return embedded.read(path)
end

function resources.readDefaultThemeFile(relativePath: string): string
	local embeddedContent = resources.readEmbedded(joinVirtual("eryxdoc/theme", relativePath))
	if embeddedContent ~= nil then
		return embeddedContent
	end

	return fs.openSync(joinVirtual(resources.getDefaultThemePath(), relativePath)):readSync()
end

function resources.copyDefaultTheme(outputDir: string)
	if fs.isFile(outputDir) then
		error(string.format("destination is a file: %s", outputDir))
	end

	fs.mkdir(outputDir)
	for _, relativePath in resources.DEFAULT_THEME_FILES do
		writeFileMkdir(fs.path.join(outputDir, relativePath), resources.readDefaultThemeFile(relativePath))
	end

	return {
		fileCount = #resources.DEFAULT_THEME_FILES,
		output = outputDir,
	}
end

return table.freeze(resources)
