--!nolint LocalShadow
local fs = require("@eryx/fs")
local os = require("@eryx/os")
local project = require("@eryx/project")
local cycles = require("../cycles")
local types = require("../types")
local util = require("../util")

local function canonicalGitIdentity(url: string): string
	url = url:gsub("^%s+", ""):gsub("%s+$", "")

	url = url:gsub("^git%+ssh://", "")
	url = url:gsub("^ssh://", "")
	url = url:gsub("^https://", "")
	url = url:gsub("^http://", "")
	url = url:gsub("^git://", "")

	local userHost, scpPath = url:match("^([^/%s:@]+@[^/%s:]+):(.+)$")
	if userHost and scpPath then
		local host = userHost:match("@(.+)$") :: string
		url = host .. "/" .. scpPath
	else
		url = url:gsub("^[^/@]+@", "")
	end

	url = url:gsub("[#?].*$", "")
	url = url:gsub("\\", "/")
	url = url:gsub("/+", "/")
	url = url:gsub("/+$", "")
	url = url:gsub("%.git$", "")

	local host, path = url:match("^([^/]+)/(.*)$")
	if host and path then
		host = host:lower()
		host = host:gsub(":22$", "")
		host = host:gsub(":443$", "")
		host = host:gsub(":80$", "")

		return host .. "/" .. path
	end

	return url:lower()
end

local function callGit(cwd: string, args: { string }): (boolean, string, string)
	local res = os.exec("git", args, { cwd = cwd })

	return res.code == 0, res.stdout, res.stderr
end

local function prepare(root: string, cloneUrl: string, ref: types.GitRef): (string, string?)
	local identity = canonicalGitIdentity(cloneUrl)
	local dir = util.identityToDirName(identity) .. ".git"

	local cacheFolder = util.ensurePackagesSubDir(root, ".git-cache")
	local gitFolder, isGitNew = util.ensureDir(fs.path.join(cacheFolder, dir))

	if isGitNew then
		if not callGit(cacheFolder, { "init", "--bare", dir }) then
			error(`Failed to initialise bare repo for {cloneUrl}`)
		end

		if not callGit(gitFolder, { "remote", "add", "origin", cloneUrl }) then
			error(`Failed to setup remote for {cloneUrl}`)
		end
	else
		if not callGit(gitFolder, { "remote", "set-url", "origin", cloneUrl }) then
			error(`Failed to setup remote for {cloneUrl}`)
		end
	end

	local fetchRef: string
	if ref.type == "branch" then
		fetchRef = `refs/heads/{ref.value}`
	elseif ref.type == "tag" then
		fetchRef = `refs/tags/{ref.value}`
	else
		fetchRef = ref.value
	end

	print(`Fetching {cloneUrl} {ref.type} {ref.value}`)

	if ref.type == "commit" then
		local haveCommit = callGit(gitFolder, {
			"cat-file",
			"-e",
			ref.value .. "^{commit}",
		})

		if haveCommit then
			local ok, out = callGit(gitFolder, {
				"show",
				ref.value .. ":eryx.toml",
			})

			if ok then
				return gitFolder, out
			end

			return gitFolder, nil
		end
	end

	if not callGit(gitFolder, {
		"fetch",
		"origin",
		fetchRef,
		"--depth=1",
		"--filter=blob:none",
	}) then
		error(`Failed to fetch {cloneUrl} {ref.type} {ref.value}`)
	end

	local ok, out = callGit(gitFolder, {
		"show",
		"FETCH_HEAD:eryx.toml",
	})

	if not ok then
		return gitFolder, nil
	end

	return gitFolder, out
end
local function getGitRef(dep: project.GitDependency): types.GitRef
	local rev = (dep :: any).rev
	local tag = (dep :: any).tag
	local branch = (dep :: any).branch

	local count = 0
	if rev then
		count += 1
	end
	if tag then
		count += 1
	end
	if branch then
		count += 1
	end

	if count ~= 1 then
		error("Git dependency must specify exactly one of 'rev', 'tag', or 'branch'")
	end

	if rev then
		return { type = "commit", value = rev }
	elseif tag then
		return { type = "tag", value = tag }
	else
		return { type = "branch", value = branch }
	end
end

local function gitRefIdentity(ref: types.GitRef): string
	return ref.type .. ":" .. ref.value
end

local gitSource: types.Source = {
	type = "git",

	checkDependency = function(dep)
		if (dep :: any)["git"] then
			return true
		end
		return false
	end,

	collect = function(
		root: string,
		path: string,
		manifest: project.Manifest,
		name: string,
		dep: project.Dependency,
		requirements: { types.Requirement },
		visiting: types.Visiting,
		allowLocal: boolean,
		recurse: types.CollectRecursion
	)
		local dep = dep :: project.GitDependency

		local ref = getGitRef(dep)
		local gitFolder, config = prepare(root, dep.git, ref)

		local r: types.Requirement = {
			type = "git",
			name = name,
			path = canonicalGitIdentity(dep.git),
			url = dep.git,
			ref = ref,
			gitFolder = gitFolder,
			tree = {},
		}

		if config then
			local visitingKey = cycles.pushVisiting(r, visiting, name)

			local childPrj = project.parse(config)
			recurse(root, path, childPrj.manifest, r.tree, visiting, false)

			cycles.popVisiting(visitingKey, visiting)
		end

		table.insert(requirements, r)
	end,

	materialise = function(root: string, requirement: types.Requirement, dest: string)
		if requirement.type ~= "git" then
			error("Internal error: expected git requirement")
		end

		-- Re-fetch here so FETCH_HEAD definitely points at this exact dependency.
		prepare(root, requirement.url, requirement.ref)

		local res, _stdout, stderr = callGit(".", {
			"--git-dir",
			requirement.gitFolder,
			"--work-tree",
			dest,
			"checkout",
			"--force",
			"FETCH_HEAD",
			"--",
			".",
		})

		if not res then
			error(`Failed to checkout git dependency {requirement.url}\n{stderr}`)
		end
	end,

	identity = function(requirement: types.Requirement): string
		assert(requirement.type == "git")
		return "git:" .. requirement.path .. "#" .. gitRefIdentity(requirement.ref)
	end,

	generateLock = function(requirement: types.Requirement): { [string]: any }
		assert(requirement.type == "git")
		return {
			url = requirement.url,
			ref = {
				type = requirement.ref.type,
				value = requirement.ref.value,
			},
		}
	end,
}

return table.freeze(gitSource)
