# Running code in parallel

Parallel code can be very powerful, allowing multiple actions to be performed simultaneously.

Luau does not support threads, nor does Eryx add threads. Luau does however support [cooperative multitasking](https://en.wikipedia.org/wiki/Cooperative_multitasking).

Cooperative multitasking means only one section of code ever runs at a given time, but it can "yield" to another section of code while waiting on a long-running operation to complete. Luau provides the [coroutine library](https://luau.org/library/#coroutine-library) which allows programmers to write "coroutines" which can explicitly yield.

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
