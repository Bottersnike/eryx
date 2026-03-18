--[=[
	Image texture loading.

	```luau
	local texture = require("@eryx/gfx/texture")
	local img = texture.load("sprite.png")
	```

	The returned Texture object has methods like :size() provided
	by the native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local texture = {}

--[=[
	Loads an image file and returns a Texture.
	@param filename string
	@return Texture
]=]
texture.load = _gfx.loadImage

return texture
