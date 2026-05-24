local fs = require("@eryx/fs")
local logging = require("@eryx/logging")
local yaml = require("@eryx/data/yaml")

local modulesApi = require("@self/content/modules")
local Article = require("@self/content/article")
local buildWarnings = require("@self/warnings")

local log = logging.getLogger("eryxdoc.siteModel")

export type SectionLandingConfig = {
	title: string?,
	description: string?,
	generate: boolean?,
}

export type SectionConfig = {
	id: string,
	label: string,
	mount: string?,
	headerHref: string?,
	articles: string?,
	modules: string?,
	prefix: string?,
	landing: SectionLandingConfig?,
	children: { SectionConfig }?,
}

export type SiteSection = {
	id: string,
	label: string,
	mount: string?,
	headerHref: string?,
	articles: string?,
	modules: string?,
	prefix: string?,
	landing: SectionLandingConfig?,
	children: { SiteSection }?,
	parentId: string?,
	topLevelId: string,
	isLeaf: boolean,
}

export type SectionFolderMeta = {
	sectionTitles: { [string]: string },
	folderTitles: { [string]: string },
	folderOrder: { [string]: number },
}

export type ArticleEntry = {
	key: string,
	localName: string,
	routePath: string,
	article: Article.Article,
	sectionId: string,
}

export type CollectedSite = {
	sections: { SiteSection },
	leafSections: { SiteSection },
	sectionsById: { [string]: SiteSection },
	articles: { ArticleEntry },
	modules: { any },
	moduleSectionByName: { [string]: string },
	folderMetaBySectionId: { [string]: SectionFolderMeta },
	explicitSections: boolean,
}

type LegacyConfig = {
	title: string?,
	articles: string?,
	modules: string?,
	prefix: string?,
	noModules: boolean?,
	sections: { SectionConfig }?,
}

local function normalizeMount(mount: string?): string
	if not mount or mount == "" or mount == "/" then
		return "/"
	end

	local normalized = mount:gsub("\\", "/")
	normalized = normalized:gsub("^/+", ""):gsub("/+$", "")
	return "/" .. normalized
end

local function mountRouteBase(mount: string): string
	if mount == "/" then
		return ""
	end
	return mount:sub(2)
end

local function joinRoute(base: string, suffix: string): string
	if base == "" then
		return suffix
	end
	if suffix == "" then
		return base
	end
	return base .. "/" .. suffix
end

local function parseMeta(path: string): { children: { string }?, title: string? }
	if not fs.isFile(path) then
		return {}
	end
	local content = fs.openSync(path):readSync()
	local ok, data = pcall(yaml.decode, content)
	if not ok or type(data) ~= "table" then
		buildWarnings.warn("Failed to parse .meta at " .. path)
		return {}
	end
	local result: { children: { string }?, title: string? } = {}
	if type(data.children) == "table" then
		result.children = data.children
	end
	if type(data.title) == "string" then
		result.title = data.title
	end
	return result
end

local function collectFolderTitles(path: string): ({ [string]: string }, { [string]: string }, { [string]: number })
	local sectionTitles: { [string]: string } = {}
	local folderTitles: { [string]: string } = {}
	local folderOrder: { [string]: number } = {}

	local function walk(dir: string, prefix: string?, isTopLevel: boolean)
		if not fs.isDirectory(dir) then
			return
		end
		local currentMeta = parseMeta(dir .. "/.meta")
		if currentMeta.children then
			for i, child in currentMeta.children :: { string } do
				local key = if prefix then prefix .. "/" .. child else child
				folderOrder[key] = i
			end
		end
		for _, entry in fs.listDir(dir) do
			local fullPath = dir .. "/" .. entry
			if not fs.isDirectory(fullPath) then
				continue
			end
			local meta = parseMeta(fullPath .. "/.meta")
			local key = if prefix then prefix .. "/" .. entry else entry
			if meta.title then
				if isTopLevel then
					sectionTitles[entry] = meta.title
				end
				folderTitles[key] = meta.title
			end
			walk(fullPath, key, false)
		end
	end

	walk(path, nil, true)
	return sectionTitles, folderTitles, folderOrder
end

local function formatFolderTitle(prefix: string?, metaTitle: string?): string
	if metaTitle then
		return metaTitle
	end
	if not prefix then
		return "Home"
	end
	local stem = prefix:match("[^/]+$") or prefix
	return stem:gsub("%-", " "):gsub("(%a)([%w]*)", function(first: string, rest: string)
		return first:upper() .. rest
	end)
end

local function collectArticles(path: string, prefix: string?): { { name: string, article: Article.Article } }
	local articles = {}
	if not fs.isDirectory(path) then
		return {}
	end

	local meta = parseMeta(path .. "/.meta")
	local entries = fs.listDir(path)
	local hasIndexArticle = false
	local generatedSectionPages: { Article.GeneratedSectionPage } = {}

	if meta.children then
		local childOrder: { [string]: number } = {}
		for i, child in meta.children :: { string } do
			childOrder[child] = i
		end

		local function entryOrder(entry: string)
			local stem = entry:match("^(.+)%.[^.]+$") or entry
			local candidates = {
				stem,
				entry,
				entry .. "/index",
				entry .. "/index.md",
				entry .. "/index.mdx",
			}
			for _, candidate in candidates do
				if childOrder[candidate] then
					return childOrder[candidate]
				end
			end
			return 9999
		end

		table.sort(entries, function(a: string, b: string)
			local orderA = entryOrder(a)
			local orderB = entryOrder(b)
			if orderA ~= orderB then
				return orderA < orderB
			end
			return a < b
		end)
	else
		table.sort(entries)
	end

	for _, entry in entries do
		if entry == ".meta" then
			continue
		end
		local fullPath = path .. "/" .. entry
		if fs.isDirectory(fullPath) then
			local subPrefix = if prefix then prefix .. "/" .. entry else entry
			local sub = collectArticles(fullPath, subPrefix)
			for _, articleEntry in sub do
				table.insert(articles, articleEntry)
				if articleEntry.name == subPrefix then
					table.insert(generatedSectionPages, {
						title = articleEntry.article.title,
						article = articleEntry.article,
					})
				end
			end
			continue
		end
		if not entry:match("%.md$") and not entry:match("%.txt$") then
			continue
		end
		local stem = fs.path.stem(fullPath)
		local name: string
		if stem == "index" and prefix then
			name = prefix
		else
			name = if prefix then prefix .. "/" .. stem else stem
		end
		log:info(string.format("  article: %s", name))
		local article = Article.fromFile(fullPath)
		table.insert(articles, { name = name, article = article })
		if stem == "index" then
			hasIndexArticle = true
		else
			table.insert(generatedSectionPages, {
				title = article.title,
				article = article,
			})
		end
	end

	if not hasIndexArticle and #generatedSectionPages > 0 then
		local name = prefix or "index"
		log:info(string.format("  article: %s (generated)", name))
		table.insert(articles, 1, {
			name = name,
			article = Article.generated(
				formatFolderTitle(prefix, meta.title),
				path .. "/index.md",
				"",
				"Overview for this section.",
				generatedSectionPages
			),
		})
	end

	return articles
end

local function buildLegacyDefaultSection(cfg: LegacyConfig): ({ SiteSection }, boolean)
	local label = cfg.title or "Docs"
	if not cfg.articles and cfg.modules and not cfg.noModules then
		label = "API"
	end

	return {
		{
			id = "default",
			label = label,
			mount = "/",
			headerHref = nil,
			articles = cfg.articles,
			modules = if cfg.noModules then nil else cfg.modules,
			prefix = cfg.prefix or "@eryx",
			landing = nil,
			children = nil,
			parentId = nil,
			topLevelId = "default",
			isLeaf = true,
		},
	},
		false
end

local function normalizeSections(
	cfg: LegacyConfig
): ({ SiteSection }, { SiteSection }, { [string]: SiteSection }, boolean)
	local configuredSections = cfg.sections
	if not configuredSections or #configuredSections == 0 then
		local defaultSections, explicit = buildLegacyDefaultSection(cfg)
		local defaultSection = defaultSections[1]
		return defaultSections, { defaultSection }, { [defaultSection.id] = defaultSection }, explicit
	end

	local sectionsById: { [string]: SiteSection } = {}
	local leafSections: { SiteSection } = {}
	local seenLeafMounts: { [string]: boolean } = {}

	local function buildSection(
		config: SectionConfig,
		parentId: string?,
		topLevelId: string?,
		depth: number
	): SiteSection
		if sectionsById[config.id] then
			error("Duplicate section id: " .. config.id)
		end

		local hasChildren = config.children ~= nil and #config.children > 0
		local section: SiteSection = {
			id = config.id,
			label = config.label,
			mount = nil,
			headerHref = config.headerHref,
			articles = nil,
			modules = nil,
			prefix = nil,
			landing = config.landing,
			children = nil,
			parentId = parentId,
			topLevelId = topLevelId or config.id,
			isLeaf = not hasChildren,
		}
		sectionsById[section.id] = section

		if hasChildren then
			if depth >= 1 then
				error("Only one level of nested sections is supported in the first implementation.")
			end
			if config.mount or config.articles or config.modules or config.prefix then
				error("Parent sections cannot own content in the first implementation: " .. config.id)
			end

			section.children = {}
			for _, child in config.children :: { SectionConfig } do
				if child.children and #child.children > 0 then
					error("Only one level of nested sections is supported in the first implementation.")
				end
				table.insert(section.children, buildSection(child, section.id, section.topLevelId, depth + 1))
			end
			return section
		end

		if not config.mount then
			error("Leaf section requires a mount: " .. config.id)
		end
		if not config.articles and not config.modules then
			error("Leaf section must define articles and/or modules: " .. config.id)
		end

		section.mount = normalizeMount(config.mount)
		section.articles = config.articles
		section.modules = config.modules
		section.prefix = if config.modules then (config.prefix or "@eryx") else config.prefix

		if seenLeafMounts[section.mount] then
			error("Duplicate leaf section mount: " .. section.mount)
		end
		seenLeafMounts[section.mount] = true

		table.insert(leafSections, section)
		return section
	end

	local sections: { SiteSection } = {}
	for _, config in configuredSections do
		table.insert(sections, buildSection(config, nil, nil, 0))
	end

	return sections, leafSections, sectionsById, true
end

local function articleRoutePath(section: SiteSection, localName: string): string
	local routeBase = mountRouteBase(section.mount :: string)
	if localName == "index" then
		return routeBase
	end
	return joinRoute(routeBase, localName)
end

local function moduleRoutePath(section: SiteSection, qualifiedName: string): string
	return joinRoute(mountRouteBase(section.mount :: string), qualifiedName)
end

local function collectSiteContent(
	sections: { SiteSection },
	leafSections: { SiteSection },
	sectionsById: { [string]: SiteSection }
): CollectedSite
	local articles: { ArticleEntry } = {}
	local modules: { any } = {}
	local moduleSectionByName: { [string]: string } = {}
	local folderMetaBySectionId: { [string]: SectionFolderMeta } = {}
	local seenArticleRoutes: { [string]: boolean } = {}

	for _, section in leafSections do
		if section.articles then
			local sectionTitles, folderTitles, folderOrder =
				if fs.isDirectory(section.articles) then collectFolderTitles(section.articles) else {}, {}, {}
			folderMetaBySectionId[section.id] = {
				sectionTitles = sectionTitles,
				folderTitles = folderTitles,
				folderOrder = folderOrder,
			}

			for _, articleInfo in collectArticles(section.articles) do
				local routePath = articleRoutePath(section, articleInfo.name)
				if seenArticleRoutes[routePath] then
					error("Duplicate article route generated for section mounts: " .. routePath)
				end
				seenArticleRoutes[routePath] = true
				local articleObject = articleInfo.article :: any
				articleObject.sitePath = routePath
				articleObject.sourceRoot = section.articles
				table.insert(articles, {
					key = routePath,
					localName = articleInfo.name,
					routePath = routePath,
					article = articleInfo.article,
					sectionId = section.id,
				})
			end
		else
			folderMetaBySectionId[section.id] = {
				sectionTitles = {},
				folderTitles = {},
				folderOrder = {},
			}
		end

		if section.modules then
			for _, mod in modulesApi.collectModules(section.modules, section.prefix or "@eryx", "") do
				if moduleSectionByName[mod.qualifiedName] then
					error("Duplicate module qualified name across sections: " .. mod.qualifiedName)
				end
				moduleSectionByName[mod.qualifiedName] = section.id
				local moduleObject = mod :: any
				moduleObject.sitePath = moduleRoutePath(section, mod.qualifiedName)
				table.insert(modules, mod)
			end
		end
	end

	return {
		sections = sections,
		leafSections = leafSections,
		sectionsById = sectionsById,
		articles = articles,
		modules = modules,
		moduleSectionByName = moduleSectionByName,
		folderMetaBySectionId = folderMetaBySectionId,
		explicitSections = true,
	}
end

local siteModel = {}

function siteModel.normalizeMount(mount: string?): string
	return normalizeMount(mount)
end

function siteModel.getSectionRoutePath(section: SiteSection): string
	return mountRouteBase(section.mount :: string)
end

function siteModel.getArticleRoutePath(section: SiteSection, localName: string): string
	return articleRoutePath(section, localName)
end

function siteModel.getModuleRoutePath(section: SiteSection, qualifiedName: string): string
	return moduleRoutePath(section, qualifiedName)
end

function siteModel.collect(cfg: LegacyConfig): CollectedSite
	local sections, leafSections, sectionsById, explicitSections = normalizeSections(cfg)
	local collected = collectSiteContent(sections, leafSections, sectionsById)
	collected.explicitSections = explicitSections
	return collected
end

return siteModel
