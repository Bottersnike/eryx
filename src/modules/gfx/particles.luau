--[=[
	Particle system creation.

	```luau
	local particles = require("@eryx/gfx/particles")
	local ps = particles.createSystem({ life = 2, speed = 100, ... })
	```

	The returned ParticleSystem object has methods like :Update(dt),
	:Draw(window), :SpawnParticles(x, y, count?) provided by the
	native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local particles = {}

--[=[
	Creates a new particle system.
	@param config {life, speed, angle, size, color, texture?, gravity?}
	@return ParticleSystem
]=]
particles.createSystem = _gfx.particles_createSystem

return particles
