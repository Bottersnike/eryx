--[=[
	Run Luau work in isolated child runtimes backed by OS threads.

	Threads can be spawned one at a time with [[thread.spawn]], reused through a
	[[ThreadPool]], or preconfigured as a [[ThreadWorker]] for repeated jobs.

	Child entrypoints always receive a context object. That context exposes:
	- `value`: the initial payload sent by the parent
	- `send(...)`: publish messages back to the parent
	- `update(...)`: publish progress updates for pooled jobs
	- `recv()`: wait for a value from the parent

	**Example:**
	```luau
	local thread = require("@eryx/thread")

	local handle = thread.spawn(function(ctx)
		ctx:send("ready")
		local input = ctx:recv()
		return input * 2
	end)

	print(handle:recv()) -- "ready"
	handle:send(21)
	print(handle:join()) -- 42
	```
]=]

local exception = require("@eryx/exception")

--- Lifecycle states exposed by a direct thread handle.
export type Status = "starting" | "running" | "finished" | "error" | "killed" | "interrupted"

--- Lifecycle states exposed by pooled work items.
export type FutureStatus = "queued" | "running" | "finished" | "error" | "cancelled"

--- Exception payload copied back from a failed child runtime.
export type Exception = exception.Exception

--[=[
	Context object passed into a child thread entrypoint.

	Generic parameters are expressed from the child's point of view:
	- `InitialData`: initial payload supplied by the parent
	- `SendData`: values sent from the child to the parent via `send`
	- `UpdateData`: values published from the child to the parent via `update`
	- `RecvData`: values received from the parent via `recv`
]=]
export type ThreadContext<InitialData, SendData, UpdateData, RecvData> = setmetatable<
	{
		--- Initial payload provided when the thread or job was started.
		read value: InitialData,
	},
	{
		__index: {
			--[=[
				Send a message from the child thread back to the parent handle.

				@param value Message payload delivered to the parent through `handle:recv()`.
			]=]
			send: (self: ThreadContext<InitialData, SendData, UpdateData, RecvData>, value: SendData) -> (),
			--[=[
				Publish a progress update for a pooled or worker-backed job.

				Updates are surfaced on the parent-side future through `future.update`
				and `future.onUpdate`.

				@param value Progress payload to publish to the parent runtime.
			]=]
			update: (self: ThreadContext<InitialData, SendData, UpdateData, RecvData>, value: UpdateData) -> (),
			--[=[
				Wait for the next message from the parent.

				@return Next payload sent from the parent thread or pooled caller.
			]=]
			recv: (self: ThreadContext<InitialData, SendData, UpdateData, RecvData>) -> RecvData,
		},
	}
>

--- Untyped alias for child thread contexts.
export type AnyThreadContext = ThreadContext<any, any, any, any>

--[=[
	Handle to a directly spawned child thread.

	Generic parameters are expressed from the parent's point of view:
	- `SendData`: values the parent sends to the child
	- `RecvData`: values the parent receives from the child
	- `ResultData`: final value returned by `join`
]=]
export type ThreadHandle<SendData, RecvData, ResultData> = setmetatable<
	{
		--- Current lifecycle state of the child thread.
		read status: Status,
		--- Copied exception payload when the thread has failed, otherwise `nil`.
		read error: Exception?,
	},
	{
		__index: {
			--[=[
				Optional callback invoked on the parent runtime when the thread errors.

				@param handle Original thread handle that raised the error.
				@param err Copied exception payload from the child runtime.
			]=]
			onError: ((handle: ThreadHandle<SendData, RecvData, ResultData>, err: Exception) -> ())?,
			--[=[
				Send a value from the parent to the child thread.

				@param value Payload made available to the child through `context:recv()`.
			]=]
			send: (self: ThreadHandle<SendData, RecvData, ResultData>, value: SendData) -> (),
			--[=[
				Wait for the next message sent from the child thread.

				@return Next payload published by the child through `context:send()`.
			]=]
			recv: (self: ThreadHandle<SendData, RecvData, ResultData>) -> RecvData,
			--[=[
				Wait for the thread to finish and return its final result.

				@return Final value returned by the child entrypoint.
			]=]
			join: (self: ThreadHandle<SendData, RecvData, ResultData>) -> ResultData,
			--[=[
				Request that the child thread stop as soon as possible.

				@return Nothing.
			]=]
			kill: (self: ThreadHandle<SendData, RecvData, ResultData>) -> (),
		},
	}
>

--- Untyped alias for direct thread handles.
export type AnyThreadHandle = ThreadHandle<any, any, any>

--[=[
	Thread entrypoint function.

	The generic parameter order is written from the API caller's point of view,
	but the actual context object flips send/receive directions so the child sees
	the correct interface:
	- parent `SendData` becomes child `RecvData`
	- parent `RecvData` becomes child `SendData`

	@param context Child-side thread context used to exchange data with the parent.
	@return Final value returned to the parent through `join()` or `wait()`.
]=]
export type ThreadEntryFunction<InitialData, SendData, UpdateData, RecvData, ResultData> = (
	context: ThreadContext<InitialData, RecvData, UpdateData, SendData>
) -> ResultData

--[=[
	Handle to a pooled job or worker submission.

	`wait()` returns the job result, while `update` and `onUpdate` expose the most
	recent progress value published by the child thread.
]=]
export type Future<UpdateData, ResultData> = setmetatable<
	{
		--- Current lifecycle state for this queued or running job.
		read status: FutureStatus,
		--- Copied exception payload when the job has failed or been cancelled.
		read error: Exception?,
		--- Most recent progress value published by the child, if any.
		read update: UpdateData?,
	},
	{
		__index: {
			--[=[
				Optional callback invoked on the parent runtime when the job errors.

				@param future Original future that failed.
				@param err Copied exception payload from the child runtime.
			]=]
			onError: ((future: Future<UpdateData, ResultData>, err: Exception) -> ())?,
			--[=[
				Optional callback invoked whenever the child publishes an update.

				@param future Original future that received the update.
				@param value Latest progress payload published by the child.
			]=]
			onUpdate: ((future: Future<UpdateData, ResultData>, value: UpdateData) -> ())?,
			--[=[
				Wait for the job to finish and return its final result.

				@return Final value returned by the pooled job.
			]=]
			wait: (self: Future<UpdateData, ResultData>) -> ResultData,
		},
	}
>

--- Pool of reusable worker slots for ad-hoc thread jobs.
export type ThreadPool = setmetatable<
	{
		--- Maximum number of jobs that may run in parallel.
		read workers: number,
		--- Number of jobs currently running.
		read active: number,
		--- Number of jobs currently queued waiting for a free worker slot.
		read queued: number,
	},
	{
		__index: {
			--[=[
				Default error callback for futures created by this pool.

				@param future Future that failed.
				@param err Copied exception payload from the child runtime.
			]=]
			onError: (<T, U>(future: Future<T, U>, err: Exception) -> ())?,
			--[=[
				Default update callback for futures created by this pool.

				@param future Future that received the update.
				@param value Latest progress payload published by the child.
			]=]
			onUpdate: (<T, U>(future: Future<T, U>, value: T) -> ())?,
			--[=[
				Queue a job to run on the pool and return a future for its result.

				@param entry File path or pure Luau function to execute for this job.
				@param context Initial payload exposed to the child as `context.value`.
				@return Future that resolves to the job result and receives progress updates.
			]=]
			spawn: <InitialData, SendData, UpdateData, RecvData, ResultData>(
				self: ThreadPool,
				entry: string | ThreadEntryFunction<InitialData, SendData, UpdateData, RecvData, ResultData>,
				context: InitialData
			) -> Future<UpdateData, ResultData>,
		},
	}
>

--[=[
	Preconfigured worker that reuses the same job entry for every submission.

	This is useful when you want pool-like parallelism but do not want to pass the
	entry function or file path on every call.
]=]
export type ThreadWorker<InitialData, UpdateData, ResultData> = setmetatable<
	{
		--- Maximum number of jobs that may run in parallel.
		read workers: number,
		--- Number of jobs currently running.
		read active: number,
		--- Number of jobs currently queued waiting for a free worker slot.
		read queued: number,
	},
	{
		__index: {
			--[=[
				Default error callback for futures created by this worker.

				@param future Future that failed.
				@param err Copied exception payload from the child runtime.
			]=]
			onError: ((future: Future<UpdateData, ResultData>, err: Exception) -> ())?,
			--[=[
				Default update callback for futures created by this worker.

				@param future Future that received the update.
				@param value Latest progress payload published by the child.
			]=]
			onUpdate: ((future: Future<UpdateData, ResultData>, value: UpdateData) -> ())?,
			--[=[
				Submit one or more payloads to the worker's configured job entry.

				When called with one payload, this returns a single future. When
				called with multiple payloads, it returns an array of futures in the
				same order as the submitted inputs.

				@param ... One or more initial payloads to run through the worker's job entry.
				@return Future when called with one payload, or an array of futures when called with many.
			]=]
			submit: ((
				self: ThreadWorker<InitialData, UpdateData, ResultData>,
				InitialData
			) -> Future<UpdateData, ResultData>) & ((
				self: ThreadWorker<InitialData, UpdateData, ResultData>,
				InitialData,
				InitialData,
				...InitialData
			) -> { Future<UpdateData, ResultData> }),
		},
	}
>

--- Options for constructing a thread pool.
export type PoolOptions = {
	--- Maximum number of jobs that may run in parallel.
	workers: number,
}

--- Options for constructing a preconfigured thread worker.
export type WorkerOptions<InitialData, SendData, UpdateData, RecvData, ResultData> = {
	--- Maximum number of jobs that may run in parallel.
	workers: number,
	--- Job entry to run for every submission made through this worker.
	job: string | ThreadEntryFunction<InitialData, SendData, UpdateData, RecvData, ResultData>,
}

local thread = {}

--[=[
	Spawn a single child thread immediately.

	`entry` may be a file path or a pure Luau function that can be serialized into
	the child runtime. The returned handle can be used for bidirectional messaging,
	error observation, and final result collection.

	@param entry File path or pure Luau function to execute in the child runtime.
	@param context Initial payload exposed to the child as `context.value`.
	@return Handle used to communicate with the child and collect its final result.
]=]
function thread.spawn<InitialData, SendData, UpdateData, RecvData, ResultData>(
	entry: string | ThreadEntryFunction<
		InitialData,
		SendData,
		UpdateData,
		RecvData,
		ResultData
	>,
	context: InitialData
): ThreadHandle<
	SendData,
	RecvData,
	ResultData
>
	return nil :: any
end

--[=[
	Return the number of logical CPUs visible to the host process.

	This is a good default upper bound when choosing a pool size for CPU-bound
	work, though IO-bound workloads may prefer different tuning.

	@return Number of logical CPUs reported by the operating system.
]=]
function thread.cpuCount(): number
	return nil :: any
end

--[=[
	Create a thread pool for running many jobs with bounded concurrency.

	Each call to `pool:spawn(...)` returns a future that resolves when that job
	completes.

	@param options Pool construction options such as worker-count limits.
	@return Thread pool that queues jobs and runs them with bounded parallelism.
]=]
function thread.pool(options: PoolOptions): ThreadPool
	return nil :: any
end

--[=[
	Create a reusable worker with a fixed job entry and bounded concurrency.

	Each call to `worker:submit(...)` reuses the configured `job` entry and only
	changes the submitted payload.

	@param options Worker construction options including the shared job entry.
	@return Reusable worker that submits payloads to the configured job entry.
]=]
function thread.worker<InitialData, SendData, UpdateData, RecvData, ResultData>(
	options: WorkerOptions<
		InitialData,
		SendData,
		UpdateData,
		RecvData,
		ResultData
	>
): ThreadWorker<
	InitialData,
	UpdateData,
	ResultData
>
	return nil :: any
end

return table.freeze(thread)
