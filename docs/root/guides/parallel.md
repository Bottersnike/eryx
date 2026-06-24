# Running code in parallel

Doing more than one thing at once can be very powerful. Eryx offers two distinct tools for it, and they solve different problems:

- **Cooperative multitasking** with [[@eryx/task]], where many tasks share a single runtime and take turns. This is ideal for IO-bound work such as waiting on the network or the filesystem.
- **True parallelism** with [[@eryx/thread]], where work runs on separate OS threads and genuinely executes at the same time. This is ideal for CPU-bound work you want spread across multiple cores.

## Cooperative multitasking with `task`

Within a single runtime, only one section of code ever runs at a given time, but it can "yield" to another section while waiting on a long-running operation to complete. This is [cooperative multitasking](https://en.wikipedia.org/wiki/Cooperative_multitasking). Luau provides the [coroutine library](https://luau.org/library/#coroutine-library) to write "coroutines" that explicitly yield.

Rather than ever using raw coroutines, it is recommended to always use the [[@eryx/task]] library. This library provides a simpler interface to coroutines, in addition to utilities such as `task.wait` and `task.delay`.

Across the Eryx API, many library functions are marked as yielding. This means when they are called there is an opportunity for control to be handed to a different task. Generally these are functions that can take a significant amount of time, such as connecting to a network server.

:::danger
Eryx cannot forcibly interrupt your code if you never call a yielding function. If you spawn a task that never returns or yields (such as an empty infinite loop) no other code will ever run.

Great care is advised when writing multi-tasking code. For infinite loops the following pattern is strongly recommend:

```luau
while task.wait() do
    ...
end
```
:::

## True parallelism with threads

Cooperative multitasking never runs two pieces of Luau at the same instant, so it cannot speed up CPU-bound work. For that, [[@eryx/thread]] runs Luau in isolated child runtimes backed by real OS threads, so multiple jobs execute simultaneously across cores.

Each child runtime is fully isolated: there is no shared memory between threads. Instead, you give a thread an entrypoint (a file path, or a pure Luau function that can be serialized into the child) along with an initial payload, and the two sides exchange data by passing messages. Values are copied across the boundary rather than shared.

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

The child entrypoint receives a context object exposing `value` (the initial payload), `send(...)` and `recv()` for messaging the parent, and `update(...)` for publishing progress. The parent's handle mirrors this with `send`, `recv`, `join` (wait for the final result), and `kill` (request the thread stop).

### Running many jobs

For more than a single thread, two higher-level helpers manage bounded concurrency:

- `thread.pool({ workers = n })` queues jobs and runs up to `n` at a time. Each `pool:spawn(entry, payload)` returns a future you can `wait()` on.
- `thread.worker({ workers = n, job = entry })` is a pool preconfigured with one fixed job, so each `worker:submit(payload)` reuses the same entry.

`thread.cpuCount()` reports the number of logical CPUs, which is a good default upper bound when sizing a pool for CPU-bound work.

See the [[@eryx/thread]] reference for the full API, including futures, progress updates, and error handling.
