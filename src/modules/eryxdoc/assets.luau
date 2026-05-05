local fs = require("@eryx/fs")
local pathlib = require("@eryx/path")

local assets = {}

local function normalizeWebPath(path: string): string
	return (path:gsub("\\", "/"))
end

local function splitUrl(url: string): (string, string)
	local pathPart, suffix = url:match("^([^?#]*)(.*)$")
	return pathPart or url, suffix or ""
end

local function isLocalUrl(pathPart: string): boolean
	if pathPart == "" or pathPart:sub(1, 1) == "#" or pathPart:sub(1, 1) == "/" then
		return false
	end
	if pathPart:sub(1, 2) == "//" then
		return false
	end
	return pathPart:match("^[%a][%w+.-]*:") == nil
end

local function isArticlePath(pathPart: string): boolean
	local lower = pathPart:lower()
	return lower:match("%.md$") ~= nil or lower:match("%.txt$") ~= nil
end

local function startsWithPath(path: string, prefix: string): boolean
	if path == prefix then
		return true
	end
	if #path <= #prefix then
		return false
	end
	local nextChar = path:sub(#prefix + 1, #prefix + 1)
	return path:sub(1, #prefix) == prefix and (nextChar == "/" or nextChar == "\\")
end

function assets.resolveArticleAsset(
	articlesRoot: string?,
	sourceFilename: string?,
	url: string
): { sourcePath: string, sitePath: string, suffix: string }?
	if not articlesRoot or not sourceFilename then
		return nil
	end

	local pathPart, suffix = splitUrl(url)
	if not isLocalUrl(pathPart) or isArticlePath(pathPart) then
		return nil
	end

	local sourceDir = pathlib.dirname(sourceFilename)
	if not sourceDir then
		return nil
	end

	local candidate = tostring(pathlib.join(sourceDir, pathPart):normalizeDots())
	if not fs.isFile(candidate) then
		return nil
	end

	local canonicalRoot = tostring(pathlib.canonicalize(articlesRoot))
	local canonicalSource = tostring(pathlib.canonicalize(candidate))
	if not startsWithPath(canonicalSource, canonicalRoot) then
		return nil
	end

	local relPath = pathlib.canonicalize(candidate):relativeTo(pathlib.canonicalize(articlesRoot))
	if not relPath then
		return nil
	end

	local rel = normalizeWebPath(tostring(relPath))
	if rel == ".." or rel:sub(1, 3) == "../" then
		return nil
	end

	return {
		sourcePath = candidate,
		sitePath = "assets/" .. rel,
		suffix = suffix,
	}
end

function assets.rewriteArticleAssetUrl(
	articlesRoot: string?,
	sourceFilename: string?,
	siteRoot: string,
	url: string
): string
	local resolved = assets.resolveArticleAsset(articlesRoot, sourceFilename, url)
	if not resolved then
		return url
	end
	return siteRoot .. resolved.sitePath .. resolved.suffix
end

function assets.copyArticleAsset(articlesRoot: string?, sourceFilename: string?, outputDir: string, url: string): string
	local resolved = assets.resolveArticleAsset(articlesRoot, sourceFilename, url)
	if not resolved then
		return url
	end

	local destPath = outputDir .. "/" .. resolved.sitePath
	local destDir = destPath:match("^(.+)/[^/]*$")
	if destDir then
		fs.mkdir(destDir)
	end
	fs.copy(resolved.sourcePath, destPath)

	return url
end

return table.freeze(assets)
