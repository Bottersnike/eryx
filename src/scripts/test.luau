local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local test = require("@eryx/test")

local parser = argparse.Parser.new("eryx test", "Run .test.luau test suites")
parser:AddPositional("path", "string", nil, true, "File or directory to test")

local args = parser:Parse()
local path = fs.canonicalize(args.path)

if fs.isDirectory(path) then
	test.runAll(path)
elseif fs.isFile(path) then
	test.runOne(path)
else
	error(`{args.path}: not a file or directory`)
end
