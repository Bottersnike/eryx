local modules = require("../content/modules")

type TNode = {
	children: TTree,
	info: modules.ModuleInfo?,
	path: string,
}
type TTree = { [string]: TNode }

export type SidebarEntry = {
	name: string,
	displayName: string,
	filename: string?,
	children: { SidebarEntry }?,
	isOpen: boolean,
	isActive: boolean,
}

-- Recursively convert tree to sidebar format
local function toSidebar(node: TTree, parentPath: string, activePage: string?): ({ SidebarEntry }, boolean)
	local result: { SidebarEntry } = {}
	local anyChildrenOpen = false

	for k, v in pairs(node) do
		if type(v) == "table" then
			local children, hadActiveChildren = toSidebar(v.children, v.path, activePage)
			if hadActiveChildren then
				anyChildrenOpen = true
			end

			local entry: SidebarEntry = {
				name = v.info and v.info.qualifiedName or v.path,
				displayName = v.info and v.info.qualifiedName or v.path,
				filename = v.info and v.info.filename or nil,
				children = #children > 0 and children or nil,
				isOpen = false,
				isActive = false,
			}
			if entry.displayName == activePage then
				entry.isActive = true
			end
			if entry.displayName == activePage or hadActiveChildren then
				entry.isOpen = true
				anyChildrenOpen = true
			end
			table.insert(result, entry)
		end
	end
	table.sort(result, function(a: SidebarEntry, b: SidebarEntry)
		local function basename(name: string)
			if not name then
				return ""
			end
			return name:match("[^/]+$") or name
		end

		local an = basename(a.displayName)
		local bn = basename(b.displayName)
		local a_und = an:match("^_") ~= nil
		local b_und = bn:match("^_") ~= nil

		-- If one starts with '_' and the other doesn't, put the '_' one last.
		if a_und ~= b_und then
			return not a_und
		end

		return a.displayName < b.displayName
	end)

	return result, anyChildrenOpen
end

-- Group modules by prefix hierarchy for sidebar navigation.
-- `stripPrefix` is the root prefix to strip from display (e.g. "@eryx").
local function buildSidebarModuleTree(
	modules: { [string]: modules.ModuleInfo },
	activePage: string?,
	stripPrefix: string?
): { SidebarEntry }
	local tree: TTree = {}

	local function splitParts(qname: string): { string }
		local parts = {}
		for part in string.gmatch(qname, "[^/]+") do
			table.insert(parts, part)
		end

		if stripPrefix and parts[1] == stripPrefix then
			table.remove(parts, 1)
		end

		return parts
	end

	for _, mod in modules do
		local parts = splitParts(mod.qualifiedName)
		local node = tree
		local path = ""
		-- Split the full qualified name without stripping to build proper display paths.
		local fullParts: { string } = {}
		for p in mod.qualifiedName:gmatch("[^/]+") do
			table.insert(fullParts, p)
		end
		local offset = #fullParts - #parts -- how many prefix parts were stripped (e.g. 1 for "@eryx/...")
		for i, part in ipairs(parts) do
			path = path ~= "" and (path .. "/" .. part) or part
			if not node[part] then
				node[part] = { children = {}, info = nil, path = table.concat(fullParts, "/", 1, offset + i) }
			end
			if i == #parts then
				node[part].info = mod
			end
			node = node[part].children
		end
	end

	local sidebar = toSidebar(tree, "", activePage)
	return sidebar
end

export type ArticleSidebarEntry = {
	displayName: string,
	sitePath: string?,
	isActive: boolean,
	isOpen: boolean,
	children: { ArticleSidebarEntry }?,
}

export type ArticleSidebarSection = {
	title: string,
	entries: { ArticleSidebarEntry },
}

type ANode = {
	children: { [string]: ANode },
	insertionOrder: number, -- preserves the order from collectArticles
	name: string?, -- the article's registration key
	sitePath: string?,
	title: string?,
}

-- Global counter used to stamp insertion order on tree nodes.
local insertionCounter = 0

local function toArticleSidebar(
	tree: { [string]: ANode },
	activePage: string?,
	folderTitles: { [string]: string }?
): ({ ArticleSidebarEntry }, boolean)
	local result: { ArticleSidebarEntry } = {}
	local anyActive = false

	for stem, node in pairs(tree) do
		local hasChildren = next(node.children) ~= nil
		local isActive = node.name ~= nil and node.name == activePage
		if isActive then
			anyActive = true
		end

		local children: { ArticleSidebarEntry }? = nil
		local childActive = false
		if hasChildren then
			children, childActive = toArticleSidebar(node.children, activePage, folderTitles)
			if childActive then
				anyActive = true
			end
		end

		-- Resolve display name: article title > folder title from .meta > stem
		local displayName = node.title or (if folderTitles then folderTitles[node.name or stem] else nil) or stem

		local entry: ArticleSidebarEntry = {
			displayName = displayName,
			sitePath = node.sitePath,
			isActive = isActive,
			isOpen = isActive or childActive,
			children = children,
		}
		-- Carry insertion order for sorting
		(entry :: any)._order = node.insertionOrder
		table.insert(result, entry)
	end

	-- Sort by insertion order — this preserves the order from collectArticles,
	-- which already handles .meta children lists and alphabetical fallback.
	table.sort(result, function(a: ArticleSidebarEntry, b: ArticleSidebarEntry)
		return (a :: any)._order < (b :: any)._order
	end)

	return result, anyActive
end

-- Format a folder name into a human-readable title.
-- "getting-started" → "Getting Started"
local function formatFolderName(name: string): string
	return name:gsub("%-", " "):gsub("(%a)([%w]*)", function(first: string, rest: string)
		return first:upper() .. rest
	end)
end

export type ArticleSidebarResult = {
	-- Loose top-level articles — displayed as bare links, not in any section
	topLevel: { ArticleSidebarEntry },
	-- Top-level folders, each as a titled section
	sections: { ArticleSidebarSection },
}

-- Build article sidebar with top-level loose articles separate from folder sections.
-- `sectionTitles` maps top-level folder names to display titles (from .meta title fields).
-- `folderTitles` maps nested path keys to display titles for sub-directory labels.
local function buildSidebarArticleSections(
	articles: { { name: string, article: { title: string? } } },
	activePage: string?,
	getLink: (article: any) -> string,
	sectionTitles: { [string]: string }?,
	folderTitles: { [string]: string }?
): ArticleSidebarResult
	-- Build the full tree
	local tree: { [string]: ANode } = {}
	insertionCounter = 0

	for _, articleInfo in articles do
		if articleInfo.name == "index" then
			continue
		end
		local parts: { string } = {}
		for part in articleInfo.name:gmatch("[^/]+") do
			table.insert(parts, part)
		end

		local cur = tree
		for i, part in ipairs(parts) do
			if not cur[part] then
				insertionCounter += 1
				cur[part] = { children = {}, insertionOrder = insertionCounter }
			end
			if i == #parts then
				cur[part].name = articleInfo.name
				cur[part].sitePath = getLink(articleInfo.article)
				cur[part].title = (articleInfo.article :: any).title
			end
			cur = cur[part].children
		end
	end

	-- Split top-level tree: folders → sections, loose files → topLevel
	local sections: { ArticleSidebarSection } = {}
	local topLevel: { ArticleSidebarEntry } = {}

	local sorted: { { stem: string, node: ANode } } = {}
	for stem, node in pairs(tree) do
		table.insert(sorted, { stem = stem, node = node })
	end
	table.sort(sorted, function(a, b)
		return a.node.insertionOrder < b.node.insertionOrder
	end)

	for _, item in sorted do
		local stem = item.stem
		local node = item.node
		local hasChildren = next(node.children) ~= nil

		if hasChildren then
			-- Folder → becomes a titled section
			local title = node.title or (if sectionTitles then sectionTitles[stem] else nil) or formatFolderName(stem)
			local entries, _ = toArticleSidebar(node.children, activePage, folderTitles)
			table.insert(sections, { title = title, entries = entries })
		else
			-- Loose top-level article
			local isActive = node.name ~= nil and node.name == activePage
			local entry: ArticleSidebarEntry = {
				displayName = node.title or stem,
				sitePath = node.sitePath,
				isActive = isActive,
				isOpen = isActive,
			}
			(entry :: any)._order = node.insertionOrder
			table.insert(topLevel, entry)
		end
	end

	return { topLevel = topLevel, sections = sections }
end

return {
	buildSidebarModuleTree = buildSidebarModuleTree,
	buildSidebarArticleSections = buildSidebarArticleSections,
}
