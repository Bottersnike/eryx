--[=[
Image loading, encoding, pixel access, and small in-memory image operations.
]=]

local image = {}
local path = require("@eryx/path")

type PathLike = path.PathLike

export type PixelFormat = "rgba8" | "rgb8" | "gray8" | "grayAlpha8"

export type Color = {
	r: number,
	g: number,
	b: number,
	a: number,
}

export type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type DecodeOptions = {
	format: PixelFormat?,
	applyOrientation: boolean?,
}

export type NewImageOptions = {
	format: PixelFormat?,
	color: Color?,
}

export type BufferImageOptions = {
	format: PixelFormat,
	stride: number?,
	copy: boolean?,
}

export type ImageFormat = "png" | "jpeg" | "webp"

export type EncodeOptions = {
	format: ImageFormat?,
	quality: number?,
	lossless: boolean?,
	progressive: boolean?,
}

export type ConvertOptions = {
	background: Color?,
}

export type ResizeFilter = "nearest"

export type ResizeOptions = {
	filter: ResizeFilter?,
	fit: "stretch" | "contain" | "cover"?,
	position: "center" | "topLeft" | "top" | "bottom" | "left" | "right" | "bottomRight"?,
	background: Color?,
}

export type BlendMode = "replace" | "normal" | "add" | "multiply" | "screen"

export type BlitOptions = {
	blend: BlendMode?,
	opacity: number?,
	tint: Color?,
	mask: Image?,
}

export type DrawOptions = BlitOptions

export type LineOptions = {
	thickness: number?,
}

export type ExifTagValue = number | string | buffer | { number }

export type ImageMetadata = {
	read format: string?,
	read width: number?,
	read height: number?,
	read originalChannels: number?,
	read source: string?,
	read exif: {
		read orientation: number?,
		read make: string?,
		read model: string?,
		read software: string?,
		read dateTime: string?,
		read artist: string?,
		read copyright: string?,
		read tags: { read [number]: ExifTagValue }?,
	},
}

export type Image = {
	read width: number,
	read height: number,
	read format: PixelFormat,
	read channels: number,
	read stride: number,
	read bounds: Rect,
	read colorSpace: "srgb" | "linear",
	read metadata: ImageMetadata,
	read buffer: buffer,
	read pixelBuffer: buffer,
	read closed: boolean,

	close: (self: Image) -> (),

	save: (self: Image, path: PathLike, options: EncodeOptions?) -> (),
	encode: (self: Image, format: ImageFormat, options: EncodeOptions?) -> buffer,

	clone: (self: Image) -> Image,
	crop: ((self: Image, x: number, y: number, width: number, height: number) -> Image)
		& ((self: Image, rect: Rect) -> Image),
	subimage: ((self: Image, x: number, y: number, width: number, height: number) -> ImageView)
		& ((self: Image, rect: Rect) -> ImageView),

	getPixel: (self: Image, x: number, y: number) -> Color,
	setPixel: (self: Image, x: number, y: number, color: Color) -> (),

	convert: (self: Image, format: PixelFormat, options: ConvertOptions?) -> Image,
	resize: (self: Image, width: number, height: number, options: ResizeOptions?) -> Image,
	thumbnail: (self: Image, maxWidth: number, maxHeight: number, options: ResizeOptions?) -> Image,

	flipX: (self: Image) -> Image,
	flipY: (self: Image) -> Image,
	rotate90: (self: Image) -> Image,
	rotate180: (self: Image) -> Image,
	rotate270: (self: Image) -> Image,

	blit: ((self: Image, src: Image, x: number, y: number, options: BlitOptions?) -> ())
		& ((self: Image, src: Image, srcRect: Rect, dstX: number, dstY: number, options: BlitOptions?) -> ()),
	draw: (self: Image, src: Image, srcRect: Rect, dstRect: Rect, options: DrawOptions?) -> (),

	clear: (self: Image, color: Color) -> (),
	fillRect: ((self: Image, x: number, y: number, width: number, height: number, color: Color) -> ())
		& ((self: Image, rect: Rect, color: Color) -> ()),
	strokeRect: ((
		self: Image,
		x: number,
		y: number,
		width: number,
		height: number,
		color: Color,
		thickness: number?
	) -> ()) & ((self: Image, rect: Rect, color: Color, thickness: number?) -> ()),
	line: (self: Image, x1: number, y1: number, x2: number, y2: number, color: Color, options: LineOptions?) -> (),

	invert: (self: Image) -> Image,
	grayscale: (self: Image) -> Image,
	brightness: (self: Image, amount: number) -> Image,
	contrast: (self: Image, amount: number) -> Image,
	opacity: (self: Image, amount: number) -> Image,

	threshold: (self: Image, value: number) -> Image,
	colorMatrix: (self: Image, matrix: { number }) -> Image,
}

export type ImageView = Image

function image.open(path: PathLike, options: DecodeOptions?): Image
	return nil :: any
end

function image.decode(data: buffer, options: DecodeOptions?): Image
	return nil :: any
end

function image.new(width: number, height: number, options: NewImageOptions? | PixelFormat): Image
	return nil :: any
end

function image.fromBuffer(data: buffer, width: number, height: number, options: BufferImageOptions): Image
	return nil :: any
end

function image.fromRGBABuffer(pixelData: buffer, width: number, height: number, channels: number): Image
	return nil :: any
end

function image.rgb(r: number, g: number, b: number): Color
	return nil :: any
end

function image.rgba(r: number, g: number, b: number, a: number): Color
	return nil :: any
end

function image.gray(v: number, a: number?): Color
	return nil :: any
end

function image.rect(x: number, y: number, width: number, height: number): Rect
	return nil :: any
end

return table.freeze(image)
