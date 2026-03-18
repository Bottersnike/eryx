--[=[
	Window creation and management.

	```luau
	local window = require("@eryx/gfx/window")
	local win = window.create(800, 600, "My App")
	```

	The returned Window object has methods like :PollEvents(), :StartFrame(),
	:EndFrame(), :DrawText(), :DrawTexture(), :DrawRectangle(), etc.
	These are provided by the native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local window = {}

--[=[
	Creates a new window.
	@param width number
	@param height number
	@param title string
	@return Window
]=]
window.create = _gfx.window_create

return window
