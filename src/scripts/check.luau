local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local luau = require("@eryx/luau")
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")

local parser = argparse.Parser.new("eryx check", "Type-check + lint Luau files")
parser:addPositional("path", "string", nil, true, "File or directory to test")
print("hi")

local args = parser:parse()
local path = fs.path.canonicalize(args.path)

local function readFile(filePath)
	return fs.openSync(filePath):readSync()
end

local function splitLines(source)
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	if #lines == 0 then
		table.insert(lines, "")
	end
	return lines
end

local function digits(n)
	local d = 1
	while n >= 10 do
		d = d + 1
		n = math.floor(n / 10)
	end
	return d
end

local function clamp(n, lo, hi)
	return math.max(lo, math.min(hi, n))
end

local function spaces(count)
	return string.rep(" ", math.max(0, count))
end

local function tildes(count)
	return string.rep("~", math.max(0, count))
end

local function makeUnderline(lineText, lineNo, loc)
	local startLine = loc.start.line
	local endLine = loc["end"].line
	local startCol = loc.start.column
	local endCol = loc["end"].column
	local lineLen = #lineText

	local fromCol = 1
	local toCol = lineLen + 1

	if startLine == endLine then
		fromCol = clamp(startCol, 1, lineLen + 1)
		toCol = clamp(endCol, 1, lineLen + 1)
		if toCol <= fromCol then
			toCol = fromCol + 1
		end
	elseif lineNo == startLine then
		fromCol = clamp(startCol, 1, lineLen + 1)
		toCol = lineLen + 1
	elseif lineNo == endLine then
		fromCol = 1
		toCol = clamp(endCol, 1, lineLen + 1)
		if toCol <= fromCol then
			toCol = fromCol + 1
		end
	else
		fromCol = 1
		toCol = lineLen + 1
	end

	local waveCount = math.max(1, toCol - fromCol - 1)
	return spaces(fromCol - 1) .. "^" .. tildes(waveCount)
end

local function printDiagnosticFrame(filePath, sourceLines, d)
	local loc = d.location
	local startLine = clamp(loc.start.line, 1, #sourceLines)
	local endLine = clamp(loc["end"].line, startLine, #sourceLines)
	local contextStart = clamp(startLine - 1, 1, #sourceLines)
	local contextEnd = clamp(endLine + 1, 1, #sourceLines)
	local width = digits(contextEnd)
	local codePart = ""
	if d.code then
		codePart = "[" .. tostring(d.code) .. "]"
	end

	stdio.write(
		"\n"
			.. filePath
			.. ":"
			.. tostring(loc.start.line)
			.. ":"
			.. tostring(loc.start.column)
			.. ": "
			.. d.severity
			.. codePart
			.. ": "
			.. d.message
			.. "\n"
	)
	stdio.write(spaces(width) .. " |\n")
	for lineNo = contextStart, contextEnd do
		local text = sourceLines[lineNo] or ""
		local lineLabel = string.format("%" .. tostring(width) .. "d", lineNo)
		stdio.write(lineLabel .. " | " .. text .. "\n")
		if lineNo >= startLine and lineNo <= endLine then
			local underline = makeUnderline(text, lineNo, loc)
			stdio.write(spaces(width) .. " | " .. underline .. "\n")
		end
	end
end

local function collectDiagnostics(result)
	local out = {}

	for _, e in result.errors do
		table.insert(out, {
			severity = "error",
			kind = tostring(e.category),
			code = tostring(e.category),
			message = e.message,
			location = e.location,
		})
	end

	if result.lints and result.lints.all then
		for _, l in result.lints.all do
			table.insert(out, {
				severity = l.severity,
				kind = "Lint",
				code = l.name,
				message = l.message,
				location = l.location,
			})
		end
	end

	table.sort(out, function(a, b)
		if a.location.start.line ~= b.location.start.line then
			return a.location.start.line < b.location.start.line
		end
		if a.location.start.column ~= b.location.start.column then
			return a.location.start.column < b.location.start.column
		end
		return a.message < b.message
	end)

	return out
end

local function checkFile(filePath)
	local source = readFile(filePath)
	local _start = os.clock()
	local result = luau.check(source, {
		mode = "strict",
		solver = "new",
		filePath = filePath,
	})
	print("Checked in", os.clock() - _start)

	local diagnostics = collectDiagnostics(result)
	local lines = splitLines(source)
	local hasErrors = false
	local warningCount = 0

	for _, d in diagnostics do
		if d.severity == "error" then
			hasErrors = true
		else
			warningCount = warningCount + 1
		end
		printDiagnosticFrame(filePath, lines, d)
	end

	return {
		filePath = filePath,
		total = #diagnostics,
		hasErrors = hasErrors,
		warnings = warningCount,
	}
end

local function shouldCheckFile(name)
	return name:match("%.luau$") ~= nil or name:match("%.lua$") ~= nil
end

local function walkFiles(root, out)
	local entries = fs.listDir(root)
	table.sort(entries)
	for _, entry in entries do
		local full = fs.path.join(root, entry)
		if fs.isDirectory(full) then
			if entry ~= ".git" and entry ~= "build" and entry ~= "vendor" then
				walkFiles(full, out)
			end
		elseif fs.isFile(full) and shouldCheckFile(entry) then
			table.insert(out, full)
		end
	end
end

if fs.isDirectory(path) then
	local files = {}
	walkFiles(path, files)
	local totalDiagnostics = 0
	local filesWithErrors = 0
	local totalWarnings = 0

	for _, filePath in files do
		local result = checkFile(filePath)
		totalDiagnostics = totalDiagnostics + result.total
		totalWarnings = totalWarnings + result.warnings
		if result.hasErrors then
			filesWithErrors = filesWithErrors + 1
		end
	end

	stdio.write(
		"\nchecked "
			.. tostring(#files)
			.. " file(s), "
			.. tostring(totalDiagnostics)
			.. " diagnostic(s), "
			.. tostring(totalWarnings)
			.. " warning(s)\n"
	)
	if filesWithErrors > 0 then
		stdio.write("failed: " .. tostring(filesWithErrors) .. " file(s) with errors\n")
		os.exit(1)
	end
	stdio.write("ok\n")
elseif fs.isFile(path) then
	local result = checkFile(path)
	stdio.write(
		"\nchecked 1 file, "
			.. tostring(result.total)
			.. " diagnostic(s), "
			.. tostring(result.warnings)
			.. " warning(s)\n"
	)
	if result.hasErrors then
		stdio.write("failed: type/lint errors found\n")
		os.exit(1)
	end
	stdio.write("ok\n")
else
	error(args.path .. ": not a file or directory")
end
