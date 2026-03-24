--[=[
	Audio loading and playback via miniaudio.

	```luau
	local sound = require("@eryx/gfx/sound")
	sound.init()
	local sfx = sound.load("click.wav")
	sfx:play()
	```

	The returned Sound object has methods like :play(), :stop(),
	:setVolume(), :setCursor(), :getCursor(), :getDuration()
	provided by the native metatable.
]=]

local _gfx = require("@eryx/gfx/_gfx")

local sound = {}

--[=[
	Initialises the audio engine. Must be called before loading sounds.
	@param channels number? -- Default 2
	@param sampleRate number? -- Default 48000
]=]
sound.init = _gfx.sound_init

--[=[
	Loads an audio file and returns a Sound.
	@param filename string
	@param voiceCount number? -- Number of concurrent voices (default 4)
	@return Sound
]=]
sound.load = _gfx.sound_load

return sound
