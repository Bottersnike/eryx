--[=[
	Mouse input utilities.

	```luau
	local mouse = require("@eryx/gfx/mouse")
	local x, y = mouse.getPosition()
	```
]=]

local _gfx = require("@eryx/gfx/_gfx")

local mouse = {}

--[=[
	Returns whether a mouse is available.
	@return boolean
]=]
mouse.available = _gfx.mouse_available

--[=[
	Returns the current mouse position.
	@return number x
	@return number y
]=]
mouse.getPosition = _gfx.mouse_getPosition

--[=[
	Returns a table of currently pressed mouse buttons.
	@return {left: boolean, right: boolean, middle: boolean, side1: boolean, side2: boolean}
]=]
mouse.getButtons = _gfx.mouse_getButtons

return mouse
