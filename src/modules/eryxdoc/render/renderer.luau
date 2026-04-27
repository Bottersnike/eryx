local fs = require("@eryx/fs")
local template = require("@eryx/template")
local sidebar = require("./sidebar")
local markdown = require("@eryx/markdown")

local wikilinkRuleBuilder = require("@eryx/markdown/extensions/wikilink")

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

local function htmlEscapeFilter(s: string): string
	if not s then
		return ""
	end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
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

type RendererFields = {
	siteTitle: string,
	siteRoot: string,
	exportMode: "flat" | "directory",
	modulePrefix: string?,
	modules: { [string]: modules.ModuleInfo },
	articles: { { name: string, article: Article.Article } },
	stylesPath: string,
	favicon: string?,
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
	sectionTitles: { [string]: string }?,
	folderTitles: { [string]: string }?,
	folderOrder: { [string]: number }?,

	templates: {
		article: template.Template,
		api: template.Template,
		index: template.Template,
		notFound: template.Template?,
	},

	markdown: markdown.Markdown,
	hoverMarkdown: markdown.Markdown,
	currentMod: modules.ModuleInfo?,
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
		favicon: string?,
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
		sectionTitles: { [string]: string }?,
		folderTitles: { [string]: string }?,
		folderOrder: { [string]: number }?,
	}?
): Renderer
	local siteRoot = (if options then options.siteRoot else nil) or "/"
	if siteRoot:sub(-1) ~= "/" then
		siteRoot = siteRoot .. "/"
	end
	local exportMode: "flat" | "directory" = (if options then options.exportMode else nil) or "flat"

	local this = {
		siteTitle = siteTitle,
		siteRoot = siteRoot,
		exportMode = exportMode,
		modulePrefix = if options then options.modulePrefix else nil,
		modules = {},
		articles = {},

		stylesPath = stylesPath,
		favicon = if options then options.favicon else nil,
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
		sectionTitles = if options then options.sectionTitles else nil,
		folderTitles = if options then options.folderTitles else nil,
		folderOrder = if options then options.folderOrder else nil,
		templates = {
			article = template.compile(fs.openSync(templates.article):readSync(), templates.article),
			api = template.compile(fs.openSync(templates.api):readSync(), templates.api),
			index = template.compile(fs.openSync(templates.index):readSync(), templates.index),
			notFound = if templates.notFound and fs.isFile(templates.notFound)
				then template.compile(fs.openSync(templates.notFound):readSync(), templates.notFound)
				else nil,
		},

		currentMod = nil,
	}
	setmetatable(this, Renderer)
	this.markdown = markdown.Markdown.new({
		extraInlineExtensions = {
			wikilinkRuleBuilder(function(link: string): any
				return this:_resolveWikiLinkInfo(link, this.currentMod)
			end),
		},
		codeLanguages = highlight,
		useCrlf = false,
		annotateHtml = true,
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

	for _, f in currentMod.functions do
		if f.name == core then
			return {
				signature = f.signature,
				doc = self:_truncateDocForHover(f.doc),
			}
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
		error(":(")
	end

	-- Sidebar module
	if (item :: any).displayName then
		return "api/" .. item.name
	end

	-- ModuleInfo
	if (item :: any).functions then
		return "api/" .. item.qualifiedName
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

	if self.exportMode == "directory" then
		return self.siteRoot .. path
	else
		return self.siteRoot .. (path:gsub("/", "_"):gsub("\\", "_") .. ".html")
	end
end

function Renderer.registerArticle(self: Renderer, article: Article.Article, sitePath: string): ()
	article.sitePath = sitePath
	table.insert(self.articles, { name = sitePath, article = article })
end

function Renderer.registerModule(self: Renderer, module: modules.ModuleInfo)
	self.modules[module.qualifiedName] = module
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
	local articleSections = sidebar.buildSidebarArticleSections(
		self.articles,
		pageName,
		function(article: Article.Article): string
			return self:getLink(article)
		end,
		self.sectionTitles,
		self.folderTitles,
		self.folderOrder
	)

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
			modules = self.modules,
			articles = self.articles,
			stylePath = self.stylesPath,
			pageName = displayName,
			siteRoot = self.siteRoot,
			favicon = self.favicon,
			extraHead = self.extraHead,
			extraScripts = self.extraScripts,
			announcement = self.announcement,
			versionName = self.versionName,
			versionLabel = self.versionLabel or self.versionName,
		},
		sidebar = {
			articleTopLevel = articleSections.topLevel,
			articleSections = articleSections.sections,
			modules = sidebar.buildSidebarModuleTree(self.modules, pageName, self.modulePrefix),
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

	local function signatureHtml(parts: any, ctx: { [string]: any }, doLinks: true?): string
		if not parts then
			return ""
		end
		local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
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
			local hoverHtml = self:_renderTypeHoverHtml(part.hoverText)
			if not hoverHtml then
				return ""
			end
			return ` data-hover-html="{htmlEscapeFilter(hoverHtml)}"`
		end
		local function symbolHoverAttr(core: string): string
			local symbol = self:_findHoverSymbol(currentMod, core)
			if not symbol then
				return ""
			end
			local hoverHtml = self:_renderSymbolHoverHtml(currentMod, symbol.signature, symbol.doc)
			if not hoverHtml then
				return ""
			end
			return ` data-hover-html="{htmlEscapeFilter(hoverHtml)}"`
		end
		local function resolveLocal(core: string): string?
			if not currentMod then
				return nil
			end
			local cls, mem = core:match("^([^.]+)%.(.+)$")
			local anchor: string? = nil
			if cls and mem then
				anchor = links.resolveClassMember(currentMod, cls, mem)
			else
				anchor = links.resolveInModule(currentMod, core)
			end
			if anchor then
				return self:getLink(currentMod) .. anchor
			end
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
					local link = if currentMod then self:_resolveTypeLink(part.text, currentMod) else nil
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
		return table.concat(out)
	end

	local function signatureHtmlLinks(parts: any, ctx: { [string]: any }): string
		return signatureHtml(parts, ctx, true)
	end

	local filters = {
		escape = htmlEscapeFilter,
		markdown = function(text: string, ctx: { [string]: any }): string
			local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
			self.currentMod = currentMod

			local html_ = self.markdown:renderHtml(self.markdown:parse(text))

			return html_
		end,
		webPath = function(x: any)
			return self:getLink(x)
		end,
		isActivePage = function(x: string)
			return false
		end,
		highlight = highlight.luau,
		highlightSig = highlight.LUAU_SIGNATURE,
		signatureHtml = signatureHtml,
		signatureHtmlLinks = signatureHtmlLinks,
		typeLink = function(typeName: string, ctx: { [string]: any }): string
			local currentMod: modules.ModuleInfo? = if ctx then (ctx :: any).module else nil
			if not currentMod then
				return ""
			end
			return self:_resolveTypeLink(typeName, currentMod) or ""
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
		},
	}, name)
end

function Renderer.renderArticle(self: Renderer, name: string): string
	local article: Article.Article? = nil
	local articleIndex: number = 0
	for i, a in self.articles do
		if a.name == name then
			article = a.article
			articleIndex = i
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
	local parts: { string } = {}
	for part in name:gmatch("[^/]+") do
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
				if a.name == pathSoFar then
					parentLink = self:getLink(a.article)
					parentTitle = a.article.title
					break
				end
			end
			-- Fall back to folder titles from theme .meta if available
			if not parentTitle and self.folderTitles and self.folderTitles[pathSoFar] then
				parentTitle = self.folderTitles[pathSoFar]
			end
			-- Also consider top-level section title mapping
			if not parentTitle and self.sectionTitles and self.sectionTitles[parts[i]] then
				parentTitle = self.sectionTitles[parts[i]]
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

	if name ~= "index" then
		local navArticles: { { name: string, article: Article.Article } } = {}
		for _, a in self.articles do
			if a.name ~= "index" then
				table.insert(navArticles, a)
			end
		end

		local navPos: number? = nil
		for i, a in navArticles do
			if a.name == name then
				navPos = i
				break
			end
		end

		if navPos then
			if navPos > 1 then
				local prev = navArticles[navPos - 1]
				prevArticle = { name = prev.name, title = prev.article.title, link = self:getLink(prev.article) }
			end
			if navPos < #navArticles then
				local nxt = navArticles[navPos + 1]
				nextArticle = { name = nxt.name, title = nxt.article.title, link = self:getLink(nxt.article) }
			end
		end
	end

	local articlePath = self:getLink(article)
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
			},
		},
		name,
		article.title
	)
end

function Renderer.renderIndex(self: Renderer): string
	local moduleSummaries = {}

	for _, mod in self.modules do
		if mod.description then
			local md = markdown.parse(mod.description)
			for _, i in md.children do
				if i.type == "paragraph" then
					moduleSummaries[mod.qualifiedName] = html.inlineNodesToHtml(i.children, {})
					break
				end
			end
		end
	end

	return self:renderPage(self.templates.index, {}, { moduleSummaries = moduleSummaries }, nil)
end

function Renderer.render404(self: Renderer): string?
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

	-- Index articles (page-level + per-section)
	for _, articleInfo in self.articles do
		local article = articleInfo.article
		if articleInfo.name == "index" then
			continue
		end
		local articleLink = self:getLink(article)
		local body = article.body or ""

		-- Page-level entry
		table.insert(entries, {
			t = article.title or articleInfo.name,
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
					t = (article.title or articleInfo.name) .. " > " .. section.heading,
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
				t = cls.name,
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
				t = t.name,
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

	-- Index page
	table.insert(urls, baseUrl .. self.siteRoot)

	-- Articles
	for _, articleInfo in self.articles do
		if articleInfo.name == "index" then
			continue
		end
		table.insert(urls, baseUrl .. self:getLink(articleInfo.article))
	end

	-- Modules
	for _, mod in self.modules do
		table.insert(urls, baseUrl .. self:getLink(mod))
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
