--[=[
	Font loading for text rendering.

	```luau
	local font = require("@eryx/gfx/font")
	local f = font.load("arial.ttf", 24)
	```

	The returned Font object has methods like :Measure(text) provided
	by the native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local font = {}

--[=[
	Loads a font file at the given pixel size and returns a Font.
	@param filename string
	@param size number
	@return Font
]=]
font.load = _gfx.loadFont

return font
