local fs = require("@eryx/fs")
local markdown = require("@markdown")
local yaml = require("@eryx/data/yaml")

export type ArticleMeta = { [string]: any }

export type SidebarModule = {
	name: string,
	displayName: string,
	filename: string,
	children: { SidebarModule },
}

export type SidebarArticle = {
	title: string,
	filename: string,
	summary: string?,
}

export type GeneratedSectionPage = {
	title: string,
	article: any,
}

local Article = {}
Article.__index = Article

type ArticleFields = {
	title: string,
	summary: string?,
	sitePath: string?, -- set externally when registered; used for URL path
	lastUpdated: string?, -- ISO date string from git, set externally

	meta: ArticleMeta?,
	hero: ArticleMeta?,
	body: string,
	sourceFilename: string,
	generatedSectionPages: { GeneratedSectionPage }?,
}
export type Article = setmetatable<ArticleFields, typeof(Article)>

local function trim(s: string): string
	return (s:match("^%s*(.-)%s*$")) :: string
end

function Article.fromSource(source: string, sourceFilename: string): Article
	local this = {
		title = nil :: string?,
		summary = nil :: string?,
		sourceFilename = sourceFilename,
	}

	local body = source

	-- Check for --- frontmatter (YAML). Decode into a table when present.
	if source:sub(1, 3) == "---" then
		local endPos = source:find("\n---", 4, true)
		if endPos then
			local frontmatter = source:sub(5, endPos - 1) -- skip first ---\n
			body = source:sub(endPos + 5) -- skip \n---\n

			local ok, data = pcall(function()
				return yaml.decode(frontmatter)
			end)
			if ok and type(data) == "table" then
				this.meta = data
				if data.title and type(data.title) == "string" then
					this.title = trim(data.title)
				end
				if data.summary and type(data.summary) == "string" then
					this.summary = trim(data.summary)
				end
				if data.hero and type(data.hero) == "table" then
					this.hero = data.hero
				end
			else
				-- Fallback: simple line-based parsing for legacy frontmatter
				for line in frontmatter:gmatch("[^\n]+") do
					local key, value = line:match("^(%w+):%s*(.+)$")
					if key and value then
						value = trim(value)
						if key == "title" then
							this.title = value
						elseif key == "summary" then
							this.summary = value
						end
					end
				end
			end
		end
	end

	-- If no title from frontmatter, pull from first # heading and strip it from the body
	-- to avoid duplicating it alongside the <h1> in the rendered template.
	if this.title == nil then
		local headingStart, headingEnd, heading = body:find("^%s*#%s+([^\n]+)")
		if heading then
			this.title = trim(heading)
			-- Remove the heading line (and any immediately following blank line)
			body = body:sub(headingEnd + 1):gsub("^\n", "")
		else
			error(`Unable to identify article title for {sourceFilename}`)
		end
	end

	this.body = body

	return setmetatable(this :: ArticleFields, Article)
end

function Article.fromFile(path: string): Article
	local source = fs.openSync(path):readSync()
	return Article.fromSource(source, path)
end

function Article.generated(
	title: string,
	sourceFilename: string,
	body: string?,
	summary: string?,
	generatedSectionPages: { GeneratedSectionPage }?
): Article
	return setmetatable({
		title = title,
		summary = summary,
		sourceFilename = sourceFilename,
		body = body or "",
		generatedSectionPages = generatedSectionPages,
	}, Article)
end

function Article.generateToc(self: Article): { markdown.TocEntry }
	return markdown.toc(markdown.parse(self.body, {}))
end

return Article
