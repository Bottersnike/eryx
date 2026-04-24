--[=[
	JSON log handler.

	Encodes each log record as JSON and writes newline-delimited JSON (NDJSON)
	to a provided callback, stream-like object, or stdout.
]=]
local json = require("@eryx/data/json")
local stdio = require("@eryx/stdio")
local LoggingTypes = require("@self/types")

local JsonHandler = {}

export type LogRecord = LoggingTypes.LogRecord
export type LevelInput = LoggingTypes.LevelInput
export type Handler = LoggingTypes.Handler

export type StreamLike = {
	write: ((self: StreamLike, data: string) -> ())?,
	writeSync: ((self: StreamLike, data: string) -> ())?,
}

export type Options = {
	level: LevelInput?,
	filter: ((record: LogRecord) -> boolean)?,
	write: ((line: string, record: LogRecord) -> ())?,
	stream: StreamLike?,
}

local function defaultWrite(line: string)
	stdio.write(line)
end

local function writerFromStream(stream: StreamLike): (line: string) -> ()
	if stream.writeSync ~= nil then
		return function(line: string)
			(stream.writeSync :: (self: StreamLike, data: string) -> ())(stream, line)
		end
	end
	if stream.write ~= nil then
		return function(line: string)
			(stream.write :: (self: StreamLike, data: string) -> ())(stream, line)
		end
	end

	error("JsonHandler stream must provide writeSync(self, data) or write(self, data)")
end

local function encodeRecord(record: LogRecord): string
	local payload = {
		timestamp = record.timestamp,
		timestampIso = record.timestampIso,
		level = record.level,
		levelValue = record.levelValue,
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
		timestamp = os.time(),
		timestampIso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		level = "error",
		levelValue = 40,
		logger = "logging.json",
		message = "failed to encode log record as json",
		attrs = {
			originalMessage = record.message,
		},
	})
end

--[=[
	Creates an NDJSON logging handler.

	Output sink precedence:
	1. `options.write(line, record)` when provided
	2. `options.stream` (`writeSync` preferred, otherwise `write`)
	3. stdout

	@param options Optional sink and filtering options.
	@return Handler -- A logging handler suitable for structured log pipelines.
]=]
function JsonHandler.new(options: Options?): Handler
	local opts = options or ({} :: Options)
	local writeLine: (line: string) -> () = if opts.stream ~= nil then writerFromStream(opts.stream) else defaultWrite

	local handler: Handler = {
		level = opts.level,
		filter = opts.filter,
		write = function(record: LogRecord)
			local line = encodeRecord(record) .. "\n"
			if opts.write ~= nil then
				(opts.write :: (line: string, record: LogRecord) -> ())(line, record)
				return
			end
			writeLine(line)
		end,
	}
	return handler
end

return table.freeze(JsonHandler)
