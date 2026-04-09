--[=[
	Console log handler.

	Writes formatted text records to stdout/stderr, with optional
	ANSI colour output and optional source metadata rendering.

	`stderrLevel` controls when records are routed to stderr.
]=]
local json = require("@eryx/encoding/json")
local pprint = require("@eryx/pprint")
local stdio = require("@eryx/stdio")
local LoggingTypes = require("@self/types")

local ConsoleHandler = {}

export type LogRecord = LoggingTypes.LogRecord
export type LevelInput = LoggingTypes.LevelInput
export type Handler = LoggingTypes.Handler

export type Options = {
	level: LevelInput?,
	filter: ((record: LogRecord) -> boolean)?,
	write: ((line: string, record: LogRecord) -> ())?,
	includeSource: boolean?,
	stderrLevel: number?,
	color: boolean?,
}

local function attrsToString(attrs: LoggingTypes.LogAttrs): string
	if next(attrs) == nil then
		return ""
	end

	local ok, encoded = pcall(json.encode, attrs)
	if ok then
		return encoded
	end

	return pprint.format(attrs)
end

local function renderLine(record: LogRecord, includeSource: boolean): string
	local loggerName = if record.logger ~= "" then record.logger else "root"
	local level = string.upper(record.level)
	local line = `{record.timestampIso} [{level}] {loggerName}: {record.message}`

	local attrs = attrsToString(record.attrs)
	if attrs ~= "" then
		line ..= ` {attrs}`
	end

	if includeSource and record.sourcePath ~= nil then
		line ..= ` ({record.sourcePath}:{record.sourceLine or 0})`
		if record.sourceFunction ~= nil and record.sourceFunction ~= "" then
			line ..= ` {record.sourceFunction}`
		end
	end

	return line
end

local function shouldUseColor(explicitColor: boolean?): boolean
	if explicitColor ~= nil then
		return explicitColor
	end

	local tty = stdio.isatty()
	return tty.stdout or tty.stderr
end

local function colourLevel(level: string, text: string): string
	local code = nil
	if level == "debug" then
		code = "36"
	elseif level == "info" then
		code = "2"
	elseif level == "warning" then
		code = "33"
	elseif level == "error" then
		code = "31"
	elseif level == "critical" then
		code = "1;31"
	end

	if code == nil then
		return text
	end
	return `\27[{code}m{text}\27[0m`
end

--[=[
	Creates a console-backed logging handler.

	By default:
	- messages at level >= warning are written to stderr
	- lower levels are written to stdout
	- colours are auto-enabled when a TTY is detected

	@param options Optional handler options (level/filter/custom writer/etc.).
	@return Handler -- A logging handler suitable for `logging.addHandler`.
]=]
function ConsoleHandler.new(options: Options?): Handler
	local opts = options or ({} :: Options)
	local includeSource = opts.includeSource == true
	local stderrLevel = opts.stderrLevel or 30
	local customWrite = opts.write
	local useColor = shouldUseColor(opts.color)

	local handler: Handler = {
		level = opts.level,
		filter = opts.filter,
		write = function(record: LogRecord)
			local line = renderLine(record, includeSource)
			if useColor then
				line = colourLevel(record.level, line)
			end
			if customWrite ~= nil then
				customWrite(line, record)
				return
			end

			if record.levelValue >= stderrLevel then
				stdio.writeerr(line .. "\n")
			else
				stdio.write(line .. "\n")
			end
		end,
	}
	return handler
end

return table.freeze(ConsoleHandler)
