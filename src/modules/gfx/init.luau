--[=[
	Graphics module aggregator. Provides convenient access to all
	gfx sub-modules via a single require:

	```luau
	local gfx = require("@eryx/gfx")
	local win = gfx.window.create(800, 600, "Hello")
	local img = gfx.texture.load("sprite.png")
	```

	Or require individual sub-modules directly:
	```luau
	local window = require("@eryx/gfx/window")
	```
]=]

local _gfx = require("@eryx/gfx/_gfx")

return {
	window = require("@eryx/gfx/window"),
	mouse = require("@eryx/gfx/mouse"),
	texture = require("@eryx/gfx/texture"),
	font = require("@eryx/gfx/font"),
	shader = require("@eryx/gfx/shader"),
	sound = require("@eryx/gfx/sound"),
	particles = require("@eryx/gfx/particles"),

	shutdown = _gfx.shutdown,
}
