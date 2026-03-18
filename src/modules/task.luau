--[=[
	Roblox-compatible task scheduling library backed by libuv timers.

	**Example:**
	```luau
	local task = require("@eryx/task")

	task.spawn(function()
		print("tick 1")
		local dt = task.wait(1)
		print("tick 2 after", dt, "s")
	end)
	```

	When the top-level script yields, the libuv event loop drives timer
	callbacks that resume coroutines automatically - no manual `task.step()`
	call is required (though it is still available for backward compatibility).
]=]

local task = {}

function task.spawn(functionOrThread: ((...any) -> ...any) | thread, ...: any): thread return nil :: any end
function task.defer(functionOrThread: ((...any) -> ...any) | thread, ...: any): thread return nil :: any end
function task.delay(duration: number, functionOrThread: ((...any) -> ...any) | thread, ...: any): thread return nil :: any end
function task.wait(duration: number?): number return 0 end
function task.cancel(t: thread) end

return task
