return {
	output = "build-docs/",

	modules = "./src/modules",
	articles = "./docs",
	prefix = "@eryx",

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
}
