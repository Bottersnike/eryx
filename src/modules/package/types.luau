local project = require("@eryx/project")
local semver = require("@eryx/semver")

export type VisitingEntry = {
	key: string,
	name: string,
}

export type Visiting = {
	order: { VisitingEntry },
	set: { [string]: number },
}

export type GitRef = {
	type: "branch" | "tag" | "commit",
	value: string,
}

export type Requirement =
	{
		type: "local",
		name: string,
		path: string,
		tree: { Requirement },
	}
	| {
		type: "path",
		name: string,
		path: string,
		tree: { Requirement },
	}
	| {
		type: "git",
		name: string,
		path: string,
		url: string,
		ref: GitRef,
		gitFolder: string,
		tree: { Requirement },
	}
	| {
		type: "file",
		name: string,
		path: string,
		sha256: string?,
		tree: { Requirement },
	}
	| {
		type: "repository",
		-- The dep key from the manifest; used as the .luaurc alias
		name: string,
		-- The package name in the repository (= packageName if specified in toml, else name)
		key: string,
		repository: string,
		path: string,
		range: semver.Range?,
		version: semver.Version?,
		tree: { Requirement },
	}
export type RequirementKind = "local" | "path" | "git" | "file" | "repository"

export type InstallEdge = {
	alias: string,
	target: string,
}

export type InstallNode = {
	id: string,
	installName: string,
	requirement: Requirement,
	dependencies: { InstallEdge },
}

export type InstallPlan = {
	nodes: { [string]: InstallNode },
	roots: { InstallEdge },
}

export type ResolveContext = {
	plan: InstallPlan,
	repositorySelections: { [string]: { InstallNode } },
	resolving: { [string]: boolean },
}

export type CollectRecursion = (
	root: string,
	path: string,
	manifest: project.Manifest,
	requirements: { Requirement },
	visiting: Visiting,
	allowLocal: boolean
) -> ()

export type ResolveRecursion = (ctx: ResolveContext, node: InstallNode, children: { Requirement }) -> ()

export type Source = {
	read type: RequirementKind,

	-- Check if a dependency matches this source
	read checkDependency: (dep: project.Dependency) -> boolean,

	--- Perform "collection" on a dependency, resolving it
	read collect: (
		-- The root of the project
		root: string,
		-- The path for this dependency. Only particularly relative in local packages
		path: string,
		-- The project manifest
		manifest: project.Manifest,
		-- The name for this dependency, as defined in eryx.toml
		name: string,
		-- The specific dependency to collect
		dep: project.Dependency,
		-- List of requirements; effectively the "return" of this function
		requirements: { Requirement },
		-- List of currently visiting packages, for cycle detection
		visiting: Visiting,
		-- Are local-copy packages allowed at this point in the chain?
		allowLocal: boolean,

		-- For recursing into children
		recurse: CollectRecursion
	) -> (),

	read materialise: (root: string, requirement: Requirement, destination: string) -> (),

	read identity: (retirement: Requirement) -> string,

	read resolveInstallPlan: ((
		ctx: ResolveContext,
		parent: InstallNode?,
		requirement: Requirement,
		resolve: ResolveRecursion
	) -> InstallNode)?,

	read generateLock: (requirement: Requirement) -> { [string]: any },
}

return table.freeze({})
