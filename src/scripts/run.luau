local fs = require("@eryx/fs")
local os = require("@eryx/os")
local path = require("@eryx/path")
local project = require("@eryx/project")
local stdio = require("@eryx/stdio")

local args = os.cliargs()
local name = args[1]

if not name then
	stdio.writeerr("Usage: eryx run <script> [args...]\n")
	os.exit(1)
end

local function hasPathSyntax(value: string): boolean
	return value:find("/", 1, true) ~= nil or value:find("\\", 1, true) ~= nil or value:find(".", 1, true) ~= nil
end

local function tailArgs(startIndex: number): { string }
	local out = {}
	for i = startIndex, #args do
		table.insert(out, args[i])
	end
	return out
end

local function join(root: string, child: string): string
	return tostring(path.join(root, child))
end

local function quotePosix(value: string): string
	return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function quoteWindows(value: string): string
	if value == "" then
		return '""'
	end

	local needsQuotes = value:find('[%s"]') ~= nil
	if not needsQuotes then
		return (value:gsub("([%%%^&|<>()])", "^%1"))
	end

	local out = { '"' }
	local backslashes = 0
	for i = 1, #value do
		local ch = value:sub(i, i)
		if ch == "\\" then
			backslashes += 1
		elseif ch == '"' then
			table.insert(out, string.rep("\\", backslashes * 2 + 1))
			table.insert(out, '"')
			backslashes = 0
		else
			if backslashes > 0 then
				table.insert(out, string.rep("\\", backslashes))
				backslashes = 0
			end
			table.insert(out, ch)
		end
	end
	if backslashes > 0 then
		table.insert(out, string.rep("\\", backslashes * 2))
	end
	table.insert(out, '"')

	return (table.concat(out):gsub("([%%%^&|<>()])", "^%1"))
end

local function quoteArg(value: string): string
	if os.platform() == "windows" then
		return quoteWindows(value)
	end
	return quotePosix(value)
end

local function runFile(scriptPath: string, scriptArgs: { string }, cwd: string?)
	local exe = os.getenv("ERYX_EXE_PATH") or "eryx"
	local childArgs = { exe, "__run-file", scriptPath }
	for _, arg in scriptArgs do
		table.insert(childArgs, arg)
	end

	local parts = {}
	for _, arg in childArgs do
		table.insert(parts, quoteArg(arg))
	end

	os.exit(os.shell(table.concat(parts, " "), { cwd = cwd }))
end

if hasPathSyntax(name) or fs.isFile(name) then
	runFile(name, tailArgs(2), nil)
end

local doc = project.loadNearest()
if doc and doc.manifest.scripts and doc.manifest.scripts[name] then
	local root = doc.root or tostring(os.cwd())
	local scriptPath = join(root, doc.manifest.scripts[name])
	if not fs.isFile(scriptPath) then
		stdio.writeerr(`Project script '{name}' points to missing file: {scriptPath}\n`)
		os.exit(1)
	end

	runFile(scriptPath, tailArgs(2), root)
end

if fs.isFile(name) then
	runFile(name, tailArgs(2), nil)
end

if doc then
	stdio.writeerr(`No project script named '{name}' in {doc.path or "eryx.toml"}\n`)
else
	stdio.writeerr(`No project found and script file does not exist: {name}\n`)
end
os.exit(1)
