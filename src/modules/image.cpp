/**
Image processing.

For file formats:

- libpng for PNGs
- libjpeg-turbo for JPEGs
- libwebp for WEBP
- STB Image for obscure image formats (decode only)

For resizing:

- stb_image_resize2
- In future, we might want to move to libvips, or do it ourselves

For fonts:

- We'll use freetype, but we probably want @eryx/font as a standalone font manipulation layer, which can render an Image for us?
    - Would this make a tight dependency between the C++ side of /image and /font? Would that require a shared native backing?

For image manipulation:

- Basic things like drawing rectangles can probably be done by hand?
- Blit/crop/etc is easiest by hand
- What about more complex things? libvips again or hand-roll? libvips seems potentially overkill?


API overview:

```luau
type PixelFormat =
    "rgba8"
    | "rgb8"
    | "gray8"
    | "grayAlpha8"
type Color = {  -- table?
    r: number,
    g: number,
    b: number?,
    a: number?,
}
type Rect = {  -- table?
    x: number,
    y: number,
    width: number,
    height: number,
}

type DecodeOptions = {  -- table
    format: PixelFormat?,
    applyOrientation: boolean?, -- default true
}
type NewImageOptions = {  -- table
    format: PixelFormat?, -- default "rgba8"
    color: Color?,
}
type BufferImageOptions = {  -- table
    format: PixelFormat, -- "rgba8", "rgb8", "gray8", etc
    stride: number?,
    copy: boolean?, -- default true
}

type ImageFormat = "png" | "jpeg" | "webp"

type EncodeOptions = {  -- table
    format: ImageFormat?, -- save override
    quality: number?, -- jpeg/webp
    lossless: boolean?, -- webp
    progressive: boolean?, -- jpeg
}

type ConvertOptions = {  -- table
    background: Color?, -- for dropping alpha
}

type ResizeFilter = "nearest"

type ResizeOptions = {  -- table
    filter: ResizeFilter?,
    fit: "stretch" | "contain" | "cover"?,
    position: "center" | "topLeft" | "top" | "bottom" | "left" | "right" | "bottomRight"?,
    background: Color?,
}

type BlendMode =
    "replace"
    | "normal"
    | "add"
    | "multiply"
    | "screen"

type BlitOptions = {  -- table
    blend: BlendMode?,
    opacity: number?,
    tint: Color?,
    mask: Image?,
}

type DrawOptions = BlitOptions & {  -- table
}

type LineOptions = { -- table
    thickness: number?,
}

image.open(path: string, options: DecodeOptions?) -> Image
image.decode(data: buffer, options: DecodeOptions?) -> Image
image.new(width: number, height: number, format: PixelFormat) -> Image

image.new(width: number, height: number, options: NewImageOptions?) -> Image
image.fromBuffer(data: buffer, width: number, height: number, options: BufferImageOptions) -> Image

image.rgb(r, g, b) -> Color
image.rgba(r, g, b, a) -> Color
image.gray(v, a?) -> Color
image.rect(x, y, width, height) -> Rect

type Image {  -- Userdata
    width: number
    height: number
    format: PixelFormat
    stride: number
    bounds: Rect

    colorSpace: "srgb" | "linear"
    metadata: ImageMetadata

    -- Luau-owned buffer that contains the backing pixel data (see current impl)
    buffer: buffer

    save: (path: string, options: EncodeOptions?) -> ()
    encode: (format: ImageFormat, options: EncodeOptions?) -> buffer

    clone: () -> Image

    -- Create a new image by cropping
    crop: (x: number, y: number, width: number, height: number) -> Image
    crop: (rect: Rect) -> Image

    -- Create a new view into the existing image
    subimage: (x: number, y: number, width: number, height: number) -> ImageView
    subimage: (rect: Rect) -> ImageView

    getPixel: (x: number, y: number) -> Color
    setPixel: (x: number, y: number, color: Color) -> ()

    convert: (format: PixelFormat, options: ConvertOptions?) -> Image

    resize: (width: number, height: number, options: ResizeOptions?) -> Image
    thumbnail: (maxWidth: number, maxHeight: number, options: ResizeOptions?) -> Image

    flipX: () -> Image
    flipY: () -> Image

    rotate90: () -> Image
    rotate180: () -> Image
    rotate270: () -> Image

    -- TODO: Arbitrary rotation?

    -- Very basic suite of drawing ability:
    blit: (src: Image, x: number, y: number, options: BlitOptions?) -> ()
    blit: (src: Image, srcRect: Rect, dstX: number, dstY: number, options: BlitOptions?) -> ()
    draw: (src: Image, srcRect: Rect, dstRect: Rect, options: DrawOptions?) -> ()

    clear: (color: Color) -> ()

    fillRect: (x: number, y: number, width: number, height: number, color: Color) -> ()
    fillRect: (rect: Rect, color: Color) -> ()

    strokeRect: (x: number, y: number, width: number, height: number, color: Color, thickness: number?) -> ()
    strokeRect: (rect: Rect, color: Color, thickness: number?) -> ()

    line: (x1: number, y1: number, x2: number, y2: number, color: Color, options: LineOptions?) -> ()

    -- Future: Circles

    -- Very basic image effects:
    invert: () -> Image
    grayscale: () -> Image
    brightness: (amount: number) -> Image
    contrast: (amount: number) -> Image
    opacity: (amount: number) -> Image
    threshold: (value: number) -> Image
    colorMatrix: (matrix: {number}) -> Image
}
```
*/

#include "../LuaUtil.hpp"
#include "lualib.h"
#include "module_api.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <utility>
#include <vector>

// Must be here to ensure it's only in a single unit.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_FAILURE_USERMSG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"
#include "png.h"
#include "turbojpeg.h"
#include "webp/decode.h"
#include "webp/encode.h"

// See lbuffer.h in luau/VM/src/
#define MAX_BUFFER_SIZE (1 << 30)

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_image",
};
LUAU_MODULE_INFO()

enum class PixelFormat : uint8_t {
    Rgba8,
    Rgb8,
    Gray8,
    GrayAlpha8,
};

struct Color {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
};

enum class ExifValueKind : uint8_t {
    None,
    String,
    Numbers,
    Bytes,
};

struct ExifTag {
    uint16_t tag = 0;
    uint16_t type = 0;
    ExifValueKind kind = ExifValueKind::None;
    bool integral = false;
    std::string text;
    std::vector<double> numbers;
    std::vector<uint8_t> bytes;
};

struct ExifMetadata {
    bool hasOrientation = false;
    uint16_t orientation = 1;
    std::string make;
    std::string model;
    std::string software;
    std::string dateTime;
    std::string artist;
    std::string copyright;
    std::vector<ExifTag> tags;
};

struct Rect {
    int x;
    int y;
    int width;
    int height;
};

enum class BlendMode : uint8_t {
    Replace,
    Normal,
    Add,
    Multiply,
    Screen,
};

enum class ResizeFit : uint8_t {
    Stretch,
    Contain,
    Cover,
};

enum class ResizePosition : uint8_t {
    Center,
    TopLeft,
    Top,
    Bottom,
    Left,
    Right,
    BottomRight,
};

struct LuaImage;

struct BlitOptions {
    BlendMode blend;
    double opacity;
    Color tint;
    LuaImage* mask;
};

struct DecodeOptions {
    PixelFormat format;
    bool applyOrientation;
};

struct ResizeOptionsNative {
    ResizeFit fit;
    ResizePosition position;
    Color background;
    bool nearest;
};

typedef struct LuaImage {
    uint32_t width;
    uint32_t height;
    PixelFormat format;
    size_t stride;
    uint8_t* pixels;
    lua_State* L;
    int bufferRef;
    int metadataRef;
    bool closed;
    bool view;
} LuaImage;

static const char* IMAGE_METATABLE = "Image";

static const char* format_name(PixelFormat format) {
    switch (format) {
        case PixelFormat::Rgba8:
            return "rgba8";
        case PixelFormat::Rgb8:
            return "rgb8";
        case PixelFormat::Gray8:
            return "gray8";
        case PixelFormat::GrayAlpha8:
            return "grayAlpha8";
    }

    return "rgba8";
}

static int format_channels(PixelFormat format) {
    switch (format) {
        case PixelFormat::Rgba8:
            return 4;
        case PixelFormat::Rgb8:
            return 3;
        case PixelFormat::Gray8:
            return 1;
        case PixelFormat::GrayAlpha8:
            return 2;
    }

    return 4;
}

static bool format_has_alpha(PixelFormat format) {
    return format == PixelFormat::Rgba8 || format == PixelFormat::GrayAlpha8;
}

static PixelFormat check_format(lua_State* L, int idx) {
    const char* s = luaL_checkstring(L, idx);
    if (strcmp(s, "rgba8") == 0) return PixelFormat::Rgba8;
    if (strcmp(s, "rgb8") == 0) return PixelFormat::Rgb8;
    if (strcmp(s, "gray8") == 0) return PixelFormat::Gray8;
    if (strcmp(s, "grayAlpha8") == 0) return PixelFormat::GrayAlpha8;

    luaL_error(L, "unsupported pixel format '%s'", s);
    return PixelFormat::Rgba8;
}

static PixelFormat opt_format_field(lua_State* L, int idx, const char* field, PixelFormat fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    PixelFormat format = check_format(L, -1);
    lua_pop(L, 1);
    return format;
}

static int opt_int_field(lua_State* L, int idx, const char* field, int fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    int value = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    return value;
}

static bool opt_bool_field(lua_State* L, int idx, const char* field, bool fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    bool value = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return value;
}

static uint8_t check_u8(lua_State* L, int idx, const char* name) {
    int value = luaL_checkinteger(L, idx);
    if (value < 0 || value > 255) {
        luaL_error(L, "%s must be in range 0-255", name);
    }
    return (uint8_t)value;
}

static uint8_t opt_u8_field(lua_State* L, int idx, const char* field, uint8_t fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    uint8_t value = check_u8(L, -1, field);
    lua_pop(L, 1);
    return value;
}

static Color check_color(lua_State* L, int idx, Color fallback = {0, 0, 0, 255}) {
    idx = lua_absindex(L, idx);
    luaL_checktype(L, idx, LUA_TTABLE);

    Color c = fallback;
    c.r = opt_u8_field(L, idx, "r", c.r);
    c.g = opt_u8_field(L, idx, "g", c.g);
    c.b = opt_u8_field(L, idx, "b", c.b);
    c.a = opt_u8_field(L, idx, "a", c.a);
    return c;
}

static Rect check_rect(lua_State* L, int idx) {
    idx = lua_absindex(L, idx);
    luaL_checktype(L, idx, LUA_TTABLE);

    Rect r;
    r.x = opt_int_field(L, idx, "x", 0);
    r.y = opt_int_field(L, idx, "y", 0);
    r.width = opt_int_field(L, idx, "width", 0);
    r.height = opt_int_field(L, idx, "height", 0);
    return r;
}

static Rect check_rect_args(lua_State* L, int idx) {
    if (lua_istable(L, idx)) return check_rect(L, idx);

    Rect r;
    r.x = luaL_checkinteger(L, idx);
    r.y = luaL_checkinteger(L, idx + 1);
    r.width = luaL_checkinteger(L, idx + 2);
    r.height = luaL_checkinteger(L, idx + 3);
    return r;
}

static void push_color(lua_State* L, Color c) {
    lua_createtable(L, 0, 4);
    lua_pushinteger(L, c.r);
    lua_setfield(L, -2, "r");
    lua_pushinteger(L, c.g);
    lua_setfield(L, -2, "g");
    lua_pushinteger(L, c.b);
    lua_setfield(L, -2, "b");
    lua_pushinteger(L, c.a);
    lua_setfield(L, -2, "a");
    lua_setreadonly(L, -1, true);
}

static void push_rect(lua_State* L, Rect r) {
    lua_createtable(L, 0, 4);
    lua_pushinteger(L, r.x);
    lua_setfield(L, -2, "x");
    lua_pushinteger(L, r.y);
    lua_setfield(L, -2, "y");
    lua_pushinteger(L, r.width);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, r.height);
    lua_setfield(L, -2, "height");
    lua_setreadonly(L, -1, true);
}

static bool checked_image_size(lua_State* L, uint32_t width, uint32_t height, PixelFormat format, size_t stride) {
    if (width == 0 || height == 0) {
        luaL_error(L, "image dimensions must be positive");
        return false;
    }

    size_t minStride = (size_t)width * format_channels(format);
    if (stride < minStride) {
        luaL_error(L, "stride must be at least width * bytesPerPixel");
        return false;
    }

    if (height > 0 && stride > (size_t)MAX_BUFFER_SIZE / height) {
        luaL_error(L, "image is too large for a Luau buffer");
        return false;
    }

    return true;
}

static uint8_t* pixel_at(const LuaImage* i, int x, int y) {
    return i->pixels + (size_t)y * i->stride + (size_t)x * format_channels(i->format);
}

static Color read_pixel(const LuaImage* i, int x, int y) {
    const uint8_t* p = pixel_at(i, x, y);
    switch (i->format) {
        case PixelFormat::Rgba8:
            return {p[0], p[1], p[2], p[3]};
        case PixelFormat::Rgb8:
            return {p[0], p[1], p[2], 255};
        case PixelFormat::Gray8:
            return {p[0], p[0], p[0], 255};
        case PixelFormat::GrayAlpha8:
            return {p[0], p[0], p[0], p[1]};
    }

    return {0, 0, 0, 255};
}

static uint8_t luminance(Color c) {
    return (uint8_t)std::clamp((int)std::round(0.299 * c.r + 0.587 * c.g + 0.114 * c.b), 0, 255);
}

static uint8_t composite_channel(uint8_t src, uint8_t alpha, uint8_t bg) {
    int inv = 255 - alpha;
    return (uint8_t)((src * alpha + bg * inv + 127) / 255);
}

static Color composite_over(Color src, Color bg) {
    if (src.a == 255) return src;
    if (src.a == 0) return {bg.r, bg.g, bg.b, 255};

    return {
        composite_channel(src.r, src.a, bg.r),
        composite_channel(src.g, src.a, bg.g),
        composite_channel(src.b, src.a, bg.b),
        255,
    };
}

static void write_pixel(LuaImage* i, int x, int y, Color c) {
    uint8_t* p = pixel_at(i, x, y);
    switch (i->format) {
        case PixelFormat::Rgba8:
            p[0] = c.r;
            p[1] = c.g;
            p[2] = c.b;
            p[3] = c.a;
            return;
        case PixelFormat::Rgb8:
            p[0] = c.r;
            p[1] = c.g;
            p[2] = c.b;
            return;
        case PixelFormat::Gray8:
            p[0] = luminance(c);
            return;
        case PixelFormat::GrayAlpha8:
            p[0] = luminance(c);
            p[1] = c.a;
            return;
    }
}

static void image_release(LuaImage* i) {
    if (!i || i->closed) return;

    if (i->bufferRef != LUA_NOREF) {
        lua_unref(i->L, i->bufferRef);
        i->bufferRef = LUA_NOREF;
    }
    if (i->metadataRef != LUA_NOREF) {
        lua_unref(i->L, i->metadataRef);
        i->metadataRef = LUA_NOREF;
    }

    i->pixels = nullptr;
    i->closed = true;
}

static void image_dtor(void* ud) {
    image_release((LuaImage*)ud);
}

static LuaImage* check_image(lua_State* L, int idx) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, idx, IMAGE_METATABLE);
    if (i->closed || !i->pixels) {
        luaL_error(L, "attempt to use a closed image");
    }
    return i;
}

static double opt_number_field(lua_State* L, int idx, const char* field, double fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    double value = luaL_checknumber(L, -1);
    lua_pop(L, 1);
    return value;
}

static BlendMode check_blend_mode(lua_State* L, int idx) {
    const char* s = luaL_checkstring(L, idx);
    if (strcmp(s, "replace") == 0) return BlendMode::Replace;
    if (strcmp(s, "normal") == 0) return BlendMode::Normal;
    if (strcmp(s, "add") == 0) return BlendMode::Add;
    if (strcmp(s, "multiply") == 0) return BlendMode::Multiply;
    if (strcmp(s, "screen") == 0) return BlendMode::Screen;

    luaL_error(L, "unsupported blend mode '%s'", s);
    return BlendMode::Normal;
}

static BlendMode opt_blend_field(lua_State* L, int idx, const char* field, BlendMode fallback) {
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    BlendMode value = check_blend_mode(L, -1);
    lua_pop(L, 1);
    return value;
}

static ResizeFit check_resize_fit(lua_State* L, int idx) {
    const char* s = luaL_checkstring(L, idx);
    if (strcmp(s, "stretch") == 0) return ResizeFit::Stretch;
    if (strcmp(s, "contain") == 0) return ResizeFit::Contain;
    if (strcmp(s, "cover") == 0) return ResizeFit::Cover;

    luaL_error(L, "unsupported resize fit '%s'", s);
    return ResizeFit::Stretch;
}

static ResizePosition check_resize_position(lua_State* L, int idx) {
    const char* s = luaL_checkstring(L, idx);
    if (strcmp(s, "center") == 0) return ResizePosition::Center;
    if (strcmp(s, "topLeft") == 0) return ResizePosition::TopLeft;
    if (strcmp(s, "top") == 0) return ResizePosition::Top;
    if (strcmp(s, "bottom") == 0) return ResizePosition::Bottom;
    if (strcmp(s, "left") == 0) return ResizePosition::Left;
    if (strcmp(s, "right") == 0) return ResizePosition::Right;
    if (strcmp(s, "bottomRight") == 0) return ResizePosition::BottomRight;

    luaL_error(L, "unsupported resize position '%s'", s);
    return ResizePosition::Center;
}

static ResizeOptionsNative parse_resize_options(lua_State* L, int idx) {
    ResizeOptionsNative opts;
    opts.fit = ResizeFit::Stretch;
    opts.position = ResizePosition::Center;
    opts.background = {0, 0, 0, 0};
    opts.nearest = false;

    if (lua_isnoneornil(L, idx)) return opts;
    idx = lua_absindex(L, idx);
    luaL_checktype(L, idx, LUA_TTABLE);

    lua_getfield(L, idx, "fit");
    if (!lua_isnil(L, -1)) {
        opts.fit = check_resize_fit(L, -1);
    }
    lua_pop(L, 1);

    lua_getfield(L, idx, "position");
    if (!lua_isnil(L, -1)) {
        opts.position = check_resize_position(L, -1);
    }
    lua_pop(L, 1);

    lua_getfield(L, idx, "background");
    if (!lua_isnil(L, -1)) {
        opts.background = check_color(L, -1, opts.background);
    }
    lua_pop(L, 1);

    lua_getfield(L, idx, "filter");
    if (!lua_isnil(L, -1)) {
        const char* filter = luaL_checkstring(L, -1);
        if (strcmp(filter, "nearest") == 0) {
            opts.nearest = true;
        } else {
            luaL_error(L, "unsupported resize filter '%s'", filter);
        }
    }
    lua_pop(L, 1);

    return opts;
}

static BlitOptions parse_blit_options(lua_State* L, int idx) {
    BlitOptions opts;
    opts.blend = BlendMode::Replace;
    opts.opacity = 1.0;
    opts.tint = {255, 255, 255, 255};
    opts.mask = nullptr;

    if (lua_isnoneornil(L, idx)) return opts;
    idx = lua_absindex(L, idx);
    luaL_checktype(L, idx, LUA_TTABLE);

    opts.blend = opt_blend_field(L, idx, "blend", opts.blend);
    opts.opacity = std::clamp(opt_number_field(L, idx, "opacity", opts.opacity), 0.0, 1.0);

    lua_getfield(L, idx, "tint");
    if (!lua_isnil(L, -1)) {
        opts.tint = check_color(L, -1, opts.tint);
    }
    lua_pop(L, 1);

    lua_getfield(L, idx, "mask");
    if (!lua_isnil(L, -1)) {
        opts.mask = check_image(L, -1);
    }
    lua_pop(L, 1);

    return opts;
}

static uint8_t blend_channel(double value) {
    return (uint8_t)std::clamp((int)std::round(value), 0, 255);
}

static Color tint_color(Color c, Color tint) {
    c.r = (uint8_t)((int)c.r * tint.r / 255);
    c.g = (uint8_t)((int)c.g * tint.g / 255);
    c.b = (uint8_t)((int)c.b * tint.b / 255);
    c.a = (uint8_t)((int)c.a * tint.a / 255);
    return c;
}

static Color blend_colors(Color dst, Color src, const BlitOptions& opts, double maskAlpha) {
    src = tint_color(src, opts.tint);
    double coverage = std::clamp(opts.opacity * maskAlpha, 0.0, 1.0);
    double alpha = (src.a / 255.0) * coverage;

    if (opts.blend == BlendMode::Replace) {
        if (coverage >= 1.0) return src;
        return {
            blend_channel(dst.r * (1.0 - coverage) + src.r * coverage),
            blend_channel(dst.g * (1.0 - coverage) + src.g * coverage),
            blend_channel(dst.b * (1.0 - coverage) + src.b * coverage),
            blend_channel(dst.a * (1.0 - coverage) + src.a * coverage),
        };
    }

    auto blendBase = [&](uint8_t d, uint8_t s) -> double {
        switch (opts.blend) {
            case BlendMode::Add:
                return std::min(255, (int)d + (int)s);
            case BlendMode::Multiply:
                return (double)d * s / 255.0;
            case BlendMode::Screen:
                return 255.0 - ((255.0 - d) * (255.0 - s) / 255.0);
            case BlendMode::Normal:
            case BlendMode::Replace:
                return s;
        }
        return s;
    };

    double outA = alpha + (dst.a / 255.0) * (1.0 - alpha);
    return {
        blend_channel(dst.r * (1.0 - alpha) + blendBase(dst.r, src.r) * alpha),
        blend_channel(dst.g * (1.0 - alpha) + blendBase(dst.g, src.g) * alpha),
        blend_channel(dst.b * (1.0 - alpha) + blendBase(dst.b, src.b) * alpha),
        blend_channel(outA * 255.0),
    };
}

static void write_blended_pixel(LuaImage* dst, int x, int y, Color src, const BlitOptions& opts, int maskX, int maskY) {
    double maskAlpha = 1.0;
    if (opts.mask) {
        if (maskX < 0 || maskY < 0 || maskX >= (int)opts.mask->width || maskY >= (int)opts.mask->height) return;
        maskAlpha = read_pixel(opts.mask, maskX, maskY).a / 255.0;
    }

    Color dstColor = read_pixel(dst, x, y);
    write_pixel(dst, x, y, blend_colors(dstColor, src, opts, maskAlpha));
}

static void attach_metatable(lua_State* L) {
    luaL_getmetatable(L, IMAGE_METATABLE);
    lua_setmetatable(L, -2);
}

static void push_optional_string_field(lua_State* L, const char* field, const std::string& value) {
    if (value.empty()) return;
    lua_pushlstring(L, value.data(), value.size());
    lua_setfield(L, -2, field);
}

static void push_exif_number_list(lua_State* L, const ExifTag& tag) {
    if (tag.numbers.size() == 1) {
        if (tag.integral) {
            lua_pushinteger(L, (lua_Integer)tag.numbers[0]);
        } else {
            lua_pushnumber(L, tag.numbers[0]);
        }
        return;
    }

    lua_createtable(L, (int)tag.numbers.size(), 0);
    for (size_t i = 0; i < tag.numbers.size(); i++) {
        if (tag.integral) {
            lua_pushinteger(L, (lua_Integer)tag.numbers[i]);
        } else {
            lua_pushnumber(L, tag.numbers[i]);
        }
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setreadonly(L, -1, true);
}

static void push_exif_tag_value(lua_State* L, const ExifTag& tag) {
    switch (tag.kind) {
        case ExifValueKind::String:
            lua_pushlstring(L, tag.text.data(), tag.text.size());
            return;
        case ExifValueKind::Numbers:
            push_exif_number_list(L, tag);
            return;
        case ExifValueKind::Bytes: {
            void* out = lua_newbuffer(L, tag.bytes.size());
            if (!tag.bytes.empty()) {
                memcpy(out, tag.bytes.data(), tag.bytes.size());
            }
            return;
        }
        case ExifValueKind::None:
            lua_pushnil(L);
            return;
    }
}

static void push_exif_tags_table(lua_State* L, const ExifMetadata* exif) {
    lua_createtable(L, 0, 0);
    if (exif) {
        for (const ExifTag& tag : exif->tags) {
            push_exif_tag_value(L, tag);
            lua_rawseti(L, -2, tag.tag);
        }
    }
    lua_setreadonly(L, -1, true);
}

static void push_exif_table(lua_State* L, const ExifMetadata* exif) {
    lua_createtable(L, 0, 8);
    if (exif) {
        if (exif->hasOrientation) {
            lua_pushinteger(L, exif->orientation);
            lua_setfield(L, -2, "orientation");
        }
        push_optional_string_field(L, "make", exif->make);
        push_optional_string_field(L, "model", exif->model);
        push_optional_string_field(L, "software", exif->software);
        push_optional_string_field(L, "dateTime", exif->dateTime);
        push_optional_string_field(L, "artist", exif->artist);
        push_optional_string_field(L, "copyright", exif->copyright);

        push_exif_tags_table(L, exif);
        lua_setfield(L, -2, "tags");
    }
    lua_setreadonly(L, -1, true);
}

static int make_metadata_ref(lua_State* L, const char* format, int originalChannels = 0, const char* source = nullptr, const ExifMetadata* exif = nullptr, int width = 0, int height = 0) {
    lua_createtable(L, 0, 6);
    if (format) {
        lua_pushstring(L, format);
        lua_setfield(L, -2, "format");
    }
    if (width > 0) {
        lua_pushinteger(L, width);
        lua_setfield(L, -2, "width");
    }
    if (height > 0) {
        lua_pushinteger(L, height);
        lua_setfield(L, -2, "height");
    }
    if (originalChannels > 0) {
        lua_pushinteger(L, originalChannels);
        lua_setfield(L, -2, "originalChannels");
    }
    if (source) {
        lua_pushstring(L, source);
        lua_setfield(L, -2, "source");
    }

    push_exif_table(L, exif);
    lua_setfield(L, -2, "exif");

    lua_setreadonly(L, -1, true);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);
    return ref;
}

static LuaImage* new_image_userdata(lua_State* L, uint32_t width, uint32_t height, PixelFormat format, size_t stride, int metadataRef) {
    checked_image_size(L, width, height, format, stride);

    LuaImage* i = (LuaImage*)lua_newuserdatadtor(L, sizeof(LuaImage), image_dtor);
    i->width = width;
    i->height = height;
    i->format = format;
    i->stride = stride;
    i->pixels = nullptr;
    i->L = L;
    i->bufferRef = LUA_NOREF;
    i->metadataRef = metadataRef;
    i->closed = false;
    i->view = false;
    attach_metatable(L);
    return i;
}

static LuaImage* new_owned_image(lua_State* L, uint32_t width, uint32_t height, PixelFormat format, int metadataRef) {
    size_t stride = (size_t)width * format_channels(format);
    LuaImage* i = new_image_userdata(L, width, height, format, stride, metadataRef);

    void* bufferData = lua_newbuffer(L, stride * height);
    i->pixels = (uint8_t*)bufferData;
    i->bufferRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return i;
}

static void copy_image_pixels(LuaImage* dst, const LuaImage* src) {
    for (uint32_t y = 0; y < dst->height; y++) {
        for (uint32_t x = 0; x < dst->width; x++) {
            write_pixel(dst, x, y, read_pixel(src, x, y));
        }
    }
}

static void copy_image_pixels(LuaImage* dst, const LuaImage* src, Color background) {
    for (uint32_t y = 0; y < dst->height; y++) {
        for (uint32_t x = 0; x < dst->width; x++) {
            write_pixel(dst, x, y, composite_over(read_pixel(src, x, y), background));
        }
    }
}

static void write_oriented_pixel(LuaImage* dst, const LuaImage* src, uint32_t x, uint32_t y, uint16_t orientation) {
    uint32_t dx = x;
    uint32_t dy = y;

    switch (orientation) {
        case 2:
            dx = src->width - x - 1;
            dy = y;
            break;
        case 3:
            dx = src->width - x - 1;
            dy = src->height - y - 1;
            break;
        case 4:
            dx = x;
            dy = src->height - y - 1;
            break;
        case 5:
            dx = y;
            dy = x;
            break;
        case 6:
            dx = src->height - y - 1;
            dy = x;
            break;
        case 7:
            dx = src->height - y - 1;
            dy = src->width - x - 1;
            break;
        case 8:
            dx = y;
            dy = src->width - x - 1;
            break;
        default:
            break;
    }

    write_pixel(dst, (int)dx, (int)dy, read_pixel(src, (int)x, (int)y));
}

static void copy_image_pixels_oriented(LuaImage* dst, const LuaImage* src, uint16_t orientation) {
    if (orientation < 1 || orientation > 8) orientation = 1;
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_oriented_pixel(dst, src, x, y, orientation);
        }
    }
}

static bool rect_in_bounds(const LuaImage* i, Rect r) {
    if (r.width <= 0 || r.height <= 0 || r.x < 0 || r.y < 0) return false;
    if (r.x > (int)i->width || r.y > (int)i->height) return false;
    if (r.width > (int)i->width - r.x || r.height > (int)i->height - r.y) return false;
    return true;
}

static void check_rect_in_bounds(lua_State* L, const LuaImage* i, Rect r) {
    if (!rect_in_bounds(i, r)) {
        luaL_error(L, "rectangle is out of image bounds");
    }
}

static std::string lower_ext(const std::string& path) {
    size_t dot = path.find_last_of('.');
    if (dot == std::string::npos) return "";
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return ext;
}

static bool read_file_bytes(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return false;

    file.seekg(0, std::ios::end);
    std::streamoff size = file.tellg();
    if (size < 0) return false;
    file.seekg(0, std::ios::beg);

    out.resize((size_t)size);
    if (size > 0) {
        file.read((char*)out.data(), size);
        if (!file) return false;
    }
    return true;
}

static void write_file_bytes(lua_State* L, const std::string& path, const std::vector<uint8_t>& bytes) {
    std::ofstream file(path, std::ios::binary);
    if (!file) luaL_error(L, "failed to open %s for writing", path.c_str());
    file.write((const char*)bytes.data(), (std::streamsize)bytes.size());
    if (!file) luaL_error(L, "failed to write %s", path.c_str());
}

static PixelFormat parse_new_format(lua_State* L, int idx) {
    if (lua_isstring(L, idx)) return check_format(L, idx);
    if (lua_istable(L, idx)) return opt_format_field(L, idx, "format", PixelFormat::Rgba8);
    if (lua_isnoneornil(L, idx)) return PixelFormat::Rgba8;

    luaL_typeerror(L, idx, "PixelFormat or NewImageOptions");
    return PixelFormat::Rgba8;
}

static Color parse_new_color(lua_State* L, int idx) {
    if (!lua_istable(L, idx)) return {0, 0, 0, 0};
    lua_getfield(L, idx, "color");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return {0, 0, 0, 0};
    }
    Color c = check_color(L, -1, {0, 0, 0, 255});
    lua_pop(L, 1);
    return c;
}

static DecodeOptions parse_decode_options(lua_State* L, int idx) {
    DecodeOptions opts;
    opts.format = PixelFormat::Rgba8;
    opts.applyOrientation = true;
    if (!lua_istable(L, idx)) return opts;

    opts.format = opt_format_field(L, idx, "format", opts.format);
    opts.applyOrientation = opt_bool_field(L, idx, "applyOrientation", opts.applyOrientation);
    return opts;
}

static int stbi_channels_for_format(PixelFormat format) {
    return format_channels(format);
}

static png_uint_32 png_format_for_image(PixelFormat format) {
    switch (format) {
        case PixelFormat::Rgba8:
            return PNG_FORMAT_RGBA;
        case PixelFormat::Rgb8:
            return PNG_FORMAT_RGB;
        case PixelFormat::Gray8:
            return PNG_FORMAT_GRAY;
        case PixelFormat::GrayAlpha8:
            return PNG_FORMAT_GA;
    }
    return PNG_FORMAT_RGBA;
}

static LuaImage* image_from_stbi(lua_State* L, stbi_uc* data, int w, int h, int sourceChannels, PixelFormat format, const char* codec, const char* source) {
    if (!data) {
        luaL_error(L, "failed to decode image: %s", stbi_failure_reason());
        return nullptr;
    }
    if (w <= 0 || h <= 0) {
        stbi_image_free(data);
        luaL_error(L, "decoded image has invalid dimensions");
        return nullptr;
    }

    int channels = format_channels(format);
    size_t stride = (size_t)w * channels;
    if (stride > (size_t)MAX_BUFFER_SIZE / (size_t)h) {
        stbi_image_free(data);
        luaL_error(L, "decoded image is too large for a Luau buffer");
        return nullptr;
    }

    int metadataRef = make_metadata_ref(L, codec, sourceChannels, source, nullptr, w, h);
    LuaImage* i = new_owned_image(L, (uint32_t)w, (uint32_t)h, format, metadataRef);
    memcpy(i->pixels, data, stride * (size_t)h);
    stbi_image_free(data);
    return i;
}

static LuaImage* image_from_png_memory(lua_State* L, const uint8_t* bytes, size_t len, PixelFormat format, const char* source) {
    png_image png;
    memset(&png, 0, sizeof(png));
    png.version = PNG_IMAGE_VERSION;

    if (!png_image_begin_read_from_memory(&png, bytes, len)) {
        luaL_error(L, "failed to decode PNG image: %s", png.message);
        return nullptr;
    }

    png.format = png_format_for_image(format);
    checked_image_size(L, png.width, png.height, format, (size_t)png.width * format_channels(format));

    LuaImage* i = new_owned_image(L, png.width, png.height, format, make_metadata_ref(L, "png", format_channels(format), source, nullptr, png.width, png.height));
    if (!png_image_finish_read(&png, nullptr, i->pixels, (png_int_32)i->stride, nullptr)) {
        std::string message = png.message;
        image_release(i);
        luaL_error(L, "failed to decode PNG image: %s", message.c_str());
        return nullptr;
    }

    return i;
}

static LuaImage* image_from_png_file(lua_State* L, const std::string& path, PixelFormat format) {
    png_image png;
    memset(&png, 0, sizeof(png));
    png.version = PNG_IMAGE_VERSION;

    if (!png_image_begin_read_from_file(&png, path.c_str())) {
        luaL_error(L, "failed to decode %s: %s", path.c_str(), png.message);
        return nullptr;
    }

    png.format = png_format_for_image(format);
    checked_image_size(L, png.width, png.height, format, (size_t)png.width * format_channels(format));

    LuaImage* i = new_owned_image(L, png.width, png.height, format, make_metadata_ref(L, "png", format_channels(format), path.c_str(), nullptr, png.width, png.height));
    if (!png_image_finish_read(&png, nullptr, i->pixels, (png_int_32)i->stride, nullptr)) {
        std::string message = png.message;
        image_release(i);
        luaL_error(L, "failed to decode %s: %s", path.c_str(), message.c_str());
        return nullptr;
    }

    return i;
}

static ExifMetadata parse_jpeg_exif(const uint8_t* bytes, size_t len);

static LuaImage* image_from_jpeg_memory(lua_State* L, const uint8_t* bytes, size_t len, DecodeOptions options, const char* source) {
    tjhandle handle = tjInitDecompress();
    if (!handle) {
        luaL_error(L, "failed to initialize JPEG decoder: %s", tjGetErrorStr());
        return nullptr;
    }

    int w = 0;
    int h = 0;
    int subsamp = TJSAMP_UNKNOWN;
    int colorspace = TJCS_DEFAULT;
    if (tjDecompressHeader3(handle, bytes, len, &w, &h, &subsamp, &colorspace) != 0) {
        std::string message = tjGetErrorStr2(handle);
        tjDestroy(handle);
        luaL_error(L, "failed to decode JPEG image: %s", message.c_str());
        return nullptr;
    }
    if (w <= 0 || h <= 0) {
        tjDestroy(handle);
        luaL_error(L, "decoded JPEG image has invalid dimensions");
        return nullptr;
    }
    if ((size_t)w * 4 > (size_t)MAX_BUFFER_SIZE / (size_t)h) {
        tjDestroy(handle);
        luaL_error(L, "decoded JPEG image is too large for a Luau buffer");
        return nullptr;
    }

    std::vector<uint8_t> rgba((size_t)w * h * 4);
    if (tjDecompress2(handle, bytes, len, rgba.data(), w, w * 4, h, TJPF_RGBA, 0) != 0) {
        std::string message = tjGetErrorStr2(handle);
        tjDestroy(handle);
        luaL_error(L, "failed to decode JPEG image: %s", message.c_str());
        return nullptr;
    }
    tjDestroy(handle);

    LuaImage tmp;
    tmp.width = (uint32_t)w;
    tmp.height = (uint32_t)h;
    tmp.format = PixelFormat::Rgba8;
    tmp.stride = (size_t)w * 4;
    tmp.pixels = rgba.data();
    tmp.L = L;
    tmp.bufferRef = LUA_NOREF;
    tmp.metadataRef = LUA_NOREF;
    tmp.closed = false;
    tmp.view = false;

    ExifMetadata exif = parse_jpeg_exif(bytes, len);
    uint32_t outWidth = (uint32_t)w;
    uint32_t outHeight = (uint32_t)h;
    if (options.applyOrientation && exif.hasOrientation && exif.orientation >= 5 && exif.orientation <= 8) {
        outWidth = (uint32_t)h;
        outHeight = (uint32_t)w;
    }

    LuaImage* i = new_owned_image(L, outWidth, outHeight, options.format, make_metadata_ref(L, "jpeg", 3, source, &exif, w, h));
    copy_image_pixels_oriented(i, &tmp, options.applyOrientation && exif.hasOrientation ? exif.orientation : 1);
    return i;
}

static LuaImage* image_from_jpeg_file(lua_State* L, const std::string& path, DecodeOptions options) {
    std::vector<uint8_t> bytes;
    if (!read_file_bytes(path, bytes)) {
        luaL_error(L, "failed to read %s", path.c_str());
    }
    return image_from_jpeg_memory(L, bytes.data(), bytes.size(), options, path.c_str());
}

static LuaImage* image_from_webp(lua_State* L, const uint8_t* bytes, size_t len, PixelFormat format, const char* source) {
    int w = 0;
    int h = 0;
    if (!WebPGetInfo(bytes, len, &w, &h)) {
        luaL_error(L, "failed to decode WEBP image: invalid WEBP data");
        return nullptr;
    }
    if (w <= 0 || h <= 0) {
        luaL_error(L, "decoded WEBP image has invalid dimensions");
        return nullptr;
    }
    if ((size_t)w * 4 > (size_t)MAX_BUFFER_SIZE / (size_t)h) {
        luaL_error(L, "decoded WEBP image is too large for a Luau buffer");
        return nullptr;
    }

    uint8_t* decoded = WebPDecodeRGBA(bytes, len, &w, &h);
    if (!decoded) {
        luaL_error(L, "failed to decode WEBP image");
        return nullptr;
    }

    LuaImage tmp;
    tmp.width = (uint32_t)w;
    tmp.height = (uint32_t)h;
    tmp.format = PixelFormat::Rgba8;
    tmp.stride = (size_t)w * 4;
    tmp.pixels = decoded;
    tmp.L = L;
    tmp.bufferRef = LUA_NOREF;
    tmp.metadataRef = LUA_NOREF;
    tmp.closed = false;
    tmp.view = false;

    LuaImage* i = new_owned_image(L, (uint32_t)w, (uint32_t)h, format, make_metadata_ref(L, "webp", 4, source, nullptr, w, h));
    copy_image_pixels(i, &tmp);
    WebPFree(decoded);
    return i;
}

static bool looks_like_webp(const uint8_t* bytes, size_t len) {
    if (len < 12) return false;
    return memcmp(bytes, "RIFF", 4) == 0 && memcmp(bytes + 8, "WEBP", 4) == 0;
}

static bool looks_like_png(const uint8_t* bytes, size_t len) {
    static const uint8_t sig[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    return len >= sizeof(sig) && memcmp(bytes, sig, sizeof(sig)) == 0;
}

static bool looks_like_jpeg(const uint8_t* bytes, size_t len) {
    return len >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
}

static uint16_t exif_u16(const uint8_t* p, bool le) {
    if (le) return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    return ((uint16_t)p[0] << 8) | (uint16_t)p[1];
}

static uint32_t exif_u32(const uint8_t* p, bool le) {
    if (le) return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int32_t exif_i32(const uint8_t* p, bool le) {
    return (int32_t)exif_u32(p, le);
}

static size_t exif_type_size(uint16_t type) {
    switch (type) {
        case 1:
        case 2:
        case 7:
            return 1;
        case 3:
            return 2;
        case 4:
        case 9:
            return 4;
        case 5:
        case 10:
            return 8;
        default:
            return 0;
    }
}

static bool exif_entry_data(const uint8_t* tiff, size_t tiffLen, const uint8_t* entry, bool le, const uint8_t** data, size_t* size) {
    uint16_t type = exif_u16(entry + 2, le);
    uint32_t count = exif_u32(entry + 4, le);
    size_t typeSize = exif_type_size(type);
    if (typeSize == 0 || count > SIZE_MAX / typeSize) return false;
    *size = count * typeSize;

    if (*size <= 4) {
        *data = entry + 8;
        return true;
    }

    uint32_t offset = exif_u32(entry + 8, le);
    if (offset > tiffLen || *size > tiffLen - offset) return false;
    *data = tiff + offset;
    return true;
}

static std::string exif_ascii(const uint8_t* data, size_t size) {
    while (size > 0 && data[size - 1] == 0) size--;
    return std::string((const char*)data, size);
}

static ExifTag parse_exif_tag_value(uint16_t tagId, uint16_t type, uint32_t count, const uint8_t* data, size_t size, bool le) {
    ExifTag tag;
    tag.tag = tagId;
    tag.type = type;

    switch (type) {
        case 1:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = true;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && i < size; i++) {
                tag.numbers.push_back(data[i]);
            }
            break;
        case 2:
            tag.kind = ExifValueKind::String;
            tag.text = exif_ascii(data, size);
            break;
        case 3:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = true;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && (size_t)i * 2 + 2 <= size; i++) {
                tag.numbers.push_back(exif_u16(data + (size_t)i * 2, le));
            }
            break;
        case 4:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = true;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && (size_t)i * 4 + 4 <= size; i++) {
                tag.numbers.push_back(exif_u32(data + (size_t)i * 4, le));
            }
            break;
        case 5:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = false;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && (size_t)i * 8 + 8 <= size; i++) {
                uint32_t numerator = exif_u32(data + (size_t)i * 8, le);
                uint32_t denominator = exif_u32(data + (size_t)i * 8 + 4, le);
                tag.numbers.push_back(denominator == 0 ? 0.0 : (double)numerator / denominator);
            }
            break;
        case 7:
            tag.kind = ExifValueKind::Bytes;
            tag.bytes.assign(data, data + size);
            break;
        case 9:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = true;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && (size_t)i * 4 + 4 <= size; i++) {
                tag.numbers.push_back(exif_i32(data + (size_t)i * 4, le));
            }
            break;
        case 10:
            tag.kind = ExifValueKind::Numbers;
            tag.integral = false;
            tag.numbers.reserve(count);
            for (uint32_t i = 0; i < count && (size_t)i * 8 + 8 <= size; i++) {
                int32_t numerator = exif_i32(data + (size_t)i * 8, le);
                int32_t denominator = exif_i32(data + (size_t)i * 8 + 4, le);
                tag.numbers.push_back(denominator == 0 ? 0.0 : (double)numerator / denominator);
            }
            break;
    }

    if ((tag.kind == ExifValueKind::Numbers && tag.numbers.empty()) || (tag.kind == ExifValueKind::Bytes && tag.bytes.empty())) {
        tag.kind = ExifValueKind::None;
    }
    return tag;
}

static void parse_exif_ifd(const uint8_t* tiff, size_t tiffLen, uint32_t ifdOffset, bool le, ExifMetadata& out, int depth) {
    if (depth > 4 || ifdOffset > tiffLen || tiffLen - ifdOffset < 2) return;

    const uint8_t* ifd = tiff + ifdOffset;
    uint16_t count = exif_u16(ifd, le);
    if (count > (tiffLen - ifdOffset - 2) / 12) return;

    for (uint16_t i = 0; i < count; i++) {
        const uint8_t* entry = ifd + 2 + (size_t)i * 12;
        uint16_t tag = exif_u16(entry, le);
        uint16_t type = exif_u16(entry + 2, le);
        uint32_t valueCount = exif_u32(entry + 4, le);
        const uint8_t* data = nullptr;
        size_t size = 0;
        if (!exif_entry_data(tiff, tiffLen, entry, le, &data, &size)) continue;

        ExifTag genericTag = parse_exif_tag_value(tag, type, valueCount, data, size, le);
        if (genericTag.kind != ExifValueKind::None) {
            out.tags.push_back(std::move(genericTag));
        }

        if (tag == 0x0112 && type == 3 && valueCount >= 1 && size >= 2) {
            out.orientation = exif_u16(data, le);
            out.hasOrientation = true;
        } else if (type == 2) {
            std::string value = exif_ascii(data, size);
            switch (tag) {
                case 0x010f:
                    out.make = value;
                    break;
                case 0x0110:
                    out.model = value;
                    break;
                case 0x0131:
                    out.software = value;
                    break;
                case 0x0132:
                    out.dateTime = value;
                    break;
                case 0x013b:
                    out.artist = value;
                    break;
                case 0x8298:
                    out.copyright = value;
                    break;
            }
        } else if ((tag == 0x8769 || tag == 0x8825) && type == 4 && valueCount >= 1 && size >= 4) {
            parse_exif_ifd(tiff, tiffLen, exif_u32(data, le), le, out, depth + 1);
        }
    }

    size_t nextOffsetPos = ifdOffset + 2 + (size_t)count * 12;
    if (nextOffsetPos + 4 <= tiffLen) {
        uint32_t nextIfd = exif_u32(tiff + nextOffsetPos, le);
        if (nextIfd != 0) {
            parse_exif_ifd(tiff, tiffLen, nextIfd, le, out, depth + 1);
        }
    }
}

static ExifMetadata parse_exif_payload(const uint8_t* data, size_t len) {
    ExifMetadata out;
    if (len < 14 || memcmp(data, "Exif\0\0", 6) != 0) return out;

    const uint8_t* tiff = data + 6;
    size_t tiffLen = len - 6;
    bool le = false;
    if (tiffLen < 8) return out;
    if (tiff[0] == 'I' && tiff[1] == 'I') {
        le = true;
    } else if (tiff[0] == 'M' && tiff[1] == 'M') {
        le = false;
    } else {
        return out;
    }
    if (exif_u16(tiff + 2, le) != 42) return out;

    uint32_t ifd0 = exif_u32(tiff + 4, le);
    parse_exif_ifd(tiff, tiffLen, ifd0, le, out, 0);
    return out;
}

static ExifMetadata parse_jpeg_exif(const uint8_t* bytes, size_t len) {
    ExifMetadata out;
    if (!looks_like_jpeg(bytes, len)) return out;

    size_t pos = 2;
    while (pos + 4 <= len) {
        if (bytes[pos] != 0xff) break;
        while (pos < len && bytes[pos] == 0xff) pos++;
        if (pos >= len) break;
        uint8_t marker = bytes[pos++];
        if (marker == 0xda || marker == 0xd9) break;
        if (marker >= 0xd0 && marker <= 0xd7) continue;
        if (pos + 2 > len) break;
        uint16_t segmentLen = ((uint16_t)bytes[pos] << 8) | bytes[pos + 1];
        pos += 2;
        if (segmentLen < 2 || pos + segmentLen - 2 > len) break;
        size_t payloadLen = segmentLen - 2;
        if (marker == 0xe1) {
            out = parse_exif_payload(bytes + pos, payloadLen);
            if (out.hasOrientation || !out.make.empty() || !out.model.empty() || !out.software.empty() || !out.dateTime.empty() ||
                !out.artist.empty() || !out.copyright.empty() || !out.tags.empty()) {
                return out;
            }
        }
        pos += payloadLen;
    }

    return out;
}

static int image_open(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    DecodeOptions options = parse_decode_options(L, 2);

    std::vector<uint8_t> bytes;
    if (!read_file_bytes(path, bytes)) {
        luaL_error(L, "failed to read %s", path.c_str());
    }
    if (bytes.empty()) {
        luaL_error(L, "image file is empty: %s", path.c_str());
    }

    if (looks_like_png(bytes.data(), bytes.size())) {
        image_from_png_memory(L, bytes.data(), bytes.size(), options.format, path.c_str());
        return 1;
    }

    if (looks_like_jpeg(bytes.data(), bytes.size())) {
        image_from_jpeg_memory(L, bytes.data(), bytes.size(), options, path.c_str());
        return 1;
    }

    if (looks_like_webp(bytes.data(), bytes.size())) {
        image_from_webp(L, bytes.data(), bytes.size(), options.format, path.c_str());
        return 1;
    }

    if (bytes.size() > (size_t)std::numeric_limits<int>::max()) {
        luaL_error(L, "image file is too large to decode with STB fallback");
    }

    int forceChannels = stbi_channels_for_format(options.format);

    int w, h, channels;
    stbi_uc* data = stbi_load_from_memory(bytes.data(), (int)bytes.size(), &w, &h, &channels, forceChannels);
    image_from_stbi(L, data, w, h, channels, options.format, "stb", path.c_str());
    return 1;
}

static int image_decode(lua_State* L) {
    size_t len;
    const void* bytes = luaL_checkbuffer(L, 1, &len);
    DecodeOptions options = parse_decode_options(L, 2);
    if (len == 0) {
        luaL_error(L, "image buffer is empty");
    }

    if (looks_like_png((const uint8_t*)bytes, len)) {
        image_from_png_memory(L, (const uint8_t*)bytes, len, options.format, nullptr);
        return 1;
    }

    if (looks_like_jpeg((const uint8_t*)bytes, len)) {
        image_from_jpeg_memory(L, (const uint8_t*)bytes, len, options, nullptr);
        return 1;
    }

    if (looks_like_webp((const uint8_t*)bytes, len)) {
        image_from_webp(L, (const uint8_t*)bytes, len, options.format, nullptr);
        return 1;
    }

    if (len > (size_t)std::numeric_limits<int>::max()) {
        luaL_error(L, "image buffer is too large to decode with STB fallback");
    }

    int forceChannels = stbi_channels_for_format(options.format);

    int w, h, channels;
    stbi_uc* data = stbi_load_from_memory((const stbi_uc*)bytes, (int)len, &w, &h, &channels, forceChannels);
    image_from_stbi(L, data, w, h, channels, options.format, "stb", nullptr);
    return 1;
}

static int image_new(lua_State* L) {
    int width = luaL_checkinteger(L, 1);
    int height = luaL_checkinteger(L, 2);
    if (width <= 0 || height <= 0) luaL_error(L, "image dimensions must be positive");

    PixelFormat format = parse_new_format(L, 3);
    Color color = parse_new_color(L, 3);
    LuaImage* i = new_owned_image(L, (uint32_t)width, (uint32_t)height, format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < i->height; y++) {
        for (uint32_t x = 0; x < i->width; x++) {
            write_pixel(i, x, y, color);
        }
    }

    return 1;
}

static int image_fromBuffer(lua_State* L) {
    size_t bufLen;
    void* buffer = luaL_checkbuffer(L, 1, &bufLen);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);
    luaL_checktype(L, 4, LUA_TTABLE);

    if (width <= 0 || height <= 0) luaL_error(L, "image dimensions must be positive");
    PixelFormat format = opt_format_field(L, 4, "format", PixelFormat::Rgba8);
    size_t minStride = (size_t)width * format_channels(format);
    int strideOpt = opt_int_field(L, 4, "stride", (int)minStride);
    if (strideOpt <= 0) luaL_error(L, "stride must be positive");
    size_t stride = (size_t)strideOpt;
    bool copy = opt_bool_field(L, 4, "copy", true);

    checked_image_size(L, (uint32_t)width, (uint32_t)height, format, stride);
    if (stride > bufLen / (size_t)height) {
        luaL_error(L, "provided buffer is too small for image dimensions and stride");
    }

    if (copy) {
        LuaImage* i = new_owned_image(L, (uint32_t)width, (uint32_t)height, format, make_metadata_ref(L, "raw"));
        for (int y = 0; y < height; y++) {
            memcpy(i->pixels + (size_t)y * i->stride, (uint8_t*)buffer + (size_t)y * stride, minStride);
        }
        return 1;
    }

    LuaImage* i = new_image_userdata(L, (uint32_t)width, (uint32_t)height, format, stride, make_metadata_ref(L, "raw"));
    i->pixels = (uint8_t*)buffer;
    i->bufferRef = lua_ref(L, 1);
    return 1;
}

static int image_fromRGBABuffer(lua_State* L) {
    size_t bufLen;
    void* buffer = luaL_checkbuffer(L, 1, &bufLen);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);
    int channels = luaL_checkinteger(L, 4);
    if (channels != 4) luaL_error(L, "only RGBA channel format supported");
    if (width <= 0 || height <= 0) luaL_error(L, "image dimensions must be positive");
    if (bufLen != (size_t)width * (size_t)height * 4) {
        luaL_error(L, "provided buffer does not exactly match %dx%dx4", width, height);
    }

    LuaImage* i = new_image_userdata(L, (uint32_t)width, (uint32_t)height, PixelFormat::Rgba8, (size_t)width * 4, make_metadata_ref(L, "raw"));
    i->pixels = (uint8_t*)buffer;
    i->bufferRef = lua_ref(L, 1);
    return 1;
}

static int image_rgb(lua_State* L) {
    Color c = {check_u8(L, 1, "r"), check_u8(L, 2, "g"), check_u8(L, 3, "b"), 255};
    push_color(L, c);
    return 1;
}

static int image_rgba(lua_State* L) {
    Color c = {check_u8(L, 1, "r"), check_u8(L, 2, "g"), check_u8(L, 3, "b"), check_u8(L, 4, "a")};
    push_color(L, c);
    return 1;
}

static int image_gray(lua_State* L) {
    uint8_t v = check_u8(L, 1, "v");
    uint8_t a = lua_isnoneornil(L, 2) ? 255 : check_u8(L, 2, "a");
    push_color(L, {v, v, v, a});
    return 1;
}

static int image_rect(lua_State* L) {
    Rect r = {
        luaL_checkinteger(L, 1),
        luaL_checkinteger(L, 2),
        luaL_checkinteger(L, 3),
        luaL_checkinteger(L, 4),
    };
    push_rect(L, r);
    return 1;
}

static int image_tostring(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    if (i->closed) {
        lua_pushstring(L, "Image(closed)");
    } else {
        lua_pushfstring(L, "Image(%d, %d, %s)", i->width, i->height, format_name(i->format));
    }
    return 1;
}

static int image_index(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, i->closed);
        return 1;
    }

    if (i->closed) {
        lua_pushvalue(L, 2);
        lua_rawget(L, lua_upvalueindex(1));
        return 1;
    }

    if (strcmp(key, "width") == 0) {
        lua_pushinteger(L, i->width);
        return 1;
    }
    if (strcmp(key, "height") == 0) {
        lua_pushinteger(L, i->height);
        return 1;
    }
    if (strcmp(key, "format") == 0) {
        lua_pushstring(L, format_name(i->format));
        return 1;
    }
    if (strcmp(key, "channels") == 0) {
        lua_pushinteger(L, format_channels(i->format));
        return 1;
    }
    if (strcmp(key, "stride") == 0) {
        lua_pushinteger(L, (int)i->stride);
        return 1;
    }
    if (strcmp(key, "bounds") == 0) {
        push_rect(L, {0, 0, (int)i->width, (int)i->height});
        return 1;
    }
    if (strcmp(key, "colorSpace") == 0) {
        lua_pushstring(L, "srgb");
        return 1;
    }
    if (strcmp(key, "metadata") == 0) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, i->metadataRef);
        return 1;
    }
    if (strcmp(key, "buffer") == 0 || strcmp(key, "pixelBuffer") == 0) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, i->bufferRef);
        return 1;
    }

    lua_pushvalue(L, 2);
    lua_rawget(L, lua_upvalueindex(1));
    return 1;
}

static int image_close(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    image_release(i);
    return 0;
}

static int image_getPixel(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    if (x < 0 || x >= (int)i->width || y < 0 || y >= (int)i->height) {
        luaL_error(L, "pixel coordinate out of bounds");
    }

    push_color(L, read_pixel(i, x, y));
    return 1;
}

static int image_setPixel(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    if (x < 0 || x >= (int)i->width || y < 0 || y >= (int)i->height) {
        luaL_error(L, "pixel coordinate out of bounds");
    }
    Color c = check_color(L, 4);
    write_pixel(i, x, y, c);
    return 0;
}

static int image_clone(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    copy_image_pixels(dst, src);
    return 1;
}

static int image_crop(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    Rect r = check_rect_args(L, 2);
    check_rect_in_bounds(L, src, r);

    LuaImage* dst = new_owned_image(L, (uint32_t)r.width, (uint32_t)r.height, src->format, make_metadata_ref(L, "raw"));
    for (int y = 0; y < r.height; y++) {
        memcpy(pixel_at(dst, 0, y), pixel_at(src, r.x, r.y + y), (size_t)r.width * format_channels(src->format));
    }
    return 1;
}

static int image_subimage(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    Rect r = check_rect_args(L, 2);
    check_rect_in_bounds(L, src, r);

    LuaImage* view = new_image_userdata(L, (uint32_t)r.width, (uint32_t)r.height, src->format, src->stride, make_metadata_ref(L, "raw"));
    view->pixels = pixel_at(src, r.x, r.y);
    view->view = true;

    lua_rawgeti(L, LUA_REGISTRYINDEX, src->bufferRef);
    view->bufferRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return 1;
}

static int image_convert(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    PixelFormat format = check_format(L, 2);
    LuaImage* dst = new_owned_image(L, src->width, src->height, format, make_metadata_ref(L, "raw"));

    bool useBackground = false;
    Color background = {0, 0, 0, 255};
    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "background");
        if (!lua_isnil(L, -1)) {
            background = check_color(L, -1, {0, 0, 0, 255});
            background.a = 255;
            useBackground = format_has_alpha(src->format) && !format_has_alpha(format);
        }
        lua_pop(L, 1);
    }

    if (useBackground) {
        copy_image_pixels(dst, src, background);
    } else {
        copy_image_pixels(dst, src);
    }
    return 1;
}

static stbir_pixel_layout stbir_layout(PixelFormat format) {
    switch (format) {
        case PixelFormat::Rgba8:
            return STBIR_RGBA;
        case PixelFormat::Rgb8:
            return STBIR_RGB;
        case PixelFormat::Gray8:
            return STBIR_1CHANNEL;
        case PixelFormat::GrayAlpha8:
            return STBIR_2CHANNEL;
    }
    return STBIR_RGBA;
}

static double position_x_align(ResizePosition position) {
    switch (position) {
        case ResizePosition::TopLeft:
        case ResizePosition::Left:
            return 0.0;
        case ResizePosition::Right:
        case ResizePosition::BottomRight:
            return 1.0;
        case ResizePosition::Center:
        case ResizePosition::Top:
        case ResizePosition::Bottom:
            return 0.5;
    }
    return 0.5;
}

static double position_y_align(ResizePosition position) {
    switch (position) {
        case ResizePosition::TopLeft:
        case ResizePosition::Top:
            return 0.0;
        case ResizePosition::Bottom:
        case ResizePosition::BottomRight:
            return 1.0;
        case ResizePosition::Center:
        case ResizePosition::Left:
        case ResizePosition::Right:
            return 0.5;
    }
    return 0.5;
}

static void fill_image(LuaImage* dst, Color color) {
    for (uint32_t y = 0; y < dst->height; y++) {
        for (uint32_t x = 0; x < dst->width; x++) {
            write_pixel(dst, x, y, color);
        }
    }
}

static bool resize_rect_into(const LuaImage* src, Rect srcRect, LuaImage* dst, bool nearest) {
    if (nearest) {
        for (uint32_t y = 0; y < dst->height; y++) {
            int sy = srcRect.y + std::min(srcRect.height - 1, (int)((uint64_t)y * srcRect.height / dst->height));
            for (uint32_t x = 0; x < dst->width; x++) {
                int sx = srcRect.x + std::min(srcRect.width - 1, (int)((uint64_t)x * srcRect.width / dst->width));
                write_pixel(dst, (int)x, (int)y, read_pixel(src, sx, sy));
            }
        }
        return true;
    }

    return stbir_resize_uint8_srgb(pixel_at(src, srcRect.x, srcRect.y), srcRect.width, srcRect.height, (int)src->stride,
                                   dst->pixels, (int)dst->width, (int)dst->height, (int)dst->stride, stbir_layout(src->format));
}

static LuaImage* resize_exact(lua_State* L, LuaImage* src, Rect srcRect, int width, int height, bool nearest) {
    LuaImage* dst = new_owned_image(L, (uint32_t)width, (uint32_t)height, src->format, make_metadata_ref(L, "raw"));
    if (!resize_rect_into(src, srcRect, dst, nearest)) {
        lua_pop(L, 1);
        luaL_error(L, "failed to resize image");
    }
    return dst;
}

static int image_resize(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);
    if (width <= 0 || height <= 0) luaL_error(L, "image dimensions must be positive");
    ResizeOptionsNative opts = parse_resize_options(L, 4);

    Rect srcRect = {0, 0, (int)src->width, (int)src->height};
    if (opts.fit == ResizeFit::Stretch) {
        resize_exact(L, src, srcRect, width, height, opts.nearest);
        return 1;
    }

    if (opts.fit == ResizeFit::Cover) {
        double targetRatio = (double)width / height;
        double sourceRatio = (double)src->width / src->height;
        if (sourceRatio > targetRatio) {
            srcRect.width = std::max(1, (int)std::round(src->height * targetRatio));
            srcRect.x = (int)std::round(((int)src->width - srcRect.width) * position_x_align(opts.position));
        } else {
            srcRect.height = std::max(1, (int)std::round(src->width / targetRatio));
            srcRect.y = (int)std::round(((int)src->height - srcRect.height) * position_y_align(opts.position));
        }
        resize_exact(L, src, srcRect, width, height, opts.nearest);
        return 1;
    }

    double scale = std::min((double)width / src->width, (double)height / src->height);
    int innerWidth = std::max(1, (int)std::round(src->width * scale));
    int innerHeight = std::max(1, (int)std::round(src->height * scale));
    int offsetX = (int)std::round((width - innerWidth) * position_x_align(opts.position));
    int offsetY = (int)std::round((height - innerHeight) * position_y_align(opts.position));

    LuaImage* dst = new_owned_image(L, (uint32_t)width, (uint32_t)height, src->format, make_metadata_ref(L, "raw"));
    fill_image(dst, opts.background);
    LuaImage* inner = resize_exact(L, src, srcRect, innerWidth, innerHeight, opts.nearest);
    for (int y = 0; y < innerHeight; y++) {
        for (int x = 0; x < innerWidth; x++) {
            write_pixel(dst, offsetX + x, offsetY + y, read_pixel(inner, x, y));
        }
    }
    lua_pop(L, 1);
    return 1;
}

static int image_thumbnail(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    int maxWidth = luaL_checkinteger(L, 2);
    int maxHeight = luaL_checkinteger(L, 3);
    if (maxWidth <= 0 || maxHeight <= 0) luaL_error(L, "thumbnail bounds must be positive");

    double scale = std::min((double)maxWidth / src->width, (double)maxHeight / src->height);
    scale = std::min(scale, 1.0);
    int width = std::max(1, (int)std::round(src->width * scale));
    int height = std::max(1, (int)std::round(src->height * scale));
    ResizeOptionsNative opts = parse_resize_options(L, 4);
    resize_exact(L, src, {0, 0, (int)src->width, (int)src->height}, width, height, opts.nearest);
    return 1;
}

static int image_flipX(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(dst, src->width - x - 1, y, read_pixel(src, x, y));
        }
    }
    return 1;
}

static int image_flipY(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(dst, x, src->height - y - 1, read_pixel(src, x, y));
        }
    }
    return 1;
}

static int image_rotate90(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->height, src->width, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(dst, src->height - y - 1, x, read_pixel(src, x, y));
        }
    }
    return 1;
}

static int image_rotate180(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(dst, src->width - x - 1, src->height - y - 1, read_pixel(src, x, y));
        }
    }
    return 1;
}

static int image_rotate270(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->height, src->width, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(dst, y, src->width - x - 1, read_pixel(src, x, y));
        }
    }
    return 1;
}

static int image_clear(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    Color c = check_color(L, 2);
    for (uint32_t y = 0; y < i->height; y++) {
        for (uint32_t x = 0; x < i->width; x++) {
            write_pixel(i, x, y, c);
        }
    }
    return 0;
}

static int image_fillRect(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    Rect r = check_rect_args(L, 2);
    int colorArg = lua_istable(L, 2) ? 3 : 6;
    Color c = check_color(L, colorArg);
    check_rect_in_bounds(L, i, r);

    for (int y = r.y; y < r.y + r.height; y++) {
        for (int x = r.x; x < r.x + r.width; x++) {
            write_pixel(i, x, y, c);
        }
    }
    return 0;
}

static int image_strokeRect(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    Rect r = check_rect_args(L, 2);
    int colorArg = lua_istable(L, 2) ? 3 : 6;
    int thicknessArg = colorArg + 1;
    Color c = check_color(L, colorArg);
    int thickness = luaL_optinteger(L, thicknessArg, 1);
    if (thickness <= 0) luaL_error(L, "thickness must be positive");
    check_rect_in_bounds(L, i, r);

    for (int t = 0; t < thickness; t++) {
        int left = r.x + t;
        int right = r.x + r.width - t - 1;
        int top = r.y + t;
        int bottom = r.y + r.height - t - 1;
        if (left > right || top > bottom) break;
        for (int x = left; x <= right; x++) {
            write_pixel(i, x, top, c);
            write_pixel(i, x, bottom, c);
        }
        for (int y = top; y <= bottom; y++) {
            write_pixel(i, left, y, c);
            write_pixel(i, right, y, c);
        }
    }
    return 0;
}

static int image_blit(lua_State* L) {
    LuaImage* dst = check_image(L, 1);
    LuaImage* src = check_image(L, 2);

    Rect srcRect;
    int dstX;
    int dstY;
    int optionsArg;
    if (lua_istable(L, 3)) {
        srcRect = check_rect(L, 3);
        dstX = luaL_checkinteger(L, 4);
        dstY = luaL_checkinteger(L, 5);
        optionsArg = 6;
    } else {
        srcRect = {0, 0, (int)src->width, (int)src->height};
        dstX = luaL_checkinteger(L, 3);
        dstY = luaL_checkinteger(L, 4);
        optionsArg = 5;
    }

    check_rect_in_bounds(L, src, srcRect);
    BlitOptions opts = parse_blit_options(L, optionsArg);
    for (int y = 0; y < srcRect.height; y++) {
        int ty = dstY + y;
        if (ty < 0 || ty >= (int)dst->height) continue;
        for (int x = 0; x < srcRect.width; x++) {
            int tx = dstX + x;
            if (tx < 0 || tx >= (int)dst->width) continue;
            write_blended_pixel(dst, tx, ty, read_pixel(src, srcRect.x + x, srcRect.y + y), opts, x, y);
        }
    }
    return 0;
}

static int image_draw(lua_State* L) {
    LuaImage* dst = check_image(L, 1);
    LuaImage* src = check_image(L, 2);
    Rect srcRect = check_rect(L, 3);
    Rect dstRect = check_rect(L, 4);
    check_rect_in_bounds(L, src, srcRect);
    if (dstRect.width <= 0 || dstRect.height <= 0) {
        luaL_error(L, "destination rectangle dimensions must be positive");
    }

    BlitOptions opts = parse_blit_options(L, 5);
    for (int y = 0; y < dstRect.height; y++) {
        int ty = dstRect.y + y;
        if (ty < 0 || ty >= (int)dst->height) continue;
        int sy = srcRect.y + std::min(srcRect.height - 1, (int)((int64_t)y * srcRect.height / dstRect.height));
        for (int x = 0; x < dstRect.width; x++) {
            int tx = dstRect.x + x;
            if (tx < 0 || tx >= (int)dst->width) continue;
            int sx = srcRect.x + std::min(srcRect.width - 1, (int)((int64_t)x * srcRect.width / dstRect.width));
            write_blended_pixel(dst, tx, ty, read_pixel(src, sx, sy), opts, x, y);
        }
    }
    return 0;
}

static void line_point(LuaImage* i, int x, int y, int thickness, Color c) {
    int radius = thickness / 2;
    for (int yy = y - radius; yy <= y - radius + thickness - 1; yy++) {
        if (yy < 0 || yy >= (int)i->height) continue;
        for (int xx = x - radius; xx <= x - radius + thickness - 1; xx++) {
            if (xx < 0 || xx >= (int)i->width) continue;
            write_pixel(i, xx, yy, c);
        }
    }
}

static int image_line(lua_State* L) {
    LuaImage* i = check_image(L, 1);
    int x1 = luaL_checkinteger(L, 2);
    int y1 = luaL_checkinteger(L, 3);
    int x2 = luaL_checkinteger(L, 4);
    int y2 = luaL_checkinteger(L, 5);
    Color c = check_color(L, 6);

    int thickness = 1;
    if (lua_istable(L, 7)) {
        thickness = opt_int_field(L, 7, "thickness", 1);
    }
    if (thickness <= 0) luaL_error(L, "thickness must be positive");

    int dx = std::abs(x2 - x1);
    int sx = x1 < x2 ? 1 : -1;
    int dy = -std::abs(y2 - y1);
    int sy = y1 < y2 ? 1 : -1;
    int err = dx + dy;

    while (true) {
        line_point(i, x1, y1, thickness, c);
        if (x1 == x2 && y1 == y2) break;
        int e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x1 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y1 += sy;
        }
    }
    return 0;
}

static int image_invert(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            write_pixel(dst, x, y, {(uint8_t)(255 - c.r), (uint8_t)(255 - c.g), (uint8_t)(255 - c.b), c.a});
        }
    }
    return 1;
}

static int image_grayscale(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            uint8_t v = luminance(c);
            write_pixel(dst, x, y, {v, v, v, c.a});
        }
    }
    return 1;
}

static int image_opacity(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    double amount = luaL_checknumber(L, 2);
    amount = std::clamp(amount, 0.0, 1.0);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            c.a = (uint8_t)std::clamp((int)std::round(c.a * amount), 0, 255);
            write_pixel(dst, x, y, c);
        }
    }
    return 1;
}

static int image_brightness(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    double amount = luaL_checknumber(L, 2);
    int delta = (int)std::round(amount * 255.0);
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            c.r = (uint8_t)std::clamp((int)c.r + delta, 0, 255);
            c.g = (uint8_t)std::clamp((int)c.g + delta, 0, 255);
            c.b = (uint8_t)std::clamp((int)c.b + delta, 0, 255);
            write_pixel(dst, x, y, c);
        }
    }
    return 1;
}

static int image_contrast(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    double amount = luaL_checknumber(L, 2);
    double factor = 1.0 + amount;
    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            c.r = (uint8_t)std::clamp((int)std::round((c.r - 128) * factor + 128), 0, 255);
            c.g = (uint8_t)std::clamp((int)std::round((c.g - 128) * factor + 128), 0, 255);
            c.b = (uint8_t)std::clamp((int)std::round((c.b - 128) * factor + 128), 0, 255);
            write_pixel(dst, x, y, c);
        }
    }
    return 1;
}

static int image_threshold(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    int value = luaL_checkinteger(L, 2);
    value = std::clamp(value, 0, 255);

    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            uint8_t v = luminance(c) >= value ? 255 : 0;
            write_pixel(dst, x, y, {v, v, v, c.a});
        }
    }
    return 1;
}

static int image_colorMatrix(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    double m[20];
    for (int i = 0; i < 20; i++) {
        lua_rawgeti(L, 2, i + 1);
        m[i] = luaL_checknumber(L, -1);
        lua_pop(L, 1);
    }

    LuaImage* dst = new_owned_image(L, src->width, src->height, src->format, make_metadata_ref(L, "raw"));
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            Color c = read_pixel(src, x, y);
            double in[4] = {(double)c.r, (double)c.g, (double)c.b, (double)c.a};
            Color out = {
                blend_channel(m[0] * in[0] + m[1] * in[1] + m[2] * in[2] + m[3] * in[3] + m[4]),
                blend_channel(m[5] * in[0] + m[6] * in[1] + m[7] * in[2] + m[8] * in[3] + m[9]),
                blend_channel(m[10] * in[0] + m[11] * in[1] + m[12] * in[2] + m[13] * in[3] + m[14]),
                blend_channel(m[15] * in[0] + m[16] * in[1] + m[17] * in[2] + m[18] * in[3] + m[19]),
            };
            write_pixel(dst, x, y, out);
        }
    }
    return 1;
}

static void image_as_format(LuaImage* src, PixelFormat format, std::vector<uint8_t>& out) {
    int channels = format_channels(format);
    out.resize((size_t)src->width * src->height * channels);
    LuaImage tmp = *src;
    tmp.format = format;
    tmp.stride = (size_t)src->width * channels;
    tmp.pixels = out.data();
    tmp.closed = false;
    for (uint32_t y = 0; y < src->height; y++) {
        for (uint32_t x = 0; x < src->width; x++) {
            write_pixel(&tmp, x, y, read_pixel(src, x, y));
        }
    }
}

static bool encode_webp_image(LuaImage* src, bool lossless, int quality, std::vector<uint8_t>& out) {
    std::vector<uint8_t> rgba;
    image_as_format(src, PixelFormat::Rgba8, rgba);

    uint8_t* encoded = nullptr;
    size_t encodedSize = 0;
    if (lossless) {
        encodedSize = WebPEncodeLosslessRGBA(rgba.data(), (int)src->width, (int)src->height, (int)src->width * 4, &encoded);
    } else {
        encodedSize = WebPEncodeRGBA(rgba.data(), (int)src->width, (int)src->height, (int)src->width * 4, (float)quality, &encoded);
    }

    if (encodedSize == 0 || !encoded) return false;
    out.assign(encoded, encoded + encodedSize);
    WebPFree(encoded);
    return true;
}

static bool encode_png_image(LuaImage* src, std::vector<uint8_t>& out) {
    png_image png;
    memset(&png, 0, sizeof(png));
    png.version = PNG_IMAGE_VERSION;
    png.width = src->width;
    png.height = src->height;
    png.format = png_format_for_image(src->format);

    png_alloc_size_t size = 0;
    if (!png_image_write_to_memory(&png, nullptr, &size, 0, src->pixels, (png_int_32)src->stride, nullptr) || size == 0) {
        return false;
    }

    out.resize(size);
    if (!png_image_write_to_memory(&png, out.data(), &size, 0, src->pixels, (png_int_32)src->stride, nullptr)) {
        out.clear();
        return false;
    }

    out.resize(size);
    return true;
}

static bool encode_jpeg_image(LuaImage* src, int quality, bool progressive, std::vector<uint8_t>& out, std::string& error) {
    std::vector<uint8_t> rgb;
    image_as_format(src, PixelFormat::Rgb8, rgb);

    tjhandle handle = tjInitCompress();
    if (!handle) {
        error = tjGetErrorStr();
        return false;
    }

    unsigned char* jpeg = nullptr;
    unsigned long jpegSize = 0;
    int flags = progressive ? TJFLAG_PROGRESSIVE : 0;
    int subsamp = quality >= 90 ? TJSAMP_444 : TJSAMP_420;
    if (tjCompress2(handle, rgb.data(), (int)src->width, (int)src->width * 3, (int)src->height,
                    TJPF_RGB, &jpeg, &jpegSize, subsamp, quality, flags) != 0) {
        error = tjGetErrorStr2(handle);
        tjDestroy(handle);
        if (jpeg) tjFree(jpeg);
        return false;
    }

    out.assign(jpeg, jpeg + jpegSize);
    tjFree(jpeg);
    tjDestroy(handle);
    return true;
}

static std::string explicit_encode_format(lua_State* L, int idx) {
    if (!lua_istable(L, idx)) return "";
    lua_getfield(L, idx, "format");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return "";
    }

    const char* format = luaL_checkstring(L, -1);
    if (strcmp(format, "png") != 0 && strcmp(format, "jpeg") != 0 && strcmp(format, "jpg") != 0 && strcmp(format, "webp") != 0) {
        luaL_error(L, "unsupported image format '%s'", format);
    }

    std::string result = format;
    lua_pop(L, 1);
    return result;
}

static int image_encode(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    const char* format = luaL_checkstring(L, 2);
    int quality = 90;
    bool lossless = false;
    if (lua_istable(L, 3)) {
        quality = opt_int_field(L, 3, "quality", 90);
        lossless = opt_bool_field(L, 3, "lossless", false);
    }
    bool progressive = lua_istable(L, 3) ? opt_bool_field(L, 3, "progressive", false) : false;
    quality = std::clamp(quality, 1, 100);

    std::vector<uint8_t> pngBytes;
    std::vector<uint8_t> webp;
    std::vector<uint8_t> jpeg;

    if (strcmp(format, "png") == 0) {
        if (!encode_png_image(src, pngBytes)) {
            luaL_error(L, "failed to encode PNG image");
        }
        void* out = lua_newbuffer(L, pngBytes.size());
        memcpy(out, pngBytes.data(), pngBytes.size());
        return 1;
    } else if (strcmp(format, "jpeg") == 0 || strcmp(format, "jpg") == 0) {
        std::string error;
        if (!encode_jpeg_image(src, quality, progressive, jpeg, error)) {
            luaL_error(L, "failed to encode JPEG image: %s", error.c_str());
        }
        void* out = lua_newbuffer(L, jpeg.size());
        memcpy(out, jpeg.data(), jpeg.size());
        return 1;
    } else if (strcmp(format, "webp") == 0) {
        if (!encode_webp_image(src, lossless, quality, webp)) {
            luaL_error(L, "failed to encode WEBP image");
        }
        void* out = lua_newbuffer(L, webp.size());
        memcpy(out, webp.data(), webp.size());
        return 1;
    } else {
        luaL_error(L, "unsupported image format '%s'", format);
    }

    return 0;
}

static int image_save(lua_State* L) {
    LuaImage* src = check_image(L, 1);
    std::string path = luaL_checkpathlike(L, 2);
    std::string ext = lower_ext(path);
    std::string explicitFormat = explicit_encode_format(L, 3);
    std::string format = explicitFormat.empty() ? ext : explicitFormat;
    int quality = lua_istable(L, 3) ? opt_int_field(L, 3, "quality", 90) : 90;
    bool lossless = lua_istable(L, 3) ? opt_bool_field(L, 3, "lossless", false) : false;
    bool progressive = lua_istable(L, 3) ? opt_bool_field(L, 3, "progressive", false) : false;
    quality = std::clamp(quality, 1, 100);

    int ok = 0;
    std::vector<uint8_t> scratch;
    std::vector<uint8_t> pngBytes;
    std::vector<uint8_t> jpeg;
    std::vector<uint8_t> webp;
    if (format == "png") {
        if (!encode_png_image(src, pngBytes)) {
            luaL_error(L, "failed to encode PNG image");
        }
        write_file_bytes(L, path, pngBytes);
        return 0;
    } else if (format == "jpg" || format == "jpeg") {
        std::string error;
        if (!encode_jpeg_image(src, quality, progressive, jpeg, error)) {
            luaL_error(L, "failed to encode JPEG image: %s", error.c_str());
        }
        write_file_bytes(L, path, jpeg);
        return 0;
    } else if (explicitFormat.empty() && ext == "bmp") {
        image_as_format(src, PixelFormat::Rgba8, scratch);
        ok = stbi_write_bmp(path.c_str(), src->width, src->height, 4, scratch.data());
    } else if (explicitFormat.empty() && ext == "tga") {
        image_as_format(src, PixelFormat::Rgba8, scratch);
        ok = stbi_write_tga(path.c_str(), src->width, src->height, 4, scratch.data());
    } else if (format == "webp") {
        if (!encode_webp_image(src, lossless, quality, webp)) {
            luaL_error(L, "failed to encode WEBP image");
        }
        write_file_bytes(L, path, webp);
        return 0;
    } else {
        luaL_error(L, "unsupported image format for path '%s'; pass { format = \"png\" | \"jpeg\" | \"webp\" } to override", path.c_str());
    }

    if (!ok) luaL_error(L, "failed to save %s", path.c_str());
    return 0;
}

LUAU_MODULE_EXPORT int luauopen_image(lua_State* L) {
    luaL_newmetatable(L, IMAGE_METATABLE);

    lua_pushcfunction(L, image_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    lua_newtable(L);

    lua_pushcfunction(L, image_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, image_getPixel, "getPixel");
    lua_setfield(L, -2, "getPixel");
    lua_pushcfunction(L, image_setPixel, "setPixel");
    lua_setfield(L, -2, "setPixel");
    lua_pushcfunction(L, image_save, "save");
    lua_setfield(L, -2, "save");
    lua_pushcfunction(L, image_encode, "encode");
    lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, image_clone, "clone");
    lua_setfield(L, -2, "clone");
    lua_pushcfunction(L, image_crop, "crop");
    lua_setfield(L, -2, "crop");
    lua_pushcfunction(L, image_subimage, "subimage");
    lua_setfield(L, -2, "subimage");
    lua_pushcfunction(L, image_convert, "convert");
    lua_setfield(L, -2, "convert");
    lua_pushcfunction(L, image_resize, "resize");
    lua_setfield(L, -2, "resize");
    lua_pushcfunction(L, image_thumbnail, "thumbnail");
    lua_setfield(L, -2, "thumbnail");
    lua_pushcfunction(L, image_flipX, "flipX");
    lua_setfield(L, -2, "flipX");
    lua_pushcfunction(L, image_flipY, "flipY");
    lua_setfield(L, -2, "flipY");
    lua_pushcfunction(L, image_rotate90, "rotate90");
    lua_setfield(L, -2, "rotate90");
    lua_pushcfunction(L, image_rotate180, "rotate180");
    lua_setfield(L, -2, "rotate180");
    lua_pushcfunction(L, image_rotate270, "rotate270");
    lua_setfield(L, -2, "rotate270");
    lua_pushcfunction(L, image_blit, "blit");
    lua_setfield(L, -2, "blit");
    lua_pushcfunction(L, image_draw, "draw");
    lua_setfield(L, -2, "draw");
    lua_pushcfunction(L, image_clear, "clear");
    lua_setfield(L, -2, "clear");
    lua_pushcfunction(L, image_fillRect, "fillRect");
    lua_setfield(L, -2, "fillRect");
    lua_pushcfunction(L, image_strokeRect, "strokeRect");
    lua_setfield(L, -2, "strokeRect");
    lua_pushcfunction(L, image_line, "line");
    lua_setfield(L, -2, "line");
    lua_pushcfunction(L, image_invert, "invert");
    lua_setfield(L, -2, "invert");
    lua_pushcfunction(L, image_grayscale, "grayscale");
    lua_setfield(L, -2, "grayscale");
    lua_pushcfunction(L, image_brightness, "brightness");
    lua_setfield(L, -2, "brightness");
    lua_pushcfunction(L, image_contrast, "contrast");
    lua_setfield(L, -2, "contrast");
    lua_pushcfunction(L, image_opacity, "opacity");
    lua_setfield(L, -2, "opacity");
    lua_pushcfunction(L, image_threshold, "threshold");
    lua_setfield(L, -2, "threshold");
    lua_pushcfunction(L, image_colorMatrix, "colorMatrix");
    lua_setfield(L, -2, "colorMatrix");

    lua_pushcclosure(L, image_index, "__index", 1);
    lua_setfield(L, -2, "__index");
    lua_setreadonly(L, -1, true);
    lua_pop(L, 1);

    lua_newtable(L);

    lua_pushcfunction(L, image_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, image_decode, "decode");
    lua_setfield(L, -2, "decode");
    lua_pushcfunction(L, image_new, "new");
    lua_setfield(L, -2, "new");
    lua_pushcfunction(L, image_fromBuffer, "fromBuffer");
    lua_setfield(L, -2, "fromBuffer");
    lua_pushcfunction(L, image_fromRGBABuffer, "fromRGBABuffer");
    lua_setfield(L, -2, "fromRGBABuffer");
    lua_pushcfunction(L, image_rgb, "rgb");
    lua_setfield(L, -2, "rgb");
    lua_pushcfunction(L, image_rgba, "rgba");
    lua_setfield(L, -2, "rgba");
    lua_pushcfunction(L, image_gray, "gray");
    lua_setfield(L, -2, "gray");
    lua_pushcfunction(L, image_rect, "rect");
    lua_setfield(L, -2, "rect");

    lua_setreadonly(L, -1, true);
    return 1;
}
