return {
	output = "build-docs/",

	title = "Eryx",
	siteRoot = "/",
	baseUrl = "https://eryx.bsnk.me",
	exportMode = "directory",

	static = "./docs/static",
	staticMount = "/",
	head = {
		{ tag = "link", rel = "icon", type = "image/png", href = "/favicon-96x96.png", sizes = "96x96" },
		{ tag = "link", rel = "icon", type = "image/svg+xml", href = "/favicon.svg" },
		{ tag = "link", rel = "shortcut icon", href = "/favicon.ico" },
		{ tag = "link", rel = "apple-touch-icon", sizes = "180x180", href = "/apple-touch-icon.png" },
		{ tag = "meta", name = "apple-mobile-web-app-title", content = "Eryx" },
		{ tag = "link", rel = "manifest", href = "/site.webmanifest" },
	},
	sections = {
		{
			id = "docs",
			label = "Documentation",
			mount = "/",
			headerHref = "/getting-started/welcome",
			articles = "./docs/root",
		},
		{
			id = "api",
			label = "Libraries",
			children = {
				{
					id = "reference",
					label = "All Libraries",
					mount = "/api",
					modules = "./src/modules",
					prefix = "@eryx",
					landing = {
						title = "All Libraries",
						description = "Browse all available Eryx libraries.",
					},
				},
				{
					id = "http",
					label = "HTTP",
					mount = "/http",
					headerHref = "/http/overview",
					articles = "./docs/libs/http",
				},
				{
					id = "crypto",
					label = "Cryptography",
					mount = "/crypto",
					headerHref = "/crypto/overview",
					articles = "./docs/libs/crypto",
				},
				{
					id = "ip",
					label = "IP Addresses",
					mount = "/ip",
					headerHref = "/ip",
					articles = "./docs/libs/ip",
				},
			},
		},
		{
			id = "packages",
			label = "Packages",
			children = {
				{
					id = "markdown",
					label = "Markdown",
					mount = "/packages/markdown",
					modules = "./packages/markdown/src",
					articles = "./docs/packages/markdown",
					prefix = "@markdown",
					landing = {
						title = "Markdown Package",
						description = "Browse the Markdown package API.",
					},
				},
				{
					id = "eryxdoc",
					label = "Eryxdoc",
					mount = "/packages/eryxdoc",
					modules = "./packages/eryxdoc/src",
					prefix = "@eryxdoc",
					landing = {
						title = "Eryxdoc Package",
						description = "Browse the Eryxdoc package API.",
					},
				},
			},
		},
	},
}
