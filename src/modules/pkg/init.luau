--[=[
	Project package management.

	The public API intentionally stays small. `pkg.plan()` performs a validated
	dry-run and returns the filesystem/config changes that would be made.
	`pkg.install()` runs that same plan and then materializes it.
]=]

local project = require("@eryx/project")

local config = require("@self/config")
local dependencies = require("@self/dependencies")
local installer = require("@self/install")
local lockfile = require("@self/lockfile")
local plan = require("@self/plan")
local util = require("@self/util")

local pkg = {}

export type InstallResult = {
	root: string,
	packages: { dependencies.ResolvedPackage },
	aliases: { lockfile.AliasRecord },
	lockPath: string,
}

export type InstallPlan = plan.InstallPlan

function pkg.plan(rootOrManifestPath: string?): InstallPlan
	local doc = if rootOrManifestPath then project.load(rootOrManifestPath) else project.loadNearest()
	if doc == nil then
		util.fail("No eryx.toml found")
		assert(false)
	end

	local root = util.projectRoot(doc.root)
	local packages = dependencies.resolveGraph(doc)
	return plan.build(root, packages)
end

function pkg.install(rootOrManifestPath: string?): InstallResult
	local installPlan = pkg.plan(rootOrManifestPath)

	installer.packages(installPlan.root, installPlan.packages)
	config.write(installPlan.config)
	lockfile.write(installPlan.root, installPlan.lockSource)

	return {
		root = installPlan.root,
		packages = installPlan.packages,
		aliases = installPlan.aliases,
		lockPath = installPlan.lockPath,
	}
end

return table.freeze(pkg)
