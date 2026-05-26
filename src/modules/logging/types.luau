--[=[
	Shared type definitions for `@eryx/logging`.

	This library exists to keep the core logger and built-in handlers aligned
	on one set of record and handler contracts.
]=]
local types = {}

export type LevelName = "debug" | "info" | "warning" | "error" | "critical"
export type LevelInput = LevelName | "warn" | number
export type LogAttrs = { [string]: unknown }

export type LogRecord = {
	read timestamp: number,
	read timestampIso: string,
	read level: LevelName,
	read levelValue: number,
	read logger: string,
	read message: string,
	read attrs: LogAttrs,
	read sourcePath: string?,
	read sourceLine: number?,
	read sourceFunction: string?,
}

export type Handler = {
	level: LevelInput?,
	filter: ((record: LogRecord) -> boolean)?,
	write: (record: LogRecord) -> (),
	close: (() -> ())?,
}

return table.freeze(types)
