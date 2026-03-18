local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local vfs = require("@eryx/vfs")

local parser = argparse.Parser.new("eryx compile", "Bundle files into a standalone executable")
parser:AddPositional("root", "string", nil, true, "Project root directory")
parser:AddPositional("output", "string", nil, true, "Output executable path")
parser:AddPositional("entrypoint", "string", nil, true, "Entrypoint script (relative to root)")
parser:AddOption("source-exe", "s", "string", nil, false, "Source executable to clone (default: current)")

local args = parser:Parse()

-- Collect all files under root
local files = {}
local function walk(dir: string)
	for _, entry in fs.listDir(dir) do
		local full = fs.join(dir, entry)
		if fs.isDirectory(full) then
			walk(full)
		elseif fs.isFile(full) then
			table.insert(files, full)
		end
	end
end
walk(args.root)

local options = {
	outputExe = args.output,
	root = args.root,
	entrypoint = args.entrypoint,
	files = files,
	sourceExe = args["source-exe"],
}

vfs.build(options)
print(`Bundle written to: {args.output}`)
