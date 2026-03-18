local fs = require("@eryx/fs")
local mime = {}

local EXTENSIONS: { [string]: string } = {
	-- Web documents and markup
	["html"] = "text/html; charset=utf-8",
	["htm"] = "text/html; charset=utf-8",
	["css"] = "text/css; charset=utf-8",
	["js"] = "application/javascript; charset=utf-8",
	["mjs"] = "application/javascript; charset=utf-8",
	["cjs"] = "application/javascript; charset=utf-8",
	["ts"] = "text/plain; charset=utf-8",
	["tsx"] = "text/plain; charset=utf-8",
	["jsx"] = "text/plain; charset=utf-8",
	["json"] = "application/json; charset=utf-8",
	["jsonld"] = "application/ld+json; charset=utf-8",
	["webmanifest"] = "application/manifest+json",
	["map"] = "application/json; charset=utf-8",
	["xml"] = "application/xml; charset=utf-8",
	["xhtml"] = "application/xhtml+xml; charset=utf-8",
	["mathml"] = "application/mathml+xml; charset=utf-8",
	["rss"] = "application/rss+xml; charset=utf-8",
	["atom"] = "application/atom+xml; charset=utf-8",
	["txt"] = "text/plain; charset=utf-8",
	["md"] = "text/markdown; charset=utf-8",
	["markdown"] = "text/markdown; charset=utf-8",
	["csv"] = "text/csv; charset=utf-8",
	["tsv"] = "text/tab-separated-values; charset=utf-8",
	["yaml"] = "application/yaml; charset=utf-8",
	["yml"] = "application/yaml; charset=utf-8",
	["ini"] = "text/plain; charset=utf-8",
	["conf"] = "text/plain; charset=utf-8",
	["log"] = "text/plain; charset=utf-8",

	-- Images
	["svg"] = "image/svg+xml",
	["svgz"] = "image/svg+xml",
	["png"] = "image/png",
	["apng"] = "image/apng",
	["jpg"] = "image/jpeg",
	["jpeg"] = "image/jpeg",
	["gif"] = "image/gif",
	["ico"] = "image/x-icon",
	["webp"] = "image/webp",
	["avif"] = "image/avif",
	["bmp"] = "image/bmp",
	["tif"] = "image/tiff",
	["tiff"] = "image/tiff",
	["heic"] = "image/heic",
	["heif"] = "image/heif",

	-- Fonts
	["woff"] = "font/woff",
	["woff2"] = "font/woff2",
	["ttf"] = "font/ttf",
	["otf"] = "font/otf",
	["eot"] = "application/vnd.ms-fontobject",
	["sfnt"] = "font/sfnt",

	-- Audio
	["mp3"] = "audio/mpeg",
	["m4a"] = "audio/mp4",
	["aac"] = "audio/aac",
	["wav"] = "audio/wav",
	["ogg"] = "audio/ogg",
	["oga"] = "audio/ogg",
	["opus"] = "audio/opus",
	["flac"] = "audio/flac",
	["weba"] = "audio/webm",

	-- Video
	["mp4"] = "video/mp4",
	["m4v"] = "video/mp4",
	["mpeg"] = "video/mpeg",
	["mpg"] = "video/mpeg",
	["webm"] = "video/webm",
	["ogv"] = "video/ogg",
	["mov"] = "video/quicktime",
	["avi"] = "video/x-msvideo",
	["mkv"] = "video/x-matroska",
	["3gp"] = "video/3gpp",
	["3g2"] = "video/3gpp2",

	-- Binary web payloads
	["wasm"] = "application/wasm",
	["pdf"] = "application/pdf",
	["rtf"] = "application/rtf",

	-- Archives and compressed files
	["zip"] = "application/zip",
	["tar"] = "application/x-tar",
	["gz"] = "application/gzip",
	["tgz"] = "application/gzip",
	["bz"] = "application/x-bzip",
	["bz2"] = "application/x-bzip2",
	["xz"] = "application/x-xz",
	["zst"] = "application/zstd",
	["7z"] = "application/x-7z-compressed",
	["rar"] = "application/vnd.rar",
	["br"] = "application/brotli",

	-- Office and common document formats
	["doc"] = "application/msword",
	["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	["xls"] = "application/vnd.ms-excel",
	["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	["ppt"] = "application/vnd.ms-powerpoint",
	["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	["odt"] = "application/vnd.oasis.opendocument.text",
	["ods"] = "application/vnd.oasis.opendocument.spreadsheet",
	["odp"] = "application/vnd.oasis.opendocument.presentation",
	["epub"] = "application/epub+zip",

	-- Certificates and keys
	["pem"] = "application/x-pem-file",
	["crt"] = "application/x-x509-ca-cert",
	["cer"] = "application/pkix-cert",
	["der"] = "application/x-x509-ca-cert",
	["key"] = "application/octet-stream",
	["p12"] = "application/x-pkcs12",
	["pfx"] = "application/x-pkcs12",
}

function mime.fromExtension(extension: string): string?
	return EXTENSIONS[extension]
end

local function startsWithBytes(data: string, signature: { number }, offset: number?): boolean
	local base = (offset or 0)
	if #data < base + #signature then
		return false
	end

	for i = 1, #signature do
		local b = string.byte(data, base + i)
		if b ~= signature[i] then
			return false
		end
	end

	return true
end

local function startsWithString(data: string, signature: string, offset: number?): boolean
	local base = (offset or 0)
	local sigLen = #signature
	if #data < base + sigLen then
		return false
	end

	return string.sub(data, base + 1, base + sigLen) == signature
end

local function toLowerPrefix(data: string, maxLen: number): string
	if #data == 0 then
		return ""
	end

	local n = math.min(#data, maxLen)
	return string.lower(string.sub(data, 1, n))
end

local function isLikelyText(data: string): boolean
	if #data == 0 then
		return false
	end

	local sampleSize = math.min(#data, 512)
	local printable = 0
	local disallowed = 0

	for i = 1, sampleSize do
		local b = string.byte(data, i) :: number
		if b == 0 then
			return false
		end

		if b == 9 or b == 10 or b == 13 or (b >= 32 and b <= 126) then
			printable += 1
		elseif b >= 128 then
			printable += 1
		else
			disallowed += 1
		end
	end

	return disallowed <= (sampleSize * 0.15) and printable > 0
end

function mime.fromFileContent(file: string | buffer): string?
	local data: string
	local filePath: string?

	if type(file) == "buffer" then
		data = buffer.tostring(file)
	else
		filePath = file
		local ok, result = pcall(function()
			return buffer.fromstring(fs.readFile(file))
		end)
		if ok and type(result) == "string" then
			data = result
		else
			-- Fallback: treat string input as raw bytes when it isn't a readable path.
			data = file
			filePath = nil
		end
	end

	local len = #data
	if len == 0 then
		if filePath then
			local ext = fs.extension(filePath)
			if ext then
				return mime.fromExtension(ext)
			end
		end
		return "application/octet-stream"
	end

	-- Images
	if startsWithBytes(data, { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }) then
		return "image/png"
	end
	if startsWithBytes(data, { 0xFF, 0xD8, 0xFF }) then
		return "image/jpeg"
	end
	if startsWithString(data, "GIF87a") or startsWithString(data, "GIF89a") then
		return "image/gif"
	end
	if startsWithString(data, "BM") then
		return "image/bmp"
	end
	if startsWithBytes(data, { 0x00, 0x00, 0x01, 0x00 }) or startsWithBytes(data, { 0x00, 0x00, 0x02, 0x00 }) then
		return "image/x-icon"
	end
	if startsWithString(data, "RIFF") and startsWithString(data, "WEBP", 8) then
		return "image/webp"
	end
	if startsWithBytes(data, { 0x49, 0x49, 0x2A, 0x00 }) or startsWithBytes(data, { 0x4D, 0x4D, 0x00, 0x2A }) then
		return "image/tiff"
	end

	-- Fonts
	if startsWithString(data, "wOFF") then
		return "font/woff"
	end
	if startsWithString(data, "wOF2") then
		return "font/woff2"
	end
	if startsWithBytes(data, { 0x00, 0x01, 0x00, 0x00 }) then
		return "font/ttf"
	end
	if startsWithString(data, "OTTO") then
		return "font/otf"
	end

	-- Web/binary payloads and documents
	if startsWithBytes(data, { 0x00, 0x61, 0x73, 0x6D }) then
		return "application/wasm"
	end
	if startsWithString(data, "%PDF-") then
		return "application/pdf"
	end
	if startsWithString(data, "{\\rtf") then
		return "application/rtf"
	end

	-- Compressed/archive/container formats
	if startsWithString(data, "PK") then
		return "application/zip"
	end
	if startsWithBytes(data, { 0x1F, 0x8B, 0x08 }) then
		return "application/gzip"
	end
	if startsWithString(data, "BZh") then
		return "application/x-bzip2"
	end
	if startsWithBytes(data, { 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 }) then
		return "application/x-xz"
	end
	if startsWithBytes(data, { 0x28, 0xB5, 0x2F, 0xFD }) then
		return "application/zstd"
	end
	if startsWithBytes(data, { 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C }) then
		return "application/x-7z-compressed"
	end
	if
		startsWithBytes(data, { 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 })
		or startsWithBytes(data, { 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 })
	then
		return "application/vnd.rar"
	end
	if len >= 262 and startsWithString(data, "ustar", 257) then
		return "application/x-tar"
	end

	-- Executable/library formats
	if startsWithBytes(data, { 0x7F, 0x45, 0x4C, 0x46 }) then
		return "application/x-elf"
	end

	-- Media formats
	if startsWithString(data, "fLaC") then
		return "audio/flac"
	end
	if startsWithString(data, "OggS") then
		if string.find(data, "OpusHead", 1, true) then
			return "audio/opus"
		end
		if string.find(data, "theora", 1, true) then
			return "video/ogg"
		end
		return "audio/ogg"
	end
	if startsWithString(data, "RIFF") and startsWithString(data, "WAVE", 8) then
		return "audio/wav"
	end
	if startsWithString(data, "FORM") and (startsWithString(data, "AIFF", 8) or startsWithString(data, "AIFC", 8)) then
		return "audio/aiff"
	end
	if startsWithString(data, "MThd") then
		return "audio/midi"
	end
	if startsWithString(data, "ID3") then
		return "audio/mpeg"
	end
	if len >= 2 then
		local b1 = string.byte(data, 1) :: number
		local b2 = string.byte(data, 2) :: number
		if b1 == 0xFF and bit32.band(b2, 0xE0) == 0xE0 then
			return "audio/mpeg"
		end
		if b1 == 0xFF and bit32.band(b2, 0xF6) == 0xF0 then
			return "audio/aac"
		end
	end
	if startsWithString(data, "RIFF") and startsWithString(data, "AVI ", 8) then
		return "video/x-msvideo"
	end
	if startsWithBytes(data, { 0x1A, 0x45, 0xDF, 0xA3 }) then
		return "video/x-matroska"
	end

	-- ISO BMFF family: MP4/QuickTime/HEIF/AVIF/3GPP
	if len >= 12 and startsWithString(data, "ftyp", 4) then
		local brand = string.sub(data, 9, 12)
		if brand == "avif" or brand == "avis" then
			return "image/avif"
		end
		if brand == "heic" or brand == "heix" or brand == "hevc" or brand == "hevx" then
			return "image/heic"
		end
		if brand == "mif1" or brand == "msf1" then
			return "image/heif"
		end
		if string.sub(brand, 1, 3) == "3gp" then
			return "video/3gpp"
		end
		if string.sub(brand, 1, 3) == "3g2" then
			return "video/3gpp2"
		end
		if brand == "qt  " then
			return "video/quicktime"
		end
		if brand == "M4A " then
			return "audio/mp4"
		end
		if
			brand == "M4V "
			or brand == "isom"
			or brand == "iso2"
			or brand == "mp41"
			or brand == "mp42"
			or brand == "avc1"
		then
			return "video/mp4"
		end
		return "video/mp4"
	end

	-- Text-oriented sniffing
	local lowerPrefix = toLowerPrefix(data, 2048)
	local trimmed = string.match(lowerPrefix, "^%s*(.-)%s*$") or lowerPrefix

	if startsWithString(trimmed, "<!doctype html") or startsWithString(trimmed, "<html") then
		return "text/html; charset=utf-8"
	end
	if startsWithString(trimmed, "<?xml") then
		return "application/xml; charset=utf-8"
	end
	if startsWithString(trimmed, "<svg") then
		return "image/svg+xml"
	end
	if startsWithString(trimmed, "<rss") then
		return "application/rss+xml; charset=utf-8"
	end
	if startsWithString(trimmed, "<feed") and string.find(trimmed, "http://www.w3.org/2005/atom", 1, true) then
		return "application/atom+xml; charset=utf-8"
	end
	if startsWithString(trimmed, "{") or startsWithString(trimmed, "[") then
		return "application/json; charset=utf-8"
	end

	if isLikelyText(data) then
		return "text/plain; charset=utf-8"
	end

	if filePath then
		local ext = fs.extension(filePath)
		if ext then
			local fromExt = mime.fromExtension(ext)
			if fromExt then
				return fromExt
			end
		end
	end

	return "application/octet-stream"
end

function mime.fileMatchesMime(file: string | buffer, validateMime: string): boolean
	return mime.fromFileContent(file) == validateMime
end

return mime
