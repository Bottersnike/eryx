--[=[
	Font loading, inspection, shaping, and rasterization.

	This library opens OpenType, TrueType, and font collection files from disk,
	from memory, or from the host system font registry. A `Typeface` represents
	an unsized face and exposes font metadata, glyph coverage, raw OpenType
	tables, and variable-font axes. Calling `Typeface:at()` creates a sized
	`Font`, which can shape UTF-8 text with HarfBuzz, measure text, inspect glyph
	metrics and outlines, rasterize individual glyphs, or render text into a
	pixel buffer.

	Text shaping operates on one run at a time. Resolve bidi order, split text
	into script/language/font runs, apply fallback fonts, and perform wrapping
	before calling `Font:shape()` or the higher-level measurement and rendering
	helpers.

	Example:

	```luau
	local font = require("@eryx/font")

	local face = font.findSystem("Inter", { weight = 600 }) or font.openFile("Inter-Regular.ttf")
	local body = face:at(18)

	local measure = body:measure("Hello, world!")
	print(measure.width, measure.height)

	local image = body:render("Hello, world!", {
		width = 320,
		align = "center",
		mode = "gray",
	})

	body:close()
	face:close()
	```

	Variable-font example:

	```luau
	local face = font.openFile("Recursive_VF.ttf")
	local display = face:at(48, {
		variations = {
			wght = 750,
			slnt = -8,
		},
	})
	```
]=]

local font = {}

--[=[
	Options for opening a font face from a file or buffer.
]=]
export type OpenOptions = {
	-- 0-based index for TTC/OTC font collections.
	faceIndex: number?,
}

--[=[
	Options for system font discovery and matching.
]=]
export type SystemFontOptions = {
	-- 0-based index for TTC/OTC font collections.
	faceIndex: number?,

	-- Preferred style name, such as "Regular", "Bold", or "Italic".
	style: string?,

	-- Preferred OpenType weight class. Typical values are 100 through 900.
	weight: number?,

	-- Preferred OpenType width class, where 5 is normal width.
	stretch: number?,

	-- Preferred italic or oblique state.
	italic: boolean?,

	-- Extra directories to scan in addition to the platform defaults.
	directories: { string }?,

	-- Rebuild the process-local system font cache before answering.
	refresh: boolean?,
}

--[=[
	Metadata for a discovered system font face.
]=]
export type SystemFontInfo = {
	-- Family name reported by the font.
	family: string,

	-- Style name reported by the font.
	style: string,

	-- 0-based face index for font collections.
	faceIndex: number,

	-- OpenType weight class. Typical values are 100 through 900.
	weight: number,

	-- OpenType width class, where 5 is normal width.
	stretch: number,

	-- Whether the face is italic or oblique.
	italic: boolean,

	-- A single path for the common case, or all matching paths when duplicates were found.
	path: string | { string },

	-- All discovered paths for this family/style/face combination.
	paths: { string },
}

--[=[
	A system font family grouped with all discovered faces in that family.
]=]
export type SystemFontFamilyInfo = {
	-- Family name.
	family: string,

	-- Faces discovered for this family.
	faces: { SystemFontInfo },
}

--[=[
	OpenType variable-font axis metadata.
]=]
export type VariationAxis = {
	-- 4-byte OpenType variation tag, such as "wght", "wdth", or "slnt".
	tag: string,

	-- Human-readable axis name when present in the font.
	name: string?,

	-- Minimum supported design coordinate.
	min: number,

	-- Maximum supported design coordinate.
	max: number,

	-- Default design coordinate.
	default: number,
}

--[=[
	A decoded entry from a font `name` table.
]=]
export type FontNameRecord = {
	-- OpenType name identifier.
	nameId: number,

	-- OpenType platform identifier.
	platformId: number,

	-- OpenType encoding identifier.
	encodingId: number,

	-- OpenType language identifier.
	languageId: number,

	-- Decoded text for this name record.
	text: string,

	-- Raw name bytes as stored in the font.
	raw: buffer,
}

--[=[
	A character-to-glyph mapping entry.
]=]
export type CmapEntry = {
	-- Unicode codepoint.
	codepoint: number,

	-- Glyph id used by the font.
	glyphId: number,
}

--[=[
	Selected metrics from a font OS/2 table.
]=]
export type OS2Metrics = {
	-- OS/2 table version.
	version: number,

	-- OpenType weight class.
	weight: number,

	-- OpenType width class.
	stretch: number,

	-- OS/2 selection bitfield.
	selection: number,

	-- Typographic ascender in font units.
	typoAscender: number,

	-- Typographic descender in font units.
	typoDescender: number,

	-- Typographic line gap in font units.
	typoLineGap: number,

	-- Windows ascent in font units.
	winAscent: number,

	-- Windows descent in font units.
	winDescent: number,

	-- Recommended subscript glyph width in font units.
	subscriptXSize: number,

	-- Recommended subscript glyph height in font units.
	subscriptYSize: number,

	-- Recommended superscript glyph width in font units.
	superscriptXSize: number,

	-- Recommended superscript glyph height in font units.
	superscriptYSize: number,

	-- Recommended strikeout thickness in font units.
	strikeoutSize: number,

	-- Recommended strikeout position in font units.
	strikeoutPosition: number,

	-- Lowercase x-height in font units when available.
	xHeight: number?,

	-- Capital letter height in font units when available.
	capHeight: number?,
}

--[=[
	FreeType hinting mode used when sizing and rasterizing glyphs.
]=]
export type HintingMode = "none" | "light" | "normal" | "mono"

--[=[
	Options for creating or using a sized font.
]=]
export type FontOptions = {
	-- Device DPI for backends that need physical point-size conversion.
	dpi: number?,

	-- Hinting mode.
	hinting: HintingMode?,

	-- Whether to use antialiasing when rasterizing.
	antialias: boolean?,

	-- Whether embedded bitmap strikes may be used.
	embeddedBitmaps: boolean?,

	-- Whether color glyph layers may be used.
	colorGlyphs: boolean?,

	-- OpenType variation coordinates keyed by 4-byte axis tags.
	variations: { [string]: number }?,
}

--[=[
	A missing codepoint reported by `Typeface:missingGlyphs()`.
]=]
export type MissingGlyph = {
	-- Unicode codepoint that has no glyph.
	codepoint: number,

	-- 0-based byte offset into the original UTF-8 string.
	offset: number,
}

--[=[
	An unsized font face.
]=]
export type Typeface = setmetatable<
	{
		-- Family name reported by the font.
		family: string,

		-- Style name reported by the font.
		style: string,

		-- Source file path when the face was opened from disk or the system.
		path: string?,

		-- Whether this typeface has been closed.
		closed: boolean,

		-- Design units per em.
		unitsPerEm: number,

		-- Number of glyphs in the face.
		glyphCount: number,

		-- 0-based face index for font collections.
		faceIndex: number,

		-- OpenType weight class.
		weight: number,

		-- OpenType width class.
		stretch: number,

		-- Whether the face is italic or oblique.
		italic: boolean,

		-- Selected OS/2 table metrics when available.
		os2: OS2Metrics?,

		-- Variable-font axes exposed by this face.
		variations: { VariationAxis },
	},
	{
		__index: {
			--[=[
				Return whether the face contains a glyph for a Unicode codepoint.
				@param codepoint Unicode codepoint to test.
				@return Whether the face has a glyph for the codepoint.
			]=]
			hasGlyph: (self: Typeface, codepoint: number) -> boolean,

			--[=[
				Return the glyph id for a Unicode codepoint.
				@param codepoint Unicode codepoint to look up.
				@return Glyph id, or nil when the codepoint is missing.
			]=]
			glyphId: (self: Typeface, codepoint: number) -> number?,

			--[=[
				Return whether every codepoint in a UTF-8 string has a glyph.
				@param text Text to check.
				@return Whether every codepoint has a glyph.
			]=]
			hasText: (self: Typeface, text: string) -> boolean,

			--[=[
				Return the codepoints in a UTF-8 string that are missing from this face.
				@param text Text to check.
				@return Missing glyph records in text order.
			]=]
			missingGlyphs: (self: Typeface, text: string) -> { MissingGlyph },

			--[=[
				Return decoded records from the font `name` table.
				@return Name records.
			]=]
			names: (self: Typeface) -> { FontNameRecord },

			--[=[
				Return raw data for an OpenType table.
				@param tag 4-byte OpenType table tag, such as "head", "name", or "OS/2".
				@return Table bytes, or nil when the table is absent.
			]=]
			table: (self: Typeface, tag: string) -> buffer?,

			--[=[
				Return the Unicode cmap entries exposed by this face.
				@return Character-to-glyph mapping entries.
			]=]
			codepoints: (self: Typeface) -> { CmapEntry },

			--[=[
				Create a sized font from this typeface. `size` is in CSS-style pixels, not points.
				@param size Pixel size.
				@param options Sizing and rendering options.
				@return Sized font.
			]=]
			at: (self: Typeface, size: number, options: FontOptions?) -> Font,

			--[=[
				Release resources held by this typeface.
			]=]
			close: (self: Typeface) -> (),
		},
	}
>

--- Deprecated alias for `Typeface`.
export type TypeFace = Typeface

--[=[
	Metrics for a sized font in pixels.
]=]
export type FontMetrics = {
	-- Distance from baseline to ascender.
	ascent: number,

	-- Distance from baseline to descender.
	descent: number,

	-- Recommended gap between lines.
	lineGap: number,

	-- Recommended line height.
	height: number,

	-- Underline position relative to the baseline when available.
	underlinePosition: number?,

	-- Underline thickness when available.
	underlineThickness: number?,

	-- Strikethrough position relative to the baseline when available.
	strikethroughPosition: number?,

	-- Strikethrough thickness when available.
	strikethroughThickness: number?,
}

--[=[
	Text direction for shaping.
]=]
export type TextDirection = "auto" | "ltr" | "rtl" | "ttb" | "btt"

--[=[
	HarfBuzz cluster granularity.
]=]
export type ClusterLevel = "monotoneGraphemes" | "monotoneCharacters" | "characters"

--[=[
	Options for shaping a single text run.
]=]
export type ShapeOptions = {
	-- Text direction.
	direction: TextDirection?,

	-- ISO 15924 script tag, such as "Latn", "Arab", "Deva", or "auto".
	script: string?,

	-- BCP 47 language tag, such as "en" or "ar".
	language: string?,

	-- OpenType feature settings keyed by feature tag.
	features: { [string]: boolean | number }?,

	-- Cluster granularity reported in shaped glyphs.
	clusterLevel: ClusterLevel?,
}

--[=[
	A positioned glyph from a shaped text run.
]=]
export type ShapedGlyph = {
	-- Glyph id.
	id: number,

	-- 0-based byte offset into the original UTF-8 string.
	cluster: number,

	-- Horizontal advance in pixels.
	xAdvance: number,

	-- Vertical advance in pixels.
	yAdvance: number,

	-- Horizontal offset in pixels.
	xOffset: number,

	-- Vertical offset in pixels.
	yOffset: number,
}

--[=[
	Metrics for a single glyph in a sized font.
]=]
export type GlyphMetrics = {
	-- Glyph bitmap width in pixels.
	width: number,

	-- Glyph bitmap height in pixels.
	height: number,

	-- Horizontal bearing X in pixels.
	horiBearingX: number,

	-- Horizontal bearing Y in pixels.
	horiBearingY: number,

	-- Horizontal advance in pixels.
	horiAdvance: number,

	-- Vertical bearing X in pixels when available.
	vertBearingX: number?,

	-- Vertical bearing Y in pixels when available.
	vertBearingY: number?,

	-- Vertical advance in pixels when available.
	vertAdvance: number?,
}

--[=[
	A path command that moves the current point.
]=]
export type PathMoveToCommand = {
	-- Command discriminator.
	type: "moveTo",

	-- Destination X coordinate.
	x: number,

	-- Destination Y coordinate.
	y: number,
}

--[=[
	A path command that draws a line.
]=]
export type PathLineToCommand = {
	-- Command discriminator.
	type: "lineTo",

	-- Destination X coordinate.
	x: number,

	-- Destination Y coordinate.
	y: number,
}

--[=[
	A path command that draws a quadratic Bezier curve.
]=]
export type PathQuadToCommand = {
	-- Command discriminator.
	type: "quadTo",

	-- Control point X coordinate.
	controlX: number,

	-- Control point Y coordinate.
	controlY: number,

	-- Destination X coordinate.
	x: number,

	-- Destination Y coordinate.
	y: number,
}

--[=[
	A path command that draws a cubic Bezier curve.
]=]
export type PathCubicToCommand = {
	-- Command discriminator.
	type: "cubicTo",

	-- First control point X coordinate.
	control1X: number,

	-- First control point Y coordinate.
	control1Y: number,

	-- Second control point X coordinate.
	control2X: number,

	-- Second control point Y coordinate.
	control2Y: number,

	-- Destination X coordinate.
	x: number,

	-- Destination Y coordinate.
	y: number,
}

--[=[
	A vector outline drawing command for a glyph.
]=]
export type PathCommand = PathMoveToCommand | PathLineToCommand | PathQuadToCommand | PathCubicToCommand

--[=[
	A glyph outline and its layout metrics.
]=]
export type GlyphOutline = {
	-- Drawing commands in glyph coordinate order.
	commands: { PathCommand },

	-- Outline bounds in pixels.
	bounds: Rect,

	-- Horizontal advance in pixels.
	advanceX: number,

	-- Vertical advance in pixels.
	advanceY: number,
}

--[=[
	Mode for rasterizing an individual glyph.
]=]
export type RasterizeMode = "mono" | "gray" | "lcd" | "color"

--[=[
	Options for rasterizing an individual glyph.
]=]
export type RasterizeOptions = {
	-- Rasterization mode.
	mode: RasterizeMode?,

	-- Horizontal subpixel offset.
	subpixelX: number?,

	-- Vertical subpixel offset.
	subpixelY: number?,
}

--[=[
	Mode for rendering text buffers.
]=]
export type RenderMode = "mono" | "gray"

--[=[
	Horizontal alignment for multiline rendering.
]=]
export type TextAlign = "left" | "center" | "right"

--[=[
	Options for rendering text into a pixel buffer.
]=]
export type RenderOptions = {
	-- Text direction.
	direction: TextDirection?,

	-- ISO 15924 script tag, such as "Latn", "Arab", or "Deva".
	script: string?,

	-- BCP 47 language tag, such as "en" or "ar".
	language: string?,

	-- OpenType feature settings keyed by feature tag.
	features: { [string]: boolean | number }?,

	-- Cluster granularity reported during shaping.
	clusterLevel: ClusterLevel?,

	-- Device DPI for backends that need physical point-size conversion.
	dpi: number?,

	-- Hinting mode.
	hinting: HintingMode?,

	-- Whether to use antialiasing when rasterizing.
	antialias: boolean?,

	-- Whether embedded bitmap strikes may be used.
	embeddedBitmaps: boolean?,

	-- Whether color glyph layers may be used.
	colorGlyphs: boolean?,

	-- OpenType variation coordinates keyed by 4-byte axis tags.
	variations: { [string]: number }?,

	-- Render mode.
	mode: RenderMode?,

	-- Horizontal subpixel offset.
	subpixelX: number?,

	-- Vertical subpixel offset.
	subpixelY: number?,

	-- Maximum line width for multiline rendering.
	width: number?,

	-- Override line height in pixels.
	lineHeight: number?,

	-- Horizontal alignment for lines.
	align: TextAlign?,
}

--[=[
	Subpixel component order for LCD glyph bitmaps.
]=]
export type LcdOrder = "rgb" | "bgr" | "vrgb" | "vbgr"

--[=[
	Pixel format for an individual glyph bitmap.
]=]
export type GlyphBitmapFormat = "mono1" | "gray8" | "lcd24" | "bgra32"

--[=[
	A rasterized individual glyph.
]=]
export type GlyphBitmap = {
	-- Bitmap width in pixels.
	width: number,

	-- Bitmap height in pixels.
	height: number,

	-- Bytes per bitmap row.
	pitch: number,

	-- Horizontal bitmap origin relative to the pen position.
	left: number,

	-- Vertical bitmap origin relative to the baseline.
	top: number,

	-- Horizontal advance in pixels.
	advanceX: number,

	-- Vertical advance in pixels.
	advanceY: number,

	-- Pixel format.
	format: GlyphBitmapFormat,

	-- LCD component order when `format` is "lcd24".
	lcdOrder: LcdOrder?,

	-- Raw pixel data.
	buffer: buffer,
}

--[=[
	A rendered text or glyph image buffer.
]=]
export type RenderedBuffer = {
	-- Buffer width in pixels.
	width: number,

	-- Buffer height in pixels.
	height: number,

	-- Bytes per image row.
	stride: number,

	-- Pixel format.
	format: "grayAlpha8" | "rgba8",

	-- Baseline position inside the image.
	baseline: Vector2,

	-- Final pen advance after rendering.
	advance: Vector2,

	-- Ink bounds inside the image.
	bounds: Rect,

	-- Raw pixel data.
	buffer: buffer,
}

--[=[
	Measurement result for shaped text.
]=]
export type TextMeasure = {
	-- Measured width in pixels.
	width: number,

	-- Measured height in pixels.
	height: number,

	-- Final pen advance.
	advance: Vector2,

	-- Ink bounds.
	bounds: Rect,
}

--[=[
	A 2D vector.
]=]
export type Vector2 = {
	-- X coordinate.
	x: number,

	-- Y coordinate.
	y: number,
}

--[=[
	A rectangle.
]=]
export type Rect = {
	-- X coordinate of the top-left corner.
	x: number,

	-- Y coordinate of the top-left corner.
	y: number,

	-- Rectangle width.
	width: number,

	-- Rectangle height.
	height: number,
}

--[=[
	A shaped text run.
]=]
export type ShapedRun = setmetatable<
	{
		-- Original text that was shaped.
		text: string,

		-- Whether this shaped run has been closed.
		closed: boolean,

		-- Positioned glyphs in shaping order.
		glyphs: { ShapedGlyph },

		-- Final pen advance.
		advance: Vector2,

		-- Ink bounds.
		bounds: Rect,
	},
	{
		__index: {
			--[=[
				Release resources held by this shaped run.
			]=]
			close: (self: ShapedRun) -> (),
		},
	}
>

--[=[
	A sized font created from a `Typeface`.
]=]
export type Font = setmetatable<
	{
		-- Source typeface.
		face: Typeface,

		-- Pixel size.
		size: number,

		-- Whether this font has been closed.
		closed: boolean,

		-- Font-wide metrics at this size.
		metrics: FontMetrics,
	},
	{
		__index: {
			--[=[
				Shape a UTF-8 text run.
				@param text Text to shape.
				@param options Shaping options.
				@return Shaped run.
			]=]
			shape: (self: Font, text: string, options: ShapeOptions?) -> ShapedRun,

			--[=[
				Measure shaped text.
				@param text Text to measure.
				@param options Shaping options.
				@return Text measurement.
			]=]
			measure: (self: Font, text: string, options: ShapeOptions?) -> TextMeasure,

			--[=[
				Return ink bounds for shaped text.
				@param text Text to measure.
				@param options Shaping options.
				@return Ink bounds.
			]=]
			bounds: (self: Font, text: string, options: ShapeOptions?) -> Rect,

			--[=[
				Return metrics for a glyph id.
				@param glyphId Glyph id to inspect.
				@param options Font options to apply for this lookup.
				@return Glyph metrics.
			]=]
			glyphMetrics: (self: Font, glyphId: number, options: FontOptions?) -> GlyphMetrics,

			--[=[
				Return a vector outline for a glyph id.
				@param glyphId Glyph id to outline.
				@param options Font options to apply for this lookup.
				@return Glyph outline, or nil when no outline is available.
			]=]
			outlineGlyph: (self: Font, glyphId: number, options: FontOptions?) -> GlyphOutline?,

			--[=[
				Rasterize a glyph id into a glyph bitmap.
				@param glyphId Glyph id to rasterize.
				@param options Rasterization options.
				@return Glyph bitmap.
			]=]
			rasterizeGlyph: (self: Font, glyphId: number, options: RasterizeOptions?) -> GlyphBitmap,

			--[=[
				Render a glyph id into an image buffer.
				@param glyphId Glyph id to render.
				@param options Rendering options.
				@return Rendered image buffer.
			]=]
			renderGlyph: (self: Font, glyphId: number, options: RenderOptions?) -> RenderedBuffer,

			--[=[
				Render UTF-8 text into an image buffer.
				Multiline rendering splits on "\n". Mixed-direction bidi text still needs run itemization before shaping.
				@param text Text to render.
				@param options Rendering options.
				@return Rendered image buffer.
			]=]
			render: (self: Font, text: string, options: RenderOptions?) -> RenderedBuffer,

			--[=[
				Release resources held by this sized font.
			]=]
			close: (self: Font) -> (),
		},
	}
>

--[=[
	Open a font face from a file path.
	@param path File path to an OpenType, TrueType, TTC, or OTC font.
	@param options Open options.
	@return Opened typeface.
]=]
function font.openFile(path: string, options: OpenOptions?): Typeface
	return nil :: any
end

--[=[
	Open a font face from an in-memory font buffer.
	@param data Font bytes.
	@param options Open options.
	@return Opened typeface.
]=]
function font.fromBuffer(data: buffer, options: OpenOptions?): Typeface
	return nil :: any
end

--[=[
	Find and open the best matching installed system font for a family name.
	@param family Family name to search for.
	@param options System font match options.
	@return Opened typeface, or nil when no matching font is found.
]=]
function font.findSystem(family: string, options: SystemFontOptions?): Typeface?
	return nil :: any
end

--[=[
	List discovered system font faces.
	@param options System font discovery options.
	@return Discovered font faces.
]=]
function font.listSystem(options: SystemFontOptions?): { SystemFontInfo }
	return nil :: any
end

--[=[
	List discovered system font faces grouped by family.
	@param options System font discovery options.
	@return Discovered font families.
]=]
function font.listSystemFamilies(options: SystemFontOptions?): { SystemFontFamilyInfo }
	return nil :: any
end

--[=[
	Refresh the process-local system font cache.
	@param options System font discovery options.
]=]
function font.refreshSystem(options: SystemFontOptions?)
	return nil :: any
end

return table.freeze(font)
