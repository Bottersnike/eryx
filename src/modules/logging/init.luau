--[=[
	Structured, hierarchical logging for Luau applications.

	This module provides:
	- named loggers with parent/child inheritance (`app`, `app.http`, ...)
	- leveled logging (`debug`..`critical`)
	- handler-based output routing
	- optional source metadata capture

	The root logger is `""` and includes a default [[ConsoleHandler]].

	```luau
	local logging = require("@eryx/logging")

	logging.config({
		level = "info",
	})

	local log = logging.getLogger("app")
	log:info("server started", { port = 8080 })
	```
]=]
local stdio = require("@eryx/stdio")

local LoggingTypes = require("@self/types")
local ConsoleHandler = require("@self/ConsoleHandler")
local FileHandler = require("@self/FileHandler")
local JsonHandler = require("@self/JsonHandler")

local logging = {}

export type LevelName = LoggingTypes.LevelName
export type LevelInput = LoggingTypes.LevelInput
export type LogAttrs = LoggingTypes.LogAttrs
export type LogRecord = LoggingTypes.LogRecord
export type Handler = LoggingTypes.Handler

export type LoggingConfig = {
	level: LevelInput?,
	captureSource: boolean?,
	sourceDepth: number?,
	reset: boolean?,
}

type LoggerState = {
	name: string,
	parent: LoggerState?,
	level: number?,
	handlers: { Handler },
	propagate: boolean,
}

type ModuleState = {
	root: LoggerState,
	loggers: { [string]: LoggerState },
	captureSource: boolean,
	sourceDepth: number,
}

local Logger = {}
Logger.__index = Logger

type LoggerData = {
	_state: LoggerState,
	_context: LogAttrs?,
}

export type Logger = setmetatable<LoggerData, typeof(Logger)>

local LEVEL_VALUES: { [LevelName]: number } = {
	debug = 10,
	info = 20,
	warning = 30,
	error = 40,
	critical = 50,
}
local LEVEL_BY_NAME: { [string]: number } = {
	debug = 10,
	info = 20,
	warning = 30,
	warn = 30,
	error = 40,
	critical = 50,
}

local function freezeLevels()
	local frozen = {}
	for name, value in LEVEL_VALUES do
		frozen[name] = value
	end
	return table.freeze(frozen)
end

local function defaultRootHandlers(): { Handler }
	return {
		ConsoleHandler.new(),
	}
end

local state: ModuleState = {
	root = {
		name = "",
		parent = nil,
		level = LEVEL_VALUES.info,
		handlers = defaultRootHandlers(),
		propagate = true,
	},
	loggers = {},
	captureSource = false,
	sourceDepth = 4,
}

state.loggers[""] = state.root

local function cloneAttrs(attrs: LogAttrs?): LogAttrs
	local out = {}
	if attrs == nil then
		return out
	end
	for key, value in attrs do
		out[key] = value
	end
	return out
end

local function hasAnyAttrs(attrs: LogAttrs?): boolean
	if attrs == nil then
		return false
	end
	return next(attrs) ~= nil
end

--[=[
	Parses a level input into its numeric representation.

	Supports canonical names (`"debug"`, `"warning"`, ...), alias `"warn"`,
	and raw numeric values.

	@param level Level name/alias or numeric value.
	@return number -- Numeric level value used for comparisons.
]=]
function logging.parseLevel(level: LevelInput): number
	if type(level) == "number" then
		return level
	end
	if type(level) ~= "string" then
		error("level must be a string or number", 2)
	end

	local normalized = string.lower(level)
	local parsed = LEVEL_BY_NAME[normalized]
	if parsed == nil then
		error(`Unknown log level '{level}'`, 2)
	end
	return parsed
end

local function toLevelName(levelValue: number): LevelName
	if levelValue >= LEVEL_VALUES.critical then
		return "critical"
	end
	if levelValue >= LEVEL_VALUES.error then
		return "error"
	end
	if levelValue >= LEVEL_VALUES.warning then
		return "warning"
	end
	if levelValue >= LEVEL_VALUES.info then
		return "info"
	end
	return "debug"
end

local function splitParentName(name: string): string
	local index = string.match(name, "^.*()%.")
	if index == nil then
		return ""
	end
	return string.sub(name, 1, index - 1)
end

local function getOrCreateState(name: string): LoggerState
	local existing = state.loggers[name]
	if existing ~= nil then
		return existing
	end

	local parentName = splitParentName(name)
	local parent = getOrCreateState(parentName)
	local created: LoggerState = {
		name = name,
		parent = parent,
		level = nil :: number?,
		handlers = {},
		propagate = true,
	}

	state.loggers[name] = created
	return created
end

local function effectiveLevel(loggerState: LoggerState): number
	local current = loggerState
	while current ~= nil do
		if current.level ~= nil then
			return current.level :: number
		end
		current = current.parent :: LoggerState
	end
	return LEVEL_VALUES.info
end

local function mergeAttrs(base: LogAttrs?, extra: LogAttrs?): LogAttrs
	if not hasAnyAttrs(base) and not hasAnyAttrs(extra) then
		return {}
	end

	local merged = cloneAttrs(base)
	if extra ~= nil then
		for key, value in extra do
			merged[key] = value
		end
	end
	return merged
end

local function sourceInfo(depth: number): (string?, number?, string?)
	if debug == nil or debug.info == nil then
		return nil, nil, nil
	end

	local okSource, sourcePath = pcall(function()
		return debug.info(depth, "s")
	end)
	local okLine, sourceLine = pcall(function()
		return debug.info(depth, "l")
	end)
	local okName, sourceFn = pcall(function()
		return debug.info(depth, "n")
	end)

	return if okSource and type(sourcePath) == "string" then sourcePath else nil,
		if okLine and type(sourceLine) == "number" then sourceLine else nil,
		if okName and type(sourceFn) == "string" then sourceFn else nil
end

local function createRecord(logger: LoggerData, levelValue: number, message: string, attrs: LogAttrs?): LogRecord
	local now = os.time()
	local timestampIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
	local path, line, fn = nil, nil, nil
	if state.captureSource then
		path, line, fn = sourceInfo(state.sourceDepth)
	end

	return {
		timestamp = now,
		timestampIso = timestampIso,
		level = toLevelName(levelValue),
		levelValue = levelValue,
		logger = logger._state.name,
		message = message,
		attrs = mergeAttrs(logger._context, attrs),
		sourcePath = path,
		sourceLine = line,
		sourceFunction = fn,
	}
end

local function handlerLevel(handler: Handler): number?
	if handler.level == nil then
		return nil
	end
	return logging.parseLevel(handler.level :: LevelInput)
end

local function writeHandlerError(err: unknown)
	stdio.writeerr(`[logging] handler error: {tostring(err)}\n`)
end

local function collectHandlers(loggerState: LoggerState): { Handler }
	local out = {}
	local seen = {}
	local current: LoggerState? = loggerState

	while current ~= nil do
		for _, handler in current.handlers do
			if not seen[handler] then
				seen[handler] = true
				table.insert(out, handler)
			end
		end

		if not current.propagate then
			break
		end
		current = current.parent
	end

	return out
end

local function normalizeHandler(handler: Handler): Handler
	assert(type(handler) == "table", "handler must be a table")
	assert(type(handler.write) == "function", "handler.write must be a function")
	if handler.filter ~= nil then
		assert(type(handler.filter) == "function", "handler.filter must be a function when provided")
	end
	if handler.close ~= nil then
		assert(type(handler.close) == "function", "handler.close must be a function when provided")
	end
	if handler.level ~= nil then
		logging.parseLevel(handler.level :: LevelInput)
	end
	return handler
end

--[=[
	Returns a logger by name, creating it if needed.

	Logger names are hierarchical with dot-separated segments.
	Omit the name (or pass `""`) to retrieve the root logger.

	@param name Optional logger name (for example `"app.http"`).
	@return Logger -- Logger instance bound to the requested name.
]=]
function logging.getLogger(name: string?): Logger
	local normalizedName = if name == nil then "" else name
	local loggerState = getOrCreateState(normalizedName)
	return setmetatable({
		_state = loggerState,
		_context = nil :: LogAttrs?,
	}, Logger)
end

--[=[
	Configures global logging behavior.

	When `reset` is true, logger overrides/handlers are reset to defaults.
	The root logger is reset to info level with the default console handler.

	@param config Optional logging configuration.
	@return () -- No return value.
]=]
function logging.config(config: LoggingConfig?)
	local cfg = config or ({} :: LoggingConfig)

	if cfg.reset == true then
		for loggerName, loggerState in state.loggers do
			if loggerName == "" then
				loggerState.handlers = defaultRootHandlers()
				loggerState.level = LEVEL_VALUES.info
				loggerState.propagate = true
			else
				loggerState.handlers = {}
				loggerState.level = nil
				loggerState.propagate = true
			end
		end
		state.captureSource = false
		state.sourceDepth = 4
	end

	if cfg.level ~= nil then
		state.root.level = logging.parseLevel(cfg.level :: LevelInput)
	end
	if cfg.captureSource ~= nil then
		state.captureSource = cfg.captureSource == true
	end
	if cfg.sourceDepth ~= nil then
		assert(cfg.sourceDepth >= 1, "sourceDepth must be >= 1")
		state.sourceDepth = cfg.sourceDepth
	end
end

--[=[
	Adds a handler to the root logger.

	Root handlers receive records from all propagating child loggers.

	@param handler A handler implementing the logging handler contract.
	@return Handler -- The normalized handler that was added.
]=]
function logging.addHandler(handler: Handler): Handler
	local normalized = normalizeHandler(handler)
	table.insert(state.root.handlers, normalized)
	return normalized
end

--[=[
	Removes a handler from the root logger.

	@param handler The handler instance to remove.
	@return boolean -- `true` when removed, `false` when not found.
]=]
function logging.removeHandler(handler: Handler): boolean
	for index, current in state.root.handlers do
		if current == handler then
			table.remove(state.root.handlers, index)
			return true
		end
	end
	return false
end

--[=[
	Clears all handlers from the root logger.

	@param none
	@return () -- No return value.
]=]
function logging.clearHandlers()
	state.root.handlers = {}
end

local function writeLog(logger: LoggerData, level: LevelInput, message: string, attrs: LogAttrs?): boolean
	local levelValue = logging.parseLevel(level)
	if levelValue < effectiveLevel(logger._state) then
		return false
	end

	local record = createRecord(logger, levelValue, message, attrs)
	local handlers = collectHandlers(logger._state)
	local dispatched = false

	for _, handler in handlers do
		local minLevel = handlerLevel(handler)
		if minLevel ~= nil and levelValue < minLevel then
			continue
		end

		if handler.filter ~= nil and not (handler.filter :: (LogRecord) -> boolean)(record) then
			continue
		end

		local ok, err = pcall(handler.write, record)
		if not ok then
			writeHandlerError(err)
		else
			dispatched = true
		end
	end

	return dispatched
end

--[=[
	Emits a log record at a specific level.

	@param level Level name (`"debug"`, `"warn"`, ...) or numeric level.
	@param message Human-readable log message.
	@param attrs Optional structured attributes merged into the record.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.log(self: Logger, level: LevelInput, message: string, attrs: LogAttrs?): boolean
	return writeLog(self :: LoggerData, level, message, attrs)
end

--[=[
	Logs a record at `debug` level.

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.debug(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:log("debug", message, attrs)
end

--[=[
	Logs a record at `info` level.

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.info(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:log("info", message, attrs)
end

--[=[
	Logs a record at `warning` level.

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.warning(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:log("warning", message, attrs)
end

--[=[
	Logs a record at `warning` level (alias for [[Logger.warning]]).

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.warn(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:warning(message, attrs)
end

--[=[
	Logs a record at `error` level.

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.error(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:log("error", message, attrs)
end

--[=[
	Logs a record at `critical` level.

	@param message Human-readable log message.
	@param attrs Optional structured attributes.
	@return boolean -- `true` when at least one handler emitted the record.
]=]
function Logger.critical(self: Logger, message: string, attrs: LogAttrs?): boolean
	return self:log("critical", message, attrs)
end

--[=[
	Checks whether the logger is enabled for the provided level.

	@param level Level name or numeric level.
	@return boolean -- `true` if records at this level would pass logger-level gating.
]=]
function Logger.isEnabledFor(self: Logger, level: LevelInput): boolean
	return logging.parseLevel(level) >= effectiveLevel((self :: LoggerData)._state)
end

--[=[
	Sets or clears this logger's explicit level.

	Pass `nil` to clear the override and inherit from parents/root.

	@param level Optional level override for this logger.
	@return Logger -- Self, for chaining.
]=]
function Logger.setLevel(self: Logger, level: LevelInput?): Logger
	local loggerState = (self :: LoggerData)._state
	if level == nil then
		loggerState.level = nil
	else
		loggerState.level = logging.parseLevel(level)
	end
	return self
end

--[=[
	Adds a handler directly to this logger.

	@param handler A handler implementing the logging handler contract.
	@return Handler -- The normalized handler that was added.
]=]
function Logger.addHandler(self: Logger, handler: Handler): Handler
	local normalized = normalizeHandler(handler)
	table.insert((self :: LoggerData)._state.handlers, normalized)
	return normalized
end

--[=[
	Removes a handler from this logger.

	@param handler The handler instance to remove.
	@return boolean -- `true` when removed, `false` when not found.
]=]
function Logger.removeHandler(self: Logger, handler: Handler): boolean
	local handlers = (self :: LoggerData)._state.handlers
	for index, current in handlers do
		if current == handler then
			table.remove(handlers, index)
			return true
		end
	end
	return false
end

--[=[
	Clears all handlers attached to this logger.

	@param none
	@return () -- No return value.
]=]
function Logger.clearHandlers(self: Logger)
	(self :: LoggerData)._state.handlers = {}
end

--[=[
	Creates or retrieves a child logger.

	Child names are joined with `.` (for example `app` + `http` -> `app.http`).
	When `context` is provided, the returned child logger includes that context.

	@param suffix Child segment to append to this logger name.
	@param context Optional context merged into all child log records.
	@return Logger -- Child logger instance.
]=]
function Logger.child(self: Logger, suffix: string, context: LogAttrs?): Logger
	assert(suffix ~= "", "child suffix cannot be empty")
	local baseName = (self :: LoggerData)._state.name
	local childName = if baseName == "" then suffix else `{baseName}.{suffix}`
	local childLogger = logging.getLogger(childName)
	if context ~= nil then
		return childLogger:withContext(context)
	end
	return childLogger
end

--[=[
	Returns a logger view with additional bound context.

	Context is merged with per-call attrs, where per-call attrs win on conflicts.

	@param context Structured attributes to bind to this logger.
	@return Logger -- A new logger view sharing the same logger state.
]=]
function Logger.withContext(self: Logger, context: LogAttrs): Logger
	local loggerData = self :: LoggerData
	local merged = mergeAttrs(loggerData._context, context)
	local data: LoggerData = {
		_state = loggerData._state,
		_context = merged,
	}
	return setmetatable(data, Logger)
end

--[=[
	Enables or disables handler propagation to parent loggers.

	@param propagate When `false`, dispatch stops at this logger.
	@return Logger -- Self, for chaining.
]=]
function Logger.setPropagation(self: Logger, propagate: boolean): Logger
	(self :: LoggerData)._state.propagate = propagate == true
	return self
end

--[=[
	Invokes `close()` on each handler attached to this logger.

	Errors from handler close operations are suppressed.

	@param none
	@return () -- No return value.
]=]
function Logger.closeHandlers(self: Logger)
	for _, handler in (self :: LoggerData)._state.handlers do
		if handler.close ~= nil then
			pcall(handler.close :: () -> ())
		end
	end
end

logging.levels = freezeLevels()
logging.ConsoleHandler = ConsoleHandler
logging.FileHandler = FileHandler
logging.JsonHandler = JsonHandler

return table.freeze(logging)
