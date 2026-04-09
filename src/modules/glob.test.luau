local fs = require("@eryx/fs")
local glob = require("@self/glob")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("glob")

local function sorted(list: { string }): { string }
	local out = table.clone(list)
	table.sort(out)
	return out
end

local function joinSorted(list: { string }): string
	return table.concat(sorted(list), "|")
end

suite:test("match supports basic wildcard tokens", function()
	test.expect(glob.match("src/modules/glob.luau", "src/*/glob.luau")):toBeTrue()
	test.expect(glob.match("a.lua", "?.lua")):toBeTrue()
	test.expect(glob.match("cat", "[cb]at")):toBeTrue()
	test.expect(glob.match("dog", "[!cb]og")):toBeTrue()
	test.expect(glob.match("bat", "[!cb]at")):toBeFalse()
end)

suite:test("escape and escaped literals work", function()
	local literal = "docs/[draft]*.md"
	local escaped = glob.escape(literal)
	test.expect(glob.match(literal, escaped)):toBeTrue()
	test.expect(glob.match("docs/xdrafty.md", escaped)):toBeFalse()

	test.expect(glob.match("file*name.txt", "file\\*name.txt")):toBeTrue()
	test.expect(glob.match("fileZname.txt", "file\\*name.txt")):toBeFalse()
end)

suite:test("globstar spans path segments", function()
	test.expect(glob.match("src/modules/glob.luau", "src/**/glob.luau")):toBeTrue()
	test.expect(glob.match("src/glob.luau", "src/**/glob.luau")):toBeTrue()
	test.expect(glob.match("src/modules/crypto/password.luau", "src/**/glob.luau")):toBeFalse()
end)

suite:test("filter and gmatch work against arrays", function()
	local files = {
		"docs/readme.md",
		"src/modules/glob.luau",
		"src/modules/crypto/password.luau",
		"src/main.cpp",
	}

	local filtered = glob.filter(files, "src/**/*.luau")
	test.expect(joinSorted(filtered)):toBe("src/modules/crypto/password.luau|src/modules/glob.luau")

	local it = glob.gmatch(files, "src/**/*.luau")
	local seen = {}
	while true do
		local value = it()
		if value == nil then
			break
		end
		table.insert(seen, value)
	end
	test.expect(joinSorted(seen)):toBe("src/modules/crypto/password.luau|src/modules/glob.luau")
end)

suite:test("glob can walk filesystem and apply ignore patterns", function()
	tempfile.withTempDir(function(dir: string)
		local function write(rel: string)
			local abs = fs.path.join(dir, rel)
			local parent = fs.path.dirname(abs)
			if parent ~= "" and not fs.exists(parent) then
				fs.mkdir(parent)
			end
			local handle = fs.openSync(abs, "w")
			handle:writeSync("x")
			handle:closeSync()
		end

		write("docs/guide.md")
		write("docs/ref/api.md")
		write("src/glob.luau")
		write("src/crypto/password.luau")
		write("src/crypto/password.test.luau")

		local all = glob.glob("**/*.luau", { root = dir })
		test.expect(joinSorted(all)):toBe("src/crypto/password.luau|src/crypto/password.test.luau|src/glob.luau")

		local ignored = glob.glob("**/*", {
			root = dir,
			ignore = { "docs/**", "**/*.test.luau" },
		})

		test.expect(joinSorted(ignored)):toBe("src|src/crypto|src/crypto/password.luau|src/glob.luau")
	end)
end)

return suite
