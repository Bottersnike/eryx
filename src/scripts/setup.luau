local json = require("@eryx/encoding/json")
local fs = require("@eryx/fs")
local luau = require("@eryx/luau")
local os = require("@eryx/os")

-- Resolve the path to a built-in module, but with a bogus CWD, to ensure we enter internal module resolution
local _, path = luau.resolve("@eryx/fs", "IM_A_BOGON_USED_TO_ENSURE_INTERNAL_MODULE_RESOLVING")

if path == "fs" then
	print("This command is unavailable in embedded builds")
	os.exit(1)
end

if not path then
	print("Failed to locate Eryx modules")
	os.exit(1)
end

local dir = fs.path.dirname(path)
if not fs.isDirectory(dir) then
	print("Located modules folder weirdly not a folder")
	os.exit(1)
end

if fs.exists(".config.luau") then
	print("Modification of .config.luau files is currently not supported.")

	print("Please add the following line to your aliases section:")
	print()
	print(`    eryx = {json.encode(dir)}`)

	os.exit(1)
end

if not fs.exists(".luaurc") then
	local newRc = { languageMode = "strict", aliases = { eryx = dir } }
	fs.open(".luaurc", "w"):write(json.encode(newRc, { pretty = true }))
else
	local rcData = fs.open(".luaurc", "r"):read()
	local ok, data = pcall(json.decode, rcData)
	if not ok then
		print("Failed to parse existing .luaurc as JSON")
		print("While .luaurc files are JSON-with-comments, this script only supports commentless JSON")
		print("Please add the following line to your aliases section:")
		print()
		print(`    eryx: {json.encode(dir)}`)
		os.exit(1)
	end

	if data.aliases and data.aliases.eryx and data.aliases.eryx ~= dir then
		print("Existing @eryx alias already present")
		print("For full type-checking, please modify the @eryx alias to:")
		print()
		print(json.encode(dir))

		os.exit(1)
	end

	data.aliases.eryx = dir
	fs.open(".luaurc", "w"):write(json.encode(data, { pretty = true }))
end

print("Project setup complete. You may need to restart your IDE.")
