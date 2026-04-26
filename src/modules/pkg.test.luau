local fs = require("@eryx/fs")
local json = require("@eryx/data/json")
local path = require("@eryx/path")
local pkg = require("@eryx/pkg")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("pkg")

local function join(base: string, child: string): string
	return tostring(path.join(base, child))
end

local function write(filePath: string, source: string)
	local parent = path.dirname(filePath)
	if parent ~= nil then
		fs.mkdir(parent)
	end
	fs.openSync(filePath, "w"):writeSync(source)
end

suite:test("install resolves local and local-copy packages", function()
	tempfile.withTempDir(function(root)
		local live = join(root, "live")
		local copied = join(root, "copied")
		fs.mkdir(live)
		fs.mkdir(join(live, "src"))
		fs.mkdir(copied)
		fs.mkdir(join(copied, "src"))

		write(
			join(live, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/live"
version = "1.0.0"
]]
		)
		write(join(live, "src/init.luau"), "return 1\n")
		write(
			join(copied, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/copied"
version = "2.0.0"
]]
		)
		write(join(copied, "src/init.luau"), "return 2\n")
		write(
			join(root, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"

[eryx.dependencies]
"@test/live" = { local = "./live" }
"@test/copied" = { local-copy = "./copied" }
]]
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(2)
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeTrue()
		test.expect(fs.isFile(join(root, "eryx_packages/test/copied/src/init.luau"))):toBeTrue()

		local rc = json.decode(fs.openSync(join(root, ".luaurc")):readSync())
		test.expect(rc.aliases["test/live"]):toBe("./live/src")
		test.expect(rc.aliases["test/copied"]):toBe("./eryx_packages/test/copied/src")
	end, "eryx-pkg-local")
end)

suite:test("install removes stale aliases that are still lock-owned", function()
	tempfile.withTempDir(function(root)
		local live = join(root, "live")
		fs.mkdir(live)
		write(
			join(live, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/live"
version = "1.0.0"
]]
		)
		write(
			join(root, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"

[eryx.dependencies]
"@test/live" = { local = "./live" }
]]
		)

		pkg.install(join(root, "eryx.toml"))

		write(
			join(root, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"
]]
		)

		pkg.install(join(root, "eryx.toml"))
		local rc = json.decode(fs.openSync(join(root, ".luaurc")):readSync())
		test.expect(rc.aliases["test/live"]):toBeNil()
	end, "eryx-pkg-stale")
end)

suite:test("install accepts manifest-less local aliases", function()
	tempfile.withTempDir(function(root)
		local modules = join(root, "modules")
		fs.mkdir(modules)
		write(join(modules, "thing.luau"), "return 3\n")
		write(
			join(root, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"

[eryx.dependencies]
eryx = { local = "./modules", package = "eryx" }
]]
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(1)
		test.expect(result.packages[1].version):toBeNil()

		local rc = json.decode(fs.openSync(join(root, ".luaurc")):readSync())
		test.expect(rc.aliases.eryx):toBe("./modules")
	end, "eryx-pkg-manifestless")
end)

suite:test("install does not write lock when config update is unsupported", function()
	tempfile.withTempDir(function(root)
		local modules = join(root, "modules")
		fs.mkdir(modules)
		write(join(modules, "thing.luau"), "return 3\n")
		write(join(root, ".config.luau"), "return {}\n")
		write(
			join(root, "eryx.toml"),
			[[
[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"

[eryx.dependencies]
eryx = { local = "./modules", package = "eryx" }
]]
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("cannot update %.config%.luau")
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeFalse()
	end, "eryx-pkg-no-lock-on-fail")
end)

return suite
