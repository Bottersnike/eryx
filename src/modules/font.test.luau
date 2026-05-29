local font = require("@eryx/font")
local test = require("@eryx/test")

local suite = test.Suite.new("font")

local function firstPath(info: font.SystemFontInfo): string
	if type(info.path) == "string" then
		return info.path
	end

	return info.path[1]
end

local function systemFace(): font.Typeface?
	local preferred = font.findSystem("Segoe UI")
	if preferred ~= nil then
		return preferred
	end

	local fonts = font.listSystem()
	if #fonts == 0 then
		return nil
	end

	local info = fonts[1]
	return font.openFile(firstPath(info), {
		faceIndex = info.faceIndex,
	})
end

local function expectRenderedBuffer(rendered)
	test.expect(rendered.format == "grayAlpha8" or rendered.format == "rgba8"):toBeTrue()
	test.expect(rendered.width):toBeGreaterThan(0)
	test.expect(rendered.height):toBeGreaterThan(0)
	test.expect(rendered.stride):toBe(rendered.width * if rendered.format == "rgba8" then 4 else 2)
	test.expect(rendered.baseline.x):toNotBeNil()
	test.expect(rendered.baseline.y):toNotBeNil()
	test.expect(rendered.bounds.width):toBeGreaterThanOrEqual(0)
	test.expect(rendered.bounds.height):toBeGreaterThanOrEqual(0)
	test.expect(buffer.len(rendered.buffer)):toBe(rendered.stride * rendered.height)
end

suite:test("findSystem: returns nil for missing families", function()
	test.expect(font.findSystem("__Eryx Missing Font Family 7F4B__")):toBeNil()
end)

suite:test("listSystem: returns discovered fonts with paths", function()
	local fonts = font.listSystem()
	test.expect(#fonts):toBeGreaterThan(0)

	for _, info in fonts do
		test.expect(info.family):toNotBe("")
		test.expect(info.style):toNotBeNil()
		test.expect(info.faceIndex):toBeGreaterThanOrEqual(0)
		test.expect(info.weight):toBeGreaterThan(0)
		test.expect(info.stretch):toBeGreaterThan(0)
		test.expect(type(info.italic)):toBe("boolean")
		test.expect(#info.paths):toBeGreaterThan(0)
		test.expect(info.path):toNotBeNil()
	end
end)

suite:test("listSystemFamilies: groups discovered faces by family", function()
	local families = font.listSystemFamilies()
	test.expect(#families):toBeGreaterThan(0)

	for _, family in families do
		test.expect(family.family):toNotBe("")
		test.expect(#family.faces):toBeGreaterThan(0)
		for _, face in family.faces do
			test.expect(face.family):toBe(family.family)
			test.expect(#face.paths):toBeGreaterThan(0)
		end
	end
end)

suite:test("refreshSystem: rebuilds the system font cache", function()
	font.refreshSystem()
	test.expect(#font.listSystem()):toBeGreaterThan(0)
	test.expect(#font.listSystem({ refresh = true })):toBeGreaterThan(0)
	test.expect(#font.listSystem({ directories = {} })):toBeGreaterThan(0)
end)

suite:test("openFile and fromBuffer: open a discovered font", function()
	local fonts = font.listSystem()
	if #fonts == 0 then
		test.skip("no system fonts discovered")
		return
	end

	local info = fonts[1]
	local path = firstPath(info)
	local face = font.openFile(path, {
		faceIndex = info.faceIndex,
	})

	test.expect(face.family):toNotBe("")
	test.expect(face.style):toNotBeNil()
	test.expect(face.path):toBe(path)
	test.expect(face.unitsPerEm):toBeGreaterThan(0)
	test.expect(face.glyphCount):toBeGreaterThan(0)
	test.expect(face.faceIndex):toBe(info.faceIndex)
	test.expect(face.weight):toBeGreaterThan(0)
	test.expect(face.stretch):toBeGreaterThan(0)
	test.expect(type(face.italic)):toBe("boolean")
	test.expect(face.variations):toNotBeNil()
	test.expect(typeof(face)):toBe("Typeface")
	test.expect(tostring(face)):toContain("Typeface(")

	local ok, fs = pcall(require, "@eryx/fs")
	if ok then
		local file = fs.openSync(path, "r")
		local bytes = file:readBufferSync()
		file:close()

		local memoryFace = font.fromBuffer(bytes, {
			faceIndex = info.faceIndex,
		})
		test.expect(memoryFace.family):toBe(face.family)
		test.expect(memoryFace.path):toBeNil()
		test.expect(memoryFace.glyphCount):toBe(face.glyphCount)
		memoryFace:close()
		test.expect(memoryFace.closed):toBeTrue()
	end

	face:close()
	test.expect(face.closed):toBeTrue()
	test.expect(tostring(face)):toBe("Typeface(closed)")
	local glyphA = string.byte("A") :: number
	test.expect(function()
		face:glyphId(glyphA)
	end):toError("attempt to use a closed typeface")
end)

suite:test("Typeface: glyph lookup and sizing", function()
	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local glyphA = string.byte("A") :: number
	test.expect(face:hasGlyph(glyphA)):toBeTrue()
	local glyphIdA = face:glyphId(glyphA)
	test.expect(glyphIdA):toNotBeNil()
	test.expect(face:hasText("Hello\nWorld")):toBeTrue()
	test.expect(#face:missingGlyphs("Hello\nWorld")):toBe(0)
	test.expect(face:hasText(string.char(0))):toBeFalse()
	local missing = face:missingGlyphs(string.char(0))
	test.expect(#missing):toBe(1)
	test.expect(missing[1].codepoint):toBe(0)
	test.expect(missing[1].offset):toBe(0)
	test.expect(function()
		face:hasGlyph(-1)
	end):toError("codepoint must be non%-negative")
	test.expect(function()
		face:hasText(string.char(255))
	end):toError("invalid UTF%-8 text")
	test.expect(function()
		face:at(0)
	end):toError("font size must be positive")

	local matched = font.findSystem(face.family, {
		weight = face.weight,
		stretch = face.stretch,
		italic = face.italic,
	})
	if matched ~= nil then
		test.expect(matched.family):toBe(face.family)
		matched:close()
	end

	local names = face:names()
	test.expect(names):toNotBeNil()
	if #names > 0 then
		test.expect(names[1].nameId):toBeGreaterThanOrEqual(0)
		test.expect(names[1].platformId):toBeGreaterThanOrEqual(0)
		test.expect(names[1].encodingId):toBeGreaterThanOrEqual(0)
		test.expect(names[1].languageId):toBeGreaterThanOrEqual(0)
		test.expect(names[1].text):toNotBeNil()
		test.expect(buffer.len(names[1].raw)):toBeGreaterThanOrEqual(0)
	end

	local nameTable = face:table("name")
	if nameTable ~= nil then
		test.expect(buffer.len(nameTable)):toBeGreaterThan(0)
	end
	test.expect(face:table("ZZZZ")):toBeNil()

	local codepoints = face:codepoints()
	test.expect(#codepoints):toBeGreaterThan(0)
	local sawA = false
	for _, entry in codepoints do
		if entry.codepoint == glyphA then
			test.expect(entry.glyphId):toBe(glyphIdA :: number)
			sawA = true
			break
		end
	end
	test.expect(sawA):toBeTrue()

	if face.os2 ~= nil then
		test.expect(face.os2.weight):toBeGreaterThan(0)
		test.expect(face.os2.stretch):toBeGreaterThan(0)
		test.expect(face.os2.winAscent):toBeGreaterThan(0)
	end

	local sized = face:at(24, {
		dpi = 96,
		hinting = "light",
		embeddedBitmaps = true,
		colorGlyphs = true,
		antialias = true,
	})
	test.expect(sized.face.family):toBe(face.family)
	test.expect(typeof(sized)):toBe("Font")
	test.expect(sized.size):toBe(24)
	test.expect(sized.metrics.height):toBeGreaterThan(0)
	test.expect(sized.metrics.underlinePosition):toNotBeNil()
	test.expect(sized.metrics.underlineThickness):toNotBeNil()
	if sized.metrics.strikethroughThickness ~= nil then
		test.expect(sized.metrics.strikethroughThickness):toBeGreaterThan(0)
	end
	test.expect(tostring(sized)):toContain("Font(")
	test.expect(face.closed):toBeFalse()
	test.expect(sized.closed):toBeFalse()

	if #face.variations > 0 then
		local axis = face.variations[1]
		local varied = face:at(24, {
			variations = {
				[axis.tag] = axis.default,
			},
		})
		test.expect(varied.size):toBe(24)
		test.expect(varied.metrics.height):toBeGreaterThan(0)
		varied:close()
		test.expect(varied.closed):toBeTrue()
	end

	sized:close()
	test.expect(sized.closed):toBeTrue()
	test.expect(function()
		sized:shape("closed")
	end):toError("attempt to use a closed font")
end)

suite:test("Font: shape, measure, and bounds", function()
	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local sized = face:at(24)
	local run = sized:shape("Hello", {
		direction = "ltr",
		script = "Latn",
		language = "en",
		clusterLevel = "monotoneCharacters",
	})

	test.expect(run.text):toBe("Hello")
	test.expect(#run.glyphs):toBeGreaterThan(0)
	test.expect(run.glyphs[1].id):toBeGreaterThan(0)
	test.expect(run.glyphs[1].cluster):toBeGreaterThanOrEqual(0)
	test.expect(run.glyphs[1].xAdvance):toBeGreaterThan(0)
	test.expect(run.glyphs[1].yAdvance):toBe(0)
	test.expect(run.glyphs[1].xOffset):toBe(0)
	test.expect(run.advance.x):toBeGreaterThan(0)
	test.expect(run.bounds.width):toBeGreaterThan(0)
	test.expect(typeof(run)):toBe("ShapedRun")
	test.expect(tostring(run)):toContain("ShapedRun(")
	test.expect(run.closed):toBeFalse()

	local measure = sized:measure("Hello")
	test.expect(measure.width):toBeGreaterThan(0)
	test.expect(measure.height):toBeGreaterThan(0)
	test.expect(measure.advance.x):toBeGreaterThan(0)
	test.expect(measure.bounds.width):toBeGreaterThan(0)

	local bounds = sized:bounds("Hello")
	test.expect(bounds.width):toBeGreaterThan(0)
	test.expect(bounds.height):toBeGreaterThan(0)

	test.expect(function()
		sized:shape("Hello", {
			direction = "sideways" :: any,
		})
	end):toError("unsupported text direction")

	run:close()
	test.expect(run.closed):toBeTrue()
	test.expect(function()
		return run.glyphs
	end):toError("attempt to use a closed shaped run")
end)

suite:test("Font: OpenType feature overrides can affect ligature shaping", function()
	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local sized = face:at(24)
	local normal = sized:shape("office")
	local noLigatures = sized:shape("office", {
		features = {
			liga = false,
		},
	})

	test.expect(normal.advance.x):toBeGreaterThan(0)
	test.expect(noLigatures.advance.x):toBeGreaterThan(0)
	test.expect(#normal.glyphs):toBeGreaterThan(0)
	test.expect(#noLigatures.glyphs):toBeGreaterThan(0)
end)

suite:test("Font: glyph metrics and rasterizeGlyph modes", function()
	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local sized = face:at(24)
	local glyphId = face:glyphId(string.byte("H") :: number)
	test.expect(glyphId):toNotBeNil()

	local metrics = sized:glyphMetrics(glyphId :: number, {
		hinting = "normal",
	})
	test.expect(metrics.width):toBeGreaterThan(0)
	test.expect(metrics.height):toBeGreaterThan(0)
	test.expect(metrics.horiBearingX):toNotBeNil()
	test.expect(metrics.horiBearingY):toBeGreaterThan(0)
	test.expect(metrics.horiAdvance):toBeGreaterThan(0)

	local outline = sized:outlineGlyph(glyphId :: number)
	if outline ~= nil then
		test.expect(#outline.commands):toBeGreaterThan(0)
		test.expect(outline.bounds.width):toBeGreaterThan(0)
		test.expect(outline.bounds.height):toBeGreaterThan(0)
		test.expect(outline.advanceX):toBeGreaterThan(0)
	end

	local gray = sized:rasterizeGlyph(glyphId :: number, {
		mode = "gray",
		subpixelX = 0.25,
		subpixelY = 0.5,
	})
	test.expect(gray.format):toBe("gray8")
	test.expect(gray.width):toBeGreaterThan(0)
	test.expect(gray.height):toBeGreaterThan(0)
	test.expect(gray.pitch):toBeGreaterThan(0)
	test.expect(gray.left):toNotBeNil()
	test.expect(gray.top):toNotBeNil()
	test.expect(gray.advanceX):toBeGreaterThan(0)
	test.expect(buffer.len(gray.buffer)):toBe(gray.pitch * gray.height)

	local mono = sized:rasterizeGlyph(glyphId :: number, {
		mode = "mono",
	})
	test.expect(mono.format):toBe("mono1")
	test.expect(buffer.len(mono.buffer)):toBe(mono.pitch * mono.height)

	local lcd = sized:rasterizeGlyph(glyphId :: number, {
		mode = "lcd",
	})
	test.expect(lcd.format):toBe("lcd24")
	test.expect(lcd.lcdOrder):toNotBeNil()
	test.expect(buffer.len(lcd.buffer)):toBe(lcd.pitch * lcd.height)

	local color = sized:rasterizeGlyph(glyphId :: number, {
		mode = "color",
	})
	test.expect(color.format):toNotBeNil()
	test.expect(buffer.len(color.buffer)):toBe(color.pitch * color.height)

	test.expect(function()
		sized:rasterizeGlyph(glyphId :: number, {
			mode = "wat" :: any,
		})
	end):toError("unsupported rasterize mode")
end)

suite:test("Font: renderGlyph and render produce image-compatible buffers", function()
	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local sized = face:at(24)
	local glyphId = face:glyphId(string.byte("H") :: number)
	test.expect(glyphId):toNotBeNil()

	local renderedGlyph = sized:renderGlyph(glyphId :: number)
	expectRenderedBuffer(renderedGlyph)
	test.expect(renderedGlyph.advance.x):toBeGreaterThan(0)

	local renderedText = sized:render("office", {
		mode = "gray",
		language = "en",
		features = {
			liga = true,
		},
	})
	expectRenderedBuffer(renderedText)
	test.expect(renderedText.advance.x):toBeGreaterThan(0)

	local multiline = sized:render("one\ntwo", {
		width = 200,
		align = "center",
		lineHeight = 32,
	})
	expectRenderedBuffer(multiline)
	test.expect(multiline.width):toBe(200)
	test.expect(multiline.height):toBeGreaterThan(renderedText.height)

	local right = sized:render("right", {
		width = 200,
		align = "right",
	})
	expectRenderedBuffer(right)
	test.expect(right.width):toBe(200)

	local mono = sized:render("mono", {
		mode = "mono",
	})
	expectRenderedBuffer(mono)

	local empty = sized:render("")
	expectRenderedBuffer(empty)
	test.expect(empty.bounds.width):toBe(0)
	test.expect(empty.bounds.height):toBe(0)

	test.expect(function()
		sized:render("hello", {
			align = "justify" :: any,
		})
	end):toError("justify alignment is not supported yet")
end)

suite:test("Font render buffers can be opened by @eryx/image", function()
	local ok, image = pcall(require, "@eryx/image")
	if not ok then
		test.skip("@eryx/image unavailable")
		return
	end

	local face = systemFace()
	if face == nil then
		test.skip("no usable system font")
		return
	end

	local rendered = face:at(32):render("Image buffer")
	local textImage = image.fromBuffer(rendered.buffer, rendered.width, rendered.height, {
		format = rendered.format,
		stride = rendered.stride,
	})
	test.expect(textImage.width):toBe(rendered.width)
	test.expect(textImage.height):toBe(rendered.height)
	test.expect(textImage.format):toBe("grayAlpha8")
	textImage:close()
end)

suite:test("Font: color emoji render returns rgba8 when a color emoji font is available", function()
	local face = font.findSystem("Segoe UI Emoji") or font.findSystem("Noto Color Emoji")
	if face == nil then
		test.skip("no known color emoji font")
		return
	end

	local emoji = "\u{1F642}"
	if not face:hasText(emoji) then
		face:close()
		test.skip("color emoji font does not cover sample")
		return
	end

	local sized = face:at(32, {
		colorGlyphs = true,
	})
	local rendered = sized:render(emoji, {
		colorGlyphs = true,
	})

	if rendered.format ~= "rgba8" then
		sized:close()
		face:close()
		test.skip("emoji font rendered as outline glyphs")
		return
	end

	expectRenderedBuffer(rendered)
	test.expect(rendered.stride):toBe(rendered.width * 4)
	sized:close()
	face:close()
end)

return suite
