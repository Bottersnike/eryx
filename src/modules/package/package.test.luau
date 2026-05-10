local _socket = require("@eryx/_socket")
local zip = require("@eryx/compression/zip")
local hash = require("@eryx/crypto/hazmat/hash")
local json = require("@eryx/data/json")
local hex = require("@eryx/encoding/hex")
local fs = require("@eryx/fs")
local http = require("@eryx/http")
local os = require("@eryx/os")
local project = require("@eryx/project")
local task = require("@eryx/task")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local lockfile = require("@eryx/package/lockfile")
local pkg = require("@eryx/package")

local suite = test.Suite.new("package")
local WORKSPACE_ROOT = tostring(os.cwd())

local function digest(algorithm: string, data: buffer): buffer
	local ctx = hash.new(algorithm)
	ctx:update(data)
	return ctx:final()
end

type RepoDependencySpec = {
	repo: string,
	version: string?,
	package: string?,
}

type RepoVersionSpec = {
	dependencies: { [string]: RepoDependencySpec }?,
	files: { [string]: string }?,
	sourceRoot: string?,
}

type RepoState = {
	[string]: {
		[string]: RepoVersionSpec,
	},
}

type GitPackageSpec = {
	name: string,
	version: string,
	dependenciesBlock: string?,
	repositories: { [string]: string }?,
	files: { [string]: string }?,
	sourceRoot: string?,
}

local function reservePort(): number
	local sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
	sock:bind("127.0.0.1", 0)
	local _, port = sock:getSockName()
	sock:close()
	return port
end

local function writeFile(path: string, content: string | buffer)
	local handle = fs.openSync(path, "w")
	handle:writeSync(content)
	handle:closeSync()
end

local function readFile(path: string): string
	local handle = fs.openSync(path, "r")
	local content = handle:readSync()
	handle:closeSync()
	return content
end

local function withWorkingDir<T...>(dir: string, run: () -> T...): T...
	local previous = tostring(os.cwd())
	os.chdir(dir)

	local ok, result = pcall(function()
		return run()
	end)
	os.chdir(previous)

	if not ok then
		error(result, 2)
	end

	return result :: any
end

local function makeManifest(name: string, repositoryUrl: string, dependenciesBlock: string): string
	return table.concat({
		"[eryx]",
		"manifest-version = 1",
		"",
		"[eryx.project]",
		`name = "{name}"`,
		'version = "0.1.0"',
		"",
		"[eryx.repositories]",
		`dummy = "{repositoryUrl}"`,
		"",
		"[eryx.dependencies]",
		dependenciesBlock,
		"",
	}, "\n")
end

local function makeProjectManifest(
	name: string,
	version: string,
	dependenciesBlock: string?,
	repositories: { [string]: string }?,
	sourceRoot: string?,
	devDependenciesBlock: string?
): string
	local lines = {
		"[eryx]",
		"manifest-version = 1",
		"",
		"[eryx.project]",
		`name = "{name}"`,
		`version = "{version}"`,
		"",
	}

	if sourceRoot then
		table.insert(lines, `source-root = "{sourceRoot}"`)
		table.insert(lines, "")
	end

	if repositories and next(repositories) ~= nil then
		table.insert(lines, "[eryx.repositories]")
		local keys = {}
		for key in repositories do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			table.insert(lines, `{key} = "{repositories[key]}"`)
		end
		table.insert(lines, "")
	end

	if dependenciesBlock and dependenciesBlock ~= "" then
		table.insert(lines, "[eryx.dependencies]")
		table.insert(lines, dependenciesBlock)
		table.insert(lines, "")
	end

	if devDependenciesBlock and devDependenciesBlock ~= "" then
		table.insert(lines, '[eryx."dev-dependencies"]')
		table.insert(lines, devDependenciesBlock)
		table.insert(lines, "")
	end

	return table.concat(lines, "\n")
end

local function withScripts(manifest: string, scripts: { [string]: string }): string
	local lines = { manifest, "", "[eryx.scripts]" }
	local keys = {}
	for key in scripts do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(lines, `{key} = "{scripts[key]}"`)
	end
	return table.concat(lines, "\n")
end

local function withWorkspace(manifest: string, workspace: { [string]: string }): string
	local lines = { manifest, "", "[eryx.workspace]" }
	local keys = {}
	for key in workspace do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(lines, `{key} = "{workspace[key]}"`)
	end
	return table.concat(lines, "\n")
end

local function makePackageManifest(name: string, version: string, sourceRoot: string?): string
	return makeProjectManifest(name, version, nil, nil, sourceRoot, nil)
end

local function makePackageArchive(name: string, version: string, spec: RepoVersionSpec?): buffer
	local files: { [string]: buffer } = {
		["eryx.toml"] = buffer.fromstring(makePackageManifest(name, version, if spec then spec.sourceRoot else nil)),
		["init.luau"] = buffer.fromstring(
			if spec
					and spec.files
					and spec.files["init.luau"]
				then (spec.files :: any)["init.luau"]
				else `return "{name}@{version}"\n`
		),
	}

	if spec and spec.files then
		for path, content in spec.files do
			files[path] = buffer.fromstring(content)
		end
	end

	return zip.pack(files)
end

local function withRepository<T...>(state: RepoState, run: (url: string, sync: () -> ()) -> T...): T...
	return tempfile.withTempDir(function(repoDir: string)
		local function archivePath(packageName: string, version: string): string
			return fs.path.join(repoDir, `{packageName}@{version}.zip`)
		end

		local function sync()
			for _, entry in fs.listDir(repoDir) do
				if entry:match("%.zip$") then
					fs.remove(fs.path.join(repoDir, entry))
				end
			end

			for packageName, versions in state do
				for version, spec in versions do
					writeFile(archivePath(packageName, version), makePackageArchive(packageName, version, spec))
				end
			end
		end

		sync()

		local app = http.createApp()

		app:get("/packages/:package", function(ctx)
			local versions = state[ctx.params.package]
			if not versions then
				return 404, {}
			end

			local out = {}
			for version in versions do
				table.insert(out, version)
			end
			table.sort(out)
			return out
		end)

		app:get("/packages/:package/:version", function(ctx)
			local versions = state[ctx.params.package]
			if not versions or not versions[ctx.params.version] then
				return 404, {}
			end

			local spec = versions[ctx.params.version]
			return 200,
				{
					name = ctx.params.package,
					dependencies = if spec.dependencies then spec.dependencies else {},
					sourceRoot = spec.sourceRoot,
				}
		end)

		app:get("/packages/:package/:version/download", function(ctx)
			local versions = state[ctx.params.package]
			if not versions or not versions[ctx.params.version] then
				return 404, "missing"
			end

			ctx:sendFile(archivePath(ctx.params.package, ctx.params.version))
			return nil
		end)

		local port = reservePort()
		task.spawn(function()
			app:listen(nil, {
				host = "127.0.0.1",
				port = port,
				clientTimeout = 1,
			})
		end)
		task.wait(0.05)

		local ok, result = pcall(function()
			return run(`http://127.0.0.1:{port}`, sync)
		end)
		app:close()
		task.wait(0.05)

		if not ok then
			error(result, 2)
		end

		return result :: any
	end, "eryx-package-test-repo")
end

local function withArchiveServer<T...>(archive: buffer, run: (url: string, sha256: string) -> T...): T...
	return tempfile.withTempDir(function(dir)
		local archivePath = fs.path.join(dir, "package.zip")
		writeFile(archivePath, archive)

		local app = http.createApp()
		app:get("/package.zip", function(ctx)
			ctx:sendFile(archivePath)
			return nil
		end)

		local port = reservePort()
		task.spawn(function()
			app:listen(nil, {
				host = "127.0.0.1",
				port = port,
				clientTimeout = 1,
			})
		end)
		task.wait(0.05)

		local ok, result = pcall(function()
			return run(`http://127.0.0.1:{port}/package.zip`, hex.encode(digest("sha256", archive)))
		end)
		app:close()
		task.wait(0.05)

		if not ok then
			error(result, 2)
		end

		return result :: any
	end, "eryx-package-url-server")
end

local function findLockedPackage(lock: any, alias: string): any
	local target = nil

	for _, edge in lock.roots do
		if edge.alias == alias then
			target = edge.target
			break
		end
	end

	if not target then
		error(`Missing locked root alias {alias}`, 2)
	end

	local package = lock.packages[target]
	if not package then
		error(`Missing locked package {target}`, 2)
	end

	return package
end

local function readInstalledInit(root: string, lock: any, alias: string): string
	local package = findLockedPackage(lock, alias)
	test.expect(package.installName):toNotBeNil()
	return readFile(fs.path.join(root, "eryx_packages", package.installName :: string, "init.luau"))
end

local function normalizeNewlines(s: string): string
	return (s:gsub("\r\n", "\n"))
end

local function writeLuaurc(path: string, aliases: { [string]: string })
	writeFile(
		fs.path.join(path, ".luaurc"),
		json.encode({
			aliases = aliases,
		}, { pretty = true })
	)
end

local function readLuaurcAliases(path: string): { [string]: string }
	local decoded = json.decode(readFile(fs.path.join(path, ".luaurc")), json.JSONC)
	return (decoded.aliases or {}) :: { [string]: string }
end

local function listDirNames(path: string): { string }
	if not fs.exists(path) then
		return {}
	end

	local entries = fs.listDir(path)
	table.sort(entries)
	return entries
end

local function makePathPackage(path: string, name: string)
	writeFile(fs.path.join(path, "eryx.toml"), makeProjectManifest(name, "0.1.0", nil, nil))
	writeFile(fs.path.join(path, "init.luau"), `return "{name}"\n`)
end

local function runGit(cwd: string, args: { string }): string
	local res = os.exec("git", args, { cwd = cwd })
	if res.code ~= 0 then
		error(`git {table.concat(args, " ")} failed in {cwd}\n{res.stderr}`, 2)
	end

	return res.stdout
end

local function eryxExePath(): string
	local debug = fs.path.join(WORKSPACE_ROOT, "build", "Debug", "eryx.exe")
	if fs.isFile(debug) then
		return debug
	end

	local release = fs.path.join(WORKSPACE_ROOT, "build", "Release", "eryx.exe")
	if fs.isFile(release) then
		return release
	end

	error("Could not find eryx.exe in build/Debug or build/Release", 2)
end

local function runEryx(cwd: string, args: { string }): os.ExecResult
	local exe = eryxExePath()
	return os.exec(exe, args, {
		cwd = cwd,
		env = {
			ERYX_EXE_PATH = exe,
		},
	})
end

local function trim(s: string): string
	return s:match("^%s*(.-)%s*$") or ""
end

local function ensureDirRecursive(path: string)
	if path == "" or fs.exists(path) then
		return
	end

	local parent = fs.path.dirname(path)
	if parent and parent ~= path and parent ~= "" then
		ensureDirRecursive(parent)
	end

	if not fs.exists(path) then
		fs.mkdir(path)
	end
end

local function writeGitPackage(dir: string, spec: GitPackageSpec)
	writeFile(
		fs.path.join(dir, "eryx.toml"),
		makeProjectManifest(spec.name, spec.version, spec.dependenciesBlock, spec.repositories, spec.sourceRoot, nil)
	)

	local files = spec.files or {
		["init.luau"] = `return "{spec.name}@{spec.version}"\n`,
	}
	for path, content in files do
		local fullPath = fs.path.join(dir, path)
		local parent = fs.path.dirname(fullPath)
		if parent then
			ensureDirRecursive(parent)
		end
		writeFile(fullPath, content)
	end
end

local function withGitRemote<T...>(
	run: (
		-- This comment is just here for stable formatting
		remoteUrl: string,
		commit: (spec: GitPackageSpec, message: string) -> string
	) -> T...
): T...
	return tempfile.withTempDir(function(remoteDir: string)
		return tempfile.withTempDir(function(workDir: string)
			runGit(remoteDir, { "init", "--bare" })
			runGit(workDir, { "clone", remoteDir, "." })
			runGit(workDir, { "config", "user.name", "Eryx Test" })
			runGit(workDir, { "config", "user.email", "eryx-test@example.com" })
			runGit(workDir, { "config", "commit.gpgsign", "false" })
			runGit(workDir, { "checkout", "-b", "main" })

			local function commit(spec: GitPackageSpec, message: string): string
				for _, entry in fs.listDir(workDir) do
					if entry ~= ".git" then
						fs.remove(fs.path.join(workDir, entry))
					end
				end

				writeGitPackage(workDir, spec)
				runGit(workDir, { "add", "." })
				runGit(workDir, { "commit", "-m", message })
				runGit(workDir, { "push", "--force", "-u", "origin", "main" })
				return trim(runGit(workDir, { "rev-parse", "HEAD" }))
			end

			return run(remoteDir:gsub("\\", "/"), commit) :: any
		end, "eryx-package-git-work")
	end, "eryx-package-git-remote")
end

local function countLockPackages(lock: any): number
	local count = 0
	for _ in lock.packages do
		count += 1
	end
	return count
end

local function findDependencyTarget(package: any, alias: string): string
	for _, edge in package.dependencies do
		if edge.alias == alias then
			return edge.target
		end
	end

	error(`Missing dependency alias {alias}`, 2)
end

suite:test("install reuses eryx.lock for repository dependencies", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "foo@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("lock-demo", repositoryUrl, 'foo = { repo = "dummy" }')
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				local firstFoo = findLockedPackage(firstLock, "foo")
				test.expect(firstFoo.data.version):toBe("1.0.0")
				test.expect(readInstalledInit(root, firstLock, "foo")):toBe('return "foo@1.0.0"\n')

				state.foo["1.1.0"] = {
					files = {
						["init.luau"] = 'return "foo@1.1.0"\n',
					},
				}
				sync()

				pkg.doInstall()

				local secondLock = lockfile.load(root)
				test.expect(secondLock):toNotBeNil()
				local secondFoo = findLockedPackage(secondLock, "foo")
				test.expect(secondFoo.data.version):toBe("1.0.0")
				test.expect(readInstalledInit(root, secondLock, "foo")):toBe('return "foo@1.0.0"\n')
			end)
		end, "eryx-package-lock-test")
	end)
end)

suite:test("install ignores dev-dependencies by default", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
		bar = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"dev-ignore-demo",
					"0.1.0",
					'foo = { repo = "dummy", version = "1.0.0" }',
					{ dummy = repositoryUrl },
					nil,
					'bar = { repo = "dummy", version = "1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(1)
				test.expect(readLuaurcAliases(root).foo):toNotBeNil()
				test.expect(readLuaurcAliases(root).bar):toBeNil()
				test.expect(#(lock.devRoots or {})):toBe(0)
			end)
		end, "eryx-package-dev-ignore-test")
	end)
end)

suite:test("install --dev includes dev-dependencies and records them separately in the lock", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
		bar = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"dev-install-demo",
					"0.1.0",
					'foo = { repo = "dummy", version = "1.0.0" }',
					{ dummy = repositoryUrl },
					nil,
					'bar = { repo = "dummy", version = "1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall(true)

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(2)
				test.expect(#lock.roots):toBe(1)
				test.expect(#(lock.devRoots or {})):toBe(1)
				test.expect(readLuaurcAliases(root).foo):toBe(lock.rootAliases.foo)
				test.expect(readLuaurcAliases(root).bar):toBe((lock.devRootAliases or {}).bar)
			end)
		end, "eryx-package-dev-install-test")
	end)
end)

suite:test("plain install after install --dev preserves dev dependencies untouched", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
		bar = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"dev-preserve-demo",
					"0.1.0",
					'foo = { repo = "dummy", version = "1.0.0" }',
					{ dummy = repositoryUrl },
					nil,
					'bar = { repo = "dummy", version = "1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall(true)

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				assert(firstLock)
				local firstAliases = readLuaurcAliases(root)
				test.expect(firstAliases.bar):toBe((firstLock.devRootAliases or {}).bar)

				pkg.doInstall()

				local secondLock = lockfile.load(root)
				test.expect(secondLock):toNotBeNil()
				assert(secondLock)
				local secondAliases = readLuaurcAliases(root)
				test.expect(#(secondLock.devRoots or {})):toBe(1)
				test.expect(secondAliases.bar):toBe((secondLock.devRootAliases or {}).bar)
				test.expect(secondAliases.bar):toBe(firstAliases.bar)
				test.expect(countLockPackages(secondLock)):toBe(2)
			end)
		end, "eryx-package-dev-preserve-test")
	end)
end)

suite:test("selected update can target dev-dependencies when requested", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
		bar = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"dev-update-demo",
					"0.1.0",
					'foo = { repo = "dummy", version = "1.0.0" }',
					{ dummy = repositoryUrl },
					nil,
					'bar = { repo = "dummy" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall(true)

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				assert(firstLock)
				test.expect(findLockedPackage(firstLock, "foo").data.version):toBe("1.0.0")
				local firstDevRoots = firstLock.devRoots or {}
				test.expect(#firstDevRoots):toBe(1)
				test.expect(firstLock.packages[firstDevRoots[1].target].data.version):toBe("1.0.0")

				state.bar["1.1.0"] = {}
				sync()

				pkg.doUpdate({ "bar" }, true)

				local secondLock = lockfile.load(root)
				test.expect(secondLock):toNotBeNil()
				assert(secondLock)
				test.expect(findLockedPackage(secondLock, "foo").data.version):toBe("1.0.0")
				local devRoots = secondLock.devRoots or {}
				test.expect(#devRoots):toBe(1)
				test.expect(secondLock.packages[devRoots[1].target].data.version):toBe("1.1.0")
			end)
		end, "eryx-package-dev-update-test")
	end)
end)

suite:test("upgrade --dev rewrites repository versions in dev-dependencies", function()
	local state: RepoState = {
		bar = {
			["1.0.0"] = {},
			["1.1.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")
			writeFile(
				manifestPath,
				makeProjectManifest(
					"dev-upgrade-demo",
					"0.1.0",
					nil,
					{ dummy = repositoryUrl },
					nil,
					'bar = { repo = "dummy", version = "^1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doUpgrade(nil, true)

				local manifest = project.load(manifestPath)
				local depTable = manifest.cst.eryx["dev-dependencies"].bar :: any
				test.expect(depTable.version):toBe("1.1.0")
			end)
		end, "eryx-package-dev-upgrade-test")
	end)
end)

suite:test("update can refresh one repository dependency while keeping others locked", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "foo@1.0.0"\n',
				},
			},
		},
		bar = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "bar@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"partial-update-demo",
					repositoryUrl,
					table.concat({
						'foo = { repo = "dummy" }',
						'bar = { repo = "dummy" }',
					}, "\n")
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(findLockedPackage(lock, "foo").data.version):toBe("1.0.0")
				test.expect(findLockedPackage(lock, "bar").data.version):toBe("1.0.0")

				state.foo["1.1.0"] = {
					files = {
						["init.luau"] = 'return "foo@1.1.0"\n',
					},
				}
				state.bar["1.1.0"] = {
					files = {
						["init.luau"] = 'return "bar@1.1.0"\n',
					},
				}
				sync()

				pkg.doUpdate({ "foo" })

				local updatedLock = lockfile.load(root)
				test.expect(updatedLock):toNotBeNil()
				test.expect(findLockedPackage(updatedLock, "foo").data.version):toBe("1.1.0")
				test.expect(findLockedPackage(updatedLock, "bar").data.version):toBe("1.0.0")
				test.expect(readInstalledInit(root, updatedLock, "foo")):toBe('return "foo@1.1.0"\n')
				test.expect(readInstalledInit(root, updatedLock, "bar")):toBe('return "bar@1.0.0"\n')
			end)
		end, "eryx-package-update-test")
	end)
end)

suite:test("upgrade rewrites repository manifest versions to the resolved version", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "foo@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")

			writeFile(
				manifestPath,
				makeManifest("upgrade-demo", repositoryUrl, 'foo = { repo = "dummy", version = "^1.0.0" }')
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				state.foo["1.1.0"] = {
					files = {
						["init.luau"] = 'return "foo@1.1.0"\n',
					},
				}
				sync()

				pkg.doUpgrade({ "foo" })

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(findLockedPackage(lock, "foo").data.version):toBe("1.1.0")
				test.expect(readInstalledInit(root, lock, "foo")):toBe('return "foo@1.1.0"\n')

				local manifest = project.load(manifestPath)
				local manifestDep = manifest.cst.eryx.dependencies.foo :: any
				test.expect(manifestDep.repo):toBe("dummy")
				test.expect(manifestDep.version):toBe("1.1.0")
			end)
		end, "eryx-package-upgrade-test")
	end)
end)

suite:test("repository dependencies can override the package name while keeping the alias", function()
	local state: RepoState = {
		realpkg = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "realpkg@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"repo-package-override-demo",
					repositoryUrl,
					'foo = { repo = "dummy", package = "realpkg", version = "1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				local foo = findLockedPackage(lock, "foo")
				test.expect(foo.data.key):toBe("realpkg")
				test.expect(readInstalledInit(root, lock, "foo")):toBe('return "realpkg@1.0.0"\n')

				local aliases = readLuaurcAliases(root)
				test.expect(aliases.foo):toBe(lock.rootAliases.foo)
			end)
		end, "eryx-package-repo-package-override-test")
	end)
end)

suite:test("dependency alias fields are rejected because the table key is the alias", function()
	tempfile.withTempDir(function(root)
		writeFile(
			fs.path.join(root, "eryx.toml"),
			table.concat({
				"[eryx]",
				"manifest-version = 1",
				"",
				"[eryx.project]",
				'name = "alias-rejection-demo"',
				'version = "0.1.0"',
				"",
				"[eryx.dependencies]",
				'foo = { path = "./dep", alias = "bar" }',
				"",
			}, "\n")
		)

		withWorkingDir(root, function()
			test.expect(function()
				pkg.doInstall()
			end):toError(".alias is not supported")
		end)
	end, "eryx-package-alias-field-rejection-test")
end)

suite:test("path dependencies stay alias-only and do not create eryx_packages", function()
	tempfile.withTempDir(function(root)
		local depPath = fs.path.join(root, "linked-dep")
		local manifestDepPath = depPath:gsub("\\", "/")
		fs.mkdir(depPath)
		makePathPackage(depPath, "linked-dep")

		writeFile(
			fs.path.join(root, "eryx.toml"),
			table.concat({
				"[eryx]",
				"manifest-version = 1",
				"",
				"[eryx.project]",
				'name = "path-demo"',
				'version = "0.1.0"',
				"",
				"[eryx.dependencies]",
				'linked = { path = "' .. manifestDepPath .. '" }',
				"",
			}, "\n")
		)

		withWorkingDir(root, function()
			pkg.doInstall()

			test.expect(fs.exists(fs.path.join(root, "eryx_packages"))):toBeFalse()

			local lock = lockfile.load(root)
			test.expect(lock):toNotBeNil()
			local linked = findLockedPackage(lock, "linked")
			test.expect(linked.type):toBe("path")
			test.expect(linked.installName):toBeNil()
			test.expect(linked.data.path):toBe(manifestDepPath)

			local luaurc = readFile(fs.path.join(root, ".luaurc"))
			test.expect(luaurc):toContain(manifestDepPath)
		end)
	end, "eryx-package-path-test")
end)

suite:test("path dependencies ignore target eryx.toml entirely", function()
	tempfile.withTempDir(function(root)
		local depPath = fs.path.join(root, "linked-dep")
		local manifestDepPath = depPath:gsub("\\", "/")
		fs.mkdir(depPath)
		fs.mkdir(fs.path.join(depPath, "src"))
		writeFile(fs.path.join(depPath, "eryx.toml"), makeProjectManifest("linked-dep", "0.1.0", nil, nil, "src"))
		writeFile(fs.path.join(depPath, "src", "init.luau"), 'return "linked-dep"\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			makeProjectManifest("path-demo", "0.1.0", 'linked = { path = "' .. manifestDepPath .. '" }', nil)
		)

		withWorkingDir(root, function()
			pkg.doInstall()

			local aliases = readLuaurcAliases(root)
			local lock = lockfile.load(root)
			test.expect(lock):toNotBeNil()
			assert(lock)

			test.expect(aliases.linked):toBe(manifestDepPath)
			test.expect(findLockedPackage(lock, "linked").data.sourceRoot):toBeNil()
		end)
	end, "eryx-package-path-source-root-test")
end)

suite:test("selected update requires an existing lock file", function()
	tempfile.withTempDir(function(root)
		writeFile(
			fs.path.join(root, "eryx.toml"),
			table.concat({
				"[eryx]",
				"manifest-version = 1",
				"",
				"[eryx.project]",
				'name = "no-lock-demo"',
				'version = "0.1.0"',
				"",
				"[eryx.dependencies]",
				'foo = { path = "./foo" }',
				"",
			}, "\n")
		)

		withWorkingDir(root, function()
			test.expect(function()
				pkg.doUpdate({ "foo" })
			end):toError("Cannot update specific dependencies without an existing eryx%.lock")
		end)
	end, "eryx-package-no-lock-update-test")
end)

suite:test("changing top-level dependencies invalidates lock reuse", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "foo@1.0.0"\n',
				},
			},
			["1.1.0"] = {
				files = {
					["init.luau"] = 'return "foo@1.1.0"\n',
				},
			},
		},
		bar = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "bar@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")
			writeFile(manifestPath, makeManifest("lock-invalidation-demo", repositoryUrl, 'foo = { repo = "dummy" }'))

			withWorkingDir(root, function()
				pkg.doInstall()

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				test.expect(findLockedPackage(firstLock, "foo").data.version):toBe("1.1.0")

				writeFile(
					manifestPath,
					makeManifest(
						"lock-invalidation-demo",
						repositoryUrl,
						table.concat({
							'foo = { repo = "dummy" }',
							'bar = { repo = "dummy", version = "1.0.0" }',
						}, "\n")
					)
				)

				pkg.doInstall()

				local secondLock = lockfile.load(root)
				test.expect(secondLock):toNotBeNil()
				test.expect(findLockedPackage(secondLock, "foo").data.version):toBe("1.1.0")
				test.expect(findLockedPackage(secondLock, "bar").data.version):toBe("1.0.0")
			end)
		end, "eryx-package-lock-invalidation-test")
	end)
end)

suite:test("repository dependencies install their child dependencies", function()
	local state: RepoState = {
		foo = {},
		bar = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "bar@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				bar = { repo = repositoryUrl, version = "1.0.0" },
			},
			files = {
				["init.luau"] = 'return "foo@1.0.0"\n',
			},
		}
		sync()
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("repo-child-demo", repositoryUrl, 'foo = { repo = "dummy" }')
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(2)

				local foo = findLockedPackage(lock, "foo")
				local barTarget = findDependencyTarget(foo, "bar")
				local bar = lock.packages[barTarget]
				test.expect(bar.data.version):toBe("1.0.0")

				local fooRc = readFile(fs.path.join(root, "eryx_packages", foo.installName :: string, ".luaurc"))
				test.expect(fooRc):toContain("../" .. (bar.installName :: string))
			end)
		end, "eryx-package-repo-child-test")
	end)
end)

suite:test("repository aliases respect source-root across install and lock reuse", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {
				sourceRoot = "src",
				files = {
					["src/init.luau"] = 'return "foo@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("repo-source-root-demo", repositoryUrl, 'foo = { repo = "dummy", version = "1.0.0" }')
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				assert(firstLock)
				local foo = findLockedPackage(firstLock, "foo")
				local expectedAlias = `eryx_packages/{foo.installName :: string}/src`

				test.expect(readLuaurcAliases(root).foo):toBe(expectedAlias)
				test.expect(firstLock.rootAliases.foo):toBe(expectedAlias)
				test.expect(foo.data.sourceRoot):toBe("src")

				pkg.doInstall()

				test.expect(readLuaurcAliases(root).foo):toBe(expectedAlias)
			end)
		end, "eryx-package-repo-source-root-test")
	end)
end)

suite:test("child package aliases respect dependency source-root", function()
	local state: RepoState = {
		foo = {},
		bar = {
			["1.0.0"] = {
				sourceRoot = "lib",
				files = {
					["lib/init.luau"] = 'return "bar@1.0.0"\n',
				},
			},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				bar = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		sync()

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"repo-child-source-root-demo",
					repositoryUrl,
					'foo = { repo = "dummy", version = "1.0.0" }'
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)

				local foo = findLockedPackage(lock, "foo")
				local bar = lock.packages[findDependencyTarget(foo, "bar")]
				local childAliases = readLuaurcAliases(fs.path.join(root, "eryx_packages", foo.installName :: string))

				test.expect(childAliases.bar):toBe(`../{bar.installName :: string}/lib`)
			end)
		end, "eryx-package-child-source-root-test")
	end)
end)

suite:test("local dependencies are materialized and can bring child repository dependencies", function()
	withRepository({
		shared = {
			["1.0.0"] = {
				files = {
					["init.luau"] = 'return "shared@1.0.0"\n',
				},
			},
		},
	}, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local localDepDir = fs.path.join(root, "local-dep")
			fs.mkdir(localDepDir)
			writeFile(
				fs.path.join(localDepDir, "eryx.toml"),
				makeProjectManifest("local-dep", "0.1.0", 'shared = { repo = "dummy" }', {
					dummy = repositoryUrl,
				})
			)
			writeFile(fs.path.join(localDepDir, "init.luau"), 'return "local-dep"\n')

			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest("local-root", "0.1.0", 'localdep = { local = "./local-dep" }', nil)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(2)

				local localPkg = findLockedPackage(lock, "localdep")
				test.expect(localPkg.type):toBe("local")
				test.expect(readInstalledInit(root, lock, "localdep")):toBe('return "local-dep"\n')

				local sharedTarget = findDependencyTarget(localPkg, "shared")
				local shared = lock.packages[sharedTarget]
				test.expect(shared.data.version):toBe("1.0.0")

				local localRc = readFile(fs.path.join(root, "eryx_packages", localPkg.installName :: string, ".luaurc"))
				test.expect(localRc):toContain("../" .. (shared.installName :: string))
			end)
		end, "eryx-package-local-child-test")
	end)
end)

suite:test("workspace overrides keep monorepo packages in place and resolve child aliases", function()
	tempfile.withTempDir(function(root)
		local packagesDir = fs.path.join(root, "packages")
		local markdownDir = fs.path.join(packagesDir, "markdown")
		local eryxdocDir = fs.path.join(packagesDir, "eryxdoc")
		fs.mkdir(packagesDir)
		fs.mkdir(markdownDir)
		fs.mkdir(eryxdocDir)
		fs.mkdir(fs.path.join(markdownDir, "src"))
		fs.mkdir(fs.path.join(eryxdocDir, "src"))

		writeFile(
			fs.path.join(markdownDir, "eryx.toml"),
			makeProjectManifest("markdown", "0.1.0", nil, nil, "src", nil)
		)
		writeFile(fs.path.join(markdownDir, "src", "init.luau"), 'return "markdown"\n')

		writeFile(
			fs.path.join(eryxdocDir, "eryx.toml"),
			makeProjectManifest(
				"eryxdoc",
				"0.1.0",
				'markdown = { git = "https://example.invalid/eryx.git", branch = "main", subdir = "packages/markdown" }',
				nil,
				"src",
				nil
			)
		)
		writeFile(fs.path.join(eryxdocDir, "src", "init.luau"), 'return "eryxdoc"\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			withWorkspace(
				makeProjectManifest(
					"workspace-root",
					"0.1.0",
					'eryxdoc = { git = "https://example.invalid/eryx.git", branch = "main", subdir = "packages/eryxdoc" }',
					nil
				),
				{
					eryxdoc = "./packages/eryxdoc",
					markdown = "./packages/markdown",
				}
			)
		)

		withWorkingDir(root, function()
			pkg.doInstall()

			local lock = lockfile.load(root)
			test.expect(lock):toNotBeNil()
			assert(lock)
			test.expect(countLockPackages(lock)):toBe(2)

			local eryxdocPkg = findLockedPackage(lock, "eryxdoc")
			test.expect(eryxdocPkg.type):toBe("workspace")

			local markdownTarget = findDependencyTarget(eryxdocPkg, "markdown")
			local markdownPkg = lock.packages[markdownTarget]
			test.expect(markdownPkg.type):toBe("workspace")

			test.expect(fs.exists(fs.path.join(root, "eryx_packages"))):toBeFalse()

			local rootAliases = readLuaurcAliases(root)
			local expectedRootAlias = fs.path.canonicalize(eryxdocDir):gsub("\\", "/") .. "/src"
			test.expect(rootAliases.eryxdoc):toBe(expectedRootAlias)

			local childAliases = readLuaurcAliases(eryxdocDir)
			local expectedMarkdownAlias = fs.path.canonicalize(markdownDir):gsub("\\", "/") .. "/src"
			test.expect(childAliases.markdown):toBe(expectedMarkdownAlias)
		end)
	end, "eryx-package-workspace-monorepo-test")
end)

suite:test("workspace overrides reject packages whose manifest name does not match the workspace key", function()
	tempfile.withTempDir(function(root)
		local packagesDir = fs.path.join(root, "packages")
		local wrongDir = fs.path.join(packagesDir, "markdown")
		fs.mkdir(packagesDir)
		fs.mkdir(wrongDir)

		writeFile(fs.path.join(wrongDir, "eryx.toml"), makeProjectManifest("wrong-name", "0.1.0", nil, nil))
		writeFile(
			fs.path.join(root, "eryx.toml"),
			withWorkspace(makeProjectManifest("workspace-root", "0.1.0", 'markdown = { local = "./nowhere" }', nil), {
				markdown = "./packages/markdown",
			})
		)

		withWorkingDir(root, function()
			test.expect(function()
				pkg.doInstall()
			end):toError('Workspace package "markdown" expected project name "markdown", found "wrong%-name"')
		end)
	end, "eryx-package-workspace-name-test")
end)

suite:test("workspace packages are initialized even when they are not root dependencies", function()
	tempfile.withTempDir(function(root)
		local packagesDir = fs.path.join(root, "projects")
		local markdownDir = fs.path.join(packagesDir, "markdown")
		local eryxdocDir = fs.path.join(packagesDir, "eryxdoc")
		fs.mkdir(packagesDir)
		fs.mkdir(markdownDir)
		fs.mkdir(eryxdocDir)
		fs.mkdir(fs.path.join(markdownDir, "src"))
		fs.mkdir(fs.path.join(eryxdocDir, "src"))

		writeFile(
			fs.path.join(markdownDir, "eryx.toml"),
			makeProjectManifest("markdown", "0.1.0", nil, nil, "src", nil)
		)
		writeFile(fs.path.join(markdownDir, "src", "init.luau"), 'return "markdown"\n')

		writeFile(
			fs.path.join(eryxdocDir, "eryx.toml"),
			makeProjectManifest(
				"eryxdoc",
				"0.1.0",
				'markdown = { git = "https://example.invalid/eryx.git", branch = "main", subdir = "projects/markdown" }',
				nil,
				"src",
				nil
			)
		)
		writeFile(fs.path.join(eryxdocDir, "src", "init.luau"), 'return "eryxdoc"\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			withWorkspace(
				makeProjectManifest("workspace-root", "0.1.0", 'eryx = { path = "build/Debug/modules" }', nil),
				{
					eryxdoc = "./projects/eryxdoc",
					markdown = "./projects/markdown",
				}
			)
		)

		withWorkingDir(root, function()
			pkg.doInstall()

			local rootAliases = readLuaurcAliases(root)
			test.expect(rootAliases.eryx):toBe("build/Debug/modules")
			test.expect(rootAliases.eryxdoc):toBeNil()
			test.expect(rootAliases.markdown):toBeNil()

			local childAliases = readLuaurcAliases(eryxdocDir)
			local expectedMarkdownAlias = fs.path.canonicalize(markdownDir):gsub("\\", "/") .. "/src"
			test.expect(childAliases.markdown):toBe(expectedMarkdownAlias)
		end)
	end, "eryx-package-workspace-bootstrap-test")
end)

suite:test("path dependencies ignore child manifests and remain single-node aliases", function()
	withRepository({
		shared = {
			["1.0.0"] = {},
		},
	}, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local depPath = fs.path.join(root, "path-dep")
			local manifestDepPath = depPath:gsub("\\", "/")
			fs.mkdir(depPath)
			writeFile(
				fs.path.join(depPath, "eryx.toml"),
				makeProjectManifest("path-dep", "0.1.0", 'shared = { repo = "dummy" }', {
					dummy = repositoryUrl,
				})
			)
			writeFile(fs.path.join(depPath, "init.luau"), 'return "path-dep"\n')

			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest("path-root", "0.1.0", 'dep = { path = "' .. manifestDepPath .. '" }', nil)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(countLockPackages(lock)):toBe(1)
				test.expect(findLockedPackage(lock, "dep").type):toBe("path")
				test.expect(fs.exists(fs.path.join(root, "eryx_packages"))):toBeFalse()
			end)
		end, "eryx-package-path-child-test")
	end)
end)

suite:test("shared repository child dependencies are deduplicated across roots", function()
	local state: RepoState = {
		foo = {},
		bar = {},
		shared = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		state.bar["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		sync()
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"dedupe-demo",
					repositoryUrl,
					table.concat({
						'foo = { repo = "dummy", version = "1.0.0" }',
						'bar = { repo = "dummy", version = "1.0.0" }',
					}, "\n")
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(countLockPackages(lock)):toBe(3)

				local foo = findLockedPackage(lock, "foo")
				local bar = findLockedPackage(lock, "bar")
				test.expect(findDependencyTarget(foo, "shared")):toBe(findDependencyTarget(bar, "shared"))
			end)
		end, "eryx-package-dedupe-test")
	end)
end)

suite:test("git branch dependencies stay locked to the recorded commit until update", function()
	withGitRemote(function(remoteUrl, commit)
		local commit1 = commit({
			name = "gitpkg",
			version = "0.1.0",
			files = {
				["init.luau"] = 'return "gitpkg@commit1"\n',
			},
		}, "first")

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"git-root",
					"0.1.0",
					'gitpkg = { git = "' .. remoteUrl .. '", branch = "main" }',
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				local firstPkg = findLockedPackage(firstLock, "gitpkg")
				test.expect(firstPkg.type):toBe("git")
				test.expect(firstPkg.data.ref.type):toBe("commit")
				test.expect(firstPkg.data.ref.value):toBe(commit1)
				test.expect(firstPkg.data.requestedRef.type):toBe("branch")
				test.expect(firstPkg.data.requestedRef.value):toBe("main")
				test.expect(normalizeNewlines(readInstalledInit(root, firstLock, "gitpkg"))):toContain("gitpkg@commit1")

				local commit2 = commit({
					name = "gitpkg",
					version = "0.2.0",
					files = {
						["init.luau"] = 'return "gitpkg@commit2"\n',
					},
				}, "second")

				pkg.doInstall()
				local lockedAgain = lockfile.load(root)
				test.expect(lockedAgain):toNotBeNil()
				test.expect(findLockedPackage(lockedAgain, "gitpkg").data.ref.value):toBe(commit1)
				test.expect(normalizeNewlines(readInstalledInit(root, lockedAgain, "gitpkg")))
					:toContain("gitpkg@commit1")

				pkg.doUpdate({ "gitpkg" })
				local updatedLock = lockfile.load(root)
				test.expect(updatedLock):toNotBeNil()
				test.expect(findLockedPackage(updatedLock, "gitpkg").data.ref.value):toBe(commit2)
				test.expect(normalizeNewlines(readInstalledInit(root, updatedLock, "gitpkg")))
					:toContain("gitpkg@commit2")
			end)
		end, "eryx-package-git-lock-test")
	end)
end)

suite:test("transitive local dependencies from non-local sources are rejected", function()
	withRepository({
		foo = {
			["1.0.0"] = {
				dependencies = {
					badlocal = { ["local"] = "./badlocal" },
				},
			},
		},
	}, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("bad-local-demo", repositoryUrl, 'foo = { repo = "dummy" }')
			)

			withWorkingDir(root, function()
				test.expect(function()
					pkg.doInstall()
				end):toError('Dependency "badlocal" is local, but local dependencies are not allowed here')
			end)
		end, "eryx-package-transitive-local-test")
	end)
end)

suite:test("url dependencies install and discover child repository dependencies", function()
	withRepository({
		shared = {
			["1.0.0"] = {},
		},
	}, function(repositoryUrl)
		local archive = zip.pack({
			["eryx.toml"] = buffer.fromstring(
				makeProjectManifest(
					"urlpkg",
					"0.1.0",
					'shared = { repo = "' .. repositoryUrl .. '", version = "1.0.0" }',
					nil
				)
			),
			["init.luau"] = buffer.fromstring('return "urlpkg"\n'),
		})

		withArchiveServer(archive, function(url, sha256)
			tempfile.withTempDir(function(root)
				writeFile(
					fs.path.join(root, "eryx.toml"),
					makeProjectManifest(
						"url-root",
						"0.1.0",
						'archive = { url = "' .. url .. '", sha256 = "' .. sha256 .. '" }',
						nil
					)
				)

				withWorkingDir(root, function()
					pkg.doInstall()
					local lock = lockfile.load(root)
					test.expect(lock):toNotBeNil()
					assert(lock)
					test.expect(countLockPackages(lock)):toBe(2)

					local archivePkg = findLockedPackage(lock, "archive")
					local sharedTarget = findDependencyTarget(archivePkg, "shared")
					test.expect(lock.packages[sharedTarget].type):toBe("repository")
					test.expect(normalizeNewlines(readInstalledInit(root, lock, "archive"))):toContain("urlpkg")
				end)
			end, "eryx-package-url-child-test")
		end)
	end)
end)

suite:test("url dependencies strip a single top-level folder during extraction", function()
	local archive = zip.pack({
		["pkgroot/eryx.toml"] = buffer.fromstring(makeProjectManifest("urlpkg", "0.1.0", nil, nil)),
		["pkgroot/init.luau"] = buffer.fromstring('return "urlpkg-rooted"\n'),
		["pkgroot/lib/module.luau"] = buffer.fromstring('return "nested"\n'),
	})

	withArchiveServer(archive, function(url, sha256)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"url-root",
					"0.1.0",
					'archive = { url = "' .. url .. '", sha256 = "' .. sha256 .. '" }',
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				local archivePkg = findLockedPackage(lock, "archive")
				local dest = fs.path.join(root, "eryx_packages", archivePkg.installName :: string)
				test.expect(fs.exists(fs.path.join(dest, "init.luau"))):toBeTrue()
				test.expect(fs.exists(fs.path.join(dest, "lib", "module.luau"))):toBeTrue()
				test.expect(fs.exists(fs.path.join(dest, "pkgroot"))):toBeFalse()
			end)
		end, "eryx-package-url-root-strip-test")
	end)
end)

suite:test("url dependencies fail when sha256 does not match", function()
	local archive = zip.pack({
		["eryx.toml"] = buffer.fromstring(makeProjectManifest("urlpkg", "0.1.0", nil, nil)),
		["init.luau"] = buffer.fromstring('return "urlpkg"\n'),
	})

	withArchiveServer(archive, function(url, _sha256)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"url-root",
					"0.1.0",
					'archive = { url = "'
						.. url
						.. '", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" }',
					nil
				)
			)

			withWorkingDir(root, function()
				test.expect(function()
					pkg.doInstall()
				end):toError("did not match expected sha256")
			end)
		end, "eryx-package-url-sha-test")
	end)
end)

suite:test("root luaurc preserves non-owned aliases while claiming package aliases", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("alias-preserve-demo", repositoryUrl, 'foo = { repo = "dummy" }')
			)
			writeLuaurc(root, {
				userAlias = "./user/path",
				foo = "./old/foo",
			})

			withWorkingDir(root, function()
				pkg.doInstall()

				local aliases = readLuaurcAliases(root)
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(aliases.userAlias):toBe("./user/path")
				test.expect(aliases.foo):toBe(lock.rootAliases.foo)
			end)
		end, "eryx-package-alias-preserve-test")
	end)
end)

suite:test("root luaurc removes stale owned aliases but keeps user aliases", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")
			writeFile(manifestPath, makeManifest("alias-cleanup-demo", repositoryUrl, 'foo = { repo = "dummy" }'))

			withWorkingDir(root, function()
				pkg.doInstall()

				local aliases = readLuaurcAliases(root)
				aliases.userAlias = "./user/path"
				writeLuaurc(root, aliases)

				writeFile(manifestPath, makeProjectManifest("alias-cleanup-demo", "0.1.0", nil, nil))
				pkg.doInstall()

				local finalAliases = readLuaurcAliases(root)
				test.expect(finalAliases.userAlias):toBe("./user/path")
				test.expect(finalAliases.foo):toBeNil()
			end)
		end, "eryx-package-alias-cleanup-test")
	end)
end)

suite:test("stale package directories are cleaned after dependency changes", function()
	local state: RepoState = {
		foo = {
			["1.0.0"] = {},
		},
		bar = {
			["1.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")
			writeFile(manifestPath, makeManifest("package-cleanup-demo", repositoryUrl, 'foo = { repo = "dummy" }'))

			withWorkingDir(root, function()
				pkg.doInstall()
				local firstLock = lockfile.load(root)
				test.expect(firstLock):toNotBeNil()
				local fooInstall = findLockedPackage(firstLock, "foo").installName :: string
				test.expect(fs.exists(fs.path.join(root, "eryx_packages", fooInstall))):toBeTrue()

				writeFile(manifestPath, makeManifest("package-cleanup-demo", repositoryUrl, 'bar = { repo = "dummy" }'))
				pkg.doInstall()

				local secondLock = lockfile.load(root)
				test.expect(secondLock):toNotBeNil()
				local barInstall = findLockedPackage(secondLock, "bar").installName :: string
				test.expect(fs.exists(fs.path.join(root, "eryx_packages", fooInstall))):toBeFalse()
				test.expect(fs.exists(fs.path.join(root, "eryx_packages", barInstall))):toBeTrue()
			end)
		end, "eryx-package-dir-cleanup-test")
	end)
end)

suite:test("stale git cache entries are cleaned when git dependencies are removed", function()
	withGitRemote(function(remoteUrl, commit)
		commit({
			name = "gitpkg",
			version = "0.1.0",
		}, "first")

		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")
			writeFile(
				manifestPath,
				makeProjectManifest(
					"git-cleanup-root",
					"0.1.0",
					'gitpkg = { git = "' .. remoteUrl .. '", branch = "main" }',
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()
				local cacheDir = fs.path.join(root, "eryx_packages", ".git-cache")
				test.expect(#listDirNames(cacheDir)):toBeGreaterThan(0)

				writeFile(manifestPath, makeProjectManifest("git-cleanup-root", "0.1.0", nil, nil))
				pkg.doInstall()

				test.expect(fs.exists(fs.path.join(root, "eryx_packages"))):toBeFalse()
			end)
		end, "eryx-package-git-cleanup-test")
	end)
end)

suite:test("git tag dependencies resolve to the tagged commit and record requested tag", function()
	withGitRemote(function(remoteUrl, commit)
		local commit1 = commit({
			name = "gitpkg",
			version = "0.1.0",
		}, "tagged")

		tempfile.withTempDir(function(tagWorkDir)
			runGit(tagWorkDir, { "clone", remoteUrl, "." })
			runGit(tagWorkDir, { "config", "user.name", "Eryx Test" })
			runGit(tagWorkDir, { "config", "user.email", "eryx-test@example.com" })
			runGit(tagWorkDir, { "config", "commit.gpgsign", "false" })
			runGit(tagWorkDir, { "tag", "v1", commit1 })
			runGit(tagWorkDir, { "push", "origin", "v1" })
		end, "eryx-package-git-tag-work")

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"git-tag-root",
					"0.1.0",
					'gitpkg = { git = "' .. remoteUrl .. '", tag = "v1" }',
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				local pkgLock = findLockedPackage(lock, "gitpkg")
				test.expect(pkgLock.data.ref.type):toBe("commit")
				test.expect(pkgLock.data.ref.value):toBe(commit1)
				test.expect(pkgLock.data.requestedRef.type):toBe("tag")
				test.expect(pkgLock.data.requestedRef.value):toBe("v1")
			end)
		end, "eryx-package-git-tag-test")
	end)
end)

suite:test("abbreviated git revs still match the lock file", function()
	withGitRemote(function(remoteUrl, commit)
		local commit1 = commit({
			name = "gitpkg",
			version = "0.1.0",
			files = {
				["init.luau"] = 'return "gitpkg@commit1"\n',
			},
		}, "first")
		local short = commit1:sub(1, 8)

		tempfile.withTempDir(function(root)
			local manifestPath = fs.path.join(root, "eryx.toml")

			writeFile(
				manifestPath,
				makeProjectManifest(
					"git-rev-root",
					"0.1.0",
					'gitpkg = { git = "' .. remoteUrl .. '", rev = "' .. commit1 .. '" }',
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				commit({
					name = "gitpkg",
					version = "0.2.0",
					files = {
						["init.luau"] = 'return "gitpkg@commit2"\n',
					},
				}, "second")

				writeFile(
					manifestPath,
					makeProjectManifest(
						"git-rev-root",
						"0.1.0",
						'gitpkg = { git = "' .. remoteUrl .. '", rev = "' .. short .. '" }',
						nil
					)
				)

				pkg.doInstall()
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(findLockedPackage(lock, "gitpkg").data.ref.value):toBe(commit1)
				test.expect(normalizeNewlines(readInstalledInit(root, lock, "gitpkg"))):toContain("gitpkg@commit1")
			end)
		end, "eryx-package-git-rev-test")
	end)
end)

suite:test("git dependencies can bring child repository dependencies", function()
	withRepository({
		shared = {
			["1.0.0"] = {},
		},
	}, function(repositoryUrl)
		withGitRemote(function(remoteUrl, commit)
			commit({
				name = "gitpkg",
				version = "0.1.0",
				dependenciesBlock = 'shared = { repo = "' .. repositoryUrl .. '", version = "1.0.0" }',
			}, "first")

			tempfile.withTempDir(function(root)
				writeFile(
					fs.path.join(root, "eryx.toml"),
					makeProjectManifest(
						"git-child-root",
						"0.1.0",
						'gitpkg = { git = "' .. remoteUrl .. '", branch = "main" }',
						nil
					)
				)

				withWorkingDir(root, function()
					pkg.doInstall()
					local lock = lockfile.load(root)
					test.expect(lock):toNotBeNil()
					assert(lock)
					test.expect(countLockPackages(lock)):toBe(2)

					local gitpkg = findLockedPackage(lock, "gitpkg")
					local sharedTarget = findDependencyTarget(gitpkg, "shared")
					test.expect(lock.packages[sharedTarget].type):toBe("repository")
				end)
			end, "eryx-package-git-child-test")
		end)
	end)
end)

suite:test("git subdir dependencies materialize only the selected subtree", function()
	withRepository({
		shared = {
			["1.0.0"] = {},
		},
	}, function(repositoryUrl)
		withGitRemote(function(remoteUrl, commit)
			commit({
				name = "root",
				version = "0.0.0",
				files = {
					["README.md"] = "root readme\n",
					["packages/markdown/eryx.toml"] = makeProjectManifest(
						"markdown",
						"0.1.0",
						'shared = { repo = "' .. repositoryUrl .. '", version = "1.0.0" }',
						nil,
						"src"
					),
					["packages/markdown/src/init.luau"] = 'return "markdown"\n',
					["packages/markdown/notes.txt"] = "keep me\n",
					["packages/eryxdoc/eryx.toml"] = makeProjectManifest("eryxdoc", "0.1.0", nil, nil),
					["packages/eryxdoc/init.luau"] = 'return "eryxdoc"\n',
				},
			}, "first")

			tempfile.withTempDir(function(root)
				writeFile(
					fs.path.join(root, "eryx.toml"),
					makeProjectManifest(
						"git-subdir-root",
						"0.1.0",
						'markdown = { git = "' .. remoteUrl .. '", branch = "main", subdir = "packages/markdown" }',
						nil
					)
				)

				withWorkingDir(root, function()
					pkg.doInstall()

					local lock = lockfile.load(root)
					test.expect(lock):toNotBeNil()
					assert(lock)

					local markdown = findLockedPackage(lock, "markdown")
					test.expect(markdown.data.subdir):toBe("packages/markdown")
					test.expect(lock.rootAliases.markdown):toContain("/src")

					local sharedTarget = findDependencyTarget(markdown, "shared")
					test.expect(lock.packages[sharedTarget].type):toBe("repository")

					local dest = fs.path.join(root, "eryx_packages", markdown.installName :: string)
					test.expect(fs.exists(fs.path.join(dest, "src", "init.luau"))):toBeTrue()
					test.expect(fs.exists(fs.path.join(dest, "notes.txt"))):toBeTrue()
					test.expect(fs.exists(fs.path.join(dest, "packages"))):toBeFalse()
					test.expect(fs.exists(fs.path.join(dest, "README.md"))):toBeFalse()
					test.expect(fs.exists(fs.path.join(dest, "eryxdoc"))):toBeFalse()
				end)
			end, "eryx-package-git-subdir-materialize-test")
		end)
	end)
end)

suite:test("git subdir dependencies from the same repo share one cache entry", function()
	withGitRemote(function(remoteUrl, commit)
		commit({
			name = "root",
			version = "0.0.0",
			files = {
				["packages/markdown/eryx.toml"] = makeProjectManifest("markdown", "0.1.0", nil, nil),
				["packages/markdown/init.luau"] = 'return "markdown"\n',
				["packages/eryxdoc/eryx.toml"] = makeProjectManifest("eryxdoc", "0.1.0", nil, nil),
				["packages/eryxdoc/init.luau"] = 'return "eryxdoc"\n',
			},
		}, "first")

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeProjectManifest(
					"git-subdir-cache-root",
					"0.1.0",
					table.concat({
						'markdown = { git = "' .. remoteUrl .. '", branch = "main", subdir = "packages/markdown" }',
						'eryxdoc = { git = "' .. remoteUrl .. '", branch = "main", subdir = "packages/eryxdoc" }',
					}, "\n"),
					nil
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()

				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(2)

				local cacheDir = fs.path.join(root, "eryx_packages", ".git-cache")
				test.expect(#listDirNames(cacheDir)):toBe(1)

				local markdown = findLockedPackage(lock, "markdown")
				local eryxdoc = findLockedPackage(lock, "eryxdoc")
				test.expect(markdown.data.subdir):toBe("packages/markdown")
				test.expect(eryxdoc.data.subdir):toBe("packages/eryxdoc")

				local markdownDir = fs.path.join(root, "eryx_packages", markdown.installName :: string)
				local eryxdocDir = fs.path.join(root, "eryx_packages", eryxdoc.installName :: string)
				test.expect(fs.exists(fs.path.join(markdownDir, "init.luau"))):toBeTrue()
				test.expect(fs.exists(fs.path.join(markdownDir, "packages"))):toBeFalse()
				test.expect(fs.exists(fs.path.join(eryxdocDir, "init.luau"))):toBeTrue()
				test.expect(fs.exists(fs.path.join(eryxdocDir, "packages"))):toBeFalse()
			end)
		end, "eryx-package-git-subdir-cache-test")
	end)
end)

suite:test("eryx run resolves scripts from installed direct dependencies", function()
	tempfile.withTempDir(function(root)
		local depDir = fs.path.join(root, "eryxdoc")
		fs.mkdir(depDir)
		fs.mkdir(fs.path.join(depDir, "scripts"))

		writeFile(
			fs.path.join(depDir, "eryx.toml"),
			withScripts(makeProjectManifest("eryxdoc", "0.1.0", nil, nil, nil, nil), { doc = "scripts/doc.luau" })
		)
		writeFile(fs.path.join(depDir, "scripts", "doc.luau"), 'print("dep-doc")\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			makeProjectManifest("run-root", "0.1.0", 'eryxdoc = { local = "./eryxdoc" }', nil)
		)

		withWorkingDir(root, function()
			pkg.doInstall()
		end)

		local res = runEryx(root, { "run", "doc" })
		test.expect(res.code):toBe(0)
		test.expect(normalizeNewlines(res.stdout)):toContain("dep-doc")
	end, "eryx-run-dependency-script-test")
end)

suite:test("eryx run resolves scripts from direct workspace dependencies", function()
	tempfile.withTempDir(function(root)
		local packagesDir = fs.path.join(root, "projects")
		local depDir = fs.path.join(packagesDir, "eryxdoc")
		fs.mkdir(packagesDir)
		fs.mkdir(depDir)
		fs.mkdir(fs.path.join(depDir, "scripts"))

		writeFile(
			fs.path.join(depDir, "eryx.toml"),
			withScripts(makeProjectManifest("eryxdoc", "0.1.0", nil, nil, nil, nil), { doc = "scripts/doc.luau" })
		)
		writeFile(fs.path.join(depDir, "scripts", "doc.luau"), 'print("workspace-doc")\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			withWorkspace(
				makeProjectManifest(
					"run-root",
					"0.1.0",
					'eryxdoc = { git = "https://example.invalid/eryx.git", branch = "main", subdir = "projects/eryxdoc" }',
					nil
				),
				{
					eryxdoc = "./projects/eryxdoc",
				}
			)
		)

		withWorkingDir(root, function()
			pkg.doInstall()
		end)

		local res = runEryx(root, { "run", "doc" })
		test.expect(res.code):toBe(0)
		test.expect(normalizeNewlines(res.stdout)):toContain("workspace-doc")
	end, "eryx-run-workspace-dependency-script-test")
end)

suite:test("eryx run ignores workspace packages that are not direct dependencies", function()
	tempfile.withTempDir(function(root)
		local packagesDir = fs.path.join(root, "projects")
		local depDir = fs.path.join(packagesDir, "eryxdoc")
		fs.mkdir(packagesDir)
		fs.mkdir(depDir)
		fs.mkdir(fs.path.join(depDir, "scripts"))

		writeFile(
			fs.path.join(depDir, "eryx.toml"),
			withScripts(makeProjectManifest("eryxdoc", "0.1.0", nil, nil, nil, nil), { doc = "scripts/doc.luau" })
		)
		writeFile(fs.path.join(depDir, "scripts", "doc.luau"), 'print("workspace-doc")\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			withWorkspace(makeProjectManifest("run-root", "0.1.0", 'eryx = { path = "build/Debug/modules" }', nil), {
				eryxdoc = "./projects/eryxdoc",
			})
		)

		withWorkingDir(root, function()
			pkg.doInstall()
		end)

		local res = runEryx(root, { "run", "doc" })
		test.expect(res.code):toBe(1)
		test.expect(normalizeNewlines(res.stderr)):toContain("No project script named 'doc'")
	end, "eryx-run-workspace-nondependency-script-test")
end)

suite:test("eryx run prefers project scripts over dependency scripts", function()
	tempfile.withTempDir(function(root)
		local depDir = fs.path.join(root, "eryxdoc")
		fs.mkdir(depDir)
		fs.mkdir(fs.path.join(depDir, "scripts"))
		fs.mkdir(fs.path.join(root, "scripts"))

		writeFile(
			fs.path.join(depDir, "eryx.toml"),
			withScripts(makeProjectManifest("eryxdoc", "0.1.0", nil, nil, nil, nil), { doc = "scripts/doc.luau" })
		)
		writeFile(fs.path.join(depDir, "scripts", "doc.luau"), 'print("dep-doc")\n')
		writeFile(fs.path.join(root, "scripts", "doc.luau"), 'print("root-doc")\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			withScripts(
				makeProjectManifest("run-root", "0.1.0", 'eryxdoc = { local = "./eryxdoc" }', nil),
				{ doc = "scripts/doc.luau" }
			)
		)

		withWorkingDir(root, function()
			pkg.doInstall()
		end)

		local res = runEryx(root, { "run", "doc" })
		test.expect(res.code):toBe(0)
		test.expect(normalizeNewlines(res.stdout)):toContain("root-doc")
		test.expect(normalizeNewlines(res.stdout):find("dep-doc", 1, true)):toBeNil()
	end, "eryx-run-project-script-precedence-test")
end)

suite:test("eryx run errors when multiple dependencies define the same script", function()
	tempfile.withTempDir(function(root)
		local function writeDep(dirName: string)
			local depDir = fs.path.join(root, dirName)
			fs.mkdir(depDir)
			fs.mkdir(fs.path.join(depDir, "scripts"))
			writeFile(
				fs.path.join(depDir, "eryx.toml"),
				withScripts(makeProjectManifest(dirName, "0.1.0", nil, nil, nil, nil), { doc = "scripts/doc.luau" })
			)
			writeFile(fs.path.join(depDir, "scripts", "doc.luau"), `print("{dirName}-doc")\n`)
		end

		writeDep("eryxdoc")
		writeDep("markdown")

		writeFile(
			fs.path.join(root, "eryx.toml"),
			makeProjectManifest(
				"run-root",
				"0.1.0",
				table.concat({
					'eryxdoc = { local = "./eryxdoc" }',
					'markdown = { local = "./markdown" }',
				}, "\n"),
				nil
			)
		)

		withWorkingDir(root, function()
			pkg.doInstall()
		end)

		local res = runEryx(root, { "run", "doc" })
		test.expect(res.code):toBe(1)
		test.expect(normalizeNewlines(res.stderr)):toContain("multiple direct dependencies")
		test.expect(normalizeNewlines(res.stderr)):toContain("eryxdoc")
		test.expect(normalizeNewlines(res.stderr)):toContain("markdown")
	end, "eryx-run-dependency-script-conflict-test")
end)

suite:test("local dependency cycles are rejected", function()
	tempfile.withTempDir(function(root)
		local aDir = fs.path.join(root, "a")
		local bDir = fs.path.join(root, "b")
		local aPath = aDir:gsub("\\", "/")
		local bPath = bDir:gsub("\\", "/")
		fs.mkdir(aDir)
		fs.mkdir(bDir)

		writeFile(
			fs.path.join(aDir, "eryx.toml"),
			makeProjectManifest("a", "0.1.0", 'b = { local = "' .. bPath .. '" }', nil)
		)
		writeFile(fs.path.join(aDir, "init.luau"), 'return "a"\n')
		writeFile(
			fs.path.join(bDir, "eryx.toml"),
			makeProjectManifest("b", "0.1.0", 'a = { local = "' .. aPath .. '" }', nil)
		)
		writeFile(fs.path.join(bDir, "init.luau"), 'return "b"\n')

		writeFile(
			fs.path.join(root, "eryx.toml"),
			makeProjectManifest("cycle-root", "0.1.0", 'a = { local = "./a" }', nil)
		)

		withWorkingDir(root, function()
			test.expect(function()
				pkg.doInstall()
			end):toError("Cyclic dependency detected")
		end)
	end, "eryx-package-local-cycle-test")
end)

suite:test("repository dependency cycles are rejected", function()
	local state: RepoState = {
		foo = {},
		bar = {},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				bar = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		state.bar["1.0.0"] = {
			dependencies = {
				foo = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		sync()

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("repo-cycle-root", repositoryUrl, 'foo = { repo = "dummy", version = "1.0.0" }')
			)

			withWorkingDir(root, function()
				test.expect(function()
					pkg.doInstall()
				end):toError("Cyclic dependency detected")
			end)
		end, "eryx-package-repo-cycle-test")
	end)
end)

suite:test("repository ranges choose the highest satisfying version", function()
	withRepository({
		foo = {
			["1.0.0"] = {},
			["1.5.0"] = {},
			["2.0.0"] = {},
		},
	}, function(repositoryUrl)
		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest("range-root", repositoryUrl, 'foo = { repo = "dummy", version = "^1.0.0" }')
			)

			withWorkingDir(root, function()
				pkg.doInstall()
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				test.expect(findLockedPackage(lock, "foo").data.version):toBe("1.5.0")
			end)
		end, "eryx-package-range-choice-test")
	end)
end)

suite:test("compatible repository ranges deduplicate to the highest shared version", function()
	local state: RepoState = {
		foo = {},
		bar = {},
		shared = {
			["1.0.0"] = {},
			["1.1.0"] = {},
			["2.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "^1.0.0" },
			},
		}
		state.bar["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "^1.1.0" },
			},
		}
		sync()

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"range-dedupe-root",
					repositoryUrl,
					table.concat({
						'foo = { repo = "dummy", version = "1.0.0" }',
						'bar = { repo = "dummy", version = "1.0.0" }',
					}, "\n")
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)

				local foo = findLockedPackage(lock, "foo")
				local bar = findLockedPackage(lock, "bar")
				local sharedTarget = findDependencyTarget(foo, "shared")
				test.expect(sharedTarget):toBe(findDependencyTarget(bar, "shared"))
				test.expect(lock.packages[sharedTarget].data.version):toBe("1.1.0")
			end)
		end, "eryx-package-range-dedupe-test")
	end)
end)

suite:test("conflicting repository ranges can coexist as separate transitive installs", function()
	local state: RepoState = {
		foo = {},
		bar = {},
		shared = {
			["1.0.0"] = {},
			["2.0.0"] = {},
		},
	}

	withRepository(state, function(repositoryUrl, sync)
		state.foo["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "1.0.0" },
			},
		}
		state.bar["1.0.0"] = {
			dependencies = {
				shared = { repo = repositoryUrl, version = "2.0.0" },
			},
		}
		sync()

		tempfile.withTempDir(function(root)
			writeFile(
				fs.path.join(root, "eryx.toml"),
				makeManifest(
					"range-conflict-root",
					repositoryUrl,
					table.concat({
						'foo = { repo = "dummy", version = "1.0.0" }',
						'bar = { repo = "dummy", version = "1.0.0" }',
					}, "\n")
				)
			)

			withWorkingDir(root, function()
				pkg.doInstall()
				local lock = lockfile.load(root)
				test.expect(lock):toNotBeNil()
				assert(lock)
				test.expect(countLockPackages(lock)):toBe(4)

				local foo = findLockedPackage(lock, "foo")
				local bar = findLockedPackage(lock, "bar")
				local sharedFoo = lock.packages[findDependencyTarget(foo, "shared")]
				local sharedBar = lock.packages[findDependencyTarget(bar, "shared")]
				test.expect(sharedFoo.data.version):toBe("1.0.0")
				test.expect(sharedBar.data.version):toBe("2.0.0")
			end)
		end, "eryx-package-range-conflict-test")
	end)
end)

return suite
