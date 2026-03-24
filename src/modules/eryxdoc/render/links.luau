-- Link and anchor resolution for documentation cross-references.
-- Pure functions that resolve wiki-style links and type references to URLs.

local modules = require("../content/modules")
local warnings = require("../warnings")

-- Resolves a bare name to an HTML anchor within a module.
-- Returns the anchor string (with leading #), or nil if not found.
local function resolveInModule(mod: modules.ModuleInfo, name: string): string?
	for _, f in mod.functions do
		if f.name == name then
			local sep = if f.isMethod then ":" else "."
			return "#fn-" .. (f.owner or "") .. sep .. f.name
		end
	end
	if mod.primaryExport and mod.primaryExport.name == name then
		return "#class-" .. name
	end
	for _, c in mod.classes do
		if c.name == name then
			return "#class-" .. name
		end
	end
	for _, t in mod.types do
		if t.name == name then
			return "#type-" .. name
		end
	end
	for _, c in mod.constants do
		if c.name == name then
			return "#const-" .. (c.owner or "") .. "." .. name
		end
	end
	return nil
end

-- Resolves ClassName.memberName to an HTML anchor within a module.
-- Returns the anchor string (with leading #), or nil if the class isn't found.
local function resolveClassMember(mod: modules.ModuleInfo, className: string, memberName: string): string?
	local allClasses: { any } = {}
	if mod.primaryExport then
		table.insert(allClasses, mod.primaryExport)
	end
	for _, c in mod.classes do
		table.insert(allClasses, c)
	end
	for _, cls in allClasses do
		if cls.name == className then
			if cls.members then
				for _, m in cls.members do
					if m.name == memberName then
						return "#method-" .. className .. ":" .. memberName
					end
				end
			end
			-- Class found but member not found - link to the class itself
			return "#class-" .. className
		end
	end
	return nil
end

-- Resolves a wikilink target to a full URL.
-- Priority: explicit @-path → dotted class.member (local then cross-module) →
-- bare name (local → article → module last-segment).
local function resolveWikiLink(
	rawLink: string,
	currentModule: modules.ModuleInfo?,
	allModules: { [string]: modules.ModuleInfo },
	articles: { { name: string, article: any } },
	getLink: (any) -> string
): string
	-- Split trailing anchor: "Title#heading" → core="Title", trailingAnchor="#heading"
	local trailingAnchor = ""
	local core = rawLink
	local hashPos = rawLink:find("#", 1, true)
	if hashPos then
		core = rawLink:sub(1, hashPos - 1)
		trailingAnchor = rawLink:sub(hashPos)
	end

	-- Bare anchor: [[#heading]] links within the current page
	if core == "" and trailingAnchor ~= "" then
		return trailingAnchor
	end

	-- ── 1. Fully-qualified "@prefix/…" path ───────────────────────────────
	if core:sub(1, 1) == "@" then
		local lastSlash = core:find("/[^/]*$") or 0
		local dotPos = core:find(".", lastSlash + 1, true)
		if dotPos then
			local modPath = core:sub(1, dotPos - 1)
			local member = core:sub(dotPos + 1)
			local mod = allModules[modPath]
			if mod then
				local clsName, mbrName = member:match("^([^.]+)%.(.+)$")
				local anchor = if clsName and mbrName
					then resolveClassMember(mod, clsName :: string, mbrName :: string)
					else resolveInModule(mod, member)
				return getLink(mod) .. (anchor or "#" .. member) .. trailingAnchor
			end
		end
		local mod = allModules[core]
		if mod then
			return getLink(mod) .. trailingAnchor
		end
	end

	-- ── 2. Dotted: "ClassName.member" or "moduleSeg.member" ────────────────
	local dotPos = core:find(".", 1, true)
	if dotPos then
		local prefix = core:sub(1, dotPos - 1)
		local member = core:sub(dotPos + 1)

		if currentModule then
			local anchor = resolveClassMember(currentModule, prefix, member)
			if anchor then
				return getLink(currentModule) .. anchor .. trailingAnchor
			end
		end

		for _, mod in allModules do
			local lastSeg = mod.qualifiedName:match("/([^/]+)$") or mod.qualifiedName
			if lastSeg == prefix then
				local anchor = resolveInModule(mod, member)
				return getLink(mod) .. (anchor or "#" .. member) .. trailingAnchor
			end
		end
	end

	-- ── 3. Bare name ────────────────────────────────────────────────────────
	if currentModule then
		local anchor = resolveInModule(currentModule, core)
		if anchor then
			return getLink(currentModule) .. anchor .. trailingAnchor
		end
	end

	-- Article resolution: exact name/title, then partial path, then slug match.
	-- Slug: lowercase, spaces/underscores to hyphens, collapse runs.
	local coreSlug = core:lower():gsub("[%s_]+", "-")
	local coreLower = core:lower()

	-- Pass 1: exact match on name or title
	for _, articleInfo in articles do
		if articleInfo.name == core or articleInfo.article.title == core then
			return getLink(articleInfo.article) .. trailingAnchor
		end
	end

	-- Pass 2: case-insensitive title, last segment of name, or slug match
	for _, articleInfo in articles do
		local name = articleInfo.name
		local title = articleInfo.article.title or ""

		-- Case-insensitive title
		if title:lower() == coreLower then
			return getLink(articleInfo.article) .. trailingAnchor
		end

		-- Last segment of name (e.g. "getting-started" matches "guide/getting-started")
		local lastSeg = name:match("[^/]+$") or name
		if lastSeg == core or lastSeg == coreSlug then
			return getLink(articleInfo.article) .. trailingAnchor
		end

		-- Slug of title (e.g. "Getting Started" matches article titled "Getting Started"
		-- via slug "getting-started")
		local titleSlug = title:lower():gsub("[%s_]+", "-")
		if titleSlug == coreSlug then
			return getLink(articleInfo.article) .. trailingAnchor
		end
	end

	for _, mod in allModules do
		local lastSeg = mod.qualifiedName:match("/([^/]+)$") or mod.qualifiedName
		if lastSeg == core then
			return getLink(mod) .. trailingAnchor
		end
	end

	warnings.warn("Unresolved wikilink [[" .. rawLink .. "]]")
	return "#" .. core
end

-- Resolves a type name to a URL, checking the current module first then all modules.
-- Returns nil if the type is not found (e.g. primitives like string, number).
local function resolveTypeLink(
	typeName: string,
	currentModule: modules.ModuleInfo,
	allModules: { [string]: modules.ModuleInfo },
	getLink: (any) -> string
): string?
	local anchor = resolveInModule(currentModule, typeName)
	if anchor then
		return getLink(currentModule) .. anchor
	end

	for _, mod in allModules do
		if mod ~= currentModule then
			anchor = resolveInModule(mod, typeName)
			if anchor then
				return getLink(mod) .. anchor
			end
		end
	end

	return nil
end

return {
	resolveInModule = resolveInModule,
	resolveClassMember = resolveClassMember,
	resolveWikiLink = resolveWikiLink,
	resolveTypeLink = resolveTypeLink,
}
