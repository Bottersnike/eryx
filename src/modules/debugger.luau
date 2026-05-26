--[=[
	Debug Luau programs from Luau code.

	The debugger library runs a target program under debugger control and exposes
	the primitives needed by debuggers and editor adapters: session lifecycle,
	event delivery, source lookup, breakpoints, coroutine threads, stack frames,
	scopes, variable inspection, expression evaluation, variable assignment,
	exception details, output events, stepping, pausing, termination, and VM
	bytecode disassembly.

	Use `debugger.open()` to create a `Session`. Configure the session before
	starting it, usually by setting breakpoints, then call `Session:start()` and
	read events with `Session:wait()`. When a `stopped` event is received, use
	the event's `threadId` with `Session:frames()`, then inspect frames with
	`Session:scopes()`, `Session:inspect()`, `Session:evaluate()`, or
	`Session:setVariable()`. Resume execution with `Session:resume()` or
	`Session:step()`.

	Luau coroutines are reported as debugger threads. Thread identifiers are
	stable for known coroutines within a session. Frame, scope, evaluation, and
	mutation operations are guaranteed for the current stopped thread; other
	known threads may be listed even when they do not have inspectable frames.
]=]

--[=[
	Identifies a Luau coroutine thread within a session.
]=]
export type ThreadId = number

--[=[
	Identifies a stack frame captured during the current pause.
]=]
export type FrameId = number

--[=[
	Identifies a source breakpoint within a session.
]=]
export type BreakpointId = number

--[=[
	Identifies an expandable scope or value.
]=]
export type ValueRef = number

--[=[
	Session lifecycle state.
]=]
export type SessionState = "starting" | "idle" | "running" | "paused" | "terminated"

--[=[
	Debugger-visible state for a known coroutine thread.
]=]
export type ThreadState = "running" | "paused" | "terminated"

--[=[
	Step operation accepted by `Session:step()`.
]=]
export type StepMode = "in" | "over" | "out"

--[=[
	Stop reason reported by a `stopped` event.
]=]
export type StopReason = "entry" | "breakpoint" | "step" | "pause" | "exception" | "manual"

--[=[
	Evaluation context supplied by debugger clients.
]=]
export type EvaluateContext = "watch" | "repl" | "hover" | "clipboard" | "variables" | "condition" | "logpoint"

--[=[
	Output stream category.
]=]
export type OutputStream = "stdout" | "stderr" | "console" | "telemetry"

--[=[
	Category of an expandable debugger value.
]=]
export type ValueKind = "value" | "locals" | "registers"

--[=[
	Child filter for `Session:inspect()`.
]=]
export type ValueFilter = "all" | "named" | "indexed"

--[=[
	Stable source identifier.
]=]
export type SourceId = string

--[=[
	Source file or chunk known to the session.
]=]
export type Source = {
	--- Stable debugger-facing source identifier.
	id: SourceId,
	--- Human-friendly label, usually the source basename.
	name: string?,
	--- Concrete filesystem path when the source is file-backed.
	path: string?,
	--- Optional source category such as `"file"` or `"embedded"`.
	kind: string?,
}

--[=[
	Luau coroutine thread known to the session.
]=]
export type Thread = {
	--- Stable thread identifier within the session.
	id: ThreadId,
	--- Human-friendly thread name.
	name: string,
	--- Current debugger-visible thread state.
	state: ThreadState,
	--- Reason this thread is paused, when `state` is `"paused"`.
	stopReason: StopReason?,
}

--[=[
	Breakpoint request passed to `Session:setBreakpoints()`.
]=]
export type BreakpointSpec = {
	--- Requested one-based source line.
	line: number,
	--- Optional one-based source column.
	column: number?,
	--- Expression that must evaluate truthy before the breakpoint stops.
	condition: string?,
	--- Hit-count expression such as `"3"`, `">= 5"`, or `"% 2"`.
	hitCondition: string?,
	--- Logpoint message. Braced expressions are evaluated at the hit location.
	logMessage: string?,
}

--[=[
	Breakpoint returned by `Session:setBreakpoints()`.
]=]
export type Breakpoint = {
	--- Stable breakpoint identifier when the breakpoint was accepted.
	id: BreakpointId?,
	--- Source where the breakpoint was requested or resolved.
	source: Source,
	--- One-based resolved or requested source line.
	line: number,
	--- One-based resolved or requested source column.
	column: number?,
	--- Whether the debugger could bind this breakpoint to loaded code.
	verified: boolean,
	--- Human-readable explanation when the breakpoint is pending or rejected.
	message: string?,
}

--[=[
	Stack frame returned by `Session:frames()`.
]=]
export type Frame = {
	--- Stable frame identifier for the current pause.
	id: FrameId,
	--- Thread that owns this frame.
	threadId: ThreadId?,
	--- Function or chunk name for display.
	name: string,
	--- Source location for this frame, when available.
	source: Source?,
	--- One-based source line.
	line: number,
	--- One-based source column.
	column: number,
	--- VM instruction program counter, when available.
	pc: number?,
	--- Debugger instruction identifier for disassembly-oriented clients.
	instruction: string?,
}

--[=[
	Variable scope returned by `Session:scopes()`.
]=]
export type Scope = {
	--- Scope display name, such as `"Locals"` or `"Registers"`.
	name: string,
	--- Kind of values exposed by this scope.
	kind: ValueKind?,
	--- Value reference used to expand the scope with `inspect`.
	ref: ValueRef,
	--- Whether expanding the scope may be relatively expensive.
	expensive: boolean,
	--- Number of named children when known.
	namedCount: number?,
	--- Number of array-like children when known.
	indexedCount: number?,
	--- Source associated with this scope, when available.
	source: Source?,
	--- One-based source line associated with this scope, when available.
	line: number?,
	--- One-based source column associated with this scope, when available.
	column: number?,
}

--[=[
	Value returned by `Session:inspect()`, `Session:evaluate()`, or
	`Session:setVariable()`.
]=]
export type Value = {
	--- Display name for the value.
	name: string,
	--- Human-readable value summary.
	summary: string,
	--- Luau type name or debugger-specific type label.
	type: string?,
	--- Value reference for expansion, or `0` when the value has no children.
	ref: ValueRef,
	--- Kind of value reference.
	kind: ValueKind?,
	--- Number of named children when known.
	namedCount: number?,
	--- Number of array-like children when known.
	indexedCount: number?,
	--- Expression that can be evaluated to retrieve this value again.
	evaluateName: string?,
}

--[=[
	Expansion request for `Session:inspect()`.
]=]
export type InspectQuery = {
	--- Scope or value reference to expand.
	ref: ValueRef,
	--- Zero-based child offset.
	start: number?,
	--- Maximum number of children to return.
	count: number?,
	--- Child category to return.
	filter: ValueFilter?,
	--- Whether numeric summaries should prefer hexadecimal formatting.
	hex: boolean?,
}

--[=[
	Options for `Session:evaluate()`.
]=]
export type EvaluateOptions = {
	--- Frame used as the lexical evaluation context.
	frame: FrameId?,
	--- UI or protocol context for the evaluation request.
	context: EvaluateContext?,
	--- Whether numeric summaries should prefer hexadecimal formatting.
	hex: boolean?,
	--- Whether statement chunks may run when expression evaluation fails.
	allowStatements: boolean?,
}

--[=[
	Options for `Session:setVariable()`.
]=]
export type SetVariableOptions = {
	--- Frame used as the lexical evaluation context for the assigned expression.
	frame: FrameId?,
	--- Whether numeric summaries should prefer hexadecimal formatting.
	hex: boolean?,
}

--[=[
	Options for `Session:disassemble()`.
]=]
export type DisassembleOptions = {
	--- Source to disassemble. Defaults to the frame source or program source.
	source: (SourceId | Source)?,
	--- Frame whose source should be disassembled when `source` is omitted.
	frame: FrameId?,
	--- Whether local-variable debug information should be included.
	showLocals: boolean?,
	--- Whether compiler remarks should be included.
	showRemarks: boolean?,
	--- Whether type debug information should be included.
	showTypes: boolean?,
}

--[=[
	Result returned by `Session:evaluate()` and `Session:setVariable()`.
]=]
export type EvaluateResult =
	{
		--- Indicates that evaluation succeeded.
		ok: true,
		--- Evaluated value summary and expandable reference.
		value: Value,
	}
	| {
		--- Indicates that evaluation failed.
		ok: false,
		--- Error details for the failed evaluation.
		error: {
			--- Human-readable failure message.
			message: string,
			--- Optional debugger or Luau error category.
			type: string?,
		},
	}

--[=[
	Exception details captured for an exception stop.
]=]
export type Exception = {
	--- Exception identifier or category.
	id: string,
	--- Primary exception message.
	message: string?,
	--- Luau exception type name when available.
	typeName: string?,
	--- Human-readable exception description.
	description: string?,
	--- Formatted stack trace.
	stackTrace: string?,
	--- Source associated with the selected exception location.
	source: Source?,
	--- One-based source line associated with the exception.
	line: number?,
	--- One-based source column associated with the exception.
	column: number?,
}

--[=[
	Event emitted when the session state changes.
]=]
export type SessionEventState = {
	--- Event discriminator.
	kind: "state",
	--- New session state.
	state: SessionState,
	--- Thread related to the state change, when available.
	threadId: ThreadId?,
}

--[=[
	Event emitted when the debuggee stops.
]=]
export type SessionEventStopped = {
	--- Event discriminator.
	kind: "stopped",
	--- Thread that stopped.
	threadId: ThreadId,
	--- Reason execution stopped.
	reason: StopReason,
	--- Human-readable stop description.
	description: string?,
	--- Additional stop text, such as an exception message.
	text: string?,
	--- Breakpoints hit by this stop.
	breakpoints: { BreakpointId }?,
	--- Source location for the stop.
	source: Source?,
	--- One-based source line for the stop.
	line: number?,
	--- One-based source column for the stop.
	column: number?,
}

--[=[
	Event emitted for debuggee or debugger output.
]=]
export type SessionEventOutput = {
	--- Event discriminator.
	kind: "output",
	--- Output stream category.
	stream: OutputStream,
	--- Output text.
	text: string,
	--- Source associated with the output, when available.
	source: Source?,
	--- One-based source line associated with the output.
	line: number?,
	--- One-based source column associated with the output.
	column: number?,
}

--[=[
	Event emitted when a source is added, changed, or removed.
]=]
export type SessionEventSource = {
	--- Event discriminator.
	kind: "source-added" | "source-changed" | "source-removed",
	--- Source that changed.
	source: Source,
}

--[=[
	Event emitted when the debuggee terminates.
]=]
export type SessionEventTerminated = {
	--- Event discriminator.
	kind: "terminated",
	--- Process-style exit code when available.
	exitCode: number?,
}

--[=[
	Event returned by `Session:wait()`.
]=]
export type SessionEvent =
	SessionEventState
	| SessionEventStopped
	| SessionEventOutput
	| SessionEventSource
	| SessionEventTerminated

--[=[
	Options for `debugger.open()`.
]=]
export type SessionOptions = {
	--- Entry file for the debuggee.
	program: string,
	--- Command-line arguments visible to the debuggee.
	args: { string }?,
	--- Whether to pause before the first line executes.
	stopOnEntry: boolean?,
	--- Whether native codegen should be enabled for the debuggee.
	nativeCodegen: boolean?,
	--- Luau optimization level used to compile the debuggee.
	optimisationLevel: number?,
}

--[=[
	Debugger session returned by `debugger.open()`.
]=]
export type Session = setmetatable<
	{},
	{
		__index: {
			--- Starts the debuggee once breakpoints and listeners are configured.
			--- @return Nothing.
			start: (self: Session) -> (),

			--- Waits for and returns the next debugger event.
			--- @return Next debugger event, or `nil` when the session has ended and no events remain.
			--- @yields Until an event is available or the session is fully done.
			wait: (self: Session) -> SessionEvent?,

			--- Returns the current coarse session state.
			--- @return Current session state.
			state: (self: Session) -> SessionState,

			--- Returns known Luau coroutine threads in the debuggee.
			--- @return Known threads for the session.
			threads: (self: Session) -> { Thread },

			--- Resumes execution for a thread or the whole debuggee.
			--- @param threadId Thread to resume. Omit to resume the current paused debuggee.
			--- @return Nothing.
			resume: (self: Session, threadId: ThreadId?) -> (),

			--- Requests that execution pause at the next source-backed interrupt point.
			--- @param threadId Thread to pause. Omit to pause the next eligible running thread.
			--- @return Nothing.
			pause: (self: Session, threadId: ThreadId?) -> (),

			--- Steps a paused thread using the requested mode.
			--- @param mode Step operation to perform.
			--- @param threadId Paused thread to step. Omit to step the current paused thread.
			--- @return Nothing.
			step: (self: Session, mode: StepMode, threadId: ThreadId?) -> (),

			--- Requests debugger termination and debuggee shutdown.
			--- @return Nothing.
			terminate: (self: Session) -> (),

			--- Closes the session, optionally terminating the debuggee first.
			--- @param terminateDebuggee Whether to terminate a live debuggee before closing. Defaults to `true`.
			--- @return Nothing.
			close: (self: Session, terminateDebuggee: boolean?) -> (),

			--- Lists sources currently known to the debugger.
			--- @return Known sources.
			sources: (self: Session) -> { Source },

			--- Reads source text for a known source.
			--- @param source Source identifier or descriptor. Omit to read the program source.
			--- @return Source text, or an empty string when the source cannot be read.
			readSource: (self: Session, source: (SourceId | Source)?) -> string,

			--- Replaces source breakpoints for a source.
			--- @param source Source identifier or descriptor receiving the new breakpoint set.
			--- @param breakpoints Breakpoints to set for the source.
			--- @return Resolved breakpoint records.
			setBreakpoints: (
				self: Session,
				source: SourceId | Source,
				breakpoints: { BreakpointSpec }
			) -> { Breakpoint },

			--- Clears source breakpoints for one source, or all user breakpoints when omitted.
			--- @param source Source identifier or descriptor to clear. Omit to clear all user breakpoints.
			--- @return Nothing.
			clearBreakpoints: (self: Session, source: SourceId | Source?) -> (),

			--- Returns stack frames for a thread.
			--- @param threadId Thread whose frames should be returned. Omit to use the current stopped thread.
			--- @param start Zero-based frame offset.
			--- @param count Maximum number of frames to return.
			--- @return Frame page and total frame count.
			frames: (
				self: Session,
				threadId: ThreadId?,
				start: number?,
				count: number?
			) -> {
				--- Returned frame page.
				frames: { Frame },
				--- Total frames available for the thread.
				total: number?,
			},

			--- Returns the visible scopes for a frame.
			--- @param frame Frame identifier captured during the current pause.
			--- @return Scopes visible from the frame.
			scopes: (self: Session, frame: FrameId) -> { Scope },

			--- Expands values referenced by a scope or prior inspection result.
			--- @param query Value expansion request.
			--- @return Expanded child values.
			inspect: (self: Session, query: InspectQuery) -> { Value },

			--- Evaluates code in the context of a paused frame.
			--- @param expression Luau expression or, when allowed, statement chunk to evaluate.
			--- @param options Evaluation options.
			--- @return Evaluation result containing either a value or an error.
			evaluate: (self: Session, expression: string, options: EvaluateOptions?) -> EvaluateResult,

			--- Assigns a variable or table child referenced by a scope or inspection result.
			--- @param ref Scope or value reference containing the variable.
			--- @param name Variable name or table key to assign.
			--- @param expression Luau expression used to produce the assigned value.
			--- @param options Assignment options.
			--- @return Assignment result containing either the new value or an error.
			setVariable: (
				self: Session,
				ref: ValueRef,
				name: string,
				expression: string,
				options: SetVariableOptions?
			) -> EvaluateResult,

			--- Returns a VM bytecode disassembly for a source or paused frame.
			--- @param options Source, source descriptor, or disassembly options. Omit to disassemble the program source.
			--- @return Human-readable bytecode listing.
			disassemble: (self: Session, options: (SourceId | Source | DisassembleOptions)?) -> string,

			--- Returns the currently captured exception, if any.
			--- @param threadId Thread whose exception should be queried. Omit to query the current stopped thread.
			--- @return Captured exception details, or `nil` when no exception is available.
			exception: (self: Session, threadId: ThreadId?) -> Exception?,
		},
	}
>

local debugger = {}

--[=[
	Opens a debugger session for a Luau program.

	The debuggee is not started until `Session:start()` is called. Configure
	breakpoints and event consumers before starting the session.

	@param options Session options. `options.program` is required.
	@return New debugger session.
]=]
function debugger.open(options: SessionOptions): Session
	return nil :: any
end

--[=[
	Breaks into the active debugger from inside the debuggee.

	Call this from debuggee code to emit a `stopped` event with reason
	`"manual"`. If the current runtime is not running under `debugger.open()`,
	the call has no effect.

	@return Nothing.
]=]
function debugger.breakpoint() end

return table.freeze(debugger)
