--[=[
	WGSL shader creation.

	```luau
	local shader = require("@eryx/gfx/shader")
	local s = shader.load("myshader", wgslSource, uniforms?)
	```

	The returned Shader object has methods like :Set(name, ...) and :error()
	provided by the native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local shader = {}

--[=[
	Compiles a WGSL shader and returns a Shader object.
	@param name string
	@param source string -- WGSL source (vertex input/output structs are auto-injected)
	@param uniforms {{name: string, type: string}}? -- Optional custom uniform definitions
	@return Shader
]=]
shader.load = _gfx.loadShader

return shader
