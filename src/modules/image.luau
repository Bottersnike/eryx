--[=[
Basic operations for reading and writing images.
]=]

local image = {}

export type Image = {
	--- The width of the image, in pixels
	read width: number,
	--- The height of the image, in pixels
	read height: number,
	--- The number of bytes each pixel uses.
	--- All images are currently loaded in 4-channel RGBA mode.
	read channels: number,
	--- The raw buffer of pixel data, arranged in row-major order
	read pixelBuffer: buffer,

	--- Read a single pixel from an image
	--- @param x The x coordinate. 0-indexed
	--- @param y The y coordinate. 0-indexed
	--- @return Tuple of `{R, G, B, A}`, all in range 0-255
	getPixel: (self: Image, x: number, y: number) -> { number },

	--- Write a single pixel to an image
	--- @param x The x coordinate. 0-indexed
	--- @param y The y coordinate. 0-indexed
	--- @param rgba Tuple of `{R, G, B, A}`, all in range 0-255
	setPixel: (self: Image, x: number, y: number, rgba: { number }) -> (),

	--- Save this image to a file. The format is inferred from the filename.
	---
	--- Supported formats:
	--- - PNG: `.png`
	--- - JPEG: `.jpg`/`.jpeg`
	--- - BMP: `.bmp`
	--- - TGA: `.tga`
	save: (self: Image, path: string, quality: number?) -> (),

	--- Resize an image.
	---
	--- Downsampling an image uses the Mitchell filter, upsampling uses cubic interpolation.
	resize: (self: Image, width: number, height: number) -> Image,
}

--- Open an image from the filesystem. The format is inferred from the filename.
---
--- Supported formats: JPEG, PNG, TGA, BMP, PSD, GIF, HDR, PIC, PNM
function image.open(path: string): Image
	return nil :: any
end

--- Load an image from a buffer.
--- @param pixelData The buffer containing raw pixel data in RGBA format
--- @param width The width of the image in pixels
--- @param height The height of the image in pixels
--- @param channels The number of bytes per pixel. The only legal value for this parameter is `4`
function image.fromRGBABuffer(pixelData: buffer, width: number, height: number, channels: number): Image
	return nil :: any
end

return table.freeze(image)
