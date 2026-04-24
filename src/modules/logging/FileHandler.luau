--[=[
	File log handler.

	Writes log records to a file opened in append mode. Output can be
	human-readable text or JSON lines (`asJson = true`).
]=]
local fs = require("@eryx/fs")
local json = require("@eryx/data/json")
local pprint = require("@eryx/pprint")
local LoggingTypes = require("@self/types")

local FileHandler = {}

export type LogRecord = LoggingTypes.LogRecord
export type LevelInput = LoggingTypes.LevelInput
export type Handler = LoggingTypes.Handler

export type Options = {
	level: LevelInput?,
	filter: ((record: LogRecord) -> boolean)?,
	flushEachWrite: boolean?,
	asJson: boolean?,
	includeSource: boolean?,
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

local function renderTextLine(record: LogRecord, includeSource: boolean): string
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

local function toJsonLine(record: LogRecord): string
	local payload = {
		timestamp = record.timestampIso,
		level = record.level,
		logger = record.logger,
		message = record.message,
		attrs = record.attrs,
		sourcePath = record.sourcePath,
		sourceLine = record.sourceLine,
		sourceFunction = record.sourceFunction,
	}

	local ok, encoded = pcall(json.encode, payload)
	if ok then
		return encoded
	end

	return json.encode({
		timestamp = record.timestampIso,
		level = "error",
		logger = "logging.file",
		message = "failed to encode log record as json",
		attrs = {
			originalMessage = record.message,
		},
	})
end

--[=[
	Creates a file-backed logging handler.

	The returned handler writes one line per log record to `path`.

	@param path Destination file path.
	@param options Optional handler behavior (json mode, flush policy, filter, ...).
	@return Handler -- A logging handler with an optional `close()` method.
]=]
function FileHandler.new(path: string, options: Options?): Handler
	local opts = options or ({} :: Options)
	local includeSource = opts.includeSource == true
	local asJson = opts.asJson == true
	local flushEachWrite = opts.flushEachWrite == true

	local file = fs.openSync(path, "a")

	local handler: Handler = {
		level = opts.level,
		filter = opts.filter,
		write = function(record: LogRecord)
			local line = if asJson then toJsonLine(record) else renderTextLine(record, includeSource)
			file:writeSync(line .. "\n")
			if flushEachWrite then
				file:flushSync()
			end
		end,
		close = function()
			if file.isOpen then
				file:closeSync()
			end
		end,
	}
	return handler
end

return table.freeze(FileHandler)
