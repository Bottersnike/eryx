local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local luau = require("@eryx/luau/analysis")
local os = require("@eryx/os")
local stdio = require("@eryx/stdio")

local parser = argparse.Parser.new("eryx check", "Type-check + lint Luau files")
parser:addPositional("path", "string", nil, true, "File or directory to test")
parser:addOption("defs", "d", "string", nil, false, "Definition file (.d.luau); can be passed multiple times", {
	multiple = true,
})
parser:addOption(
	"exclude",
	"e",
	"string",
	nil,
	false,
	"Directory or file name to exclude; can be passed multiple times",
	{
		multiple = true,
	}
)

local args = parser:parse()
local path = fs.path.canonicalize(args.path)
local TABSTOP = 4

local COLOR: boolean
do
	if os.getenv("NO_COLOR") then
		COLOR = false
	elseif os.getenv("FORCE_COLOR") then
		COLOR = true
	else
		local tty = stdio.isatty()
		COLOR = tty.stdout or tty.stderr
	end
end

local function ansi(code: string, s: string): string
	if not COLOR then
		return s
	end
	return `\27[{code}m{s}\27[0m`
end

local function red(s: string): string
	return ansi("31", s)
end

local function yellow(s: string): string
	return ansi("33", s)
end

local function green(s: string): string
	return ansi("32", s)
end

local function cyan(s: string): string
	return ansi("36", s)
end

local function bold(s: string): string
	return ansi("1", s)
end

local function dim(s: string): string
	return ansi("2", s)
end

local function readFile(filePath: string): string
	return fs.openSync(filePath):readSync()
end

local function loadDefinitions(definitionPaths: { string }?): { luau.DefinitionSource }
	local definitions: { luau.DefinitionSource } = {}
	if not definitionPaths then
		return definitions
	end

	for _, rawPath in definitionPaths do
		local definitionPath = fs.path.canonicalize(rawPath)
		table.insert(definitions, {
			name = definitionPath,
			source = readFile(definitionPath),
		})
	end

	return definitions
end

local function splitLines(source: string): { string }
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	if #lines == 0 then
		table.insert(lines, "")
	end
	return lines
end

local function digits(n: number)
	local d = 1
	while n >= 10 do
		d = d + 1
		n = math.floor(n / 10)
	end
	return d
end

local function clamp(n: number, lo: number, hi: number)
	return math.max(lo, math.min(hi, n))
end

local function spaces(count: number)
	return string.rep(" ", math.max(0, count))
end

local function tildes(count: number)
	return string.rep("~", math.max(0, count))
end

local function expandTabs(lineText: string): string
	local out = {}
	local visualColumn = 1
	for i = 1, #lineText do
		local ch = string.sub(lineText, i, i)
		if ch == "\t" then
			local spacesToAdd = TABSTOP - ((visualColumn - 1) % TABSTOP)
			table.insert(out, string.rep(" ", spacesToAdd))
			visualColumn = visualColumn + spacesToAdd
		else
			table.insert(out, ch)
			visualColumn = visualColumn + 1
		end
	end
	return table.concat(out)
end

local function sourceColumnToVisual(lineText: string, sourceColumn: number): number
	local target = math.max(1, sourceColumn)
	local visualColumn = 1
	local sourceIndex = 1
	while sourceIndex < target and sourceIndex <= #lineText do
		local ch = string.sub(lineText, sourceIndex, sourceIndex)
		if ch == "\t" then
			visualColumn = visualColumn + (TABSTOP - ((visualColumn - 1) % TABSTOP))
		else
			visualColumn = visualColumn + 1
		end
		sourceIndex = sourceIndex + 1
	end
	return visualColumn
end

local function locationField(loc, flatKey: string, pointKey: string, coordKey: string): number?
	local flatValue = loc[flatKey]
	if type(flatValue) == "number" then
		return flatValue
	end

	local point = loc[pointKey]
	if type(point) == "table" then
		local nestedValue = point[coordKey]
		if type(nestedValue) == "number" then
			return nestedValue
		end
	end

	return nil
end

local function normalizedLocation(loc)
	local beginline = locationField(loc, "beginline", "start", "line")
	local begincolumn = locationField(loc, "begincolumn", "start", "column")
	local endline = locationField(loc, "endline", "end", "line")
	local endcolumn = locationField(loc, "endcolumn", "end", "column")

	if not beginline or not begincolumn or not endline or not endcolumn then
		error("diagnostic location is missing expected coordinates")
	end

	return {
		beginline = beginline,
		begincolumn = begincolumn,
		endline = endline,
		endcolumn = endcolumn,
	}
end

local function makeUnderline(lineText: string, lineNo: number, loc)
	local normalized = normalizedLocation(loc)
	local startLine = normalized.beginline
	local endLine = normalized.endline
	local startCol = normalized.begincolumn
	local endCol = normalized.endcolumn
	local expanded = expandTabs(lineText)
	local lineLen = #expanded

	local fromCol = 1
	local toCol = lineLen + 1

	if startLine == endLine then
		fromCol = clamp(sourceColumnToVisual(lineText, startCol), 1, lineLen + 1)
		toCol = clamp(sourceColumnToVisual(lineText, endCol), 1, lineLen + 1)
		if toCol <= fromCol then
			toCol = fromCol + 1
		end
	elseif lineNo == startLine then
		fromCol = clamp(sourceColumnToVisual(lineText, startCol), 1, lineLen + 1)
		toCol = lineLen + 1
	elseif lineNo == endLine then
		fromCol = 1
		toCol = clamp(sourceColumnToVisual(lineText, endCol), 1, lineLen + 1)
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

local function severityStyle(severity: string, text: string): string
	if severity == "error" then
		return red(text)
	end
	if severity == "warning" then
		return yellow(text)
	end
	return text
end

local function writeDiagnostic(message: string, severity: string)
	if severity == "error" then
		stdio.writeerr(message)
	else
		stdio.write(message)
	end
end

local function printDiagnosticFrame(filePath: string, sourceLines: { string }, d)
	local loc = normalizedLocation(d.location)
	local startLine = clamp(loc.beginline, 1, #sourceLines)
	local endLine = clamp(loc.endline, startLine, #sourceLines)
	local contextStart = clamp(startLine - 1, 1, #sourceLines)
	local contextEnd = clamp(endLine + 1, 1, #sourceLines)
	local width = digits(contextEnd)
	local codePart = ""
	if d.code then
		codePart = "[" .. tostring(d.code) .. "]"
	end

	writeDiagnostic(
		"\n"
			.. bold(cyan(filePath))
			.. ":"
			.. tostring(loc.beginline)
			.. ":"
			.. tostring(loc.begincolumn)
			.. ": "
			.. severityStyle(d.severity, bold(d.severity))
			.. codePart
			.. ": "
			.. bold(d.message)
			.. "\n",
		d.severity
	)
	writeDiagnostic(dim(spaces(width) .. " |\n"), d.severity)
	for lineNo = contextStart, contextEnd do
		local rawText = sourceLines[lineNo] or ""
		local text = expandTabs(rawText)
		local lineLabel = string.format("%" .. tostring(width) .. "d", lineNo)
		writeDiagnostic(dim(lineLabel .. " | ") .. text .. "\n", d.severity)
		if lineNo >= startLine and lineNo <= endLine then
			local underline = makeUnderline(rawText, lineNo, loc)
			writeDiagnostic(dim(spaces(width) .. " | ") .. severityStyle(d.severity, underline) .. "\n", d.severity)
		end
	end
end

type Diagnostic = {
	severity: string,
	kind: string,
	code: string,
	message: string,
	location: luau.Location,
	moduleName: string?,
}

local function collectDiagnostics(result: luau.CheckResult): { Diagnostic }
	local out: { Diagnostic } = {}

	for _, e in result.errors do
		table.insert(out, {
			severity = "error",
			kind = tostring(e.category),
			code = tostring(e.category),
			message = e.message,
			location = e.location,
			moduleName = e.moduleName,
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

	table.sort(out, function(a: Diagnostic, b: Diagnostic)
		local aLoc = normalizedLocation(a.location)
		local bLoc = normalizedLocation(b.location)
		if aLoc.beginline ~= bLoc.beginline then
			return aLoc.beginline < bLoc.beginline
		end
		if aLoc.begincolumn ~= bLoc.begincolumn then
			return aLoc.begincolumn < bLoc.begincolumn
		end
		return a.message < b.message
	end)

	return out
end

local definitions = loadDefinitions(args.defs)
local excludedPatterns: { string } = args.exclude or {}

local function checkFile(filePath: string)
	local source = readFile(filePath)
	local sourceCache: { [string]: { string } } = {
		[filePath] = splitLines(source),
	}
	local _start = os.clock()
	local result = luau.check(source, {
		mode = "strict",
		solver = "new",
		filePath = filePath,
		definitions = definitions,
	})
	local diagnostics = collectDiagnostics(result)
	local elapsed = string.format("%.2fms", (os.clock() - _start) * 1000)

	local hasErrors = false
	local warningCount = 0
	local errorCount = 0

	stdio.write(bold(cyan(`\n> {filePath}\n`)))
	stdio.write(dim(`  checked in {elapsed}\n`))

	for _, d in diagnostics do
		local diagnosticPath = d.moduleName or filePath
		local lines = sourceCache[diagnosticPath]
		if not lines then
			local ok, loaded = pcall(readFile, diagnosticPath)
			if ok then
				lines = splitLines(loaded)
			else
				lines = sourceCache[filePath]
			end
			sourceCache[diagnosticPath] = lines
		end

		if d.severity == "error" then
			hasErrors = true
			errorCount = errorCount + 1
		else
			warningCount = warningCount + 1
		end
		printDiagnosticFrame(diagnosticPath, lines, d)
	end

	return {
		filePath = filePath,
		total = #diagnostics,
		hasErrors = hasErrors,
		errors = errorCount,
		warnings = warningCount,
	}
end

local function shouldCheckFile(name: string): boolean
	return name:match("%.luau$") ~= nil or name:match("%.lua$") ~= nil
end

local function isExcludedEntry(name: string): boolean
	for _, pattern in excludedPatterns do
		if pattern ~= "" and string.find(name, pattern, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function walkFiles(root, out)
	local entries = fs.listDir(root)
	table.sort(entries)
	for _, entry in entries do
		if isExcludedEntry(entry) then
			continue
		end

		local full = fs.path.join(root, entry)
		if fs.isDirectory(full) then
			if entry ~= ".git" then
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
	local filesWithErrors = 0
	local totalWarnings = 0
	local totalErrors = 0

	for _, filePath in files do
		local result = checkFile(filePath)
		totalErrors = totalErrors + result.errors
		totalWarnings = totalWarnings + result.warnings
		if result.hasErrors then
			filesWithErrors = filesWithErrors + 1
		end
	end

	stdio.write(
		"\n"
			.. bold("checked ")
			.. tostring(#files)
			.. " file(s), "
			.. severityStyle("error", tostring(totalErrors))
			.. " error(s), "
			.. severityStyle("warning", tostring(totalWarnings))
			.. " warning(s)\n"
	)
	if filesWithErrors > 0 then
		stdio.writeerr(red("failed") .. ": " .. tostring(filesWithErrors) .. " file(s) with errors\n")
		os.exit(1)
	end
	stdio.write(green("ok") .. "\n")
elseif fs.isFile(path) then
	local result = checkFile(path)
	stdio.write(
		"\n"
			.. bold("checked 1 file, ")
			.. severityStyle("error", tostring(result.errors))
			.. " error(s), "
			.. severityStyle("warning", tostring(result.warnings))
			.. " warning(s)\n"
	)
	if result.hasErrors then
		stdio.writeerr(red("failed") .. ": type/lint errors found\n")
		os.exit(1)
	end
	stdio.write(green("ok") .. "\n")
else
	error(args.path .. ": not a file or directory")
end
