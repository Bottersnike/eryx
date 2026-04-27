local pkg = require("@eryx/package")
local project = require("@eryx/project")

local pkgTypes = require("@eryx/package/types")

local argparse = require("@eryx/argparse")
local os = require("@eryx/os")
local semver = require("@eryx/semver")
local stdio = require("@eryx/stdio")

local parser = argparse.Parser.new("pkg", "Erxy package manager")
parser:addSubCommand("install", "Install all packages")
parser:addSubCommand("tree", "Show the dependency tree")
parser:addSubCommand("ls", "List all top level dependencies")

local add = parser:addSubCommand("add", "Install a new dependency")
add:addFlag("path", nil, "Mark this dependency as a path dependency")
add:addFlag("dry", nil, "Do not perform an install after updating dependencies")
add:addOption("sha256", nil, "string", nil, false, "URL package SHA256")
add:addOption("rev", nil, "string", nil, false, "Git revision")
add:addOption("tag", nil, "string", nil, false, "Git tag")
add:addOption("branch", nil, "string", nil, false, "Git branch")
add:addMutuallyExclusive({ "path", "sha256", "rev", "tag", "branch" })
add:addPositional("package", "string")

local remove = parser:addSubCommand("remove", "Remove an existing dependency")
remove:addPositional("package", "string")
remove:addFlag("dry", nil, "Do not perform an install after updating dependencies")

local args = parser:parse() :: {
	help: boolean,
	install: {}?,
	ls: {}?,
	tree: {}?,
	add: {
		path: boolean,
		dry: boolean,
		sha256: string?,
		rev: string?,
		tag: string?,
		branch: string?,
		package: string,
	}?,
	remove: {
		dry: boolean,
		package: string,
	}?,
}

local COLOR: boolean
do
	-- Honour https://no-color.org/
	if os.getenv("NO_COLOR") then
		COLOR = false
	elseif os.getenv("FORCE_COLOR") then
		COLOR = true
	else
		COLOR = stdio.isatty().stdout
	end
end

local function ansi(open: string, close: string, s: string): string
	if not COLOR then
		return s
	end
	return `\27[{open}m{s}\27[{close}m`
end

local function green(s: string)
	return ansi("32", "39", s) -- reset foreground only
end

local function red(s: string)
	return ansi("31", "39", s)
end

local function cyan(s: string)
	return ansi("36", "39", s)
end

local function bold(s: string)
	return ansi("1", "22", s) -- normal intensity
end

local function dim(s: string)
	return ansi("2", "22", s) -- normal intensity
end

local function printInstallPlanTree(plan: pkgTypes.InstallPlan)
	local function formatRequirement(r: pkgTypes.Requirement): string
		if r.type == "repository" then
			return `requested {bold(if r.range then semver.formatRange(r.range) else "any")}, chose {bold(
				if r.version then semver.format(r.version) else "*ERROR*"
			)} from {r.repository}`
		elseif r.type == "git" then
			return `{r.url}#{r.ref.type}:{r.ref.value}`
		elseif r.type == "file" then
			return if r.sha256 then `{r.path} sha256:{r.sha256}` else r.path
		elseif r.type == "local" then
			return `local:{r.path}`
		elseif r.type == "path" then
			return `path:{r.path}`
		else
			return "<unknown>"
		end
	end

	local function printNode(edge: pkgTypes.InstallEdge, prefix: string, isLast: boolean, seen: { [string]: boolean })
		local node = plan.nodes[edge.target]

		if not node then
			print(
				prefix
					.. (if isLast then "└── " else "├── ")
					.. edge.alias
					.. " -> <missing "
					.. edge.target
					.. ">"
			)
			return
		end

		local branch = if isLast then "└── " else "├── "
		local childPrefix = prefix .. (if isLast then "    " else "│   ")
		local reused = seen[node.id]

		print(
			prefix
				.. branch
				.. green(edge.alias)
				.. ` -> {cyan(formatRequirement(node.requirement))}`
				.. (if node.requirement.type == "path" then "" else ` ({dim(node.installName)})`)
				.. if reused then bold(" [already shown]") else ""
		)

		if reused then
			return
		end

		seen[node.id] = true

		for i, child in node.dependencies do
			printNode(child, childPrefix, i == #node.dependencies, seen)
		end
	end

	print("Install plan:")

	local seen: { [string]: boolean } = {}

	for i, edge in plan.roots do
		printNode(edge, "", i == #plan.roots, seen)
	end
end

local function splitExplicitName(spec: string): (string?, string)
	local eq = spec:find("=", 1, true)
	if not eq then
		return nil, spec
	end

	return spec:sub(1, eq - 1), spec:sub(eq + 1)
end

local function isUrl(s: string): boolean
	return s:match("^https?://") ~= nil
end

local function isGitUrl(s: string): boolean
	return s:match("^git%+") ~= nil
end

local function isProbablyPath(s: string): boolean
	return s:match("^%.%.?[\\/]") ~= nil or s:match("^[\\/]") ~= nil or s:match("^%a:[\\/]") ~= nil
end

local function isHex(s: string): boolean
	return s:match("^[0-9a-fA-F]+$") ~= nil
end

local function validateSha256(hash: string)
	if #hash ~= 64 or not isHex(hash) then
		error("SHA256 must be exactly 64 hexadecimal characters")
	end
end

local function validateGitRev(rev: string)
	-- Git object IDs are traditionally SHA-1, 40 hex chars.
	-- Newer repositories may use SHA-256, 64 hex chars.
	--
	-- Git accepts abbreviated hashes as long as they are unambiguous,
	-- but we enforce a minimum to avoid silly/fragile inputs.
	if #rev < 7 then
		error("Git revision must be at least 7 hexadecimal characters")
	end

	if #rev > 64 then
		error("Git revision cannot be longer than 64 hexadecimal characters")
	end

	if not isHex(rev) then
		error("Git revision must contain only hexadecimal characters")
	end
end

local function validateGitRefName(kind: string, s: string)
	if s == "" then
		error(`Git {kind} cannot be empty`)
	end

	if s:find("[%z\1-\31\127]") then
		error(`Git {kind} cannot contain control characters`)
	end

	if s:find("[ ~%^:%?%*%[\\]") then
		error(`Git {kind} contains invalid characters`)
	end

	if s:find("%.%.") then
		error(`Git {kind} cannot contain '..'`)
	end

	if s:find("@{", 1, true) then
		error(`Git {kind} cannot contain '@\{'`)
	end

	if s:sub(1, 1) == "." then
		error(`Git {kind} cannot start with '.'`)
	end

	if s:sub(-1) == "." then
		error(`Git {kind} cannot end with '.'`)
	end

	if s:sub(-5) == ".lock" then
		error(`Git {kind} cannot end with '.lock'`)
	end

	if s:sub(1, 1) == "/" or s:sub(-1) == "/" then
		error(`Git {kind} cannot start or end with '/'`)
	end

	if s:find("//", 1, true) then
		error(`Git {kind} cannot contain '//'`)
	end
end

local function isNameChunk(s: string): boolean
	return s:match("^[A-Za-z0-9]+$") ~= nil
end

local function validateDependencyName(name: string)
	if name == "" then
		error("Dependency name cannot be empty")
	end

	if name:find("//", 1, true) then
		error(`Invalid dependency name '{name}': cannot contain empty '/' chunks`)
	end

	if name:sub(1, 1) == "/" or name:sub(-1) == "/" then
		error(`Invalid dependency name '{name}': cannot start or end with '/'`)
	end

	for chunk in name:gmatch("[^/]+") do
		if not isNameChunk(chunk) then
			error(`Invalid dependency name '{name}'. Expected chunks of [A-Za-z0-9] separated by single '/'`)
		end
	end
end

local function basename(path: string): string
	path = path:gsub("[/\\]+$", "")
	local name = path:match("([^/\\]+)$") or path
	name = name:gsub("%.git$", "")
	name = name:gsub("%.zip$", "")

	validateDependencyName(name)
	return name
end

local function validateHttpUrl(url: string)
	if not (url:match("^https://") or url:match("^http://")) then
		error("URL dependencies must use http:// or https://")
	end
end

local function validateGitUrl(url: string)
	-- Keep this deliberately permissive. We only reject obviously unsupported schemes.
	if url:match("^https://") then
		return
	end

	if url:match("^ssh://") then
		return
	end

	if url:match("^git://") then
		return
	end

	-- Common SCP-like Git syntax:
	-- git@github.com:owner/repo.git
	-- user@example.com:path/to/repo.git
	if url:match("^[%w%._%-]+@[%w%._%-]+:.+") then
		return
	end

	error("Git dependencies must use https://, ssh://, git://, or SCP-like user@host:path syntax")
end

local function countGitRefs(): number
	assert(args.add)
	local n = 0
	if args.add.rev then
		n += 1
	end
	if args.add.tag then
		n += 1
	end
	if args.add.branch then
		n += 1
	end
	return n
end

local function parseRepoSpec(spec: string): (string, project.RepositoryDependency)
	local repo = "eryx"
	local nameAndVersion = spec

	local colon = spec:find(":", 1, true)
	if colon then
		repo = spec:sub(1, colon - 1)
		nameAndVersion = spec:sub(colon + 1)
	end

	local name = nameAndVersion
	local version: semver.Range? = nil

	local at = nameAndVersion:find("@", 1, true)
	if at then
		name = nameAndVersion:sub(1, at - 1)
		local rangeText = nameAndVersion:sub(at + 1)

		version = semver.parseRange(rangeText)
		if not version then
			error(`Invalid semantic version range: {rangeText}`)
		end
	end

	if name == "" then
		error("Repository package name cannot be empty")
	end

	validateDependencyName(name)

	return name, {
		repo = repo,
		version = version,
	}
end

local function parseAddDependency(): (string, project.Dependency)
	assert(args.add)

	local explicitName, spec = splitExplicitName(args.add.package)
	if explicitName then
		validateDependencyName(explicitName)
	end

	if spec == "" then
		error("Dependency source cannot be empty")
	end

	if args.add.path then
		if args.add.sha256 or countGitRefs() > 0 then
			error("--path cannot be combined with --sha256, --rev, --tag or --branch")
		end

		return explicitName or basename(spec), {
			path = spec,
		} :: project.PathDependency
	end

	if isGitUrl(spec) then
		if args.add.sha256 then
			error("--sha256 is only valid for URL dependencies")
		end

		local git = spec:gsub("^git%+", "")
		validateGitUrl(git)

		if args.add.rev then
			validateGitRev(args.add.rev)
			return explicitName or basename(git), {
				git = git,
				rev = args.add.rev,
			}
		elseif args.add.tag then
			validateGitRefName("tag", args.add.tag)
			return explicitName or basename(git), {
				git = git,
				tag = args.add.tag,
			}
		elseif args.add.branch then
			validateGitRefName("branch", args.add.branch)
			return explicitName or basename(git), {
				git = git,
				branch = args.add.branch,
			}
		else
			error("Git dependencies require exactly one of --rev, --tag or --branch")
		end
	end

	if isUrl(spec) then
		if countGitRefs() > 0 then
			error("--rev, --tag and --branch are only valid for Git dependencies")
		end
		if args.add.sha256 then
			validateSha256(args.add.sha256)
		end
		validateHttpUrl(spec)

		return explicitName or basename(spec), {
			url = spec :: string,
			sha256 = args.add.sha256,
		}
	end

	if isProbablyPath(spec) then
		if args.add.sha256 or countGitRefs() > 0 then
			error("Local dependencies cannot use --sha256, --rev, --tag or --branch")
		end

		return explicitName or basename(spec), {
			["local"] = spec :: string,
		} :: project.LocalDependency
	end

	if args.add.sha256 or countGitRefs() > 0 then
		error("--sha256, --rev, --tag and --branch require a URL or Git dependency")
	end

	return parseRepoSpec(spec)
end

local function formatDependency(name: string, dep: project.Dependency): string
	-- Plain string dependency
	if type(dep) == "string" then
		return name .. "@" .. dep
	end

	-- Path dependency
	if (dep :: any).path then
		return `--path {name}={dep.path}`
	end

	-- Local dependency
	if (dep :: any)["local"] then
		return `{name}={dep["local"]}`
	end

	-- URL dependency
	if (dep :: any).url then
		local out = `{name}={dep.url}`

		if (dep :: any).sha256 then
			out ..= ` --sha256 {dep.sha256}`
		end

		return out
	end

	-- Git dependency
	if (dep :: any).git then
		local out = `{name}=git+{dep.git}`

		if (dep :: any).rev then
			out ..= ` --rev {dep.rev}`
		elseif (dep :: any).tag then
			out ..= ` --tag {dep.tag}`
		elseif (dep :: any).branch then
			out ..= ` --branch {dep.branch}`
		end

		return out
	end

	-- Repository dependency
	if typeof(dep.repo) == "string" then
		local out = ""

		if dep.repo ~= "eryx" then
			out ..= dep.repo .. ":"
		end

		out ..= name

		-- package name not present inside object, caller prefixes externally
		if dep.version then
			out ..= "@" .. semver.formatRange(dep.version)
		end

		return out
	end

	error("Unknown dependency kind")
end

local function main()
	local prj = project.loadNearest()
	if not prj then
		error("No project file present")
	end

	if args.install then
		pkg.doInstall()
		return
	end

	if args.tree then
		local plan = pkg.computeInstallPlan()
		if plan then
			printInstallPlanTree(plan)
		end
		return
	end

	if args.ls then
		if prj.manifest.dependencies then
			for name, dep in prj.manifest.dependencies do
				print(formatDependency(name, dep))
			end
		end
		return
	end

	if args.add then
		local name, dependency = parseAddDependency()

		-- Normalise semver back to a string, so we can save to TOML
		if (dependency :: any).version then
			(dependency :: any).version = semver.formatRange(dependency.version)
		end

		-- Modify in the CST, so we preserve the rest of document
		if not prj.cst.eryx.dependencies then
			prj.cst.eryx.dependencies = {}
		end
		prj.cst.eryx.dependencies[name] = dependency

		project.save(prj)

		if not args.add.dry then
			pkg.doInstall()
		end
		return
	end

	if args.remove then
		if not prj.manifest.dependencies then
			print(`Package {args.remove.package} not installed`)
			return
		end
		if not prj.manifest.dependencies[args.remove.package] then
			print(`Package {args.remove.package} not installed`)
			return
		end

		-- Modify in the CST, so we preserve the rest of document
		prj.cst.eryx.dependencies[args.remove.package] = nil

		project.save(prj)

		if not args.remove.dry then
			pkg.doInstall()
		end
		return
	end

	print(parser:generateHelp())
end

main()
