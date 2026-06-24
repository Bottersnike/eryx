local argparse = require("@eryx/argparse")
local fs = require("@eryx/fs")
local test = require("@eryx/test")

local parser = argparse.Parser.new("eryx test", "Run .test.luau test suites")
parser:addPositional("paths", "string", nil, true, "Files or directories to test", true)

local args = parser:parse()
local rawPaths = args.paths :: { string }

local paths: { string } = {}
for _, p in rawPaths do
	table.insert(paths, fs.path.canonicalize(p))
end

if #paths == 1 then
	local path = paths[1]
	if fs.isDirectory(path) then
		test.runAll(path)
	elseif fs.isFile(path) then
		test.runOne(path)
	else
		error(`{rawPaths[1]}: not a file or directory`)
	end
else
	test.runAll(paths)
end
