local fs = require("@eryx/fs")
local template = require("@eryx/template")
local sidebar = require("./sidebar")
local markdown = require("@markdown")
local glob = require("@eryx/glob")

local wikilinkRuleBuilder = require("@markdown/extensions/wikilink")

local highlight = require("../parse/highlight")
local modules = require("../content/modules")
local Article = require("../content/article")
local links = require("./links")

type TOCItem = {
	label: string,
	link: string,
	indent: boolean?,
	level: number?,
}
type TOCGroup = {
	label: string,
	children: { TOCItem },
}
type TOC = { TOCItem } | { TOCGroup }

type NavigationLinkConfig = {
	label: string,
	href: string,
	matchPrefix: string?,
	exact: boolean?,
	header: boolean?,
	mobile: boolean?,
}

type SectionLandingConfig = {
	title: string?,
	description: string?,
	generate: boolean?,
}

type SectionConfig = {
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

type SiteSection = {
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

type SectionFolderMeta = {
	sectionTitles: { [string]: string },
	folderTitles: { [string]: string },
	folderOrder: { [string]: number },
}

type ArticleRecord = {
	key: string,
	localName: string,
	article: Article.Article,
	sectionId: string,
}

type NavigationHeaderConfig = {
	mode: "auto" | "tabs" | "none"?,
	mobile: {
		includeSectionLinks: boolean?,
	}?,
}

type NavigationConfig = {
	header: NavigationHeaderConfig?,
	splitApiReference: boolean?,
	headerLinks: { NavigationLinkConfig }?,
}

type HeaderNavLink = {
	label: string,
	href: string?,
	isActive: boolean,
	children: { HeaderNavLink }?,
}

local function htmlEscapeFilter(s: string): string
	if not s then
		return ""
	end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function renderHeadTags(tags: { HeadTag }?): string
	if not tags or #tags == 0 then
		return ""
	end

	local chunks: { string } = {}
	for _, tag in tags do
		if tag.tag ~= "link" and tag.tag ~= "meta" then
			continue
		end

		local attrs: { string } = {}
		for name, value in tag do
			if name == "tag" or value == nil then
				continue
			end
			if not name:match("^[%a_:][%w:_.-]*$") then
				continue
			end
			table.insert(attrs, `{name}="{htmlEscapeFilter(value)}"`)
		end
		if #attrs == 0 then
			continue
		end
		table.insert(chunks, `<{tag.tag} {table.concat(attrs, " ")} />`)
	end

	return table.concat(chunks, "\n")
end

local function functionAnchor(owner: string?, isMethod: boolean, name: string): string
	if owner and owner ~= "" then
		local sep = if isMethod then ":" else "."
		return "#fn-" .. owner .. sep .. name
	end
	return "#fn-" .. name
end

local function functionDisplayName(owner: string?, isMethod: boolean, name: string): string
	if owner and owner ~= "" then
		local sep = if isMethod then ":" else "."
		return owner .. sep .. name
	end
	return name
end

local function constantAnchor(owner: string?, name: string): string
	if owner and owner ~= "" then
		return "#const-" .. owner .. "." .. name
	end
	return "#const-" .. name
end

local function constantDisplayName(owner: string?, name: string): string
	if owner and owner ~= "" then
		return owner .. "." .. name
	end
	return name
end

local function typeDisplayText(typeDoc: any): string
	if not typeDoc then
		return ""
	end

	local generics = typeDoc.generics
	if generics and #generics > 0 then
		return typeDoc.name .. "<" .. table.concat(generics, ", ") .. ">"
	end
	return typeDoc.name
end

local function typeDisplayHtml(typeDoc: any): string
	if not typeDoc then
		return ""
	end

	local name = htmlEscapeFilter(typeDoc.name or "")
	local generics = typeDoc.generics
	if generics and #generics > 0 then
		local escapedGenerics: { string } = {}
		for _, generic in generics do
			table.insert(escapedGenerics, htmlEscapeFilter(generic))
		end
		return `<span class="type-display-name">{name}</span><span class="type-display-generics">&lt;{table.concat(
			escapedGenerics,
			", "
		)}&gt;</span>`
	end
	return `<span class="type-display-name">{name}</span>`
end

local function resolveModuleFunction(mod: modules.ModuleInfo, core: string): { signature: string?, doc: string? }?
	for _, f in mod.functions do
		if f.name == core then
			return {
				signature = f.signature,
				doc = f.doc,
			}
		end

		if f.owner then
			local fullName = f.owner .. (if f.isMethod then ":" else ".") .. f.name
			if fullName == core then
				return {
					signature = f.signature,
					doc = f.doc,
				}
			end
		end
	end

	return nil
end

local Renderer = {}
Renderer.__index = Renderer
type PageMeta = {
	description: string?,
	image: string?,
	imageAlt: string?,
	canonicalUrl: string?,
	type: string?,
	siteName: string?,
	locale: string?,
	[string]: string?,
}
type HeadTag = {
	tag: "link" | "meta",
	[string]: string,
}

type RendererFields = {
	siteTitle: string,
	siteRoot: string,
	exportMode: "flat" | "directory",
	modulePrefix: string?,
	sections: { SiteSection }?,
	leafSections: { SiteSection },
	sectionsById: { [string]: SiteSection },
	moduleSectionByName: { [string]: string }?,
	navigation: NavigationConfig?,
	modules: { [string]: modules.ModuleInfo },
	articles: { ArticleRecord },
	stylesPath: string,
	favicon: string?,
	head: { HeadTag }?,
	extraHead: string?,
	extraScripts: string?,
	announcement: string?,
	openGraph: PageMeta?,
	articleMetaGenerator: ((ctx: any) -> PageMeta)?,
	apiMetaGenerator: ((ctx: any) -> PageMeta)?,
	customFilters: { [string]: (any, { [string]: any }) -> any }?,
	customGlobals: { [string]: any }?,
	versionName: string?,
	versionLabel: string?,
	folderMetaBySectionId: { [string]: SectionFolderMeta }?,
	assetResolver: ((article: Article.Article, url: string) -> string)?,
	includeMobileSectionLinks: boolean,

	templates: {
		article: template.Template,
		api: template.Template,
		index: template.Template,
		notFound: template.Template?,
	},

	markdown: markdown.Markdown,
	hoverMarkdown: markdown.Markdown,
	currentMod: modules.ModuleInfo?,
	currentArticle: Article.Article?,
}
export type Renderer = setmetatable<RendererFields, typeof(Renderer)>

function Renderer.new(
	siteTitle: string,
	stylesPath: string,
	templates: {
		article: string,
		api: string,
		index: string,
		notFound: string?,
	},
	options: {
		siteRoot: string?,
		exportMode: ("flat" | "directory")?,
		modulePrefix: string?,
		sections: { SiteSection }?,
		moduleSectionByName: { [string]: string }?,
		navigation: NavigationConfig?,
		favicon: string?,
		head: { HeadTag }?,
		extraHead: string?,
		extraScripts: string?,
		announcement: string?,
		openGraph: PageMeta?,
		articleMetaGenerator: ((ctx: any) -> PageMeta)?,
		apiMetaGenerator: ((ctx: any) -> PageMeta)?,
		customFilters: { [string]: (any, { [string]: any }) -> any }?,
		customGlobals: { [string]: any }?,
		versionName: string?,
		versionLabel: string?,
		folderMetaBySectionId: { [string]: SectionFolderMeta }?,
		assetResolver: ((article: Article.Article, url: string) -> string)?,
		templateReader: ((path: string) -> string)?,
	}?
): Renderer
	local siteRoot = (if options then options.siteRoot else nil) or "/"
	if siteRoot:sub(-1) ~= "/" then
		siteRoot = siteRoot .. "/"
	end
	local exportMode: "flat" | "directory" = (if options then options.exportMode else nil) or "flat"
	local readTemplate = (if options then options.templateReader else nil)
		or function(path: string): string
			return fs.openSync(path):readSync()
		end

	local this = {
		siteTitle = siteTitle,
		siteRoot = siteRoot,
		exportMode = exportMode,
		modulePrefix = if options then options.modulePrefix else nil,
		sections = if options then options.sections else nil,
		leafSections = {},
		sectionsById = {},
		moduleSectionByName = if options then options.moduleSectionByName else nil,
		navigation = if options then options.navigation else nil,
		modules = {},
		articles = {},

		stylesPath = stylesPath,
		favicon = if options then options.favicon else nil,
		head = if options then options.head else nil,
		extraHead = if options then options.extraHead else nil,
		extraScripts = if options then options.extraScripts else nil,
		announcement = if options then options.announcement else nil,
		openGraph = if options then options.openGraph else nil,
		articleMetaGenerator = if options then options.articleMetaGenerator else nil,
		apiMetaGenerator = if options then options.apiMetaGenerator else nil,
		customFilters = if options then options.customFilters else nil,
		customGlobals = if options then options.customGlobals else nil,
		versionName = if options then options.versionName else nil,
		versionLabel = if options then options.versionLabel else nil,
		folderMetaBySectionId = if options then options.folderMetaBySectionId else nil,
		assetResolver = if options then options.assetResolver else nil,
		includeMobileSectionLinks = true,
		templates = {
			article = template.compile(readTemplate(templates.article), templates.article),
			api = template.compile(readTemplate(templates.api), templates.api),
			index = template.compile(readTemplate(templates.index), templates.index),
			notFound = if templates.notFound
					and (if options and options.templateReader then true else fs.isFile(templates.notFound))
				then template.compile(readTemplate(templates.notFound), templates.notFound)
				else nil,
		},

		currentMod = nil,
		currentArticle = nil,
	}
	setmetatable(this, Renderer)
	if this.sections then
		local function registerSection(section: SiteSection)
			this.sectionsById[section.id] = section
			if section.isLeaf then
				table.insert(this.leafSections, section)
			end
			if section.children then
				for _, child in section.children do
					registerSection(child)
				end
			end
		end
		for _, section in this.sections do
			registerSection(section)
		end
	end
	local function transformURL(url: string): string
		if this.currentArticle and this.assetResolver then
			return this.assetResolver(this.currentArticle, url)
		end
		return url
	end
	this.markdown = markdown.Markdown.new({
		extraInlineExtensions = {
			wikilinkRuleBuilder(function(link: string): any
				return this:_resolveWikiLinkInfo(link, this.currentMod)
			end),
		},
		codeLanguages = highlight,
		useCrlf = false,
		annotateHtml = true,
		transformURL = transformURL,
	})
	this.hoverMarkdown = markdown.Markdown.new({
		extraInlineExtensions = {
			wikilinkRuleBuilder(function(link: string): string
				return this:_resolveWikiLink(link, this.currentMod)
			end),
		},
		codeLanguages = highlight,
		useCrlf = false,
		annotateHtml = true,
	})

	return this
end

function Renderer._resolveWikiLink(self: Renderer, rawLink: string, currentModule: modules.ModuleInfo?): string
	return links.resolveWikiLink(rawLink, currentModule, self.modules, self.articles, function(item: any): string
		return self:getLink(item)
	end)
end

function Renderer._truncateDocForHover(self: Renderer, doc: string?): string?
	if not doc or doc == "" then
		return nil
	end

	local maxLines = 30
	local maxChars = 900
	local totalChars = 0
	local fenceDepth = 0
	local truncated = false
	local kept: { string } = {}

	for i, line in string.split(doc, "\n") do
		if i > maxLines or totalChars + #line > maxChars then
			truncated = true
			break
		end
		table.insert(kept, line)
		totalChars += #line + 1

		if line:match("^%s*```") then
			if fenceDepth == 0 then
				fenceDepth = 1
			else
				fenceDepth = 0
			end
		end
	end

	if truncated and fenceDepth ~= 0 then
		table.insert(kept, "```")
	end
	if truncated then
		table.insert(kept, "")
		table.insert(kept, "...")
	end

	return table.concat(kept, "\n")
end

function Renderer._renderTypeHoverHtml(self: Renderer, signatureText: string?): string?
	if not signatureText or signatureText == "" then
		return nil
	end
	return `<pre class="type-hover-card__code">{highlight.LUAU_SIGNATURE(signatureText)}</pre>`
end

function Renderer._renderSymbolHoverHtml(
	self: Renderer,
	currentMod: modules.ModuleInfo?,
	signatureText: string?,
	docText: string?
): string?
	if docText and docText ~= "" then
		self.currentMod = currentMod
		local docHtml = self.hoverMarkdown:renderHtml(self.hoverMarkdown:parse(docText))
		local signatureHtml = if signatureText and signatureText ~= ""
			then `<div class="type-hover-card__signature-inline">{highlight.LUAU_SIGNATURE(signatureText)}</div>`
			else ""
		return `<div class="type-hover-card__doc">{docHtml}{signatureHtml}</div>`
	end
	if signatureText and signatureText ~= "" then
		return `<pre class="type-hover-card__code">{highlight.LUAU_SIGNATURE(signatureText)}</pre>`
	end
	return nil
end

function Renderer._findHoverSymbol(
	self: Renderer,
	currentMod: modules.ModuleInfo?,
	core: string
): { signature: string?, doc: string? }?
	if not currentMod then
		return nil
	end

	local exactFunction = resolveModuleFunction(currentMod, core)
	if exactFunction then
		return {
			signature = exactFunction.signature,
			doc = self:_truncateDocForHover(exactFunction.doc),
		}
	end

	local cls, mem = core:match("^([^.]+)%.(.+)$")
	if cls and mem then
		local allClasses: { any } = {}
		if currentMod.primaryExport then
			table.insert(allClasses, currentMod.primaryExport)
		end
		for _, c in currentMod.classes do
			table.insert(allClasses, c)
		end
		for _, t in currentMod.types do
			table.insert(allClasses, t)
		end
		for _, owner in allClasses do
			if owner.name == cls and owner.members then
				for _, member in owner.members do
					if member.name == mem then
						return {
							signature = member.signature,
							doc = self:_truncateDocForHover(member.doc),
						}
					end
				end
			end
		end
	end

	local allTypes: { any } = {}
	if currentMod.primaryExport then
		table.insert(allTypes, currentMod.primaryExport)
	end
	for _, c in currentMod.classes do
		table.insert(allTypes, c)
	end
	for _, t in currentMod.types do
		table.insert(allTypes, t)
	end
	for _, t in allTypes do
		if t.name == core then
			return {
				signature = t.signatureFull or t.name,
				doc = self:_truncateDocForHover(t.doc),
			}
		end
	end

	return nil
end

function Renderer._resolveWikiLinkInfo(self: Renderer, rawLink: string, currentModule: modules.ModuleInfo?): any
	local info = links.resolveWikiLinkInfo(
		rawLink,
		currentModule,
		self.modules,
		self.articles,
		function(item: any): string
			return self:getLink(item)
		end
	)

	if info.kind == "article" and info.article then
		local article = info.article
		local excerpt = self:_truncateDocForHover(article.summary or article.body)
		info.hoverHtml = self:_renderSymbolHoverHtml(nil, nil, excerpt)
	elseif info.kind == "module" and info.module then
		local mod = info.module
		info.hoverHtml = self:_renderSymbolHoverHtml(mod, nil, self:_truncateDocForHover(mod.description))
	elseif info.kind == "function" and info.module and info.symbolName then
		local symbol = self:_findHoverSymbol(info.module, info.symbolName)
		if symbol then
			info.hoverHtml = self:_renderSymbolHoverHtml(info.module, symbol.signature, symbol.doc)
		end
	elseif info.kind == "member" and info.module and info.ownerName and info.symbolName then
		local symbol = self:_findHoverSymbol(info.module, info.ownerName .. "." .. info.symbolName)
		if symbol then
			info.hoverHtml = self:_renderSymbolHoverHtml(info.module, symbol.signature, symbol.doc)
		end
	elseif (info.kind == "class" or info.kind == "type") and info.module and info.symbolName then
		local symbol = self:_findHoverSymbol(info.module, info.symbolName)
		if symbol then
			info.hoverHtml = self:_renderSymbolHoverHtml(info.module, symbol.signature, symbol.doc)
		end
	end

	return info
end

function Renderer._resolveTypeLink(self: Renderer, typeName: string, currentModule: modules.ModuleInfo): string?
	return links.resolveTypeLink(typeName, currentModule, self.modules, function(item: any): string
		return self:getLink(item)
	end)
end

function Renderer._GetPath(self: Renderer, item: modules.ModuleInfo | Article.Article | string): string
	if typeof(item) == "string" then
		return item
	end

	-- Sidebar module
	if (item :: any).displayName then
		return ((item :: any).sitePath or (item :: any).name) :: string
	end

	-- ModuleInfo
	if (item :: any).functions then
		return ((item :: any).sitePath or (item :: any).qualifiedName) :: string
	end

	-- Article — use sitePath (set during registration) which preserves directory nesting
	local article = item :: Article.Article
	if article.sitePath then
		return article.sitePath
	end
	return ((article.title :: string):lower():gsub(" ", "_"))
end

function Renderer.getPath(self: Renderer, item: (modules.ModuleInfo | Article.Article | string)?): string
	if item == nil then
		return "index.html"
	end

	local path = self:_GetPath(item)
	if path == "" then
		return "index.html"
	end

	if self.exportMode == "directory" then
		return path .. "/index.html"
	else
		return (path:gsub("/", "_"):gsub("\\", "_") .. ".html")
	end
end

function Renderer.getLink(self: Renderer, item: (modules.ModuleInfo | Article.Article | string)?): string
	if item == nil then
		return self.siteRoot
	end

	local path = self:_GetPath(item)
	if path == "" then
		return self.siteRoot
	end

	if self.exportMode == "directory" then
		return self.siteRoot .. path
	else
		return self.siteRoot .. (path:gsub("/", "_"):gsub("\\", "_") .. ".html")
	end
end

function Renderer.getPathForRoute(self: Renderer, routePath: string): string
	return self:getPath(routePath)
end

function Renderer.registerArticle(
	self: Renderer,
	article: Article.Article,
	key: string,
	localName: string,
	sectionId: string
): ()
	article.sitePath = key
	table.insert(self.articles, {
		key = key,
		localName = localName,
		article = article,
		sectionId = sectionId,
	})
end

function Renderer.registerModule(self: Renderer, module: modules.ModuleInfo, sectionId: string?)
	self.modules[module.qualifiedName] = module
	if sectionId then
		if not self.moduleSectionByName then
			self.moduleSectionByName = {}
		end
		self.moduleSectionByName[module.qualifiedName] = sectionId
	end
end

local function normaliseNavPath(path: string): string
	if path ~= "/" and path:sub(-1) == "/" then
		return path:sub(1, -2)
	end
	return path
end

local function resolveConfiguredHref(siteRoot: string, href: string): string
	if href == "" then
		return href
	end
	if href:match("^[%a][%w+.-]*:") or href:sub(1, 1) == "#" then
		return href
	end
	if href:sub(1, 1) == "/" then
		return href
	end
	return siteRoot .. href:gsub("^/+", "")
end

local function pathMatches(currentPath: string, targetPath: string, exact: boolean?): boolean
	local current = normaliseNavPath(currentPath)
	local target = normaliseNavPath(targetPath)

	if exact then
		return current == target
	end
	if target == "/" then
		return current:sub(1, 1) == "/"
	end

	return current == target or current:sub(1, #target + 1) == target .. "/"
end

local function hasSectionModel(self: Renderer): boolean
	return self.sections ~= nil and #self.sections > 0
end

local function getSectionMountHref(self: Renderer, section: SiteSection): string?
	if not section.mount then
		return nil
	end
	if section.mount == "/" then
		return self.siteRoot
	end
	return self.siteRoot .. section.mount:sub(2)
end

local function getSectionHref(self: Renderer, section: SiteSection): string?
	if section.headerHref then
		return resolveConfiguredHref(self.siteRoot, section.headerHref)
	end
	return getSectionMountHref(self, section)
end

local function getArticleRecord(self: Renderer, key: string): ArticleRecord?
	for _, articleInfo in self.articles do
		if articleInfo.key == key then
			return articleInfo
		end
	end
	return nil
end

local function findBestSectionForPath(self: Renderer, currentPath: string): SiteSection?
	local best: SiteSection? = nil
	local bestScore = -1

	for _, section in self.leafSections do
		local href = getSectionMountHref(self, section)
		if href and pathMatches(currentPath, href, false) then
			local score = #(section.mount or "")
			if score > bestScore then
				best = section
				bestScore = score
			end
		end
	end

	return best
end

local function getCurrentSection(self: Renderer, pageContext: { [string]: any }?): SiteSection?
	if not hasSectionModel(self) then
		return nil
	end

	if pageContext and pageContext.sectionId and self.sectionsById[pageContext.sectionId] then
		return self.sectionsById[pageContext.sectionId]
	end

	local currentPath = if pageContext and pageContext.path then pageContext.path else self.siteRoot
	return findBestSectionForPath(self, currentPath)
end

local function buildLegacyHeaderNavigation(self: Renderer, currentPath: string): ({ HeaderNavLink }, { HeaderNavLink })
	local configured = if self.navigation then self.navigation.headerLinks else nil
	if not configured or #configured == 0 then
		return {}, {}
	end

	local built: { { label: string, href: string, isActive: boolean, header: boolean, mobile: boolean } } = {}
	local bestMatchIndex: number? = nil
	local bestMatchLength = -1

	for _, entry in configured do
		local resolvedHref = resolveConfiguredHref(self.siteRoot, entry.href)
		table.insert(built, {
			label = entry.label,
			href = resolvedHref,
			isActive = false,
			header = entry.header ~= false,
			mobile = entry.mobile ~= false,
		})

		local matchTarget = resolveConfiguredHref(self.siteRoot, entry.matchPrefix or entry.href)
		if matchTarget:sub(1, 1) == "/" and pathMatches(currentPath, matchTarget, entry.exact) then
			local score = #normaliseNavPath(matchTarget)
			if entry.exact then
				score += 10000
			end
			if score > bestMatchLength then
				bestMatchLength = score
				bestMatchIndex = #built
			end
		end
	end

	if bestMatchIndex then
		built[bestMatchIndex].isActive = true
	end

	local headerLinks: { HeaderNavLink } = {}
	local mobileLinks: { HeaderNavLink } = {}
	for _, link in built do
		local out: HeaderNavLink = {
			label = link.label,
			href = link.href,
			isActive = link.isActive,
			children = nil,
		}
		if link.header then
			table.insert(headerLinks, out)
		end
		if link.mobile then
			table.insert(mobileLinks, out)
		end
	end

	return headerLinks, mobileLinks
end

local function buildSectionHeaderNavigation(
	self: Renderer,
	pageContext: { [string]: any }?
): ({ HeaderNavLink }, { HeaderNavLink })
	local currentPath = if pageContext and pageContext.path then pageContext.path else self.siteRoot
	local isSiteLanding = normaliseNavPath(currentPath) == normaliseNavPath(self.siteRoot)
	local currentSection = getCurrentSection(self, pageContext)
	local currentTopLevelId = if currentSection and not isSiteLanding then currentSection.topLevelId else nil

	local headerMode = if self.navigation
			and self.navigation.header
			and self.navigation.header.mode
		then self.navigation.header.mode
		else "auto"
	local visibleHeaderCount = if self.sections then #self.sections else 0
	local hasHeaderChildren = false
	if self.sections then
		for _, section in self.sections do
			if section.children and #section.children > 0 then
				hasHeaderChildren = true
				break
			end
		end
	end
	local showPrimaryNav = false
	if headerMode == "tabs" then
		showPrimaryNav = visibleHeaderCount > 0
	elseif headerMode == "auto" then
		showPrimaryNav = visibleHeaderCount > 1 or hasHeaderChildren
	end
	local includeMobileSectionLinks = if self.navigation
			and self.navigation.header
			and self.navigation.header.mobile
		then self.navigation.header.mobile.includeSectionLinks ~= false
		else true

	local headerLinks: { HeaderNavLink } = {}
	local mobileLinks: { HeaderNavLink } = {}

	for _, section in self.sections :: { SiteSection } do
		local childHeaderLinks: { HeaderNavLink } = {}
		local childMobileLinks: { HeaderNavLink } = {}
		local childActive = false
		if section.children then
			for _, child in section.children do
				local childHref = getSectionHref(self, child)
				local childMountHref = getSectionMountHref(self, child)
				local isChildActive = currentSection ~= nil and currentSection.id == child.id
				if not isChildActive and childMountHref and not isSiteLanding then
					isChildActive = pathMatches(currentPath, childMountHref, false)
				end
				if isChildActive then
					childActive = true
				end

				local childLink: HeaderNavLink = {
					label = child.label,
					href = childHref,
					isActive = isChildActive,
					children = nil,
				}
				table.insert(childHeaderLinks, childLink)
				table.insert(childMobileLinks, childLink)
			end
		end

		local isActive = (currentTopLevelId ~= nil and currentTopLevelId == section.id) or childActive
		local href = getSectionHref(self, section)
		local mountHref = getSectionMountHref(self, section)
		if not isActive and mountHref and not isSiteLanding and section.mount ~= "/" then
			isActive = pathMatches(currentPath, mountHref, false)
		end

		local item: HeaderNavLink = {
			label = section.label,
			href = href,
			isActive = isActive,
			children = if #childHeaderLinks > 0 then childHeaderLinks else nil,
		}
		if showPrimaryNav then
			table.insert(headerLinks, item)
		end

		if includeMobileSectionLinks then
			table.insert(mobileLinks, {
				label = section.label,
				href = href,
				isActive = isActive,
				children = if #childMobileLinks > 0 then childMobileLinks else nil,
			})
		end
	end

	return headerLinks, mobileLinks
end

local function buildHeaderNavigation(
	self: Renderer,
	pageContext: { [string]: any }?
): ({ HeaderNavLink }, { HeaderNavLink })
	local currentPath = if pageContext and pageContext.path then pageContext.path else self.siteRoot

	if hasSectionModel(self) then
		return buildSectionHeaderNavigation(self, pageContext)
	end
	if self.navigation and self.navigation.headerLinks and #self.navigation.headerLinks > 0 then
		return buildLegacyHeaderNavigation(self, currentPath)
	end

	return {}, {}
end

local function filterArticlesForSection(self: Renderer, section: SiteSection?): { ArticleRecord }
	if not hasSectionModel(self) or section == nil then
		return self.articles
	end

	local filtered: { ArticleRecord } = {}
	for _, articleInfo in self.articles do
		if articleInfo.sectionId == section.id then
			table.insert(filtered, articleInfo)
		end
	end
	return filtered
end

local function filterModulesForSection(self: Renderer, section: SiteSection?): { [string]: modules.ModuleInfo }
	if not hasSectionModel(self) or section == nil or not self.moduleSectionByName then
		return self.modules
	end

	local filtered: { [string]: modules.ModuleInfo } = {}
	for _, mod in self.modules do
		if self.moduleSectionByName[mod.qualifiedName] == section.id then
			filtered[mod.qualifiedName] = mod
		end
	end
	return filtered
end

local function getArticleSection(self: Renderer, articleKey: string): SiteSection?
	local articleInfo = getArticleRecord(self, articleKey)
	if not articleInfo then
		return nil
	end
	return self.sectionsById[articleInfo.sectionId]
end

local function getModuleSection(self: Renderer, moduleName: string): SiteSection?
	if not self.moduleSectionByName then
		return nil
	end
	local sectionId = self.moduleSectionByName[moduleName]
	if not sectionId then
		return nil
	end
	return self.sectionsById[sectionId]
end

local function getSectionLandingRoutePath(section: SiteSection): string
	if not section.mount or section.mount == "/" then
		return ""
	end
	return section.mount:sub(2)
end

local function sectionHasLandingArticle(self: Renderer, section: SiteSection): boolean
	for _, articleInfo in self.articles do
		if articleInfo.sectionId == section.id and articleInfo.localName == "index" then
			return true
		end
	end
	return false
end

local function sectionHasModules(self: Renderer, section: SiteSection): boolean
	if not self.moduleSectionByName then
		return false
	end
	for _, sectionId in self.moduleSectionByName do
		if sectionId == section.id then
			return true
		end
	end
	return false
end

local function shouldRenderSectionLanding(self: Renderer, section: SiteSection): boolean
	if not section.isLeaf or not section.mount then
		return false
	end
	if sectionHasLandingArticle(self, section) then
		return false
	end
	if not sectionHasModules(self, section) then
		return false
	end
	if section.landing and section.landing.generate == false then
		return false
	end
	return true
end

function Renderer.shouldRenderApiIndex(self: Renderer): boolean
	return self.navigation ~= nil and self.navigation.splitApiReference == true and next(self.modules) ~= nil
end

function Renderer.getGeneratedSectionLandingPages(self: Renderer): { { sectionId: string, routePath: string } }
	local pages = {}
	if not hasSectionModel(self) then
		return pages
	end

	for _, section in self.leafSections do
		if shouldRenderSectionLanding(self, section) then
			table.insert(pages, {
				sectionId = section.id,
				routePath = getSectionLandingRoutePath(section),
			})
		end
	end
	return pages
end

function Renderer.renderPage(
	self: Renderer,
	tmpl: template.Template,
	toc: TOC,
	params: {
		[string]: any,
	},
	pageName: string?,
	pageDisplayName: string?
): string
	local pageContext = params._pageContext
	local currentSection = getCurrentSection(self, pageContext)
	local filteredArticles = filterArticlesForSection(self, currentSection)
	local filteredModules = filterModulesForSection(self, currentSection)
	local folderMeta = if currentSection and self.folderMetaBySectionId
		then self.folderMetaBySectionId[currentSection.id]
		else nil
	-- The site root section is mounted at "/"; its index.md is the homepage and
	-- should stay out of the sidebar. Nested sections surface their index as a
	-- landing link.
	local isRootSection = currentSection == nil or currentSection.mount == nil or currentSection.mount == "/"
	local articleSections = sidebar.buildSidebarArticleSections(
		filteredArticles,
		pageName,
		function(article: Article.Article): string
			return self:getLink(article)
		end,
		if folderMeta then folderMeta.sectionTitles else nil,
		if folderMeta then folderMeta.folderTitles else nil,
		if folderMeta then folderMeta.folderOrder else nil,
		not isRootSection
	)
	local primaryLinks, drawerLinks = buildHeaderNavigation(self, pageContext)
	local isHomePage = pageContext == nil
		or pageContext.kind == "index"
		or pageContext.name == "index"
		or pageContext.path == self.siteRoot
	local pageKind = if pageContext and pageContext.kind then pageContext.kind else "index"
	local splitApiReference = not hasSectionModel(self) and self:shouldRenderApiIndex()
	local moduleTitle = "API Reference"
	local sidebarModulePrefix = self.modulePrefix
	if currentSection and currentSection.modules ~= nil then
		moduleTitle = if currentSection.landing and currentSection.landing.title
			then currentSection.landing.title
			else currentSection.label
		sidebarModulePrefix = currentSection.prefix or sidebarModulePrefix
	end

	local displayName = pageDisplayName or pageName

	-- Build pageMeta by merging: generator output > page-specific _meta > global openGraph
	local pageMeta: { [string]: any } = {}
	-- Layer 1: global openGraph defaults
	if self.openGraph then
		for k, v in self.openGraph :: any do
			pageMeta[k] = v
		end
	end
	-- Always include siteName from global config
	if not pageMeta.siteName then
		pageMeta.siteName = self.siteTitle
	end
	-- Layer 2: page-specific _meta from the render call
	if params._meta then
		for k, v in params._meta do
			if v ~= nil then
				pageMeta[k] = v
			end
		end
	end
	-- Layer 3: metaGenerator callback (highest priority)
	local generator = params._metaGenerator
	if generator and type(generator) == "function" then
		local pageCtx = params._pageContext or {}
		local ok, generated = pcall(generator, pageCtx)
		if ok and type(generated) == "table" then
			for k, v in generated :: any do
				if v ~= nil then
					pageMeta[k] = v
				end
			end
		end
	end

	local context = {
		pageTitle = if displayName then `{displayName} — {self.siteTitle}` else self.siteTitle,
		pageMeta = pageMeta,
		global = {
			title = self.siteTitle,
			modules = filteredModules,
			articles = filteredArticles,
			stylePath = self.stylesPath,
			pageName = displayName,
			siteRoot = self.siteRoot,
			favicon = self.favicon,
			headTags = renderHeadTags(self.head),
			extraHead = self.extraHead,
			extraScripts = self.extraScripts,
			announcement = self.announcement,
			versionName = self.versionName,
			versionLabel = self.versionLabel or self.versionName,
			headerPrimaryLinks = primaryLinks,
			headerDrawerLinks = drawerLinks,
			hasDesktopSidebar = not isHomePage,
			pageKind = pageKind,
			splitApiReference = splitApiReference,
			currentSection = currentSection,
		},
		sidebar = {
			articleTopLevel = articleSections.topLevel,
			articleSections = articleSections.sections,
			modules = sidebar.buildSidebarModuleTree(filteredModules, pageName, sidebarModulePrefix),
			moduleTitle = moduleTitle,
			page = toc,
		},
	}

	for k, v in params do
		context[k] = v
	end

	-- Merge custom globals into the global namespace
	if self.customGlobals then
		for k, v in self.customGlobals do
			(context :: any).global[k] = v
		end
	end

	local NO_MODULE = {}
	local signatureHtmlCache: { [any]: { [any]: string } } = {}
	local signatureHtmlLinksCache: { [any]: { [any]: string } } = {}
	local resolveLocalCache: { [any]: { [string]: string? } } = {}
	local symbolHoverAttrCache: { [any]: { [string]: string } } = {}
	local typeLinkCache: { [any]: { [string]: string? } } = {}
	local typeHoverAttrCache: { [string]: string } = {}
	local markdownCache: { [any]: { [string]: string } } = {}
	local highlightSigCache: { [string]: string } = {}

	local function getModuleCache<T>(bucket: { [any]: T }, currentMod: modules.ModuleInfo?): T
		local key = currentMod or NO_MODULE
		local cache = bucket[key]
		if cache == nil then
			cache = {} :: any
			bucket[key] = cache
		end
		return cache
	end

	local function signatureHtml(parts: any, ctx: { [string]: any }, doLinks: true?): string
		if not parts then
			return ""
		end
		local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
		local pageSignatureCache =
			getModuleCache(if doLinks then signatureHtmlLinksCache else signatureHtmlCache, currentMod)
		local cachedSignature = pageSignatureCache[parts]
		if cachedSignature then
			return cachedSignature
		end
		local kindToClass = {
			type = "syn-type",
			param = "syn-param",
			punct = "syn-punct",
			keyword = "syn-kw",
			name = "syn-fn",
			string = "syn-str",
			number = "syn-num",
		}
		local out: { string } = {}
		local function hoverAttr(part: any): string
			if not part or not part.hoverText or part.hoverText == "" then
				return ""
			end
			local cached = typeHoverAttrCache[part.hoverText]
			if cached ~= nil then
				return cached
			end
			local hoverHtml = self:_renderTypeHoverHtml(part.hoverText)
			if not hoverHtml then
				typeHoverAttrCache[part.hoverText] = ""
				return ""
			end
			local attr = ` data-hover-html="{htmlEscapeFilter(hoverHtml)}"`
			typeHoverAttrCache[part.hoverText] = attr
			return attr
		end
		local function symbolHoverAttr(core: string): string
			local cache = getModuleCache(symbolHoverAttrCache, currentMod)
			local cached = cache[core]
			if cached ~= nil then
				return cached
			end
			local symbol = self:_findHoverSymbol(currentMod, core)
			if not symbol then
				cache[core] = ""
				return ""
			end
			local hoverHtml = self:_renderSymbolHoverHtml(currentMod, symbol.signature, symbol.doc)
			if not hoverHtml then
				cache[core] = ""
				return ""
			end
			local attr = ` data-hover-html="{htmlEscapeFilter(hoverHtml)}"`
			cache[core] = attr
			return attr
		end
		local function resolveLocal(core: string): string?
			if not currentMod then
				return nil
			end
			local cache = getModuleCache(resolveLocalCache, currentMod)
			if cache[core] ~= nil then
				return cache[core]
			end
			local anchor = links.resolveInModule(currentMod, core)
			if not anchor then
				local cls, mem = core:match("^([^.]+)%.(.+)$")
				if cls and mem then
					anchor = links.resolveClassMember(currentMod, cls, mem)
				end
			end
			if anchor then
				local link = self:getLink(currentMod) .. anchor
				cache[core] = link
				return link
			end
			cache[core] = nil
			return nil
		end
		local i = 1
		while i <= #parts do
			local part = parts[i]
			local handled = false
			if i == 1 and doLinks then
				local p2 = parts[2]
				local p3 = parts[3]
				if
					p2
					and p3
					and part.kind == "name"
					and p2.kind == "punct"
					and (p2.text == "." or p2.text == ":")
					and p3.kind == "name"
				then
					local nameText = htmlEscapeFilter((part.text or "") .. (p2.text or "") .. (p3.text or ""))
					local left = part.text or ""
					local right = p3.text or ""
					local core = left .. "." .. right
					local link = resolveLocal(core)
					if not link and currentMod then
						local lastSeg = currentMod.qualifiedName:match("/([^/]+)$") or currentMod.qualifiedName
						if left == lastSeg or left == currentMod.name then
							link = resolveLocal(right)
							core = right
						end
					end
					if link then
						table.insert(
							out,
							`<a class="sig-link syn-fn" href="{link}"{symbolHoverAttr(core)}>{nameText}</a>`
						)
					else
						table.insert(out, `<span class="syn-fn">{nameText}</span>`)
					end
					i = i + 3
					handled = true
				end
				if not handled and p2 and part.kind == "name" and p2.kind == "punct" and p2.text == "(" then
					local nameText = htmlEscapeFilter(part.text or "")
					local core = part.text or ""
					local link = resolveLocal(core)
					if link then
						table.insert(
							out,
							`<a class="sig-link syn-fn" href="{link}"{symbolHoverAttr(core)}>{nameText}</a>`
						)
					else
						table.insert(out, `<span class="syn-fn">{nameText}</span>`)
					end
					i = i + 1
					handled = true
				end
			end

			if not handled then
				local text = htmlEscapeFilter(part.text or "")
				local kind: string? = part.kind
				if not kind or kind == "plain" then
					if text:sub(1, 6) == "&quot;" and text:sub(-6) == "&quot;" then
						kind = "string"
					elseif tonumber(text) ~= nil then
						kind = "number"
					end
				end

				if part.typeRef then
					local link: string? = nil
					if currentMod then
						local cache = getModuleCache(typeLinkCache, currentMod)
						if cache[part.text] ~= nil then
							link = cache[part.text]
						else
							link = self:_resolveTypeLink(part.text, currentMod)
							cache[part.text] = link
						end
					end
					if link then
						table.insert(out, `<a class="type-link syn-type" href="{link}"{hoverAttr(part)}>{text}</a>`)
					else
						table.insert(out, `<span class="syn-type"{hoverAttr(part)}>{text}</span>`)
					end
				elseif kind and kindToClass[kind] then
					table.insert(out, `<span class="{kindToClass[kind]}">{text}</span>`)
				else
					table.insert(out, text)
				end
				i = i + 1
			end
		end
		local rendered = table.concat(out)
		pageSignatureCache[parts] = rendered
		return rendered
	end

	local function signatureHtmlLinks(parts: any, ctx: { [string]: any }): string
		return signatureHtml(parts, ctx, true)
	end

	local filters = {
		escape = htmlEscapeFilter,
		markdown = function(text: string, ctx: { [string]: any }): string
			local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
			local cache = getModuleCache(markdownCache, currentMod)
			local cached = cache[text]
			if cached then
				return cached
			end
			self.currentMod = currentMod

			local html_ = self.markdown:renderHtml(self.markdown:parse(text))
			cache[text] = html_
			return html_
		end,
		webPath = function(x: any)
			return self:getLink(x)
		end,
		isActivePage = function(x: string)
			return false
		end,
		highlight = highlight.luau,
		highlightSig = function(text: string): string
			local cached = highlightSigCache[text]
			if cached then
				return cached
			end
			local html_ = highlight.LUAU_SIGNATURE(text)
			highlightSigCache[text] = html_
			return html_
		end,
		signatureHtml = signatureHtml,
		signatureHtmlLinks = signatureHtmlLinks,
		typeNameHtml = function(typeDoc: any): string
			return typeDisplayHtml(typeDoc)
		end,
		typeNameText = function(typeDoc: any): string
			return typeDisplayText(typeDoc)
		end,
		typeLink = function(typeName: string, ctx: { [string]: any }): string
			local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
			if not currentMod then
				return ""
			end
			local cache = getModuleCache(typeLinkCache, currentMod)
			if cache[typeName] ~= nil then
				return cache[typeName] or ""
			end
			local link = self:_resolveTypeLink(typeName, currentMod)
			cache[typeName] = link
			return link or ""
		end,
	}

	-- Merge custom filters (user filters can override builtins)
	if self.customFilters then
		for k, v in self.customFilters do
			filters[k] = v
		end
	end

	return template.evaluate(tmpl, context, filters)
end

function Renderer.renderModule(self: Renderer, name: string): string
	self.currentArticle = nil
	local module = self.modules[name]
	if not module then
		error("Unknown module " .. name)
	end

	local toc: { TOCGroup } = {}
	local function appendClassMemberToc(children: { TOCItem }, className: string, members: { any }?): ()
		if not members then
			return
		end

		local fields: { any } = {}
		local callables: { any } = {}
		for _, m in members do
			if m.isMethod or m.params then
				table.insert(callables, m)
			else
				table.insert(fields, m)
			end
		end

		local function pushMember(member: any)
			local sep = if member.isMethod then ":" else "."
			local suffix = if member.params then "()" else ""
			table.insert(
				children,
				{
					label = `{sep}{member.name}{suffix}`,
					link = `#method-{className}:{member.name}`,
					indent = true,
				} :: TOCItem
			)
		end

		for _, member in fields do
			pushMember(member)
		end
		for _, member in callables do
			pushMember(member)
		end
	end

	if module.primaryExport then
		local group: TOCGroup = {
			label = "Exported Class",
			children = {
				{
					label = module.primaryExport.name,
					link = `#class-{module.primaryExport.name}`,
				} :: TOCItem,
			},
		}
		appendClassMemberToc(group.children, module.primaryExport.name, module.primaryExport.members)
		table.insert(toc, group)
	end
	if #module.classes > 0 then
		local classes: TOCGroup = { label = "Classes", children = {} }
		for _, i in module.classes do
			table.insert(
				classes.children,
				{
					label = i.name,
					link = `#class-{i.name}`,
				} :: TOCItem
			)
			appendClassMemberToc(classes.children, i.name, i.members)
		end
		table.insert(toc, classes)
	end
	if #module.functions > 0 then
		local root = module.moduleRoot
		local rootFns: { TOCItem } = {}
		local subGroups: { { label: string, items: { TOCItem } } } = {}
		local subGroupMap: { [string]: { label: string, items: { TOCItem } } } = {}

		for _, i in module.functions do
			local subNs: string? = nil
			if root and i.owner and i.owner ~= root and string.sub(i.owner, 1, #root + 1) == root .. "." then
				subNs = string.sub(i.owner, #root + 2)
			end

			local link = functionAnchor(i.owner, i.isMethod, i.name)
			if subNs then
				local group = subGroupMap[subNs]
				if not group then
					group = { label = subNs, items = {} }
					subGroupMap[subNs] = group
					table.insert(subGroups, group)
				end
				table.insert(
					group.items,
					{
						label = `{subNs}.{i.name}`,
						link = link,
						indent = true,
					} :: TOCItem
				)
			else
				table.insert(
					rootFns,
					{
						label = i.name,
						link = link,
					} :: TOCItem
				)
			end
		end

		if #rootFns > 0 or #subGroups > 0 then
			local functions: TOCGroup = { label = "Functions", children = {} }
			for _, item in rootFns do
				table.insert(functions.children, item)
			end
			for _, group in subGroups do
				table.insert(
					functions.children,
					{
						label = group.label,
						link = `#fn-group-{group.label}`,
					} :: TOCItem
				)
				for _, item in group.items do
					table.insert(functions.children, item)
				end
			end
			table.insert(toc, functions)
		end
	end
	if #module.types > 0 then
		local types: TOCGroup = { label = "Types", children = {} }
		for _, i in module.types do
			table.insert(
				types.children,
				{
					label = i.name,
					link = `#type-{i.name}`,
				} :: TOCItem
			)
		end
		table.insert(toc, types)
	end
	if #module.constants > 0 then
		local constants: TOCGroup = { label = "Constants", children = {} }
		for _, i in module.constants do
			table.insert(
				constants.children,
				{
					label = i.name,
					link = constantAnchor(i.owner, i.name),
				} :: TOCItem
			)
		end
		table.insert(toc, constants)
	end

	local functionGroups: { { label: string?, functions: { any } } } = {}
	if #module.functions > 0 then
		local root = module.moduleRoot
		local rootFns: { any } = {}
		local subGroupOrder: { string } = {}
		local subGroupFns: { [string]: { any } } = {}

		for _, f in module.functions do
			local subNs: string? = nil
			if root and f.owner and f.owner ~= root and string.sub(f.owner, 1, #root + 1) == root .. "." then
				subNs = string.sub(f.owner, #root + 2)
			end

			if subNs then
				if not subGroupFns[subNs] then
					subGroupFns[subNs] = {}
					table.insert(subGroupOrder, subNs)
				end
				table.insert(subGroupFns[subNs], f)
			else
				table.insert(rootFns, f)
			end
		end

		if #rootFns > 0 then
			table.insert(functionGroups, { label = nil, functions = rootFns })
		end
		for _, ns in subGroupOrder do
			table.insert(functionGroups, { label = ns, functions = subGroupFns[ns] })
		end
	end

	-- Extract first paragraph of module description for meta description
	local metaDesc: string? = nil
	if module.description then
		-- Strip markdown, take first paragraph
		metaDesc = module.description:match("^([^\n]+)")
	end

	local modulePath = self:getLink(module)
	local section = getModuleSection(self, module.qualifiedName)
	return self:renderPage(self.templates.api, toc, {
		module = module,
		functionGroups = functionGroups,
		jsonLink = self:getJSONLink(module),
		_meta = {
			description = metaDesc,
			canonicalUrl = modulePath,
		},
		_metaGenerator = self.apiMetaGenerator,
		_pageContext = {
			kind = "module",
			name = module.qualifiedName,
			title = module.qualifiedName,
			path = modulePath,
			summary = metaDesc,
			sectionId = if section then section.id else nil,
		},
	}, name)
end

function Renderer.renderArticle(self: Renderer, name: string): string
	local article: Article.Article? = nil
	local articleInfo = getArticleRecord(self, name)
	for _, a in self.articles do
		if a.key == name then
			article = a.article
			break
		end
	end
	if not article then
		error("Unknown article " .. name)
	end

	local toc: { TOCItem } = {}

	local mdToc = article:generateToc()
	for n, i in mdToc do
		if i.level < 1 then
			continue
		end
		if i.level > 4 then
			continue
		end

		local item: TOCItem = {
			label = i.text,
			link = `#{i.id}`,
			level = i.level,
		}
		table.insert(toc, item)
	end

	-- Build breadcrumbs from the article path.
	-- Always includes at least the path ancestors; the template prepends "Home"
	-- and appends the current page title.
	local breadcrumbs: { { label: string, link: string? } } = {}
	local currentSection = getArticleSection(self, name)
	local folderMeta = if currentSection and self.folderMetaBySectionId
		then self.folderMetaBySectionId[currentSection.id]
		else nil
	local parts: { string } = {}
	for part in ((articleInfo and articleInfo.localName) or name):gmatch("[^/]+") do
		table.insert(parts, part)
	end
	if #parts > 1 then
		local pathSoFar = ""
		for i = 1, #parts - 1 do
			pathSoFar = if pathSoFar == "" then parts[i] else pathSoFar .. "/" .. parts[i]
			-- Try to find an article at this path to get its title and link
			local parentLink: string? = nil
			local parentTitle: string? = nil
			-- Prefer an article's title+link when a matching index article exists
			for _, a in self.articles do
				if a.sectionId == (if currentSection then currentSection.id else nil) and a.localName == pathSoFar then
					parentLink = self:getLink(a.article)
					parentTitle = a.article.title
					break
				end
			end
			-- Fall back to folder titles from theme .meta if available
			if not parentTitle and folderMeta and folderMeta.folderTitles[pathSoFar] then
				parentTitle = folderMeta.folderTitles[pathSoFar]
			end
			-- Also consider top-level section title mapping
			if not parentTitle and folderMeta and folderMeta.sectionTitles[parts[i]] then
				parentTitle = folderMeta.sectionTitles[parts[i]]
			end
			table.insert(
				breadcrumbs,
				{ label = parentTitle or parts[i], link = parentLink, position = i + 1, next = i + 2 }
			)
		end
	end

	-- Prev/next navigation: compute using the list of articles excluding
	-- the root `index` so that the site root doesn't participate in
	-- previous/next chains.
	local prevArticle: { name: string, title: string, link: string }? = nil
	local nextArticle: { name: string, title: string, link: string }? = nil

	if articleInfo and articleInfo.localName ~= "index" then
		local navArticles: { ArticleRecord } = {}
		for _, a in self.articles do
			if a.localName ~= "index" and a.sectionId == (if currentSection then currentSection.id else nil) then
				table.insert(navArticles, a)
			end
		end

		local navPos: number? = nil
		for i, a in navArticles do
			if a.key == name then
				navPos = i
				break
			end
		end

		if navPos then
			if navPos > 1 then
				local prev = navArticles[navPos - 1]
				prevArticle = { name = prev.key, title = prev.article.title, link = self:getLink(prev.article) }
			end
			if navPos < #navArticles then
				local nxt = navArticles[navPos + 1]
				nextArticle = { name = nxt.key, title = nxt.article.title, link = self:getLink(nxt.article) }
			end
		end
	end

	local articlePath = self:getLink(article)
	self.currentArticle = article
	return self:renderPage(
		self.templates.article,
		if #toc > 0 then { { label = "On this page", children = toc } } else {},
		{
			article = article,
			breadcrumbs = breadcrumbs,
			prevArticle = prevArticle,
			nextArticle = nextArticle,
			_meta = {
				description = article.summary,
				canonicalUrl = articlePath,
			},
			_metaGenerator = self.articleMetaGenerator,
			_pageContext = {
				kind = "article",
				name = name,
				title = article.title,
				path = articlePath,
				summary = article.summary,
				sectionId = if currentSection then currentSection.id else nil,
			},
		},
		name,
		article.title
	)
end

function Renderer.renderIndex(self: Renderer): string
	self.currentArticle = nil
	local indexSection = getCurrentSection(self, {
		kind = "index",
		name = "index",
		path = self.siteRoot,
	})
	local moduleSummaries = {}

	for _, mod in filterModulesForSection(self, indexSection) do
		if mod.description then
			local summary = mod.description:match("^(.-)\n%s*\n") or mod.description
			summary = summary:gsub("%s+", " ")
			summary = summary:match("^%s*(.-)%s*$") or ""
			moduleSummaries[mod.qualifiedName] = htmlEscapeFilter(summary)
		end
	end

	return self:renderPage(self.templates.index, {}, {
		moduleSummaries = moduleSummaries,
		_pageContext = {
			kind = "index",
			name = "index",
			title = self.siteTitle,
			path = self.siteRoot,
			sectionId = if indexSection then indexSection.id else nil,
		},
	}, nil)
end

function Renderer.renderSectionLanding(self: Renderer, sectionId: string): string
	self.currentArticle = nil
	local section = self.sectionsById[sectionId]
	if not section then
		error("Unknown section " .. sectionId)
	end

	local sectionModules = filterModulesForSection(self, section)
	local moduleSummaries = {}

	for _, mod in sectionModules do
		if mod.description then
			local summary = mod.description:match("^(.-)\n%s*\n") or mod.description
			summary = summary:gsub("%s+", " ")
			summary = summary:match("^%s*(.-)%s*$") or ""
			moduleSummaries[mod.qualifiedName] = htmlEscapeFilter(summary)
		end
	end

	local sectionIndexPath = self:getLink(getSectionLandingRoutePath(section))
	local pageHeading = section.label
	if section.landing and section.landing.title then
		pageHeading = section.landing.title
	end

	local pageSummary = "Browse all available Eryx modules."
	if section.landing and section.landing.description then
		pageSummary = section.landing.description
	end
	local showGuides = section.articles ~= nil
	return self:renderPage(self.templates.index, {}, {
		pageHeading = pageHeading,
		showGuides = showGuides,
		showApiHeading = showGuides,
		moduleSummaries = moduleSummaries,
		_meta = {
			description = pageSummary,
			canonicalUrl = sectionIndexPath,
		},
		_pageContext = {
			kind = "module",
			name = sectionId,
			title = pageHeading,
			path = sectionIndexPath,
			summary = pageSummary,
			sectionId = section.id,
		},
	}, getSectionLandingRoutePath(section), pageHeading)
end

function Renderer.renderApiIndex(self: Renderer): string
	for _, landing in self:getGeneratedSectionLandingPages() do
		if landing.routePath == "api" then
			return self:renderSectionLanding(landing.sectionId)
		end
	end
	error("No API landing page is configured")
end

function Renderer.render404(self: Renderer): string?
	self.currentArticle = nil
	if not self.templates.notFound then
		return nil
	end
	return self:renderPage(self.templates.notFound, {}, {}, nil)
end

function Renderer.getJSONPath(self: Renderer, item: modules.ModuleInfo): string
	local path = self:_GetPath(item)
	if self.exportMode == "directory" then
		return path .. "/api.json"
	else
		return (path:gsub("/", "_"):gsub("\\", "_") .. ".json")
	end
end

function Renderer.getJSONLink(self: Renderer, item: modules.ModuleInfo): string
	local path = self:_GetPath(item)
	if self.exportMode == "directory" then
		return self.siteRoot .. path .. "/api.json"
	else
		return self.siteRoot .. (path:gsub("/", "_"):gsub("\\", "_") .. ".json")
	end
end

-- Strips markdown/HTML to plain text for search indexing.
local function stripMarkdown(text: string): string
	if not text or text == "" then
		return ""
	end
	-- Remove code blocks
	text = text:gsub("```[^\n]*\n.-\n```", " ")
	-- Remove inline code
	text = text:gsub("`[^`]+`", " ")
	-- Remove HTML tags
	text = text:gsub("<[^>]+>", " ")
	-- Remove markdown links, keep text
	text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
	-- Remove wikilinks, keep text
	text = text:gsub("%[%[([^%]|]+)|?[^%]]*%]%]", "%1")
	-- Remove headings markers
	text = text:gsub("\n#+%s*", "\n")
	-- Remove emphasis markers
	text = text:gsub("[*_]+", "")
	-- Collapse whitespace
	text = text:gsub("%s+", " ")
	return text:match("^%s*(.-)%s*$") or ""
end

-- Truncates text to a maximum length, breaking at word boundaries.
local function truncate(text: string, maxLen: number): string
	if #text <= maxLen then
		return text
	end
	local cut = text:sub(1, maxLen)
	local lastSpace = cut:find("%s[^%s]*$")
	if lastSpace then
		cut = cut:sub(1, lastSpace - 1)
	end
	return cut
end

-- Generates a search index as a JSON string.
-- Each entry has: title, path, kind ("article"|"module"|"function"|"type"|"class"),
-- and a text snippet for matching.
function Renderer.generateSearchIndex(self: Renderer): string
	local json = require("@eryx/data/json")
	local entries = {}
	if not hasSectionModel(self) and self:shouldRenderApiIndex() then
		table.insert(entries, {
			t = "API Reference",
			p = if self.exportMode == "directory" then self.siteRoot .. "api" else self.siteRoot .. "api.html",
			k = "module",
			s = "Browse all available Eryx modules.",
		})
	end
	for _, landing in self:getGeneratedSectionLandingPages() do
		local section = if hasSectionModel(self) then self.sectionsById[landing.sectionId] else nil
		local pageTitle = if section then section.label else "API Reference"
		if section and section.landing and section.landing.title then
			pageTitle = section.landing.title
		end
		table.insert(entries, {
			t = pageTitle,
			p = self:getLink(landing.routePath),
			k = "module",
			s = if section
					and section.landing
					and section.landing.description
				then section.landing.description
				else "Browse all available Eryx modules.",
		})
	end

	-- Index articles (page-level + per-section)
	for _, articleInfo in self.articles do
		local article = articleInfo.article
		if articleInfo.key == "" then
			continue
		end
		local articleLink = self:getLink(article)
		local body = article.body or ""

		-- Page-level entry
		table.insert(entries, {
			t = article.title or articleInfo.localName,
			p = articleLink,
			k = "article",
			s = truncate(stripMarkdown(body), 300),
		})

		-- Split by headings and index each section
		-- Match lines like "## Heading text" or "### Sub heading"
		local sections: { { heading: string, anchor: string, text: string } } = {}
		local currentHeading: string? = nil
		local currentAnchor: string? = nil
		local currentLines: { string } = {}

		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			local hashes, heading = line:match("^(#{1,6})%s+(.+)$")
			if hashes and heading then
				-- Save previous section
				if currentHeading then
					table.insert(sections, {
						heading = currentHeading :: string,
						anchor = currentAnchor :: string,
						text = table.concat(currentLines, "\n"),
					})
				end
				currentHeading = heading
				-- Generate anchor ID matching markdown renderer: lowercase, spaces to hyphens
				currentAnchor = heading:lower():gsub("[^%w%s%-]", ""):gsub("%s+", "-")
				currentLines = {}
			else
				table.insert(currentLines, line)
			end
		end
		if currentHeading then
			table.insert(sections, {
				heading = currentHeading :: string,
				anchor = currentAnchor :: string,
				text = table.concat(currentLines, "\n"),
			})
		end

		for _, section in sections do
			local sectionText = stripMarkdown(section.text)
			if #sectionText > 20 then
				table.insert(entries, {
					t = (article.title or articleInfo.localName) .. " > " .. section.heading,
					p = articleLink .. "#" .. section.anchor,
					k = "article",
					s = truncate(sectionText, 200),
				})
			end
		end
	end

	-- Index modules and their members
	for _, mod in self.modules do
		local modLink = self:getLink(mod)
		local desc = stripMarkdown(mod.description or "")

		-- Module itself
		table.insert(entries, {
			t = mod.qualifiedName,
			p = modLink,
			k = "module",
			s = truncate(desc, 300),
		})

		-- Functions
		for _, fn in mod.functions do
			table.insert(entries, {
				t = functionDisplayName(fn.owner, fn.isMethod, fn.name),
				p = modLink .. functionAnchor(fn.owner, fn.isMethod, fn.name),
				k = "function",
				s = truncate(stripMarkdown(fn.doc or ""), 200),
			})
		end

		for _, c in mod.constants do
			table.insert(entries, {
				t = constantDisplayName(c.owner, c.name),
				p = modLink .. constantAnchor(c.owner, c.name),
				k = "member",
				s = truncate(stripMarkdown(c.doc or ""), 200),
			})
		end

		-- Classes / primary export
		local allClasses: { any } = {}
		if mod.primaryExport then
			table.insert(allClasses, mod.primaryExport)
		end
		for _, c in mod.classes do
			table.insert(allClasses, c)
		end

		for _, cls in allClasses do
			table.insert(entries, {
				t = typeDisplayText(cls),
				p = modLink .. "#class-" .. cls.name,
				k = "class",
				s = truncate(stripMarkdown(cls.doc or ""), 200),
			})
			if cls.members then
				for _, m in cls.members do
					table.insert(entries, {
						t = cls.name .. ":" .. m.name,
						p = modLink .. "#method-" .. cls.name .. ":" .. m.name,
						k = "function",
						s = truncate(stripMarkdown(m.doc or ""), 200),
					})
				end
			end
		end

		-- Types
		for _, t in mod.types do
			table.insert(entries, {
				t = typeDisplayText(t),
				p = modLink .. "#type-" .. t.name,
				k = "type",
				s = truncate(stripMarkdown(t.doc or ""), 200),
			})
		end
	end

	return json.encode(entries)
end

-- Generates a sitemap.xml string. Requires an absolute baseUrl.
function Renderer.generateSitemap(self: Renderer, baseUrl: string): string
	-- Strip trailing slash from baseUrl
	if baseUrl:sub(-1) == "/" then
		baseUrl = baseUrl:sub(1, -2)
	end

	local urls = {}
	local seenUrls: { [string]: boolean } = {}
	local function addUrl(url: string)
		if seenUrls[url] then
			return
		end
		seenUrls[url] = true
		table.insert(urls, url)
	end

	-- Index page
	addUrl(baseUrl .. self.siteRoot)

	-- Articles
	for _, articleInfo in self.articles do
		if articleInfo.key == "" then
			continue
		end
		addUrl(baseUrl .. self:getLink(articleInfo.article))
	end

	-- Modules
	if not hasSectionModel(self) and self:shouldRenderApiIndex() then
		local legacyApiPath = if self.exportMode == "directory"
			then self.siteRoot .. "api"
			else self.siteRoot .. "api.html"
		addUrl(baseUrl .. legacyApiPath)
	end
	for _, landing in self:getGeneratedSectionLandingPages() do
		addUrl(baseUrl .. self:getLink(landing.routePath))
	end

	for _, mod in self.modules do
		addUrl(baseUrl .. self:getLink(mod))
	end

	local lines = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
	}
	for _, url in urls do
		table.insert(lines, "  <url>")
		table.insert(lines, "    <loc>" .. url:gsub("&", "&amp;") .. "</loc>")
		table.insert(lines, "  </url>")
	end
	table.insert(lines, "</urlset>")
	return table.concat(lines, "\n")
end

return Renderer
