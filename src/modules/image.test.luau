local image = require("@eryx/image")
local tempfile = require("@eryx/tempfile")
local test = require("@eryx/test")

local suite = test.Suite.new("image")

type Color = {
	r: number,
	g: number,
	b: number,
	a: number,
}

local function expectColor(c: Color, r: number, g: number, b: number, a: number?)
	test.expect(c.r):toBe(r)
	test.expect(c.g):toBe(g)
	test.expect(c.b):toBe(b)
	test.expect(c.a):toBe(if a == nil then 255 else a)
end

local function expectNear(actual: number, expected: number, tolerance: number)
	test.expect(math.abs(actual - expected) <= tolerance):toBeTrue()
end

local function expectColorNear(c: Color, r: number, g: number, b: number, tolerance: number)
	expectNear(c.r, r, tolerance)
	expectNear(c.g, g, tolerance)
	expectNear(c.b, b, tolerance)
end

local function writeByteString(buf: buffer, offset: number, value: string)
	for i = 1, #value do
		buffer.writeu8(buf, offset + i - 1, string.byte(value, i))
	end
end

local function writeBE16(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, bit32.rshift(value, 8))
	buffer.writeu8(buf, offset + 1, bit32.band(value, 0xff))
end

local function writeBE32(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, bit32.band(bit32.rshift(value, 24), 0xff))
	buffer.writeu8(buf, offset + 1, bit32.band(bit32.rshift(value, 16), 0xff))
	buffer.writeu8(buf, offset + 2, bit32.band(bit32.rshift(value, 8), 0xff))
	buffer.writeu8(buf, offset + 3, bit32.band(value, 0xff))
end

local function withExif(jpeg: buffer, orientation: number): buffer
	local make = "TestCam\0"
	local entryCount = 3
	local ifdDataOffset = 8 + 2 + entryCount * 12 + 4
	local makeOffset = ifdDataOffset
	local rationalOffset = makeOffset + #make
	local tiffLen = rationalOffset + 8
	local exifPayloadLen = 6 + tiffLen
	local app1Len = 2 + 2 + exifPayloadLen
	local app1 = buffer.create(app1Len)

	writeBE16(app1, 0, 0xffe1)
	writeBE16(app1, 2, exifPayloadLen + 2)
	writeByteString(app1, 4, "Exif\0\0")

	local tiff = 10
	writeByteString(app1, tiff, "MM")
	writeBE16(app1, tiff + 2, 42)
	writeBE32(app1, tiff + 4, 8)
	writeBE16(app1, tiff + 8, entryCount)

	local orientationEntry = tiff + 10
	writeBE16(app1, orientationEntry, 0x0112)
	writeBE16(app1, orientationEntry + 2, 3)
	writeBE32(app1, orientationEntry + 4, 1)
	writeBE16(app1, orientationEntry + 8, orientation)
	writeBE16(app1, orientationEntry + 10, 0)

	local makeEntry = orientationEntry + 12
	writeBE16(app1, makeEntry, 0x010f)
	writeBE16(app1, makeEntry + 2, 2)
	writeBE32(app1, makeEntry + 4, #make)
	writeBE32(app1, makeEntry + 8, makeOffset)

	local resolutionEntry = makeEntry + 12
	writeBE16(app1, resolutionEntry, 0x011a)
	writeBE16(app1, resolutionEntry + 2, 5)
	writeBE32(app1, resolutionEntry + 4, 1)
	writeBE32(app1, resolutionEntry + 8, rationalOffset)

	writeBE32(app1, tiff + 10 + entryCount * 12, 0)
	writeByteString(app1, tiff + makeOffset, make)
	writeBE32(app1, tiff + rationalOffset, 72)
	writeBE32(app1, tiff + rationalOffset + 4, 1)

	local jpegLen = buffer.len(jpeg)
	local out = buffer.create(jpegLen + app1Len)
	buffer.copy(out, 0, jpeg, 0, 2)
	buffer.copy(out, 2, app1)
	buffer.copy(out, 2 + app1Len, jpeg, 2, jpegLen - 2)
	return out
end

local function withRichExif(jpeg: buffer): buffer
	local entryCount = 5
	local ifdDataOffset = 8 + 2 + entryCount * 12 + 4
	local shortsOffset = ifdDataOffset
	local rawOffset = shortsOffset + 6
	local signedRationalOffset = rawOffset + 5
	local tiffLen = signedRationalOffset + 8
	local exifPayloadLen = 6 + tiffLen
	local app1Len = 2 + 2 + exifPayloadLen
	local app1 = buffer.create(app1Len)

	writeBE16(app1, 0, 0xffe1)
	writeBE16(app1, 2, exifPayloadLen + 2)
	writeByteString(app1, 4, "Exif\0\0")

	local tiff = 10
	writeByteString(app1, tiff, "MM")
	writeBE16(app1, tiff + 2, 42)
	writeBE32(app1, tiff + 4, 8)
	writeBE16(app1, tiff + 8, entryCount)

	local byteEntry = tiff + 10
	writeBE16(app1, byteEntry, 0x0201)
	writeBE16(app1, byteEntry + 2, 1)
	writeBE32(app1, byteEntry + 4, 1)
	buffer.writeu8(app1, byteEntry + 8, 7)

	local shortArrayEntry = byteEntry + 12
	writeBE16(app1, shortArrayEntry, 0x0202)
	writeBE16(app1, shortArrayEntry + 2, 3)
	writeBE32(app1, shortArrayEntry + 4, 3)
	writeBE32(app1, shortArrayEntry + 8, shortsOffset)

	local signedEntry = shortArrayEntry + 12
	writeBE16(app1, signedEntry, 0x0203)
	writeBE16(app1, signedEntry + 2, 9)
	writeBE32(app1, signedEntry + 4, 1)
	writeBE32(app1, signedEntry + 8, 0xffffffd6)

	local rawEntry = signedEntry + 12
	writeBE16(app1, rawEntry, 0x0204)
	writeBE16(app1, rawEntry + 2, 7)
	writeBE32(app1, rawEntry + 4, 5)
	writeBE32(app1, rawEntry + 8, rawOffset)

	local signedRationalEntry = rawEntry + 12
	writeBE16(app1, signedRationalEntry, 0x0205)
	writeBE16(app1, signedRationalEntry + 2, 10)
	writeBE32(app1, signedRationalEntry + 4, 1)
	writeBE32(app1, signedRationalEntry + 8, signedRationalOffset)

	writeBE32(app1, tiff + 10 + entryCount * 12, 0)
	writeBE16(app1, tiff + shortsOffset, 1)
	writeBE16(app1, tiff + shortsOffset + 2, 2)
	writeBE16(app1, tiff + shortsOffset + 4, 3)
	buffer.writeu8(app1, tiff + rawOffset, 0xaa)
	buffer.writeu8(app1, tiff + rawOffset + 1, 0xbb)
	buffer.writeu8(app1, tiff + rawOffset + 2, 0xcc)
	buffer.writeu8(app1, tiff + rawOffset + 3, 0xdd)
	buffer.writeu8(app1, tiff + rawOffset + 4, 0xee)
	writeBE32(app1, tiff + signedRationalOffset, 0xfffffffd)
	writeBE32(app1, tiff + signedRationalOffset + 4, 2)

	local jpegLen = buffer.len(jpeg)
	local out = buffer.create(jpegLen + app1Len)
	buffer.copy(out, 0, jpeg, 0, 2)
	buffer.copy(out, 2, app1)
	buffer.copy(out, 2 + app1Len, jpeg, 2, jpegLen - 2)
	return out
end

local function withMalformedExif(jpeg: buffer): buffer
	local app1 = buffer.create(18)
	writeBE16(app1, 0, 0xffe1)
	writeBE16(app1, 2, 16)
	writeByteString(app1, 4, "Exif\0\0")
	writeByteString(app1, 10, "MM")
	writeBE16(app1, 12, 99)
	writeBE32(app1, 14, 8)

	local jpegLen = buffer.len(jpeg)
	local out = buffer.create(jpegLen + buffer.len(app1))
	buffer.copy(out, 0, jpeg, 0, 2)
	buffer.copy(out, 2, app1)
	buffer.copy(out, 2 + buffer.len(app1), jpeg, 2, jpegLen - 2)
	return out
end

suite:test("constructors expose image, color, rect, metadata, and buffer fields", function()
	local img = image.new(3, 2, {
		format = "rgba8",
		color = image.rgba(1, 2, 3, 4),
	})

	test.expect(tostring(img)):toContain("Image(3, 2, rgba8)")
	test.expect(img.width):toBe(3)
	test.expect(img.height):toBe(2)
	test.expect(img.format):toBe("rgba8")
	test.expect(img.channels):toBe(4)
	test.expect(img.stride):toBe(12)
	test.expect(img.colorSpace):toBe("srgb")
	test.expect(img.closed):toBeFalse()
	test.expect(buffer.len(img.buffer)):toBe(24)
	test.expect(buffer.len(img.pixelBuffer)):toBe(24)
	test.expect(img.bounds.width):toBe(3)
	test.expect(img.bounds.height):toBe(2)
	test.expect(img.metadata.format):toBe("raw")
	expectColor(img:getPixel(1, 1), 1, 2, 3, 4)

	local r = image.rect(1, 2, 3, 4)
	test.expect(r.x):toBe(1)
	test.expect(r.height):toBe(4)

	img:close()
	test.expect(img.closed):toBeTrue()
	test.expect(tostring(img)):toBe("Image(closed)")
end)

suite:test("colors and rects are read-only", function()
	local c = image.rgb(1, 2, 3)
	test.expect(function()
		(c :: any).r = 9
	end):toError()

	local r = image.rect(0, 0, 1, 1)
	test.expect(function()
		(r :: any).width = 5
	end):toError()
end)

suite:test("pixel formats read, write, and convert consistently", function()
	local rgba = image.new(1, 1, "rgba8")
	rgba:setPixel(0, 0, image.rgba(10, 20, 30, 40))
	expectColor(rgba:getPixel(0, 0), 10, 20, 30, 40)

	local rgb = rgba:convert("rgb8")
	expectColor(rgb:getPixel(0, 0), 10, 20, 30, 255)
	test.expect(rgb.channels):toBe(3)

	local gray = rgba:convert("gray8")
	expectColor(gray:getPixel(0, 0), 18, 18, 18, 255)
	test.expect(gray.channels):toBe(1)

	local ga = rgba:convert("grayAlpha8")
	expectColor(ga:getPixel(0, 0), 18, 18, 18, 40)
	test.expect(ga.channels):toBe(2)

	rgba:close()
	rgb:close()
	gray:close()
	ga:close()
end)

suite:test("convert background composites alpha when dropping alpha", function()
	local src = image.new(1, 1, {
		format = "rgba8",
		color = image.rgba(255, 0, 0, 128),
	})
	local flattened = src:convert("rgb8", {
		background = image.rgb(0, 0, 255),
	})

	local c = flattened:getPixel(0, 0)
	expectNear(c.r, 128, 1)
	test.expect(c.g):toBe(0)
	expectNear(c.b, 127, 1)
	test.expect(c.a):toBe(255)

	src:close()
	flattened:close()
end)

suite:test("fromBuffer copy=true detaches from source buffer", function()
	local data = buffer.create(6)
	buffer.writeu8(data, 0, 10)
	buffer.writeu8(data, 1, 20)
	buffer.writeu8(data, 2, 30)
	buffer.writeu8(data, 3, 40)
	buffer.writeu8(data, 4, 50)
	buffer.writeu8(data, 5, 60)

	local img = image.fromBuffer(data, 2, 1, {
		format = "rgb8",
		copy = true,
	})
	buffer.writeu8(data, 0, 99)
	expectColor(img:getPixel(0, 0), 10, 20, 30, 255)
	img:close()
end)

suite:test("fromBuffer copy=false shares source buffer", function()
	local data = buffer.create(3)
	buffer.writeu8(data, 0, 10)
	buffer.writeu8(data, 1, 20)
	buffer.writeu8(data, 2, 30)

	local img = image.fromBuffer(data, 1, 1, {
		format = "rgb8",
		copy = false,
	})
	buffer.writeu8(data, 0, 99)
	expectColor(img:getPixel(0, 0), 99, 20, 30, 255)
	img:close()
end)

suite:test("fromBuffer supports stride", function()
	local data = buffer.create(8)
	buffer.writeu8(data, 0, 1)
	buffer.writeu8(data, 1, 2)
	buffer.writeu8(data, 2, 3)
	buffer.writeu8(data, 4, 4)
	buffer.writeu8(data, 5, 5)
	buffer.writeu8(data, 6, 6)

	local img = image.fromBuffer(data, 1, 2, {
		format = "rgb8",
		stride = 4,
		copy = false,
	})
	test.expect(img.stride):toBe(4)
	expectColor(img:getPixel(0, 0), 1, 2, 3, 255)
	expectColor(img:getPixel(0, 1), 4, 5, 6, 255)
	img:close()
end)

suite:test("fromRGBABuffer compatibility helper", function()
	local data = buffer.create(4)
	buffer.writeu8(data, 0, 1)
	buffer.writeu8(data, 1, 2)
	buffer.writeu8(data, 2, 3)
	buffer.writeu8(data, 3, 4)

	local img = image.fromRGBABuffer(data, 1, 1, 4)
	test.expect(img.format):toBe("rgba8")
	expectColor(img:getPixel(0, 0), 1, 2, 3, 4)
	img:close()
end)

suite:test("subimage is a live view and keeps buffer alive after parent closes", function()
	local img = image.new(3, 2, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	img:setPixel(1, 0, image.rgba(10, 20, 30, 40))

	local view = img:subimage(1, 0, 1, 1)
	expectColor(view:getPixel(0, 0), 10, 20, 30, 40)
	view:setPixel(0, 0, image.rgba(90, 80, 70, 60))
	expectColor(img:getPixel(1, 0), 90, 80, 70, 60)

	img:close()
	test.expect(img.closed):toBeTrue()
	test.expect(view.closed):toBeFalse()
	expectColor(view:getPixel(0, 0), 90, 80, 70, 60)
	view:close()
end)

suite:test("clone and crop make independent raw images", function()
	local img = image.new(3, 2, {
		format = "rgb8",
		color = image.rgb(0, 0, 0),
	})
	img:setPixel(1, 1, image.rgb(10, 20, 30))

	local clone = img:clone()
	local crop = img:crop(1, 1, 1, 1)
	img:setPixel(1, 1, image.rgb(99, 99, 99))

	expectColor(clone:getPixel(1, 1), 10, 20, 30, 255)
	expectColor(crop:getPixel(0, 0), 10, 20, 30, 255)
	test.expect(clone.metadata.format):toBe("raw")
	test.expect(crop.metadata.format):toBe("raw")

	img:close()
	clone:close()
	crop:close()
end)

suite:test("transforms flip and rotate pixels", function()
	local img = image.new(2, 3, {
		format = "rgb8",
		color = image.rgb(0, 0, 0),
	})
	img:setPixel(0, 0, image.rgb(255, 0, 0))
	img:setPixel(1, 2, image.rgb(0, 0, 255))

	local flipX = img:flipX()
	local flipY = img:flipY()
	local rot90 = img:rotate90()
	local rot180 = img:rotate180()
	local rot270 = img:rotate270()

	expectColor(flipX:getPixel(1, 0), 255, 0, 0, 255)
	expectColor(flipY:getPixel(0, 2), 255, 0, 0, 255)
	test.expect(rot90.width):toBe(3)
	test.expect(rot90.height):toBe(2)
	expectColor(rot90:getPixel(2, 0), 255, 0, 0, 255)
	expectColor(rot180:getPixel(1, 2), 255, 0, 0, 255)
	expectColor(rot270:getPixel(0, 1), 255, 0, 0, 255)

	img:close()
	flipX:close()
	flipY:close()
	rot90:close()
	rot180:close()
	rot270:close()
end)

suite:test("resize stretch, contain, cover, and thumbnail", function()
	local wide = image.new(2, 1, {
		format = "rgb8",
		color = image.rgb(0, 0, 0),
	})
	wide:setPixel(0, 0, image.rgb(255, 0, 0))
	wide:setPixel(1, 0, image.rgb(0, 0, 255))

	local stretch = wide:resize(4, 2, { filter = "nearest" })
	test.expect(stretch.width):toBe(4)
	test.expect(stretch.height):toBe(2)
	expectColor(stretch:getPixel(0, 0), 255, 0, 0, 255)
	expectColor(stretch:getPixel(3, 1), 0, 0, 255, 255)

	local contained = wide:resize(4, 4, {
		fit = "contain",
		position = "bottomRight",
		background = image.rgb(0, 255, 0),
		filter = "nearest",
	})
	expectColor(contained:getPixel(0, 0), 0, 255, 0, 255)
	expectColor(contained:getPixel(0, 2), 255, 0, 0, 255)
	expectColor(contained:getPixel(3, 2), 0, 0, 255, 255)

	local coverSource = image.new(4, 2, {
		format = "rgb8",
		color = image.rgb(255, 0, 0),
	})
	coverSource:fillRect(2, 0, 2, 2, image.rgb(0, 0, 255))
	local covered = coverSource:resize(2, 2, {
		fit = "cover",
		position = "right",
		filter = "nearest",
	})
	expectColor(covered:getPixel(0, 0), 0, 0, 255, 255)

	local thumb = coverSource:thumbnail(2, 1, { filter = "nearest" })
	test.expect(thumb.width):toBe(2)
	test.expect(thumb.height):toBe(1)

	wide:close()
	stretch:close()
	contained:close()
	coverSource:close()
	covered:close()
	thumb:close()
end)

suite:test("resize default filter path returns requested dimensions", function()
	local src = image.new(2, 2, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	src:setPixel(0, 0, image.rgba(255, 0, 0, 255))
	src:setPixel(1, 0, image.rgba(0, 255, 0, 255))
	src:setPixel(0, 1, image.rgba(0, 0, 255, 255))
	src:setPixel(1, 1, image.rgba(255, 255, 255, 255))

	local resized = src:resize(3, 3)
	test.expect(resized.width):toBe(3)
	test.expect(resized.height):toBe(3)
	test.expect(resized.format):toBe("rgba8")
	test.expect(resized.metadata.format):toBe("raw")

	src:close()
	resized:close()
end)

suite:test("drawing primitives and blit modes", function()
	local dst = image.new(4, 4, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	dst:clear(image.rgba(10, 20, 30, 255))
	expectColor(dst:getPixel(0, 0), 10, 20, 30, 255)

	dst:fillRect(1, 1, 2, 2, image.rgba(255, 0, 0, 255))
	expectColor(dst:getPixel(1, 1), 255, 0, 0, 255)

	dst:strokeRect(0, 0, 4, 4, image.rgba(0, 255, 0, 255), 1)
	expectColor(dst:getPixel(0, 0), 0, 255, 0, 255)
	expectColor(dst:getPixel(3, 3), 0, 255, 0, 255)

	dst:line(0, 3, 3, 0, image.rgba(0, 0, 255, 255))
	expectColor(dst:getPixel(0, 3), 0, 0, 255, 255)
	expectColor(dst:getPixel(3, 0), 0, 0, 255, 255)

	local src = image.new(1, 1, {
		format = "rgba8",
		color = image.rgba(100, 50, 25, 128),
	})
	dst:setPixel(2, 2, image.rgba(10, 10, 10, 255))
	dst:blit(src, 2, 2, {
		blend = "normal",
		opacity = 1,
	})
	local blended = dst:getPixel(2, 2)
	expectNear(blended.r, 55, 1)
	expectNear(blended.g, 30, 1)
	expectNear(blended.b, 18, 1)

	local drawSrc = image.new(2, 2, {
		format = "rgba8",
		color = image.rgba(1, 2, 3, 255),
	})
	dst:draw(drawSrc, image.rect(0, 0, 2, 2), image.rect(0, 0, 2, 2))
	expectColor(dst:getPixel(0, 0), 1, 2, 3, 255)

	dst:close()
	src:close()
	drawSrc:close()
end)

suite:test("blit source rect, clipping, tint, opacity, and masks", function()
	local dst = image.new(3, 3, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	local src = image.new(3, 1, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	src:setPixel(0, 0, image.rgba(255, 0, 0, 255))
	src:setPixel(1, 0, image.rgba(0, 255, 0, 255))
	src:setPixel(2, 0, image.rgba(0, 0, 255, 255))

	dst:blit(src, image.rect(1, 0, 2, 1), 0, 0)
	expectColor(dst:getPixel(0, 0), 0, 255, 0, 255)
	expectColor(dst:getPixel(1, 0), 0, 0, 255, 255)

	dst:blit(src, -1, 1)
	expectColor(dst:getPixel(0, 1), 0, 255, 0, 255)
	expectColor(dst:getPixel(1, 1), 0, 0, 255, 255)

	local mask = image.new(1, 1, {
		format = "grayAlpha8",
		color = image.gray(255, 0),
	})
	local maskedSource = src:subimage(0, 0, 1, 1)
	dst:setPixel(2, 2, image.rgba(10, 20, 30, 255))
	dst:blit(maskedSource, 2, 2, {
		blend = "normal",
		mask = mask,
	})
	expectColor(dst:getPixel(2, 2), 10, 20, 30, 255)

	local tintedSource = src:subimage(0, 0, 1, 1)
	dst:blit(tintedSource, 2, 2, {
		blend = "replace",
		opacity = 0.5,
		tint = image.rgba(128, 255, 255, 128),
	})
	local tinted = dst:getPixel(2, 2)
	expectNear(tinted.r, 69, 1)
	expectNear(tinted.g, 10, 1)
	expectNear(tinted.b, 15, 1)
	expectNear(tinted.a, 192, 1)

	dst:close()
	src:close()
	mask:close()
	maskedSource:close()
	tintedSource:close()
end)

suite:test("add, multiply, and screen blend modes", function()
	local function blendPixel(mode: string): Color
		local dst = image.new(1, 1, {
			format = "rgba8",
			color = image.rgba(100, 150, 200, 255),
		})
		local src = image.new(1, 1, {
			format = "rgba8",
			color = image.rgba(50, 100, 150, 255),
		})
		local blend: any = mode
		dst:blit(src, 0, 0, {
			blend = blend,
		})
		local out = dst:getPixel(0, 0)
		dst:close()
		src:close()
		return out
	end

	expectColor(blendPixel("add"), 150, 250, 255, 255)
	expectColor(blendPixel("multiply"), 20, 59, 118, 255)
	expectColor(blendPixel("screen"), 130, 191, 232, 255)
end)

suite:test("draw clips partially offscreen destination rectangles", function()
	local dst = image.new(2, 2, {
		format = "rgba8",
		color = image.rgba(0, 0, 0, 255),
	})
	local src = image.new(2, 2, {
		format = "rgba8",
		color = image.rgba(255, 0, 0, 255),
	})

	dst:draw(src, image.rect(0, 0, 2, 2), image.rect(-1, -1, 2, 2))
	expectColor(dst:getPixel(0, 0), 255, 0, 0, 255)
	expectColor(dst:getPixel(1, 1), 0, 0, 0, 255)

	dst:close()
	src:close()
end)

suite:test("effects produce expected pixels", function()
	local img = image.new(1, 1, {
		format = "rgba8",
		color = image.rgba(100, 150, 200, 128),
	})

	local inverted = img:invert()
	expectColor(inverted:getPixel(0, 0), 155, 105, 55, 128)

	local gray = img:grayscale()
	expectColor(gray:getPixel(0, 0), 141, 141, 141, 128)

	local opacity = img:opacity(0.5)
	expectColor(opacity:getPixel(0, 0), 100, 150, 200, 64)

	local bright = img:brightness(0.2)
	expectColor(bright:getPixel(0, 0), 151, 201, 251, 128)

	local contrast = img:contrast(0)
	expectColor(contrast:getPixel(0, 0), 100, 150, 200, 128)

	local threshold = img:threshold(128)
	expectColor(threshold:getPixel(0, 0), 255, 255, 255, 128)

	local matrix = img:colorMatrix({
		0, 0, 0, 0, 10,
		0, 0, 0, 0, 20,
		0, 0, 0, 0, 30,
		0, 0, 0, 1, 0,
	})
	expectColor(matrix:getPixel(0, 0), 10, 20, 30, 128)

	img:close()
	inverted:close()
	gray:close()
	opacity:close()
	bright:close()
	contrast:close()
	threshold:close()
	matrix:close()
end)

suite:test("PNG, WebP, and JPEG encode/decode round trips without fixture files", function()
	local src = image.new(3, 2, {
		format = "rgba8",
		color = image.rgba(20, 40, 60, 255),
	})
	src:setPixel(1, 1, image.rgba(200, 120, 40, 255))

	local png = image.decode(src:encode("png"))
	test.expect(png.metadata.format):toBe("png")
	test.expect(png.metadata.width):toBe(3)
	expectColor(png:getPixel(1, 1), 200, 120, 40, 255)

	local webp = image.decode(src:encode("webp", { lossless = true }))
	test.expect(webp.metadata.format):toBe("webp")
	expectColor(webp:getPixel(1, 1), 200, 120, 40, 255)

	local jpeg = image.decode(src:convert("rgb8"):encode("jpeg", { quality = 95 }))
	test.expect(jpeg.metadata.format):toBe("jpeg")
	test.expect(jpeg.width):toBe(3)
	test.expect(jpeg.height):toBe(2)
	expectColorNear(jpeg:getPixel(1, 1), 200, 120, 40, 80)

	src:close()
	png:close()
	webp:close()
	jpeg:close()
end)

suite:test("save format override writes sniffable files", function()
	tempfile.withTempDir(function(dir)
		local src = image.new(2, 2, {
			format = "rgba8",
			color = image.rgba(30, 60, 90, 255),
		})

		local pngPath = `{dir}/out-png.dat`
		local webpPath = `{dir}/out-webp.bin`
		local jpegPath = `{dir}/out-jpeg.payload`
		src:save(pngPath, { format = "png" })
		src:save(webpPath, { format = "webp", lossless = true })
		src:save(jpegPath, { format = "jpeg", quality = 90 })

		local png = image.open(pngPath)
		local webp = image.open(webpPath)
		local jpeg = image.open(jpegPath)
		test.expect(png.metadata.format):toBe("png")
		test.expect(webp.metadata.format):toBe("webp")
		test.expect(jpeg.metadata.format):toBe("jpeg")

		src:close()
		png:close()
		webp:close()
		jpeg:close()
	end, "image-save")
end)

suite:test("JPEG EXIF orientation and generic tags", function()
	local src = image.new(2, 3, {
		format = "rgb8",
		color = image.rgb(0, 0, 0),
	})
	src:setPixel(0, 0, image.rgb(255, 0, 0))

	local jpeg = withExif(src:encode("jpeg", { quality = 95 }), 6)
	local oriented = image.decode(jpeg)
	local raw = image.decode(jpeg, {
		applyOrientation = false,
	})

	test.expect(oriented.metadata.exif.orientation):toBe(6)
	test.expect(oriented.metadata.exif.make):toBe("TestCam")
	test.expect(oriented.metadata.exif.tags[0x0112]):toBe(6)
	test.expect(oriented.metadata.exif.tags[0x010f]):toBe("TestCam")
	test.expect(oriented.metadata.exif.tags[0x011a]):toBe(72)
	test.expect(oriented.metadata.width):toBe(2)
	test.expect(oriented.metadata.height):toBe(3)
	test.expect(oriented.width):toBe(3)
	test.expect(oriented.height):toBe(2)
	test.expect(raw.width):toBe(2)
	test.expect(raw.height):toBe(3)

	src:close()
	oriented:close()
	raw:close()
end)

suite:test("EXIF generic tags expose arrays, signed numbers, raw bytes, and signed rationals", function()
	local src = image.new(1, 1, {
		format = "rgb8",
		color = image.rgb(10, 20, 30),
	})
	local decoded = image.decode(withRichExif(src:encode("jpeg", { quality = 95 })))
	local tags = decoded.metadata.exif.tags :: { [number]: any }

	test.expect(tags[0x0201]):toBe(7)
	test.expect(tags[0x0202][1]):toBe(1)
	test.expect(tags[0x0202][2]):toBe(2)
	test.expect(tags[0x0202][3]):toBe(3)
	test.expect(function()
		(tags[0x0202] :: any)[1] = 99
	end):toError()
	test.expect(tags[0x0203]):toBe(-42)
	test.expect(buffer.len(tags[0x0204] :: buffer)):toBe(5)
	test.expect(buffer.readu8(tags[0x0204] :: buffer, 0)):toBe(0xaa)
	test.expect(tags[0x0205]):toBe(-1.5)

	src:close()
	decoded:close()
end)

suite:test("malformed EXIF is ignored without failing JPEG decode", function()
	local src = image.new(1, 1, {
		format = "rgb8",
		color = image.rgb(10, 20, 30),
	})
	local decoded = image.decode(withMalformedExif(src:encode("jpeg", { quality = 95 })))

	test.expect(decoded.metadata.format):toBe("jpeg")
	test.expect(decoded.metadata.exif.orientation):toBeNil()
	test.expect(next(decoded.metadata.exif.tags :: { [number]: any })):toBeNil()

	src:close()
	decoded:close()
end)

suite:test("invalid inputs report errors", function()
	local img = image.new(2, 2)

	test.expect(function()
		image.new(0, 1)
	end):toError("dimensions")
	test.expect(function()
		image.new(1, 1, "bad-format")
	end):toError("unsupported pixel format")
	test.expect(function()
		img:getPixel(2, 0)
	end):toError("out of bounds")
	test.expect(function()
		img:crop(1, 1, 2, 2)
	end):toError("out of image bounds")
	test.expect(function()
		local badFilter: any = "lanczos3"
		img:resize(1, 1, { filter = badFilter })
	end):toError("unsupported resize filter")
	test.expect(function()
		local badFormat: any = "gif"
		img:encode(badFormat)
	end):toError("unsupported image format")
	test.expect(function()
		image.decode(buffer.create(0))
	end):toError("empty")

	img:close()
	test.expect(function()
		img:getPixel(0, 0)
	end):toError("closed")
end)

suite:test("fromBuffer validates dimensions, stride, and size", function()
	test.expect(function()
		image.fromBuffer(buffer.create(1), 1, 1, {
			format = "rgb8",
		})
	end):toError("too small")

	test.expect(function()
		image.fromBuffer(buffer.create(8), 2, 2, {
			format = "rgb8",
			stride = 2,
		})
	end):toError("stride")

	test.expect(function()
		image.fromRGBABuffer(buffer.create(4), 1, 1, 3)
	end):toError("only RGBA")
end)

return suite
