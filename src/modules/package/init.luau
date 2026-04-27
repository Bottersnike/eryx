local toml = require("@eryx/data/toml")
local fs = require("@eryx/fs")
local project = require("@eryx/project")

local planner = require("@self/planner")
local types = require("@self/types")
local dependency = require("@self/dependency")
local execution = require("@self/execution")

local pkg = {}

function pkg.computeInstallPlan(): types.InstallPlan?
	local prj = project.loadNearest()
	if not prj then
		print("No project")
		return nil
	end

	if not prj.manifest.dependencies then
		return nil
	end

	if not prj.root then
		print("Failed to identify project root")
		return nil
	end

	local requirements: { types.Requirement } = {}
	local visiting: types.Visiting = { order = {}, set = {} }

	dependency.collect(prj.root, prj.root, prj.manifest, requirements, visiting, true)

	local plan = planner.produceInstallPlan(requirements)
	return plan
end

function pkg.doInstall()
	local prj = project.loadNearest()
	if not prj then
		print("No project")
		return
	end

	if not prj.root then
		print("Failed to identify project root")
		return
	end

	local plan = pkg.computeInstallPlan()
	if not plan then
		return
	end

	execution.execute(prj.root, plan)

	local lock = planner.generateLockFile(plan)
	local f = fs.open(fs.path.join(prj.root, "eryx.lock"), "w")
	f:write(toml.encode(lock))
	f:close()
end

return table.freeze(pkg)
