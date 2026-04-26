local fs = require("@eryx/fs")
local json = require("@eryx/data/json")
local os = require("@eryx/os")
local path = require("@eryx/path")
local pkg = require("@eryx/pkg")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("pkg")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function join(base: string, child: string): string
	return tostring(path.join(base, child))
end

local function write(filePath: string, source: string)
	local parent = path.dirname(filePath)
	if parent ~= nil then
		fs.mkdir(parent)
	end
	local f = fs.openSync(filePath, "w")
	f:writeSync(source)
	f:closeSync()
end

local function readJson(filePath: string): { [string]: any }
	local f = fs.openSync(filePath)
	local content = f:readSync()
	f:closeSync()
	return json.decode(content) :: { [string]: any }
end

local function readFile(filePath: string): string
	local f = fs.openSync(filePath)
	local content = f:readSync()
	f:closeSync()
	return content
end

-- Creates a minimal eryx.toml string.
local function manifest(name: string, version: string, deps: string?): string
	local depSection = if deps then `\n[eryx.dependencies]\n{deps}` else ""
	return `[eryx]\nmanifest-version = 1\n\n[eryx.project]\nname = "{name}"\nversion = "{version}"{depSection}\n`
end

-- Creates a minimal git repo in `dir` with the given eryx.toml content and returns
-- the commit hash.  Pass `nil` to omit eryx.toml entirely.
local function makeGitRepoRaw(dir: string, eryxTomlContent: string?): string
	fs.mkdir(dir)
	if eryxTomlContent ~= nil then
		write(join(dir, "eryx.toml"), eryxTomlContent)
	end
	write(join(dir, "src/init.luau"), "return nil\n")

	local function git(...: string): string
		local args = { ... }
		local result = os.exec("git", args, { cwd = dir })
		if result.code ~= 0 then
			error(`git {table.concat(args, " ")} failed: {result.stderr}`)
		end
		return result.stdout:match("^%s*(.-)%s*$") or ""
	end

	git("init", "--initial-branch=main")
	git("config", "user.email", "test@eryx.test")
	git("config", "user.name", "Eryx Test")
	git("config", "commit.gpgsign", "false")
	git("config", "tag.gpgsign", "false")
	git("add", ".")
	git("commit", "--quiet", "-m", "initial")

	return git("rev-parse", "HEAD")
end

-- Creates a minimal bare git repo in `dir` and returns the commit hash of the
-- initial commit.  The repo contains a single eryx.toml described by `name`/`version`.
local function makeGitRepo(dir: string, name: string, version: string): string
	fs.mkdir(dir)
	write(join(dir, "eryx.toml"), manifest(name, version))
	write(join(dir, "src/init.luau"), `return "hello from {name}"\n`)

	local function git(...: string): string
		local args = { ... }
		local result = os.exec("git", args, { cwd = dir })
		if result.code ~= 0 then
			error(`git {table.concat(args, " ")} failed: {result.stderr}`)
		end
		return result.stdout:match("^%s*(.-)%s*$") or ""
	end

	git("init", "--initial-branch=main")
	git("config", "user.email", "test@eryx.test")
	git("config", "user.name", "Eryx Test")
	git("config", "commit.gpgsign", "false")
	git("config", "tag.gpgsign", "false")
	git("add", ".")
	git("commit", "--quiet", "-m", "initial")

	return git("rev-parse", "HEAD")
end

-- Adds a second commit to a repo and returns its hash.
local function addGitCommit(dir: string, filename: string, content: string): string
	write(join(dir, filename), content)

	local function git(...: string): string
		local args = { ... }
		local result = os.exec("git", args, { cwd = dir })
		if result.code ~= 0 then
			error(`git {table.concat(args, " ")} failed: {result.stderr}`)
		end
		return result.stdout:match("^%s*(.-)%s*$") or ""
	end

	git("add", ".")
	git("commit", "--no-gpg-sign", "--quiet", "-m", "update")
	return git("rev-parse", "HEAD")
end

-- Returns true when git is available on PATH.
local function gitAvailable(): boolean
	local result = os.exec("git", { "--version" })
	return result.code == 0
end

-- Converts a filesystem path to forward slashes for embedding in TOML strings.
-- TOML basic strings treat backslash as an escape character, so Windows paths
-- must be normalised before use as values.
local function tomlPath(p: string): string
	return (p:gsub("\\", "/"))
end

-- ── Local source tests ───────────────────────────────────────────────────────

suite:test("install resolves local and local-copy packages", function()
	tempfile.withTempDir(function(root)
		local live = join(root, "live")
		local copied = join(root, "copied")
		fs.mkdir(live)
		fs.mkdir(join(live, "src"))
		fs.mkdir(copied)
		fs.mkdir(join(copied, "src"))

		write(join(live, "eryx.toml"), manifest("@test/live", "1.0.0"))
		write(join(live, "src/init.luau"), "return 1\n")
		write(join(copied, "eryx.toml"), manifest("@test/copied", "2.0.0"))
		write(join(copied, "src/init.luau"), "return 2\n")
		write(
			join(root, "eryx.toml"),
			manifest(
				"@test/root",
				"0.1.0",
				[[
"@test/live" = { local = "./live" }
"@test/copied" = { local-copy = "./copied" }
]]
			)
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(2)
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeTrue()
		test.expect(fs.isFile(join(root, "eryx_packages/test/copied/src/init.luau"))):toBeTrue()

		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases["test/live"]):toBe("./live/src")
		test.expect(rc.aliases["test/copied"]):toBe("./eryx_packages/test/copied/src")
	end, "eryx-pkg-local")
end)

suite:test("install removes stale aliases that are still lock-owned", function()
	tempfile.withTempDir(function(root)
		local live = join(root, "live")
		fs.mkdir(live)
		write(join(live, "eryx.toml"), manifest("@test/live", "1.0.0"))
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/live" = { local = "./live" }]]))

		pkg.install(join(root, "eryx.toml"))

		-- Remove the dependency from the manifest and reinstall.
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0"))
		pkg.install(join(root, "eryx.toml"))

		local rc = readJson(join(root, ".luaurc"))
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
			manifest("@test/root", "0.1.0", [[eryx = { local = "./modules", package = "eryx" }]])
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(1)
		test.expect(result.packages[1].version):toBeNil()

		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases.eryx):toBe("./modules")
	end, "eryx-pkg-manifestless")
end)

suite:test("install respects package root metadata", function()
	tempfile.withTempDir(function(root)
		local packageRoot = join(root, "package")
		fs.mkdir(packageRoot)
		fs.mkdir(join(packageRoot, "lib"))
		write(join(packageRoot, "lib/init.luau"), "return 5\n")
		write(join(packageRoot, "eryx.toml"), manifest("@test/custom-root", "1.0.0") .. 'source-root = "lib"\n')
		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", [["@test/custom-root" = { local = "./package" }]])
		)

		pkg.install(join(root, "eryx.toml"))

		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases["test/custom-root"]):toBe("./package/lib")
	end, "eryx-pkg-package-root")
end)

suite:test("install does not write lock when config update is unsupported", function()
	tempfile.withTempDir(function(root)
		local modules = join(root, "modules")
		fs.mkdir(modules)
		write(join(modules, "thing.luau"), "return 3\n")
		write(join(root, ".config.luau"), "return {}\n")
		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", [[eryx = { local = "./modules", package = "eryx" }]])
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("cannot update %.config%.luau")
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeFalse()
	end, "eryx-pkg-no-lock-on-fail")
end)

suite:test("install validates copy plan before writing files", function()
	tempfile.withTempDir(function(root)
		local source = join(root, "eryx_packages/test/copied")
		fs.mkdir(source)
		write(join(source, "init.luau"), "return 4\n")
		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", [["@test/copied" = { local-copy = "./eryx_packages/test/copied" }]])
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("same path")
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeFalse()
		test.expect(fs.isFile(join(root, ".luaurc"))):toBeFalse()
	end, "eryx-pkg-validate-before-write")
end)

suite:test("install resolves transitive local dependencies", function()
	tempfile.withTempDir(function(root)
		-- root -> a -> b
		local a = join(root, "a")
		local b = join(root, "b")
		fs.mkdir(join(a, "src"))
		fs.mkdir(join(b, "src"))
		write(join(b, "eryx.toml"), manifest("@test/b", "1.0.0"))
		write(join(b, "src/init.luau"), "return 'b'\n")
		write(join(a, "eryx.toml"), manifest("@test/a", "1.0.0", [["@test/b" = { local = "../b" }]]))
		write(join(a, "src/init.luau"), "return 'a'\n")
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/a" = { local = "./a" }]]))

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(2)
		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases["test/a"]):toNotBeNil()
		test.expect(rc.aliases["test/b"]):toNotBeNil()
	end, "eryx-pkg-transitive")
end)

suite:test("install rejects cyclic local dependencies", function()
	tempfile.withTempDir(function(root)
		local a = join(root, "a")
		local b = join(root, "b")
		fs.mkdir(a)
		fs.mkdir(b)
		write(join(a, "eryx.toml"), manifest("@test/a", "1.0.0", [["@test/b" = { local = "../b" }]]))
		write(join(b, "eryx.toml"), manifest("@test/b", "1.0.0", [["@test/a" = { local = "../a" }]]))
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/a" = { local = "./a" }]]))

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("cyclic")
	end, "eryx-pkg-cyclic")
end)

suite:test("install rejects conflicting aliases pointing at different paths", function()
	tempfile.withTempDir(function(root)
		local a = join(root, "a")
		local b = join(root, "b")
		fs.mkdir(join(a, "src"))
		fs.mkdir(join(b, "src"))
		write(join(a, "eryx.toml"), manifest("@test/a", "1.0.0"))
		write(join(b, "eryx.toml"), manifest("@test/a", "1.0.0"))
		write(
			join(root, "eryx.toml"),
			manifest(
				"@test/root",
				"0.1.0",
				[[
"@test/a" = { local = "./a" }
"@test/b" = { local = "./b" }
]]
			)
		)
		-- b also declares @test/a pointing at a different path, so the alias
		-- would collide. Wire that up through b's own manifest.
		write(join(b, "eryx.toml"), manifest("@test/b", "1.0.0", [["@test/a" = { local = "../a" }]]))
		-- Override root to declare same alias with two different sources.
		write(
			join(root, "eryx.toml"),
			manifest(
				"@test/root",
				"0.1.0",
				[[
"@test/a-first"  = { local = "./a" }
"@test/a-second" = { local = "./b" }
]]
			)
		)
		-- Two different aliases is fine; only test the truly conflicting case.
		-- Replace with a genuine conflict: same alias key, different paths.
		write(
			join(root, "eryx.toml"),
			[=[[eryx]
manifest-version = 1

[eryx.project]
name = "@test/root"
version = "0.1.0"

[eryx.dependencies]
"@test/a" = { local = "./a" }
]=]
		)
		-- Install once to seed the lockfile, then craft a conflict through a
		-- transitive dep in b.
		pkg.install(join(root, "eryx.toml"))

		-- Now make b's transitive dep also claim @test/a but at a different path.
		write(join(b, "eryx.toml"), manifest("@test/b", "1.0.0", [["@test/a" = { local = "../a-alt" }]]))
		fs.mkdir(join(root, "a-alt"))
		write(join(join(root, "a-alt"), "eryx.toml"), manifest("@test/a", "1.0.0"))
		write(
			join(root, "eryx.toml"),
			manifest(
				"@test/root",
				"0.1.0",
				[[
"@test/a" = { local = "./a" }
"@test/b" = { local = "./b" }
]]
			)
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("multiple")
	end, "eryx-pkg-conflict")
end)

suite:test("local-copy package is re-copied on reinstall", function()
	tempfile.withTempDir(function(root)
		local source = join(root, "lib")
		fs.mkdir(join(source, "src"))
		write(join(source, "eryx.toml"), manifest("@test/lib", "1.0.0"))
		write(join(source, "src/init.luau"), "return 'v1'\n")
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/lib" = { local-copy = "./lib" }]]))

		pkg.install(join(root, "eryx.toml"))
		test.expect(readFile(join(root, "eryx_packages/test/lib/src/init.luau"))):toContain("v1")

		-- Mutate the source and reinstall.
		write(join(source, "src/init.luau"), "return 'v2'\n")
		pkg.install(join(root, "eryx.toml"))
		test.expect(readFile(join(root, "eryx_packages/test/lib/src/init.luau"))):toContain("v2")
	end, "eryx-pkg-recopy")
end)

suite:test("path-style local dependency resolves the same as local-style", function()
	tempfile.withTempDir(function(root)
		local lib = join(root, "lib")
		fs.mkdir(join(lib, "src"))
		write(join(lib, "eryx.toml"), manifest("@test/lib", "1.0.0"))
		write(join(lib, "src/init.luau"), "return 1\n")
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/lib" = { path = "./lib" }]]))

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(1)
		test.expect(result.packages[1].sourceId):toBe("local")
		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases["test/lib"]):toBe("./lib/src")
	end, "eryx-pkg-path-style")
end)

suite:test("install preserves existing user-owned aliases in .luaurc", function()
	tempfile.withTempDir(function(root)
		local lib = join(root, "lib")
		fs.mkdir(lib)
		write(join(lib, "eryx.toml"), manifest("@test/lib", "1.0.0"))
		-- Seed a user alias that eryx should not touch.
		write(join(root, ".luaurc"), json.encode({ languageMode = "strict", aliases = { myalias = "./my/path" } }))
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/lib" = { local = "./lib" }]]))

		pkg.install(join(root, "eryx.toml"))

		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases.myalias):toBe("./my/path")
		test.expect(rc.aliases["test/lib"]):toNotBeNil()
	end, "eryx-pkg-preserve-user-aliases")
end)

suite:test("lockfile records sourceId and alias target", function()
	tempfile.withTempDir(function(root)
		local lib = join(root, "lib")
		fs.mkdir(join(lib, "src"))
		write(join(lib, "eryx.toml"), manifest("@test/lib", "3.0.0"))
		write(join(lib, "src/init.luau"), "return 1\n")
		write(join(root, "eryx.toml"), manifest("@test/root", "0.1.0", [["@test/lib" = { local = "./lib" }]]))

		pkg.install(join(root, "eryx.toml"))

		local lockSource = readFile(join(root, "eryx.lock"))
		test.expect(lockSource):toContain(`source = "local"`)
		test.expect(lockSource):toContain(`version = "3.0.0"`)
		test.expect(lockSource):toContain(`target = "./lib/src"`)
	end, "eryx-pkg-lockfile-content")
end)

-- ── Git source tests ─────────────────────────────────────────────────────────

suite:test("git: install by rev copies package into eryx_packages", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(1)
		test.expect(result.packages[1].sourceId):toBe("git")
		test.expect(result.packages[1].resolvedRev):toBe(rev)
		test.expect(fs.isDirectory(join(root, "eryx_packages/test/gitpkg"))):toBeTrue()
		-- .git metadata must not be present in the installed copy
		test.expect(fs.isDirectory(join(root, "eryx_packages/test/gitpkg/.git"))):toBeFalse()
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeTrue()
	end, "eryx-pkg-git-rev")
end)

suite:test("git: alias points at src/ when present", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		pkg.install(join(root, "eryx.toml"))

		local rc = readJson(join(root, ".luaurc"))
		test.expect(rc.aliases["test/gitpkg"]):toBe("./eryx_packages/test/gitpkg/src")
	end, "eryx-pkg-git-alias-src")
end)

suite:test("git: lockfile records resolvedRev", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		pkg.install(join(root, "eryx.toml"))

		local lockSource = readFile(join(root, "eryx.lock"))
		test.expect(lockSource):toContain(`rev = "{rev}"`)
		test.expect(lockSource):toContain(`source = "git"`)
	end, "eryx-pkg-git-lockfile-rev")
end)

suite:test("git: install by branch resolves and locks exact commit", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", branch = "main" \}`)
		)

		local result = pkg.install(join(root, "eryx.toml"))

		-- resolvedRev must be the exact commit hash, not "main"
		test.expect(result.packages[1].resolvedRev):toBe(rev)
		local lockSource = readFile(join(root, "eryx.lock"))
		test.expect(lockSource):toContain(`rev = "{rev}"`)
	end, "eryx-pkg-git-branch")
end)

suite:test("git: install by tag resolves and locks exact commit", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		-- Create a tag pointing at the commit.
		os.exec("git", { "tag", "v1.0.0" }, { cwd = repoDir })

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", tag = "v1.0.0" \}`)
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(result.packages[1].resolvedRev):toBe(rev)
		local lockSource = readFile(join(root, "eryx.lock"))
		test.expect(lockSource):toContain(`rev = "{rev}"`)
	end, "eryx-pkg-git-tag")
end)

suite:test("git: install is idempotent — second install reuses cache", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		pkg.install(join(root, "eryx.toml"))
		-- Second install must not error and must produce the same output.
		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(#result.packages):toBe(1)
		test.expect(fs.isDirectory(join(root, "eryx_packages/test/gitpkg"))):toBeTrue()
	end, "eryx-pkg-git-idempotent")
end)

suite:test("git: missing rev/tag/branch is rejected before any I/O", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "https://example.invalid/repo" \}`)
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("rev, tag, or branch")
		-- No network call should have been made — lock must not exist.
		test.expect(fs.isFile(join(root, "eryx.lock"))):toBeFalse()
	end, "eryx-pkg-git-no-ref")
end)

suite:test("git: installed copy reflects the content at the locked rev", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev1 = makeGitRepo(repoDir, "@test/gitpkg", "1.0.0")
		-- Add a second commit — install should use rev1, not HEAD.
		addGitCommit(repoDir, "src/extra.luau", "return 'extra'\n")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/gitpkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev1}" \}`)
		)

		pkg.install(join(root, "eryx.toml"))

		-- extra.luau was added after rev1, so it must not appear.
		test.expect(fs.isFile(join(root, "eryx_packages/test/gitpkg/src/extra.luau"))):toBeFalse()
		test.expect(fs.isFile(join(root, "eryx_packages/test/gitpkg/src/init.luau"))):toBeTrue()
	end, "eryx-pkg-git-exact-rev-content")
end)

suite:test("git: reads eryx.toml from repo and records version in lockfile", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepo(repoDir, "@test/mypkg", "4.2.0")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/mypkg" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		local result = pkg.install(join(root, "eryx.toml"))

		test.expect(result.packages[1].version):toBe("4.2.0")
		test.expect(result.packages[1].name):toBe("@test/mypkg")
		local lockSource = readFile(join(root, "eryx.lock"))
		test.expect(lockSource):toContain(`version = "4.2.0"`)
	end, "eryx-pkg-git-version-from-manifest")
end)

suite:test("git: invalid URL fails with a clear error message", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		write(
			join(root, "eryx.toml"),
			manifest(
				"@test/root",
				"0.1.0",
				`"@test/bad" = \{ git = "https://localhost.invalid/does-not-exist", rev = "abc123" \}`
			)
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("failed to clone")
	end, "eryx-pkg-git-bad-url")
end)

suite:test("git: empty eryx.toml in repo is rejected with a clear error", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepoRaw(repoDir, "")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/bad" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("empty")
	end, "eryx-pkg-git-empty-manifest")
end)

suite:test("git: invalid eryx.toml in repo is rejected with a clear error", function()
	test.skipIf(not gitAvailable(), "git not available")
	tempfile.withTempDir(function(root)
		local repoDir = join(root, "upstream")
		local rev = makeGitRepoRaw(repoDir, "this is not valid toml ][[]")

		write(
			join(root, "eryx.toml"),
			manifest("@test/root", "0.1.0", `"@test/bad" = \{ git = "{tomlPath(repoDir)}", rev = "{rev}" \}`)
		)

		test.expect(function()
			pkg.install(join(root, "eryx.toml"))
		end):toError("failed to parse eryx.toml")
	end, "eryx-pkg-git-invalid-manifest")
end)

return suite
