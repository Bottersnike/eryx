#include <ft2build.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "./module_api.h"
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_LCD_FILTER_H
#include FT_MULTIPLE_MASTERS_H
#include FT_OUTLINE_H
#include FT_SFNT_NAMES_H
#include FT_TRUETYPE_IDS_H
#include FT_TRUETYPE_TABLES_H

#include <hb-ft.h>
#include <hb.h>

#ifdef _WIN32
#include <windows.h>
#endif

#ifdef __APPLE__
#include <CoreText/CoreText.h>
#include <limits.h>
#endif

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_font",
};
LUAU_MODULE_INFO()

static udataRef* typefaceRef;
static udataRef* fontRef;
static udataRef* shapedRunRef;

static FT_Library g_ft = nullptr;

static double ft26(FT_Pos value) { return (double)value / 64.0; }
static double ft16(FT_Fixed value) { return (double)value / 65536.0; }

static uint32_t tag_from_string(std::string_view s) {
    if (s.size() != 4) return 0;
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static std::string tag_to_string(uint32_t tag) {
    char buf[4] = {
        (char)((tag >> 24) & 0xff),
        (char)((tag >> 16) & 0xff),
        (char)((tag >> 8) & 0xff),
        (char)(tag & 0xff),
    };
    return std::string(buf, 4);
}

static std::string lower_ascii(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return s;
}

static bool is_font_file(const std::filesystem::path& path) {
    std::string ext = lower_ascii(path.extension().string());
    return ext == ".ttf" || ext == ".otf" || ext == ".ttc" || ext == ".otc";
}

static void add_unique(std::vector<std::string>& out, std::string value) {
    if (value.empty()) return;
    if (std::find(out.begin(), out.end(), value) == out.end()) out.push_back(std::move(value));
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

static bool is_no_options(lua_State* L, int idx) { return idx == 0 || lua_isnoneornil(L, idx); }

static std::string opt_string_field(lua_State* L, int idx, const char* field,
                                    const char* fallback = "") {
    if (is_no_options(L, idx)) return fallback;
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return fallback;
    }
    size_t len = 0;
    const char* value = luaL_checklstring(L, -1, &len);
    std::string out(value, len);
    lua_pop(L, 1);
    return out;
}

static bool opt_bool_field_present(lua_State* L, int idx, const char* field, bool& out) {
    if (is_no_options(L, idx)) return false;
    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    out = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return true;
}

static bool opt_refresh_system_field(lua_State* L, int idx) {
    if (is_no_options(L, idx)) return false;
    return opt_bool_field(L, idx, "refresh", false);
}

static std::vector<std::string> opt_string_array_field(lua_State* L, int idx, const char* field) {
    std::vector<std::string> out;
    if (is_no_options(L, idx)) return out;

    lua_getfield(L, idx, field);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return out;
    }
    luaL_checktype(L, -1, LUA_TTABLE);
    int n = lua_objlen(L, -1);
    out.reserve(n);
    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, -1, i);
        size_t len = 0;
        const char* s = luaL_checklstring(L, -1, &len);
        out.emplace_back(s, len);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return out;
}

static std::vector<uint8_t> read_file_bytes(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return {};

    file.seekg(0, std::ios::end);
    std::streamoff size = file.tellg();
    file.seekg(0, std::ios::beg);
    if (size <= 0) return {};

    std::vector<uint8_t> bytes((size_t)size);
    if (!file.read(reinterpret_cast<char*>(bytes.data()), size)) return {};
    return bytes;
}

static std::string path_to_utf8(const std::filesystem::path& path) {
#ifdef _WIN32
    std::wstring wide = path.wstring();
    int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), nullptr, 0, nullptr,
                                  nullptr);
    std::string out(std::max(0, len), '\0');
    if (len > 0)
        WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), out.data(), len, nullptr,
                            nullptr);
    return out;
#else
    return path.string();
#endif
}

struct VariationAxis {
    uint32_t tag = 0;
    std::string name;
    double minimum = 0;
    double maximum = 0;
    double def = 0;
};

struct FaceSource {
    std::string path;
    std::vector<uint8_t> bytes;
    int faceIndex = 0;

    std::string family;
    std::string style;
    int unitsPerEm = 0;
    int glyphCount = 0;
    int weight = 400;
    int stretch = 5;
    bool italic = false;
    std::vector<VariationAxis> variations;
};

struct SystemFontInfo {
    std::string family;
    std::string style;
    int faceIndex = 0;
    int weight = 400;
    int stretch = 5;
    bool italic = false;
    std::vector<std::string> paths;
};

static std::map<std::string, std::map<std::string, SystemFontInfo>> g_systemFontCache;

static void infer_style_attributes(const std::string& style, int& weight, int& stretch,
                                   bool& italic) {
    std::string lower = lower_ascii(style);
    italic =
        lower.find("italic") != std::string::npos || lower.find("oblique") != std::string::npos;

    if (lower.find("thin") != std::string::npos)
        weight = 100;
    else if (lower.find("extra light") != std::string::npos ||
             lower.find("extralight") != std::string::npos ||
             lower.find("ultra light") != std::string::npos ||
             lower.find("ultralight") != std::string::npos)
        weight = 200;
    else if (lower.find("light") != std::string::npos)
        weight = 300;
    else if (lower.find("medium") != std::string::npos)
        weight = 500;
    else if (lower.find("semi bold") != std::string::npos ||
             lower.find("semibold") != std::string::npos ||
             lower.find("demi bold") != std::string::npos ||
             lower.find("demibold") != std::string::npos)
        weight = 600;
    else if (lower.find("extra bold") != std::string::npos ||
             lower.find("extrabold") != std::string::npos ||
             lower.find("ultra bold") != std::string::npos ||
             lower.find("ultrabold") != std::string::npos)
        weight = 800;
    else if (lower.find("black") != std::string::npos || lower.find("heavy") != std::string::npos)
        weight = 900;
    else if (lower.find("bold") != std::string::npos)
        weight = 700;

    if (lower.find("ultra condensed") != std::string::npos ||
        lower.find("ultracondensed") != std::string::npos)
        stretch = 1;
    else if (lower.find("extra condensed") != std::string::npos ||
             lower.find("extracondensed") != std::string::npos)
        stretch = 2;
    else if (lower.find("condensed") != std::string::npos)
        stretch = 3;
    else if (lower.find("semi condensed") != std::string::npos ||
             lower.find("semicondensed") != std::string::npos)
        stretch = 4;
    else if (lower.find("semi expanded") != std::string::npos ||
             lower.find("semiexpanded") != std::string::npos)
        stretch = 6;
    else if (lower.find("expanded") != std::string::npos)
        stretch = 7;
    else if (lower.find("extra expanded") != std::string::npos ||
             lower.find("extraexpanded") != std::string::npos)
        stretch = 8;
    else if (lower.find("ultra expanded") != std::string::npos ||
             lower.find("ultraexpanded") != std::string::npos)
        stretch = 9;
}

static void read_face_style_attributes(FT_Face face, const std::string& style, int& weight,
                                       int& stretch, bool& italic) {
    weight = 400;
    stretch = 5;
    italic = (face->style_flags & FT_STYLE_FLAG_ITALIC) != 0;

    TT_OS2* os2 = (TT_OS2*)FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    if (os2) {
        if (os2->usWeightClass >= 1 && os2->usWeightClass <= 1000) weight = os2->usWeightClass;
        if (os2->usWidthClass >= 1 && os2->usWidthClass <= 9) stretch = os2->usWidthClass;
        italic = italic || (os2->fsSelection & 0x01) != 0;
    }

    infer_style_attributes(style, weight, stretch, italic);
}

static void add_system_font_info(std::map<std::string, SystemFontInfo>& fonts, std::string family,
                                 std::string style, int faceIndex, int weight, int stretch,
                                 bool italic, std::string pathText) {
    if (family.empty() || pathText.empty()) return;

    std::string key = lower_ascii(family) + "\n" + lower_ascii(style) + "\n" +
                      std::to_string(faceIndex) + "\n" + std::to_string(weight) + "\n" +
                      std::to_string(stretch) + "\n" + (italic ? "1" : "0");
    auto& info = fonts[key];
    if (info.family.empty()) {
        info.family = std::move(family);
        info.style = std::move(style);
        info.faceIndex = faceIndex;
        info.weight = weight;
        info.stretch = stretch;
        info.italic = italic;
    }
    add_unique(info.paths, std::move(pathText));
}

struct TypefaceUD {
    std::shared_ptr<FaceSource> source;
};

struct FontUD {
    std::shared_ptr<FaceSource> source;
    FT_Face face = nullptr;
    hb_font_t* hbFont = nullptr;
    double size = 0;

    void close() {
        if (hbFont) hb_font_destroy(hbFont);
        if (face) FT_Done_Face(face);
        hbFont = nullptr;
        face = nullptr;
        source.reset();
    }

    ~FontUD() { close(); }
};

struct ShapedGlyphNative {
    uint32_t id = 0;
    uint32_t cluster = 0;
    double xAdvance = 0;
    double yAdvance = 0;
    double xOffset = 0;
    double yOffset = 0;
};

struct FontRect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    FontRect() = default;
    FontRect(double x, double y, double width, double height)
        : x(x), y(y), width(width), height(height) {}
};

struct ShapedRunUD {
    std::string text;
    std::vector<ShapedGlyphNative> glyphs;
    double advanceX = 0;
    double advanceY = 0;
    FontRect bounds;
    bool closed = false;
};

struct RenderedGlyphBitmap {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    int pitch = 0;
    bool color = false;
    double advanceX = 0;
    double advanceY = 0;
    std::vector<uint8_t> pixels;
};

enum class TextAlign {
    Left,
    Center,
    Right,
};

static void typeface_dtor(lua_State* L, void* ud) {
    (void)L;
    auto* face = static_cast<TypefaceUD*>(ud);
    face->~TypefaceUD();
}

static void font_dtor(lua_State* L, void* ud) {
    (void)L;
    auto* font = static_cast<FontUD*>(ud);
    font->~FontUD();
}

static void shaped_run_dtor(lua_State* L, void* ud) {
    (void)L;
    auto* run = static_cast<ShapedRunUD*>(ud);
    run->~ShapedRunUD();
}

static TypefaceUD* check_typeface(lua_State* L, int idx) {
    TypefaceUD* tf = static_cast<TypefaceUD*>(eryxUdata_checkudata(L, typefaceRef, idx));
    if (!tf->source) luaL_error(L, "attempt to use a closed typeface");
    return tf;
}

static FontUD* check_font(lua_State* L, int idx) {
    FontUD* font = static_cast<FontUD*>(eryxUdata_checkudata(L, fontRef, idx));
    if (!font->face || !font->hbFont) luaL_error(L, "attempt to use a closed font");
    return font;
}

static ShapedRunUD* check_shaped_run(lua_State* L, int idx) {
    ShapedRunUD* run = static_cast<ShapedRunUD*>(eryxUdata_checkudata(L, shapedRunRef, idx));
    if (run->closed) luaL_error(L, "attempt to use a closed shaped run");
    return run;
}

static TypefaceUD* check_typeface_any(lua_State* L, int idx = 1) {
    return static_cast<TypefaceUD*>(eryxUdata_checkudata(L, typefaceRef, idx));
}

static FontUD* check_font_any(lua_State* L, int idx = 1) {
    return static_cast<FontUD*>(eryxUdata_checkudata(L, fontRef, idx));
}

static ShapedRunUD* check_shaped_run_any(lua_State* L, int idx = 1) {
    return static_cast<ShapedRunUD*>(eryxUdata_checkudata(L, shapedRunRef, idx));
}

static void ensure_ft(lua_State* L) {
    if (!g_ft && FT_Init_FreeType(&g_ft)) luaL_error(L, "failed to initialize FreeType");
}

static FT_Face open_source_face(lua_State* L, const FaceSource& source) {
    ensure_ft(L);

    FT_Face face = nullptr;
    FT_Error err = 0;
    if (!source.bytes.empty()) {
        err = FT_New_Memory_Face(g_ft, source.bytes.data(), (FT_Long)source.bytes.size(),
                                 source.faceIndex, &face);
    } else {
        err = FT_New_Face(g_ft, source.path.c_str(), source.faceIndex, &face);
    }

    if (err || !face) luaL_error(L, "failed to open font face");
    return face;
}

static int read_face_index(lua_State* L, int idx) {
    if (lua_isnoneornil(L, idx)) return 0;
    luaL_checktype(L, idx, LUA_TTABLE);
    int faceIndex = opt_int_field(L, idx, "faceIndex", 0);
    if (faceIndex < 0) luaL_error(L, "faceIndex must be non-negative");
    return faceIndex;
}

static std::vector<VariationAxis> read_variations(FT_Face face) {
    std::vector<VariationAxis> out;
    if (!FT_HAS_MULTIPLE_MASTERS(face)) return out;

    FT_MM_Var* mm = nullptr;
    if (FT_Get_MM_Var(face, &mm) || !mm) return out;

    out.reserve(mm->num_axis);
    for (FT_UInt i = 0; i < mm->num_axis; ++i) {
        const FT_Var_Axis& axis = mm->axis[i];
        VariationAxis v;
        v.tag = axis.tag;
        v.name = axis.name ? axis.name : "";
        v.minimum = ft16(axis.minimum);
        v.maximum = ft16(axis.maximum);
        v.def = ft16(axis.def);
        out.push_back(std::move(v));
    }

    FT_Done_MM_Var(g_ft, mm);
    return out;
}

static std::shared_ptr<FaceSource> make_source_from_face(lua_State* L, FT_Face face,
                                                         std::string path,
                                                         std::vector<uint8_t> bytes,
                                                         int faceIndex) {
    auto source = std::make_shared<FaceSource>();
    source->path = std::move(path);
    source->bytes = std::move(bytes);
    source->faceIndex = faceIndex;
    source->family = face->family_name ? face->family_name : "";
    source->style = face->style_name ? face->style_name : "";
    source->unitsPerEm = face->units_per_EM;
    source->glyphCount = face->num_glyphs;
    read_face_style_attributes(face, source->style, source->weight, source->stretch,
                               source->italic);
    source->variations = read_variations(face);
    return source;
}

static void push_vec2(lua_State* L, double x, double y) {
    lua_createtable(L, 0, 2);
    lua_pushnumber(L, x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, y);
    lua_setfield(L, -2, "y");
    lua_setreadonly(L, -1, true);
}

static void push_rect(lua_State* L, FontRect r) {
    lua_createtable(L, 0, 4);
    lua_pushnumber(L, r.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, r.y);
    lua_setfield(L, -2, "y");
    lua_pushnumber(L, r.width);
    lua_setfield(L, -2, "width");
    lua_pushnumber(L, r.height);
    lua_setfield(L, -2, "height");
    lua_setreadonly(L, -1, true);
}

static void push_variations(lua_State* L, const std::vector<VariationAxis>& variations) {
    lua_createtable(L, (int)variations.size(), 0);
    int i = 1;
    for (const VariationAxis& v : variations) {
        lua_createtable(L, 0, 5);
        std::string tag = tag_to_string(v.tag);
        lua_pushlstring(L, tag.data(), tag.size());
        lua_setfield(L, -2, "tag");
        if (!v.name.empty()) {
            lua_pushlstring(L, v.name.data(), v.name.size());
            lua_setfield(L, -2, "name");
        }
        lua_pushnumber(L, v.minimum);
        lua_setfield(L, -2, "min");
        lua_pushnumber(L, v.maximum);
        lua_setfield(L, -2, "max");
        lua_pushnumber(L, v.def);
        lua_setfield(L, -2, "default");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, i++);
    }
    lua_setreadonly(L, -1, true);
}

static void push_typeface(lua_State* L, std::shared_ptr<FaceSource> source) {
    void* ud = eryxUdata_pushudata(L, typefaceRef);
    new (ud) TypefaceUD{ std::move(source) };
}

static void push_font(lua_State* L, std::shared_ptr<FaceSource> source, FT_Face face,
                      hb_font_t* hbFont, double size) {
    void* ud = eryxUdata_pushudata(L, fontRef);
    new (ud) FontUD{ std::move(source), face, hbFont, size };
}

static void push_shaped_run(lua_State* L, ShapedRunUD run) {
    void* ud = eryxUdata_pushudata(L, shapedRunRef);
    new (ud) ShapedRunUD(std::move(run));
}

static void apply_variations(lua_State* L, FT_Face face, hb_font_t* hbFont, int optionsIdx,
                             bool applyToFreeType) {
    if (is_no_options(L, optionsIdx) || !FT_HAS_MULTIPLE_MASTERS(face)) return;
    optionsIdx = lua_absindex(L, optionsIdx);
    lua_getfield(L, optionsIdx, "variations");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    luaL_checktype(L, -1, LUA_TTABLE);
    int variationsIdx = lua_absindex(L, -1);

    FT_MM_Var* mm = nullptr;
    if (FT_Get_MM_Var(face, &mm) || !mm) {
        lua_pop(L, 1);
        return;
    }

    std::vector<FT_Fixed> coords(mm->num_axis);
    std::vector<hb_variation_t> hbVars;
    std::string invalidAxis;
    std::string unknownAxis;
    coords.reserve(mm->num_axis);
    hbVars.reserve(mm->num_axis);
    for (FT_UInt i = 0; i < mm->num_axis; ++i) coords[i] = mm->axis[i].def;

    lua_pushnil(L);
    while (lua_next(L, variationsIdx) != 0) {
        size_t tagLen = 0;
        const char* tagText = luaL_checklstring(L, -2, &tagLen);
        uint32_t tag = tag_from_string(std::string_view(tagText, tagLen));
        if (tag == 0 && invalidAxis.empty()) invalidAxis.assign(tagText, tagLen);

        double value = luaL_checknumber(L, -1);
        bool found = false;
        for (FT_UInt i = 0; i < mm->num_axis; ++i) {
            if (mm->axis[i].tag == tag) {
                coords[i] = (FT_Fixed)(value * 65536.0);
                hbVars.push_back({ tag, (float)value });
                found = true;
                break;
            }
        }
        if (tag != 0 && !found && unknownAxis.empty()) unknownAxis.assign(tagText, tagLen);
        lua_pop(L, 1);
    }

    if (!invalidAxis.empty() || !unknownAxis.empty()) {
        FT_Done_MM_Var(g_ft, mm);
        lua_pop(L, 1);
        if (!invalidAxis.empty())
            luaL_error(L, "variation axis tags must be 4 bytes");
        else
            luaL_error(L, "unknown variation axis '%s'", unknownAxis.c_str());
    }

    FT_Error variationErr = 0;
    if (applyToFreeType)
        variationErr = FT_Set_Var_Design_Coordinates(face, mm->num_axis, coords.data());
    if (hbFont && !hbVars.empty()) hb_font_set_variations(hbFont, hbVars.data(), hbVars.size());
    FT_Done_MM_Var(g_ft, mm);
    lua_pop(L, 1);
    if (variationErr) luaL_error(L, "failed to apply font variations");
}

static void set_font_size(lua_State* L, FT_Face face, double size, int optionsIdx) {
    if (size <= 0) luaL_error(L, "font size must be positive");
    int dpi = 0;
    if (!is_no_options(L, optionsIdx)) {
        luaL_checktype(L, optionsIdx, LUA_TTABLE);
        dpi = opt_int_field(L, optionsIdx, "dpi", 0);
    }

    FT_Error err = 0;
    if (dpi > 0)
        err = FT_Set_Char_Size(face, 0, (FT_F26Dot6)(size * 64.0), (FT_UInt)dpi, (FT_UInt)dpi);
    else
        err = FT_Set_Pixel_Sizes(face, 0, (FT_UInt)std::max(1.0, size));

    if (err) luaL_error(L, "failed to set font size");
}

static FT_Int32 load_flags_for_options(lua_State* L, int optionsIdx, bool render);

static bool next_utf8_codepoint(lua_State* L, const char* text, size_t len, size_t& offset,
                                uint32_t& codepoint, size_t& codepointOffset) {
    if (offset >= len) return false;

    codepointOffset = offset;
    const uint8_t b0 = (uint8_t)text[offset++];
    if (b0 < 0x80) {
        codepoint = b0;
        return true;
    }

    uint32_t cp = 0;
    int extra = 0;
    uint32_t minValue = 0;
    if ((b0 & 0xE0) == 0xC0) {
        cp = b0 & 0x1F;
        extra = 1;
        minValue = 0x80;
    } else if ((b0 & 0xF0) == 0xE0) {
        cp = b0 & 0x0F;
        extra = 2;
        minValue = 0x800;
    } else if ((b0 & 0xF8) == 0xF0) {
        cp = b0 & 0x07;
        extra = 3;
        minValue = 0x10000;
    } else {
        luaL_error(L, "invalid UTF-8 text");
        return false;
    }

    if (offset + (size_t)extra > len) {
        luaL_error(L, "invalid UTF-8 text");
        return false;
    }
    for (int i = 0; i < extra; ++i) {
        const uint8_t b = (uint8_t)text[offset++];
        if ((b & 0xC0) != 0x80) {
            luaL_error(L, "invalid UTF-8 text");
            return false;
        }
        cp = (cp << 6) | (b & 0x3F);
    }

    if (cp < minValue || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        luaL_error(L, "invalid UTF-8 text");
        return false;
    }

    codepoint = cp;
    return true;
}

static bool ignore_codepoint_for_coverage(uint32_t codepoint) {
    return codepoint == '\n' || codepoint == '\r' || codepoint == '\t' || codepoint == 0x200D ||
           (codepoint >= 0xFE00 && codepoint <= 0xFE0F) ||
           (codepoint >= 0xE0100 && codepoint <= 0xE01EF);
}

static int typeface_has_glyph(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    int codepoint = luaL_checkinteger(L, 2);
    if (codepoint < 0) luaL_error(L, "codepoint must be non-negative");

    FT_Face face = open_source_face(L, *tf->source);
    FT_UInt glyph = FT_Get_Char_Index(face, (FT_ULong)codepoint);
    FT_Done_Face(face);
    lua_pushboolean(L, glyph != 0);
    return 1;
}

static int typeface_glyph_id(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    int codepoint = luaL_checkinteger(L, 2);
    if (codepoint < 0) luaL_error(L, "codepoint must be non-negative");

    FT_Face face = open_source_face(L, *tf->source);
    FT_UInt glyph = FT_Get_Char_Index(face, (FT_ULong)codepoint);
    FT_Done_Face(face);
    if (glyph == 0) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, glyph);
    }
    return 1;
}

static int typeface_has_text(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);

    FT_Face face = open_source_face(L, *tf->source);
    size_t offset = 0;
    uint32_t codepoint = 0;
    size_t codepointOffset = 0;
    while (next_utf8_codepoint(L, text, textLen, offset, codepoint, codepointOffset)) {
        if (ignore_codepoint_for_coverage(codepoint)) continue;
        if (FT_Get_Char_Index(face, (FT_ULong)codepoint) == 0) {
            FT_Done_Face(face);
            lua_pushboolean(L, false);
            return 1;
        }
    }

    FT_Done_Face(face);
    lua_pushboolean(L, true);
    return 1;
}

static int typeface_missing_glyphs(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);

    FT_Face face = open_source_face(L, *tf->source);
    lua_newtable(L);
    int outIndex = 1;

    size_t offset = 0;
    uint32_t codepoint = 0;
    size_t codepointOffset = 0;
    while (next_utf8_codepoint(L, text, textLen, offset, codepoint, codepointOffset)) {
        if (ignore_codepoint_for_coverage(codepoint)) continue;
        if (FT_Get_Char_Index(face, (FT_ULong)codepoint) != 0) continue;

        lua_createtable(L, 0, 2);
        lua_pushinteger(L, codepoint);
        lua_setfield(L, -2, "codepoint");
        lua_pushinteger(L, (int)codepointOffset);
        lua_setfield(L, -2, "offset");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, outIndex++);
    }

    FT_Done_Face(face);
    lua_setreadonly(L, -1, true);
    return 1;
}

static void append_utf8(std::string& out, uint32_t cp) {
    if (cp <= 0x7f) {
        out.push_back((char)cp);
    } else if (cp <= 0x7ff) {
        out.push_back((char)(0xc0 | (cp >> 6)));
        out.push_back((char)(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        out.push_back((char)(0xe0 | (cp >> 12)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
        out.push_back((char)(0x80 | (cp & 0x3f)));
    } else {
        out.push_back((char)(0xf0 | (cp >> 18)));
        out.push_back((char)(0x80 | ((cp >> 12) & 0x3f)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
        out.push_back((char)(0x80 | (cp & 0x3f)));
    }
}

static std::string decode_utf16be_name(const FT_Byte* bytes, FT_UInt len) {
    std::string out;
    for (FT_UInt i = 0; i + 1 < len; i += 2) {
        uint32_t cp = ((uint32_t)bytes[i] << 8) | bytes[i + 1];
        if (cp >= 0xd800 && cp <= 0xdbff && i + 3 < len) {
            uint32_t lo = ((uint32_t)bytes[i + 2] << 8) | bytes[i + 3];
            if (lo >= 0xdc00 && lo <= 0xdfff) {
                cp = 0x10000 + (((cp - 0xd800) << 10) | (lo - 0xdc00));
                i += 2;
            }
        }
        if (cp == 0 || (cp >= 0xd800 && cp <= 0xdfff)) continue;
        append_utf8(out, cp);
    }
    return out;
}

static std::string decode_sfnt_name(const FT_SfntName& name) {
    if (name.platform_id == TT_PLATFORM_MICROSOFT || name.platform_id == TT_PLATFORM_APPLE_UNICODE)
        return decode_utf16be_name(name.string, name.string_len);
    return std::string((const char*)name.string, (size_t)name.string_len);
}

static int typeface_names(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    FT_Face face = open_source_face(L, *tf->source);
    FT_UInt count = FT_Get_Sfnt_Name_Count(face);

    lua_createtable(L, (int)count, 0);
    int outIndex = 1;
    for (FT_UInt i = 0; i < count; ++i) {
        FT_SfntName name;
        if (FT_Get_Sfnt_Name(face, i, &name)) continue;

        lua_createtable(L, 0, 6);
        lua_pushinteger(L, name.name_id);
        lua_setfield(L, -2, "nameId");
        lua_pushinteger(L, name.platform_id);
        lua_setfield(L, -2, "platformId");
        lua_pushinteger(L, name.encoding_id);
        lua_setfield(L, -2, "encodingId");
        lua_pushinteger(L, name.language_id);
        lua_setfield(L, -2, "languageId");
        std::string text = decode_sfnt_name(name);
        lua_pushlstring(L, text.data(), text.size());
        lua_setfield(L, -2, "text");
        void* raw = lua_newbuffer(L, name.string_len);
        if (name.string_len > 0) std::memcpy(raw, name.string, name.string_len);
        lua_setfield(L, -2, "raw");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, outIndex++);
    }

    FT_Done_Face(face);
    lua_setreadonly(L, -1, true);
    return 1;
}

static int typeface_table(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    size_t tagLen = 0;
    const char* tagText = luaL_checklstring(L, 2, &tagLen);
    uint32_t tag = tag_from_string(std::string_view(tagText, tagLen));
    if (tag == 0) luaL_error(L, "table tag must be 4 bytes");

    FT_Face face = open_source_face(L, *tf->source);
    FT_ULong length = 0;
    if (FT_Load_Sfnt_Table(face, tag, 0, nullptr, &length) || length == 0) {
        FT_Done_Face(face);
        lua_pushnil(L);
        return 1;
    }

    void* out = lua_newbuffer(L, (size_t)length);
    if (FT_Load_Sfnt_Table(face, tag, 0, (FT_Byte*)out, &length)) {
        FT_Done_Face(face);
        lua_pushnil(L);
        return 1;
    }

    FT_Done_Face(face);
    return 1;
}

static int typeface_codepoints(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    FT_Face face = open_source_face(L, *tf->source);

    lua_newtable(L);
    int outIndex = 1;
    FT_UInt glyphIndex = 0;
    FT_ULong codepoint = FT_Get_First_Char(face, &glyphIndex);
    while (glyphIndex != 0) {
        lua_createtable(L, 0, 2);
        lua_pushinteger(L, (lua_Integer)codepoint);
        lua_setfield(L, -2, "codepoint");
        lua_pushinteger(L, glyphIndex);
        lua_setfield(L, -2, "glyphId");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, outIndex++);
        codepoint = FT_Get_Next_Char(face, codepoint, &glyphIndex);
    }

    FT_Done_Face(face);
    lua_setreadonly(L, -1, true);
    return 1;
}

static bool push_os2_table(lua_State* L, FT_Face face) {
    TT_OS2* os2 = (TT_OS2*)FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    if (!os2) return false;

    lua_createtable(L, 0, 16);
    lua_pushinteger(L, os2->version);
    lua_setfield(L, -2, "version");
    lua_pushinteger(L, os2->usWeightClass);
    lua_setfield(L, -2, "weight");
    lua_pushinteger(L, os2->usWidthClass);
    lua_setfield(L, -2, "stretch");
    lua_pushinteger(L, os2->fsSelection);
    lua_setfield(L, -2, "selection");
    lua_pushinteger(L, os2->sTypoAscender);
    lua_setfield(L, -2, "typoAscender");
    lua_pushinteger(L, os2->sTypoDescender);
    lua_setfield(L, -2, "typoDescender");
    lua_pushinteger(L, os2->sTypoLineGap);
    lua_setfield(L, -2, "typoLineGap");
    lua_pushinteger(L, os2->usWinAscent);
    lua_setfield(L, -2, "winAscent");
    lua_pushinteger(L, os2->usWinDescent);
    lua_setfield(L, -2, "winDescent");
    lua_pushinteger(L, os2->ySubscriptXSize);
    lua_setfield(L, -2, "subscriptXSize");
    lua_pushinteger(L, os2->ySubscriptYSize);
    lua_setfield(L, -2, "subscriptYSize");
    lua_pushinteger(L, os2->ySuperscriptXSize);
    lua_setfield(L, -2, "superscriptXSize");
    lua_pushinteger(L, os2->ySuperscriptYSize);
    lua_setfield(L, -2, "superscriptYSize");
    lua_pushinteger(L, os2->yStrikeoutSize);
    lua_setfield(L, -2, "strikeoutSize");
    lua_pushinteger(L, os2->yStrikeoutPosition);
    lua_setfield(L, -2, "strikeoutPosition");
    if (os2->version >= 2) {
        lua_pushinteger(L, os2->sxHeight);
        lua_setfield(L, -2, "xHeight");
        lua_pushinteger(L, os2->sCapHeight);
        lua_setfield(L, -2, "capHeight");
    }
    lua_setreadonly(L, -1, true);
    return true;
}

static int typeface_at(lua_State* L) {
    TypefaceUD* tf = check_typeface(L, 1);
    double size = luaL_checknumber(L, 2);
    int optionsIdx = lua_isnoneornil(L, 3) ? 0 : 3;

    FT_Face face = open_source_face(L, *tf->source);
    apply_variations(L, face, nullptr, optionsIdx, true);
    set_font_size(L, face, size, optionsIdx);

    hb_font_t* hbFont = hb_ft_font_create(face, nullptr);
    if (!hbFont) {
        FT_Done_Face(face);
        luaL_error(L, "failed to create HarfBuzz font");
    }

    hb_ft_font_set_funcs(hbFont);
    hb_ft_font_set_load_flags(hbFont, load_flags_for_options(L, optionsIdx, false));
    apply_variations(L, face, hbFont, optionsIdx, false);
    hb_ft_font_changed(hbFont);
    push_font(L, tf->source, face, hbFont, size);
    return 1;
}

static int typeface_close(lua_State* L) {
    TypefaceUD* tf = check_typeface_any(L);
    tf->source.reset();
    return 0;
}

static int typeface_index(lua_State* L) {
    TypefaceUD* tf = check_typeface_any(L);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, !tf->source);
        return 1;
    }

    if (!tf->source) {
        luaL_error(L, "attempt to use a closed typeface");
    }
    FaceSource& s = *tf->source;

    if (strcmp(key, "family") == 0) {
        lua_pushlstring(L, s.family.data(), s.family.size());
        return 1;
    }
    if (strcmp(key, "style") == 0) {
        lua_pushlstring(L, s.style.data(), s.style.size());
        return 1;
    }
    if (strcmp(key, "path") == 0) {
        if (s.path.empty())
            lua_pushnil(L);
        else
            lua_pushlstring(L, s.path.data(), s.path.size());
        return 1;
    }
    if (strcmp(key, "unitsPerEm") == 0) {
        lua_pushinteger(L, s.unitsPerEm);
        return 1;
    }
    if (strcmp(key, "glyphCount") == 0) {
        lua_pushinteger(L, s.glyphCount);
        return 1;
    }
    if (strcmp(key, "faceIndex") == 0) {
        lua_pushinteger(L, s.faceIndex);
        return 1;
    }
    if (strcmp(key, "weight") == 0) {
        lua_pushinteger(L, s.weight);
        return 1;
    }
    if (strcmp(key, "stretch") == 0) {
        lua_pushinteger(L, s.stretch);
        return 1;
    }
    if (strcmp(key, "italic") == 0) {
        lua_pushboolean(L, s.italic);
        return 1;
    }
    if (strcmp(key, "variations") == 0) {
        push_variations(L, s.variations);
        return 1;
    }
    if (strcmp(key, "os2") == 0) {
        FT_Face face = open_source_face(L, s);
        bool ok = push_os2_table(L, face);
        FT_Done_Face(face);
        if (!ok) lua_pushnil(L);
        return 1;
    }

    return 0;
}

static int typeface_tostring(lua_State* L) {
    TypefaceUD* tf = check_typeface_any(L);
    if (!tf->source) {
        lua_pushstring(L, "Typeface(closed)");
        return 1;
    }

    std::string text = "Typeface(" + tf->source->family;
    if (!tf->source->style.empty()) text += " " + tf->source->style;
    text += ")";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static void push_metrics(lua_State* L, FontUD* font) {
    FT_Size_Metrics& m = font->face->size->metrics;
    double ascent = ft26(m.ascender);
    double descent = ft26(m.descender);
    double height = ft26(m.height);
    double lineGap = height - (ascent - descent);

    lua_createtable(L, 0, 10);
    lua_pushnumber(L, ascent);
    lua_setfield(L, -2, "ascent");
    lua_pushnumber(L, descent);
    lua_setfield(L, -2, "descent");
    lua_pushnumber(L, lineGap);
    lua_setfield(L, -2, "lineGap");
    lua_pushnumber(L, height);
    lua_setfield(L, -2, "height");

    lua_pushnumber(
        L, ft26(FT_MulFix(font->face->underline_position, font->face->size->metrics.y_scale)));
    lua_setfield(L, -2, "underlinePosition");
    lua_pushnumber(
        L, ft26(FT_MulFix(font->face->underline_thickness, font->face->size->metrics.y_scale)));
    lua_setfield(L, -2, "underlineThickness");

    TT_OS2* os2 = (TT_OS2*)FT_Get_Sfnt_Table(font->face, FT_SFNT_OS2);
    if (os2) {
        lua_pushnumber(L,
                       ft26(FT_MulFix(os2->yStrikeoutPosition, font->face->size->metrics.y_scale)));
        lua_setfield(L, -2, "strikethroughPosition");
        lua_pushnumber(L, ft26(FT_MulFix(os2->yStrikeoutSize, font->face->size->metrics.y_scale)));
        lua_setfield(L, -2, "strikethroughThickness");
    }
    lua_setreadonly(L, -1, true);
}

static hb_direction_t check_direction(lua_State* L, int idx) {
    const char* value = luaL_checkstring(L, idx);
    if (strcmp(value, "auto") == 0) return HB_DIRECTION_INVALID;
    if (strcmp(value, "ltr") == 0) return HB_DIRECTION_LTR;
    if (strcmp(value, "rtl") == 0) return HB_DIRECTION_RTL;
    if (strcmp(value, "ttb") == 0) return HB_DIRECTION_TTB;
    if (strcmp(value, "btt") == 0) return HB_DIRECTION_BTT;
    luaL_error(L, "unsupported text direction '%s'", value);
    return HB_DIRECTION_INVALID;
}

static void apply_shape_options(lua_State* L, hb_buffer_t* buf, int optionsIdx,
                                std::vector<hb_feature_t>& features) {
    if (is_no_options(L, optionsIdx)) {
        hb_buffer_guess_segment_properties(buf);
        return;
    }

    optionsIdx = lua_absindex(L, optionsIdx);
    luaL_checktype(L, optionsIdx, LUA_TTABLE);

    bool guessed = false;
    lua_getfield(L, optionsIdx, "direction");
    if (!lua_isnil(L, -1)) {
        hb_direction_t dir = check_direction(L, -1);
        if (dir != HB_DIRECTION_INVALID)
            hb_buffer_set_direction(buf, dir);
        else {
            hb_buffer_guess_segment_properties(buf);
            guessed = true;
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, optionsIdx, "script");
    if (!lua_isnil(L, -1)) {
        const char* script = luaL_checkstring(L, -1);
        if (strcmp(script, "auto") != 0)
            hb_buffer_set_script(buf, hb_script_from_string(script, -1));
    }
    lua_pop(L, 1);

    lua_getfield(L, optionsIdx, "language");
    if (!lua_isnil(L, -1)) {
        size_t len = 0;
        const char* language = luaL_checklstring(L, -1, &len);
        hb_buffer_set_language(buf, hb_language_from_string(language, (int)len));
    }
    lua_pop(L, 1);

    lua_getfield(L, optionsIdx, "clusterLevel");
    if (!lua_isnil(L, -1)) {
        const char* level = luaL_checkstring(L, -1);
        if (strcmp(level, "monotoneGraphemes") == 0)
            hb_buffer_set_cluster_level(buf, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
        else if (strcmp(level, "monotoneCharacters") == 0)
            hb_buffer_set_cluster_level(buf, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
        else if (strcmp(level, "characters") == 0)
            hb_buffer_set_cluster_level(buf, HB_BUFFER_CLUSTER_LEVEL_CHARACTERS);
        else
            luaL_error(L, "unsupported cluster level '%s'", level);
    }
    lua_pop(L, 1);

    lua_getfield(L, optionsIdx, "features");
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TTABLE);
        int featuresIdx = lua_absindex(L, -1);
        lua_pushnil(L);
        while (lua_next(L, featuresIdx) != 0) {
            size_t tagLen = 0;
            const char* tagText = luaL_checklstring(L, -2, &tagLen);
            hb_feature_t feature{};
            feature.tag = tag_from_string(std::string_view(tagText, tagLen));
            if (feature.tag == 0) luaL_error(L, "feature tags must be 4 bytes");
            feature.start = HB_FEATURE_GLOBAL_START;
            feature.end = HB_FEATURE_GLOBAL_END;
            feature.value = lua_isboolean(L, -1) ? (lua_toboolean(L, -1) ? 1 : 0)
                                                 : (uint32_t)luaL_checkinteger(L, -1);
            features.push_back(feature);
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    if (!guessed) hb_buffer_guess_segment_properties(buf);
}

static ShapedRunUD shape_text(lua_State* L, FontUD* font, const char* text, size_t textLen,
                              int optionsIdx) {
    hb_buffer_t* buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, text, (int)textLen, 0, (int)textLen);

    std::vector<hb_feature_t> features;
    apply_shape_options(L, buf, optionsIdx, features);

    hb_shape(font->hbFont, buf, features.empty() ? nullptr : features.data(), features.size());

    unsigned count = 0;
    hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buf, &count);
    hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buf, &count);

    ShapedRunUD run;
    run.text.assign(text, textLen);
    run.glyphs.reserve(count);

    bool hasBounds = false;
    double minX = 0, minY = 0, maxX = 0, maxY = 0;
    double penX = 0;
    double penY = 0;

    for (unsigned i = 0; i < count; ++i) {
        ShapedGlyphNative glyph;
        glyph.id = infos[i].codepoint;
        glyph.cluster = infos[i].cluster;
        glyph.xAdvance = ft26(positions[i].x_advance);
        glyph.yAdvance = ft26(positions[i].y_advance);
        glyph.xOffset = ft26(positions[i].x_offset);
        glyph.yOffset = ft26(positions[i].y_offset);
        run.glyphs.push_back(glyph);

        hb_glyph_extents_t extents{};
        if (hb_font_get_glyph_extents(font->hbFont, glyph.id, &extents)) {
            double x0 = penX + glyph.xOffset + ft26(extents.x_bearing);
            double y0 = penY + glyph.yOffset + ft26(extents.y_bearing);
            double x1 = x0 + ft26(extents.width);
            double y1 = y0 + ft26(extents.height);
            if (x1 < x0) std::swap(x0, x1);
            if (y1 < y0) std::swap(y0, y1);

            if (!hasBounds) {
                minX = x0;
                minY = y0;
                maxX = x1;
                maxY = y1;
                hasBounds = true;
            } else {
                minX = std::min(minX, x0);
                minY = std::min(minY, y0);
                maxX = std::max(maxX, x1);
                maxY = std::max(maxY, y1);
            }
        }

        penX += glyph.xAdvance;
        penY += glyph.yAdvance;
    }

    run.advanceX = penX;
    run.advanceY = penY;
    if (hasBounds) run.bounds = { minX, minY, maxX - minX, maxY - minY };
    hb_buffer_destroy(buf);
    return run;
}

static void push_shaped_glyphs(lua_State* L, const std::vector<ShapedGlyphNative>& glyphs) {
    lua_createtable(L, (int)glyphs.size(), 0);
    int i = 1;
    for (const ShapedGlyphNative& glyph : glyphs) {
        lua_createtable(L, 0, 6);
        lua_pushinteger(L, glyph.id);
        lua_setfield(L, -2, "id");
        lua_pushinteger(L, glyph.cluster);
        lua_setfield(L, -2, "cluster");
        lua_pushnumber(L, glyph.xAdvance);
        lua_setfield(L, -2, "xAdvance");
        lua_pushnumber(L, glyph.yAdvance);
        lua_setfield(L, -2, "yAdvance");
        lua_pushnumber(L, glyph.xOffset);
        lua_setfield(L, -2, "xOffset");
        lua_pushnumber(L, glyph.yOffset);
        lua_setfield(L, -2, "yOffset");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, i++);
    }
    lua_setreadonly(L, -1, true);
}

static int font_shape(lua_State* L) {
    FontUD* font = check_font(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);
    push_shaped_run(L, shape_text(L, font, text, textLen, lua_isnoneornil(L, 3) ? 0 : 3));
    return 1;
}

static void push_measure(lua_State* L, const ShapedRunUD& run) {
    lua_createtable(L, 0, 4);
    lua_pushnumber(L, run.bounds.width);
    lua_setfield(L, -2, "width");
    lua_pushnumber(L, run.bounds.height);
    lua_setfield(L, -2, "height");
    push_vec2(L, run.advanceX, run.advanceY);
    lua_setfield(L, -2, "advance");
    push_rect(L, run.bounds);
    lua_setfield(L, -2, "bounds");
    lua_setreadonly(L, -1, true);
}

static int font_measure(lua_State* L) {
    FontUD* font = check_font(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);
    ShapedRunUD run = shape_text(L, font, text, textLen, lua_isnoneornil(L, 3) ? 0 : 3);
    push_measure(L, run);
    return 1;
}

static int font_bounds(lua_State* L) {
    FontUD* font = check_font(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);
    ShapedRunUD run = shape_text(L, font, text, textLen, lua_isnoneornil(L, 3) ? 0 : 3);
    push_rect(L, run.bounds);
    return 1;
}

static TextAlign opt_text_align(lua_State* L, int optionsIdx) {
    if (is_no_options(L, optionsIdx)) return TextAlign::Left;

    lua_getfield(L, optionsIdx, "align");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return TextAlign::Left;
    }

    const char* align = luaL_checkstring(L, -1);
    lua_pop(L, 1);

    if (strcmp(align, "left") == 0) return TextAlign::Left;
    if (strcmp(align, "center") == 0) return TextAlign::Center;
    if (strcmp(align, "right") == 0) return TextAlign::Right;
    if (strcmp(align, "justify") == 0) luaL_error(L, "justify alignment is not supported yet");

    luaL_error(L, "unsupported text alignment '%s'", align);
    return TextAlign::Left;
}

static double alignment_offset(TextAlign align, double targetWidth, double lineWidth) {
    if (align == TextAlign::Center) return (targetWidth - lineWidth) * 0.5;
    if (align == TextAlign::Right) return targetWidth - lineWidth;
    return 0;
}

static FT_Int32 load_flags_for_options(lua_State* L, int optionsIdx, bool render) {
    FT_Int32 flags = render ? FT_LOAD_RENDER : FT_LOAD_DEFAULT;
    if (is_no_options(L, optionsIdx)) return flags | FT_LOAD_COLOR;

    optionsIdx = lua_absindex(L, optionsIdx);
    luaL_checktype(L, optionsIdx, LUA_TTABLE);

    const char* hinting = nullptr;
    lua_getfield(L, optionsIdx, "hinting");
    if (!lua_isnil(L, -1)) hinting = luaL_checkstring(L, -1);
    if (hinting) {
        if (strcmp(hinting, "none") == 0)
            flags |= FT_LOAD_NO_HINTING;
        else if (strcmp(hinting, "light") == 0)
            flags |= FT_LOAD_TARGET_LIGHT;
        else if (strcmp(hinting, "mono") == 0)
            flags |= FT_LOAD_TARGET_MONO;
        else if (strcmp(hinting, "normal") != 0)
            luaL_error(L, "unsupported hinting mode '%s'", hinting);
    }
    lua_pop(L, 1);

    if (!opt_bool_field(L, optionsIdx, "embeddedBitmaps", true)) flags |= FT_LOAD_NO_BITMAP;
    if (opt_bool_field(L, optionsIdx, "colorGlyphs", true)) flags |= FT_LOAD_COLOR;
    if (!opt_bool_field(L, optionsIdx, "antialias", true)) flags |= FT_LOAD_TARGET_MONO;
    return flags;
}

static int font_glyph_metrics(lua_State* L) {
    FontUD* font = check_font(L, 1);
    int glyphId = luaL_checkinteger(L, 2);
    if (glyphId < 0) luaL_error(L, "glyph id must be non-negative");
    if (FT_Load_Glyph(font->face, (FT_UInt)glyphId, load_flags_for_options(L, 3, false)))
        luaL_error(L, "failed to load glyph");

    FT_Glyph_Metrics& m = font->face->glyph->metrics;
    lua_createtable(L, 0, 8);
    lua_pushnumber(L, ft26(m.width));
    lua_setfield(L, -2, "width");
    lua_pushnumber(L, ft26(m.height));
    lua_setfield(L, -2, "height");
    lua_pushnumber(L, ft26(m.horiBearingX));
    lua_setfield(L, -2, "horiBearingX");
    lua_pushnumber(L, ft26(m.horiBearingY));
    lua_setfield(L, -2, "horiBearingY");
    lua_pushnumber(L, ft26(m.horiAdvance));
    lua_setfield(L, -2, "horiAdvance");
    if (FT_HAS_VERTICAL(font->face)) {
        lua_pushnumber(L, ft26(m.vertBearingX));
        lua_setfield(L, -2, "vertBearingX");
        lua_pushnumber(L, ft26(m.vertBearingY));
        lua_setfield(L, -2, "vertBearingY");
        lua_pushnumber(L, ft26(m.vertAdvance));
        lua_setfield(L, -2, "vertAdvance");
    }
    lua_setreadonly(L, -1, true);
    return 1;
}

struct OutlineBuilder {
    lua_State* L = nullptr;
    int commandsIndex = 0;
    int nextIndex = 1;
};

static void push_outline_point(lua_State* L, const char* prefix, const FT_Vector* point) {
    std::string xKey = *prefix ? std::string(prefix) + "X" : "x";
    std::string yKey = *prefix ? std::string(prefix) + "Y" : "y";
    lua_pushnumber(L, ft26(point->x));
    lua_setfield(L, -2, xKey.c_str());
    lua_pushnumber(L, ft26(point->y));
    lua_setfield(L, -2, yKey.c_str());
}

static int outline_move_to(const FT_Vector* to, void* user) {
    OutlineBuilder* b = static_cast<OutlineBuilder*>(user);
    lua_createtable(b->L, 0, 3);
    lua_pushstring(b->L, "moveTo");
    lua_setfield(b->L, -2, "type");
    push_outline_point(b->L, "", to);
    lua_setreadonly(b->L, -1, true);
    lua_rawseti(b->L, b->commandsIndex, b->nextIndex++);
    return 0;
}

static int outline_line_to(const FT_Vector* to, void* user) {
    OutlineBuilder* b = static_cast<OutlineBuilder*>(user);
    lua_createtable(b->L, 0, 3);
    lua_pushstring(b->L, "lineTo");
    lua_setfield(b->L, -2, "type");
    push_outline_point(b->L, "", to);
    lua_setreadonly(b->L, -1, true);
    lua_rawseti(b->L, b->commandsIndex, b->nextIndex++);
    return 0;
}

static int outline_conic_to(const FT_Vector* control, const FT_Vector* to, void* user) {
    OutlineBuilder* b = static_cast<OutlineBuilder*>(user);
    lua_createtable(b->L, 0, 5);
    lua_pushstring(b->L, "quadTo");
    lua_setfield(b->L, -2, "type");
    push_outline_point(b->L, "control", control);
    push_outline_point(b->L, "", to);
    lua_setreadonly(b->L, -1, true);
    lua_rawseti(b->L, b->commandsIndex, b->nextIndex++);
    return 0;
}

static int outline_cubic_to(const FT_Vector* control1, const FT_Vector* control2,
                            const FT_Vector* to, void* user) {
    OutlineBuilder* b = static_cast<OutlineBuilder*>(user);
    lua_createtable(b->L, 0, 7);
    lua_pushstring(b->L, "cubicTo");
    lua_setfield(b->L, -2, "type");
    push_outline_point(b->L, "control1", control1);
    push_outline_point(b->L, "control2", control2);
    push_outline_point(b->L, "", to);
    lua_setreadonly(b->L, -1, true);
    lua_rawseti(b->L, b->commandsIndex, b->nextIndex++);
    return 0;
}

static int font_outline_glyph(lua_State* L) {
    FontUD* font = check_font(L, 1);
    int glyphId = luaL_checkinteger(L, 2);
    if (glyphId < 0) luaL_error(L, "glyph id must be non-negative");

    int optionsIdx = lua_isnoneornil(L, 3) ? 0 : 3;
    FT_Int32 loadFlags = load_flags_for_options(L, optionsIdx, false);
    loadFlags |= FT_LOAD_NO_BITMAP;
    loadFlags &= ~FT_LOAD_COLOR;
    if (FT_Load_Glyph(font->face, (FT_UInt)glyphId, loadFlags))
        luaL_error(L, "failed to load glyph");

    FT_GlyphSlot slot = font->face->glyph;
    if (slot->format != FT_GLYPH_FORMAT_OUTLINE) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 3);
    lua_createtable(L, slot->outline.n_contours + slot->outline.n_points, 0);
    int commandsIndex = lua_absindex(L, -1);

    OutlineBuilder builder{ L, commandsIndex, 1 };
    FT_Outline_Funcs funcs{};
    funcs.move_to = outline_move_to;
    funcs.line_to = outline_line_to;
    funcs.conic_to = outline_conic_to;
    funcs.cubic_to = outline_cubic_to;
    funcs.shift = 0;
    funcs.delta = 0;

    if (FT_Outline_Decompose(&slot->outline, &funcs, &builder))
        luaL_error(L, "failed to decompose glyph outline");

    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "commands");

    FT_BBox box;
    FT_Outline_Get_CBox(&slot->outline, &box);
    FontRect bounds{ ft26(box.xMin), ft26(box.yMin), ft26(box.xMax - box.xMin),
                     ft26(box.yMax - box.yMin) };
    push_rect(L, bounds);
    lua_setfield(L, -2, "bounds");
    lua_pushnumber(L, ft26(slot->advance.x));
    lua_setfield(L, -2, "advanceX");
    lua_pushnumber(L, ft26(slot->advance.y));
    lua_setfield(L, -2, "advanceY");
    lua_setreadonly(L, -1, true);
    return 1;
}

static FT_Render_Mode render_mode_from_options(lua_State* L, int optionsIdx, FT_Int32& loadFlags) {
    const char* modeName = "gray";
    if (!is_no_options(L, optionsIdx)) {
        luaL_checktype(L, optionsIdx, LUA_TTABLE);
        lua_getfield(L, optionsIdx, "mode");
        if (!lua_isnil(L, -1)) modeName = luaL_checkstring(L, -1);
        lua_pop(L, 1);
    }

    if (strcmp(modeName, "mono") == 0) {
        loadFlags |= FT_LOAD_TARGET_MONO;
        return FT_RENDER_MODE_MONO;
    }
    if (strcmp(modeName, "gray") == 0) return FT_RENDER_MODE_NORMAL;
    if (strcmp(modeName, "lcd") == 0) {
        loadFlags |= FT_LOAD_TARGET_LCD;
        return FT_RENDER_MODE_LCD;
    }
    if (strcmp(modeName, "color") == 0) {
        loadFlags |= FT_LOAD_COLOR;
        return FT_RENDER_MODE_NORMAL;
    }

    luaL_error(L, "unsupported rasterize mode '%s'", modeName);
    return FT_RENDER_MODE_NORMAL;
}

static const char* bitmap_format_name(FT_Pixel_Mode mode) {
    switch (mode) {
        case FT_PIXEL_MODE_MONO:
            return "mono1";
        case FT_PIXEL_MODE_GRAY:
            return "gray8";
        case FT_PIXEL_MODE_LCD:
        case FT_PIXEL_MODE_LCD_V:
            return "lcd24";
        case FT_PIXEL_MODE_BGRA:
            return "bgra32";
        default:
            return "gray8";
    }
}

static int font_rasterize_glyph(lua_State* L) {
    FontUD* font = check_font(L, 1);
    int glyphId = luaL_checkinteger(L, 2);
    if (glyphId < 0) luaL_error(L, "glyph id must be non-negative");

    int optionsIdx = lua_isnoneornil(L, 3) ? 0 : 3;
    FT_Int32 loadFlags = load_flags_for_options(L, optionsIdx, false);
    FT_Render_Mode renderMode = render_mode_from_options(L, optionsIdx, loadFlags);

    FT_Vector delta{ 0, 0 };
    if (optionsIdx != 0) {
        delta.x = (FT_Pos)(opt_number_field(L, optionsIdx, "subpixelX", 0) * 64.0);
        delta.y = (FT_Pos)(opt_number_field(L, optionsIdx, "subpixelY", 0) * 64.0);
    }
    FT_Set_Transform(font->face, nullptr, &delta);

    if (FT_Load_Glyph(font->face, (FT_UInt)glyphId, loadFlags)) {
        FT_Set_Transform(font->face, nullptr, nullptr);
        luaL_error(L, "failed to load glyph");
    }
    if (font->face->glyph->format != FT_GLYPH_FORMAT_BITMAP) {
        if (FT_Render_Glyph(font->face->glyph, renderMode)) {
            FT_Set_Transform(font->face, nullptr, nullptr);
            luaL_error(L, "failed to render glyph");
        }
    }
    FT_Set_Transform(font->face, nullptr, nullptr);

    FT_GlyphSlot slot = font->face->glyph;
    FT_Bitmap& bitmap = slot->bitmap;
    int pitch = std::abs(bitmap.pitch);
    size_t byteSize = (size_t)pitch * bitmap.rows;

    lua_createtable(L, 0, 10);
    lua_pushinteger(L, bitmap.width);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, bitmap.rows);
    lua_setfield(L, -2, "height");
    lua_pushinteger(L, pitch);
    lua_setfield(L, -2, "pitch");
    lua_pushinteger(L, slot->bitmap_left);
    lua_setfield(L, -2, "left");
    lua_pushinteger(L, slot->bitmap_top);
    lua_setfield(L, -2, "top");
    lua_pushnumber(L, ft26(slot->advance.x));
    lua_setfield(L, -2, "advanceX");
    lua_pushnumber(L, ft26(slot->advance.y));
    lua_setfield(L, -2, "advanceY");

    const char* format = bitmap_format_name((FT_Pixel_Mode)bitmap.pixel_mode);
    lua_pushstring(L, format);
    lua_setfield(L, -2, "format");
    if (bitmap.pixel_mode == FT_PIXEL_MODE_LCD) {
        lua_pushstring(L, "rgb");
        lua_setfield(L, -2, "lcdOrder");
    } else if (bitmap.pixel_mode == FT_PIXEL_MODE_LCD_V) {
        lua_pushstring(L, "vrgb");
        lua_setfield(L, -2, "lcdOrder");
    }

    void* out = lua_newbuffer(L, byteSize);
    if (byteSize > 0 && bitmap.buffer) {
        uint8_t* dst = static_cast<uint8_t*>(out);
        for (unsigned row = 0; row < bitmap.rows; ++row) {
            const uint8_t* src = bitmap.pitch >= 0
                                     ? bitmap.buffer + row * bitmap.pitch
                                     : bitmap.buffer + (bitmap.rows - 1 - row) * pitch;
            std::memcpy(dst + row * pitch, src, pitch);
        }
    }
    lua_setfield(L, -2, "buffer");
    lua_setreadonly(L, -1, true);
    return 1;
}

static uint8_t mono_coverage(const uint8_t* row, int x) {
    return (row[x >> 3] & (0x80 >> (x & 7))) ? 255 : 0;
}

static RenderedGlyphBitmap render_glyph_for_mask(lua_State* L, FontUD* font, uint32_t glyphId,
                                                 double penX, double penY, double offsetX,
                                                 double offsetY, int optionsIdx) {
    FT_Int32 loadFlags = load_flags_for_options(L, optionsIdx, false);
    FT_Render_Mode renderMode = render_mode_from_options(L, optionsIdx, loadFlags);
    if (renderMode == FT_RENDER_MODE_LCD || renderMode == FT_RENDER_MODE_LCD_V)
        luaL_error(L, "font render currently supports mono and gray raster modes");

    FT_Vector delta{ 0, 0 };
    if (optionsIdx != 0) {
        delta.x = (FT_Pos)(opt_number_field(L, optionsIdx, "subpixelX", 0) * 64.0);
        delta.y = (FT_Pos)(opt_number_field(L, optionsIdx, "subpixelY", 0) * 64.0);
    }
    FT_Set_Transform(font->face, nullptr, &delta);

    if (FT_Load_Glyph(font->face, (FT_UInt)glyphId, loadFlags)) {
        FT_Set_Transform(font->face, nullptr, nullptr);
        luaL_error(L, "failed to load glyph");
    }
    if (font->face->glyph->format != FT_GLYPH_FORMAT_BITMAP) {
        if (FT_Render_Glyph(font->face->glyph, renderMode)) {
            FT_Set_Transform(font->face, nullptr, nullptr);
            luaL_error(L, "failed to render glyph");
        }
    }
    FT_Set_Transform(font->face, nullptr, nullptr);

    FT_GlyphSlot slot = font->face->glyph;
    FT_Bitmap& bitmap = slot->bitmap;
    if (bitmap.pixel_mode != FT_PIXEL_MODE_GRAY && bitmap.pixel_mode != FT_PIXEL_MODE_MONO &&
        bitmap.pixel_mode != FT_PIXEL_MODE_BGRA)
        luaL_error(L, "font render currently supports mono, gray, and BGRA glyph bitmaps");

    RenderedGlyphBitmap out;
    out.x = (int)std::floor(penX + offsetX + slot->bitmap_left);
    out.y = (int)std::floor(-(penY + offsetY + slot->bitmap_top));
    out.width = (int)bitmap.width;
    out.height = (int)bitmap.rows;
    out.color = bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
    out.pitch = out.width * (out.color ? 4 : 1);
    out.advanceX = ft26(slot->advance.x);
    out.advanceY = ft26(slot->advance.y);
    out.pixels.resize((size_t)out.pitch * out.height);

    int srcPitch = std::abs(bitmap.pitch);
    for (int row = 0; row < out.height; ++row) {
        const uint8_t* src = bitmap.pitch >= 0 ? bitmap.buffer + row * bitmap.pitch
                                               : bitmap.buffer + (out.height - 1 - row) * srcPitch;
        uint8_t* dst = out.pixels.data() + (size_t)row * out.pitch;
        if (bitmap.pixel_mode == FT_PIXEL_MODE_BGRA) {
            for (int x = 0; x < out.width; ++x) {
                const uint8_t* s = src + x * 4;
                uint8_t* d = dst + x * 4;
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = s[3];
            }
        } else if (bitmap.pixel_mode == FT_PIXEL_MODE_GRAY) {
            std::memcpy(dst, src, out.width);
        } else {
            for (int x = 0; x < out.width; ++x) dst[x] = mono_coverage(src, x);
        }
    }

    return out;
}

static void push_rendered_mask(lua_State* L, int width, int height, int baselineX, int baselineY,
                               double advanceX, double advanceY, FontRect bounds,
                               const std::vector<RenderedGlyphBitmap>& glyphs) {
    int imageWidth = std::max(1, width);
    int imageHeight = std::max(1, height);
    bool hasColor = false;
    for (const RenderedGlyphBitmap& glyph : glyphs) {
        if (glyph.color) {
            hasColor = true;
            break;
        }
    }

    int channels = hasColor ? 4 : 2;
    int stride = imageWidth * channels;
    size_t byteSize = (size_t)stride * imageHeight;

    lua_createtable(L, 0, 8);
    lua_pushinteger(L, imageWidth);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, imageHeight);
    lua_setfield(L, -2, "height");
    lua_pushinteger(L, stride);
    lua_setfield(L, -2, "stride");
    lua_pushstring(L, hasColor ? "rgba8" : "grayAlpha8");
    lua_setfield(L, -2, "format");
    push_vec2(L, baselineX, baselineY);
    lua_setfield(L, -2, "baseline");
    push_vec2(L, advanceX, advanceY);
    lua_setfield(L, -2, "advance");
    push_rect(L, bounds);
    lua_setfield(L, -2, "bounds");

    uint8_t* out = static_cast<uint8_t*>(lua_newbuffer(L, byteSize));
    if (byteSize > 0) std::memset(out, 0, byteSize);

    for (const RenderedGlyphBitmap& glyph : glyphs) {
        for (int row = 0; row < glyph.height; ++row) {
            int dstY = glyph.y + baselineY + row;
            if (dstY < 0 || dstY >= imageHeight) continue;
            for (int x = 0; x < glyph.width; ++x) {
                int dstX = glyph.x + baselineX + x;
                if (dstX < 0 || dstX >= imageWidth) continue;

                if (hasColor) {
                    uint8_t* px = out + (size_t)dstY * stride + (size_t)dstX * 4;
                    uint8_t srcR = 255;
                    uint8_t srcG = 255;
                    uint8_t srcB = 255;
                    uint8_t srcA = 0;
                    if (glyph.color) {
                        const uint8_t* src =
                            glyph.pixels.data() + (size_t)row * glyph.pitch + x * 4;
                        srcR = src[0];
                        srcG = src[1];
                        srcB = src[2];
                        srcA = src[3];
                    } else {
                        srcA = glyph.pixels[(size_t)row * glyph.pitch + x];
                    }
                    if (srcA == 0) continue;

                    uint32_t invA = 255 - srcA;
                    uint32_t dstA = px[3];
                    uint32_t outA = srcA + (dstA * invA + 127) / 255;
                    uint32_t srcPremulR = (srcR * srcA + 127) / 255;
                    uint32_t srcPremulG = (srcG * srcA + 127) / 255;
                    uint32_t srcPremulB = (srcB * srcA + 127) / 255;
                    uint32_t dstPremulR = (px[0] * dstA + 127) / 255;
                    uint32_t dstPremulG = (px[1] * dstA + 127) / 255;
                    uint32_t dstPremulB = (px[2] * dstA + 127) / 255;
                    uint32_t outPremulR = srcPremulR + (dstPremulR * invA + 127) / 255;
                    uint32_t outPremulG = srcPremulG + (dstPremulG * invA + 127) / 255;
                    uint32_t outPremulB = srcPremulB + (dstPremulB * invA + 127) / 255;
                    px[0] =
                        outA ? (uint8_t)std::min(255u, (outPremulR * 255 + outA / 2) / outA) : 0;
                    px[1] =
                        outA ? (uint8_t)std::min(255u, (outPremulG * 255 + outA / 2) / outA) : 0;
                    px[2] =
                        outA ? (uint8_t)std::min(255u, (outPremulB * 255 + outA / 2) / outA) : 0;
                    px[3] = (uint8_t)std::min(255u, outA);
                } else {
                    uint8_t coverage = glyph.pixels[(size_t)row * glyph.pitch + x];
                    if (coverage == 0) continue;

                    uint8_t* px = out + (size_t)dstY * stride + (size_t)dstX * 2;
                    px[0] = 255;
                    px[1] = (uint8_t)(coverage + (px[1] * (255 - coverage) + 127) / 255);
                }
            }
        }
    }

    lua_setfield(L, -2, "buffer");
    lua_setreadonly(L, -1, true);
}

static int font_render_glyph(lua_State* L) {
    FontUD* font = check_font(L, 1);
    int glyphId = luaL_checkinteger(L, 2);
    if (glyphId < 0) luaL_error(L, "glyph id must be non-negative");

    int optionsIdx = lua_isnoneornil(L, 3) ? 0 : 3;
    RenderedGlyphBitmap glyph =
        render_glyph_for_mask(L, font, (uint32_t)glyphId, 0, 0, 0, 0, optionsIdx);

    int minX = glyph.x;
    int minY = glyph.y;
    int maxX = glyph.x + glyph.width;
    int maxY = glyph.y + glyph.height;
    int width = std::max(0, maxX - minX);
    int height = std::max(0, maxY - minY);
    int baselineX = -minX;
    int baselineY = -minY;
    FontRect bounds{ (double)minX, (double)minY, (double)width, (double)height };
    push_rendered_mask(L, width, height, baselineX, baselineY, glyph.advanceX, glyph.advanceY,
                       bounds, { glyph });
    return 1;
}

static int font_render_text(lua_State* L) {
    FontUD* font = check_font(L, 1);
    size_t textLen = 0;
    const char* text = luaL_checklstring(L, 2, &textLen);
    int optionsIdx = lua_isnoneornil(L, 3) ? 0 : 3;

    TextAlign align = opt_text_align(L, optionsIdx);
    double lineHeight = ft26(font->face->size->metrics.height);
    double targetWidth = 0;
    bool hasTargetWidth = false;
    if (optionsIdx != 0) {
        lineHeight = opt_number_field(L, optionsIdx, "lineHeight", lineHeight);
        targetWidth = opt_number_field(L, optionsIdx, "width", 0);
        hasTargetWidth = targetWidth > 0;
    }
    if (lineHeight <= 0) luaL_error(L, "lineHeight must be positive");

    std::vector<ShapedRunUD> lines;
    lines.reserve(1);
    double maxLineWidth = 0;
    size_t lineStart = 0;
    while (lineStart <= textLen) {
        size_t lineEnd = lineStart;
        while (lineEnd < textLen && text[lineEnd] != '\n') ++lineEnd;
        size_t lineLen = lineEnd - lineStart;
        if (lineLen > 0 && text[lineEnd - 1] == '\r') --lineLen;

        ShapedRunUD line = shape_text(L, font, text + lineStart, lineLen, optionsIdx);
        maxLineWidth = std::max(maxLineWidth, line.advanceX);
        lines.push_back(std::move(line));

        if (lineEnd >= textLen) break;
        lineStart = lineEnd + 1;
    }

    if (lines.empty()) lines.push_back(shape_text(L, font, "", 0, optionsIdx));
    if (!hasTargetWidth) targetWidth = maxLineWidth;

    std::vector<RenderedGlyphBitmap> glyphs;
    size_t glyphCount = 0;
    for (const ShapedRunUD& line : lines) glyphCount += line.glyphs.size();
    glyphs.reserve(glyphCount);

    bool hasBounds = false;
    int minX = 0, minY = 0, maxX = 0, maxY = 0;
    double maxAdvanceX = 0;

    for (size_t lineIndex = 0; lineIndex < lines.size(); ++lineIndex) {
        const ShapedRunUD& line = lines[lineIndex];
        double penX = alignment_offset(align, targetWidth, line.advanceX);
        double penY = -(double)lineIndex * lineHeight;
        maxAdvanceX = std::max(maxAdvanceX, penX + line.advanceX);

        for (const ShapedGlyphNative& shaped : line.glyphs) {
            RenderedGlyphBitmap glyph = render_glyph_for_mask(
                L, font, shaped.id, penX, penY, shaped.xOffset, shaped.yOffset, optionsIdx);

            if (glyph.width > 0 && glyph.height > 0) {
                int gx0 = glyph.x;
                int gy0 = glyph.y;
                int gx1 = glyph.x + glyph.width;
                int gy1 = glyph.y + glyph.height;
                if (!hasBounds) {
                    minX = gx0;
                    minY = gy0;
                    maxX = gx1;
                    maxY = gy1;
                    hasBounds = true;
                } else {
                    minX = std::min(minX, gx0);
                    minY = std::min(minY, gy0);
                    maxX = std::max(maxX, gx1);
                    maxY = std::max(maxY, gy1);
                }
            }

            glyphs.push_back(std::move(glyph));
            penX += shaped.xAdvance;
            penY += shaped.yAdvance;
        }
    }

    if (hasTargetWidth) {
        minX = hasBounds ? std::min(minX, 0) : 0;
        maxX =
            hasBounds ? std::max(maxX, (int)std::ceil(targetWidth)) : (int)std::ceil(targetWidth);
        hasBounds = true;
    }

    int width = hasBounds ? std::max(0, maxX - minX) : 0;
    int height = hasBounds ? std::max(0, maxY - minY) : 0;
    int baselineX = hasBounds ? -minX : 0;
    int baselineY = hasBounds ? -minY : 0;
    FontRect bounds{ hasBounds ? (double)minX : 0, hasBounds ? (double)minY : 0, (double)width,
                     (double)height };
    double advanceY = lines.size() > 1 ? (double)(lines.size() - 1) * lineHeight : 0;
    push_rendered_mask(L, width, height, baselineX, baselineY, maxAdvanceX, advanceY, bounds,
                       glyphs);
    return 1;
}

static int font_index(lua_State* L) {
    FontUD* font = check_font_any(L);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, !font->face || !font->hbFont);
        return 1;
    }

    if (!font->face || !font->hbFont) {
        luaL_error(L, "attempt to use a closed font");
    }

    if (strcmp(key, "face") == 0) {
        push_typeface(L, font->source);
        return 1;
    }
    if (strcmp(key, "size") == 0) {
        lua_pushnumber(L, font->size);
        return 1;
    }
    if (strcmp(key, "metrics") == 0) {
        push_metrics(L, font);
        return 1;
    }

    return 0;
}

static int font_close(lua_State* L) {
    FontUD* font = check_font_any(L);
    font->close();
    return 0;
}

static int font_tostring(lua_State* L) {
    FontUD* font = check_font_any(L);
    if (!font->face || !font->hbFont) {
        lua_pushstring(L, "Font(closed)");
        return 1;
    }

    std::string text =
        "Font(" + font->source->family + ", size=" + std::to_string(font->size) + ")";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int shaped_run_index(lua_State* L) {
    ShapedRunUD* run = check_shaped_run_any(L);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, run->closed);
        return 1;
    }

    if (run->closed) {
        luaL_error(L, "attempt to use a closed shaped run");
    }

    if (strcmp(key, "text") == 0) {
        lua_pushlstring(L, run->text.data(), run->text.size());
        return 1;
    }
    if (strcmp(key, "glyphs") == 0) {
        push_shaped_glyphs(L, run->glyphs);
        return 1;
    }
    if (strcmp(key, "advance") == 0) {
        push_vec2(L, run->advanceX, run->advanceY);
        return 1;
    }
    if (strcmp(key, "bounds") == 0) {
        push_rect(L, run->bounds);
        return 1;
    }

    return 0;
}

static int shaped_run_close(lua_State* L) {
    ShapedRunUD* run = check_shaped_run_any(L);
    run->text.clear();
    run->glyphs.clear();
    run->advanceX = 0;
    run->advanceY = 0;
    run->bounds = {};
    run->closed = true;
    return 0;
}

static int shaped_run_tostring(lua_State* L) {
    ShapedRunUD* run = check_shaped_run_any(L);
    if (run->closed) {
        lua_pushstring(L, "ShapedRun(closed)");
        return 1;
    }

    std::string text = "ShapedRun(" + std::to_string(run->glyphs.size()) + " glyphs)";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int font_open_file(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    int faceIndex = read_face_index(L, 2);

    ensure_ft(L);
    FT_Face face = nullptr;
    if (FT_New_Face(g_ft, path, faceIndex, &face))
        luaL_error(L, "failed to open font file: %s", path);

    auto source = make_source_from_face(L, face, path, {}, faceIndex);
    FT_Done_Face(face);
    push_typeface(L, std::move(source));
    return 1;
}

static int font_from_buffer(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);
    int faceIndex = read_face_index(L, 2);

    std::vector<uint8_t> bytes((const uint8_t*)data, (const uint8_t*)data + len);
    ensure_ft(L);
    FT_Face face = nullptr;
    if (FT_New_Memory_Face(g_ft, bytes.data(), (FT_Long)bytes.size(), faceIndex, &face))
        luaL_error(L, "failed to open font buffer");

    auto source = make_source_from_face(L, face, "", std::move(bytes), faceIndex);
    FT_Done_Face(face);
    push_typeface(L, std::move(source));
    return 1;
}

static void add_font_file(std::map<std::string, SystemFontInfo>& fonts,
                          const std::filesystem::path& path) {
    if (!is_font_file(path)) return;

    std::string pathText = path_to_utf8(path);
    std::vector<uint8_t> bytes;
    bool useMemory = false;

    FT_Face first = nullptr;
    if (FT_New_Face(g_ft, pathText.c_str(), 0, &first)) {
        bytes = read_file_bytes(path);
        if (bytes.empty()) return;
        useMemory = true;
        if (FT_New_Memory_Face(g_ft, bytes.data(), (FT_Long)bytes.size(), 0, &first)) return;
    }

    FT_Long numFaces = std::max<FT_Long>(1, first->num_faces);
    FT_Done_Face(first);

    for (FT_Long faceIndex = 0; faceIndex < numFaces; ++faceIndex) {
        FT_Face face = nullptr;
        FT_Error err = useMemory ? FT_New_Memory_Face(g_ft, bytes.data(), (FT_Long)bytes.size(),
                                                      faceIndex, &face)
                                 : FT_New_Face(g_ft, pathText.c_str(), faceIndex, &face);
        if (err) continue;

        std::string family = face->family_name ? face->family_name : "";
        std::string style = face->style_name ? face->style_name : "";
        int weight = 400;
        int stretch = 5;
        bool italic = false;
        read_face_style_attributes(face, style, weight, stretch, italic);
        FT_Done_Face(face);
        if (family.empty()) continue;

        add_system_font_info(fonts, std::move(family), std::move(style), (int)faceIndex, weight,
                             stretch, italic, pathText);
    }
}

static bool add_font_path_once(std::map<std::string, SystemFontInfo>& fonts,
                               std::vector<std::filesystem::path>& seenPaths,
                               const std::filesystem::path& path) {
    std::error_code ec;
    std::filesystem::path canonical = std::filesystem::weakly_canonical(path, ec);
    if (ec) canonical = path;
    if (std::find(seenPaths.begin(), seenPaths.end(), canonical) != seenPaths.end()) return false;
    seenPaths.push_back(canonical);
    add_font_file(fonts, canonical);
    return true;
}

static void add_font_directory(std::map<std::string, SystemFontInfo>& fonts,
                               std::vector<std::filesystem::path>& seenPaths,
                               const std::filesystem::path& dir) {
    std::error_code ec;
    if (!std::filesystem::exists(dir, ec)) return;

    std::filesystem::recursive_directory_iterator it(
        dir, std::filesystem::directory_options::skip_permission_denied, ec);
    std::filesystem::recursive_directory_iterator end;
    while (!ec && it != end) {
        const std::filesystem::directory_entry& entry = *it;
        if (entry.is_regular_file(ec)) add_font_path_once(fonts, seenPaths, entry.path());
        it.increment(ec);
    }
}

#if !defined(_WIN32) && !defined(__APPLE__)
static std::vector<std::string> split_fontconfig_list(std::string text) {
    std::vector<std::string> out;
    size_t start = 0;
    while (start <= text.size()) {
        size_t pos = text.find(',', start);
        std::string item =
            text.substr(start, pos == std::string::npos ? std::string::npos : pos - start);
        size_t first = item.find_first_not_of(" \t");
        size_t last = item.find_last_not_of(" \t");
        if (first != std::string::npos) out.push_back(item.substr(first, last - first + 1));
        if (pos == std::string::npos) break;
        start = pos + 1;
    }
    return out;
}

static bool add_fontconfig_fonts(std::map<std::string, SystemFontInfo>& fonts,
                                 std::vector<std::filesystem::path>& seenPaths) {
    FILE* pipe = popen("fc-list --format='%{file}\\t%{index}\\t%{family}\\t%{style}\\n'", "r");
    if (!pipe) return false;

    bool any = false;
    char buffer[8192];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        std::string line(buffer);
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();

        std::vector<std::string> fields;
        std::stringstream ss(line);
        std::string field;
        while (std::getline(ss, field, '\t')) fields.push_back(std::move(field));
        if (fields.size() < 4 || fields[0].empty()) continue;

        std::filesystem::path path(fields[0]);
        if (!is_font_file(path)) continue;

        std::error_code ec;
        std::filesystem::path canonical = std::filesystem::weakly_canonical(path, ec);
        if (ec) canonical = path;
        if (std::find(seenPaths.begin(), seenPaths.end(), canonical) == seenPaths.end())
            seenPaths.push_back(canonical);

        int faceIndex = 0;
        try {
            faceIndex = fields[1].empty() ? 0 : std::stoi(fields[1]);
        } catch (...) {
            faceIndex = 0;
        }

        std::vector<std::string> families = split_fontconfig_list(fields[2]);
        std::vector<std::string> styles = split_fontconfig_list(fields[3]);
        std::string style = styles.empty() ? "" : styles[0];
        int weight = 400;
        int stretch = 5;
        bool italic = false;
        infer_style_attributes(style, weight, stretch, italic);
        std::string pathText = path_to_utf8(canonical);

        for (std::string& family : families) {
            add_system_font_info(fonts, std::move(family), style, faceIndex, weight, stretch,
                                 italic, pathText);
            any = true;
        }
    }

    pclose(pipe);
    return any;
}
#endif

#ifdef _WIN32
static std::filesystem::path windows_env_path(const wchar_t* name) {
    DWORD len = GetEnvironmentVariableW(name, nullptr, 0);
    if (len == 0) return {};
    std::wstring value(len, L'\0');
    DWORD written = GetEnvironmentVariableW(name, value.data(), len);
    if (written == 0 || written >= len) return {};
    value.resize(written);
    return value;
}

static void add_windows_font_registry(std::vector<std::filesystem::path>& paths, HKEY root,
                                      const wchar_t* subkey,
                                      const std::filesystem::path& relativeBase) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, subkey, 0, KEY_READ | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) return;

    for (DWORD i = 0;; ++i) {
        wchar_t valueName[512];
        wchar_t valueData[1024];
        DWORD valueNameLen = (DWORD)(sizeof(valueName) / sizeof(valueName[0]));
        DWORD valueDataLen = sizeof(valueData);
        DWORD type = 0;
        LONG rc = RegEnumValueW(key, i, valueName, &valueNameLen, nullptr, &type,
                                reinterpret_cast<LPBYTE>(valueData), &valueDataLen);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != ERROR_SUCCESS || type != REG_SZ) continue;

        valueData[std::min<DWORD>(valueDataLen / sizeof(wchar_t),
                                  (DWORD)(sizeof(valueData) / sizeof(valueData[0]) - 1))] = L'\0';
        std::filesystem::path path(valueData);
        if (path.is_relative()) path = relativeBase / path;
        paths.push_back(std::move(path));
    }

    RegCloseKey(key);
}
#endif

#ifdef __APPLE__
static bool add_coretext_fonts(std::map<std::string, SystemFontInfo>& fonts,
                               std::vector<std::filesystem::path>& seenPaths) {
    CTFontCollectionRef collection = CTFontCollectionCreateFromAvailableFonts(nullptr);
    if (!collection) return false;

    CFArrayRef descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection);
    CFRelease(collection);
    if (!descriptors) return false;

    bool any = false;
    CFIndex count = CFArrayGetCount(descriptors);
    for (CFIndex i = 0; i < count; ++i) {
        CTFontDescriptorRef desc = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, i);
        if (!desc) continue;

        CFURLRef url = (CFURLRef)CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute);
        if (!url) continue;

        char pathBuffer[PATH_MAX];
        bool ok =
            CFURLGetFileSystemRepresentation(url, true, (UInt8*)pathBuffer, sizeof(pathBuffer));
        CFRelease(url);
        if (!ok) continue;

        std::filesystem::path path(pathBuffer);
        if (!is_font_file(path)) continue;

        if (add_font_path_once(fonts, seenPaths, path)) any = true;
    }

    CFRelease(descriptors);
    return any;
}
#endif

static std::vector<std::filesystem::path> default_system_font_directories() {
    std::vector<std::filesystem::path> dirs;

#ifdef _WIN32
    wchar_t windowsDir[MAX_PATH];
    UINT windowsLen = GetWindowsDirectoryW(windowsDir, MAX_PATH);
    if (windowsLen > 0 && windowsLen < MAX_PATH)
        dirs.emplace_back(std::filesystem::path(windowsDir) / L"Fonts");

    std::filesystem::path localPath = windows_env_path(L"LOCALAPPDATA");
    if (!localPath.empty()) {
        dirs.emplace_back(localPath / L"Microsoft" / L"Windows" / L"Fonts");
        dirs.emplace_back(localPath / L"FontBase");
        dirs.emplace_back(localPath / L"NexusFont");
    }
    std::filesystem::path roamingPath = windows_env_path(L"APPDATA");
    if (!roamingPath.empty()) {
        dirs.emplace_back(roamingPath / L"FontBase");
        dirs.emplace_back(roamingPath / L"NexusFont");
    }
#elif defined(__APPLE__)
    dirs.emplace_back("/System/Library/Fonts");
    dirs.emplace_back("/Library/Fonts");
    if (const char* home = std::getenv("HOME"))
        dirs.emplace_back(std::string(home) + "/Library/Fonts");
#else
    dirs.emplace_back("/usr/share/fonts");
    dirs.emplace_back("/usr/local/share/fonts");
    if (const char* home = std::getenv("HOME")) {
        dirs.emplace_back(std::string(home) + "/.fonts");
        dirs.emplace_back(std::string(home) + "/.local/share/fonts");
    }
#endif

    return dirs;
}

static std::map<std::string, SystemFontInfo> discover_system_fonts(lua_State* L, int optionsIdx) {
    ensure_ft(L);

    std::map<std::string, SystemFontInfo> fonts;
    std::vector<std::string> extraDirs = opt_string_array_field(L, optionsIdx, "directories");
    std::vector<std::filesystem::path> seenPaths;
    bool usedPlatformCache = false;

#ifdef _WIN32
    wchar_t windowsDir[MAX_PATH];
    UINT windowsLen = GetWindowsDirectoryW(windowsDir, MAX_PATH);
    std::filesystem::path windowsFonts = windowsLen > 0 && windowsLen < MAX_PATH
                                             ? std::filesystem::path(windowsDir) / L"Fonts"
                                             : std::filesystem::path();
    std::vector<std::filesystem::path> registeredPaths;
    add_windows_font_registry(registeredPaths, HKEY_LOCAL_MACHINE,
                              L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
                              windowsFonts);
    std::filesystem::path localPath = windows_env_path(L"LOCALAPPDATA");
    if (!localPath.empty()) {
        add_windows_font_registry(registeredPaths, HKEY_CURRENT_USER,
                                  L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
                                  localPath / L"Microsoft" / L"Windows" / L"Fonts");
    }
    for (const auto& path : registeredPaths) add_font_path_once(fonts, seenPaths, path);
    usedPlatformCache = !registeredPaths.empty();
#elif defined(__APPLE__)
    usedPlatformCache = add_coretext_fonts(fonts, seenPaths);
#else
    usedPlatformCache = add_fontconfig_fonts(fonts, seenPaths);
#endif

    if (!usedPlatformCache) {
        for (const auto& dir : default_system_font_directories())
            add_font_directory(fonts, seenPaths, dir);
    }
    for (const std::string& dir : extraDirs) add_font_directory(fonts, seenPaths, dir);
    return fonts;
}

static std::string system_font_cache_key(const std::vector<std::string>& extraDirs) {
    std::vector<std::string> dirs = extraDirs;
    std::sort(dirs.begin(), dirs.end());

    std::string key;
    for (const std::string& dir : dirs) {
        key += dir;
        key += '\n';
    }
    return key;
}

static const std::map<std::string, SystemFontInfo>& cached_system_fonts(lua_State* L,
                                                                        int optionsIdx) {
    std::vector<std::string> extraDirs = opt_string_array_field(L, optionsIdx, "directories");
    std::string key = system_font_cache_key(extraDirs);

    auto it = g_systemFontCache.find(key);
    if (it == g_systemFontCache.end() || opt_refresh_system_field(L, optionsIdx)) {
        std::map<std::string, SystemFontInfo> fonts = discover_system_fonts(L, optionsIdx);
        it = g_systemFontCache.insert_or_assign(std::move(key), std::move(fonts)).first;
    }

    return it->second;
}

static int font_refresh_system(lua_State* L) {
    int optionsIdx = lua_isnoneornil(L, 1) ? 0 : 1;
    std::vector<std::string> extraDirs = opt_string_array_field(L, optionsIdx, "directories");
    std::string key = system_font_cache_key(extraDirs);
    std::map<std::string, SystemFontInfo> fonts = discover_system_fonts(L, optionsIdx);
    g_systemFontCache.insert_or_assign(std::move(key), std::move(fonts));
    return 0;
}

static void push_path_union(lua_State* L, const std::vector<std::string>& paths) {
    if (paths.size() == 1) {
        lua_pushlstring(L, paths[0].data(), paths[0].size());
        return;
    }

    lua_createtable(L, (int)paths.size(), 0);
    for (int i = 0; i < (int)paths.size(); ++i) {
        lua_pushlstring(L, paths[i].data(), paths[i].size());
        lua_rawseti(L, -2, i + 1);
    }
    lua_setreadonly(L, -1, true);
}

static void push_system_font_info(lua_State* L, const SystemFontInfo& info) {
    lua_createtable(L, 0, 8);
    lua_pushlstring(L, info.family.data(), info.family.size());
    lua_setfield(L, -2, "family");
    lua_pushlstring(L, info.style.data(), info.style.size());
    lua_setfield(L, -2, "style");
    lua_pushinteger(L, info.faceIndex);
    lua_setfield(L, -2, "faceIndex");
    lua_pushinteger(L, info.weight);
    lua_setfield(L, -2, "weight");
    lua_pushinteger(L, info.stretch);
    lua_setfield(L, -2, "stretch");
    lua_pushboolean(L, info.italic);
    lua_setfield(L, -2, "italic");
    push_path_union(L, info.paths);
    lua_setfield(L, -2, "path");

    lua_createtable(L, (int)info.paths.size(), 0);
    for (int i = 0; i < (int)info.paths.size(); ++i) {
        lua_pushlstring(L, info.paths[i].data(), info.paths[i].size());
        lua_rawseti(L, -2, i + 1);
    }
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "paths");
    lua_setreadonly(L, -1, true);
}

static bool is_preferred_style(const std::string& style) {
    std::string lower = lower_ascii(style);
    return lower == "regular" || lower == "book" || lower == "normal" || lower == "roman";
}

static int font_find_system(lua_State* L) {
    size_t familyLen = 0;
    const char* family = luaL_checklstring(L, 1, &familyLen);
    int optionsIdx = lua_isnoneornil(L, 2) ? 0 : 2;
    int faceIndex = read_face_index(L, 2);
    std::string familyKey = lower_ascii(std::string(family, familyLen));
    std::string wantedStyle = lower_ascii(opt_string_field(L, optionsIdx, "style"));
    int wantedWeight = is_no_options(L, optionsIdx) ? 0 : opt_int_field(L, optionsIdx, "weight", 0);
    int wantedStretch =
        is_no_options(L, optionsIdx) ? 0 : opt_int_field(L, optionsIdx, "stretch", 0);
    if (wantedWeight < 0 || wantedWeight > 1000) luaL_error(L, "weight must be between 0 and 1000");
    if (wantedStretch < 0 || wantedStretch > 9) luaL_error(L, "stretch must be between 0 and 9");
    bool wantedItalic = false;
    bool hasWantedItalic = opt_bool_field_present(L, optionsIdx, "italic", wantedItalic);

    const std::map<std::string, SystemFontInfo>& fonts = cached_system_fonts(L, optionsIdx);
    const SystemFontInfo* match = nullptr;
    int bestScore = std::numeric_limits<int>::min();
    for (const auto& [_, info] : fonts) {
        if (lower_ascii(info.family) != familyKey) continue;
        if (faceIndex != 0 && info.faceIndex != faceIndex) continue;

        std::string infoStyle = lower_ascii(info.style);
        int score = 0;
        if (!wantedStyle.empty()) {
            if (infoStyle == wantedStyle)
                score += 5000;
            else if (infoStyle.find(wantedStyle) != std::string::npos)
                score += 2500;
            else
                continue;
        }

        if (hasWantedItalic) {
            if (info.italic != wantedItalic) continue;
            score += 1000;
        } else if (!info.italic) {
            score += 100;
        }

        if (wantedWeight != 0)
            score += std::max(0, 1000 - std::abs(info.weight - wantedWeight));
        else
            score += std::max(0, 200 - std::abs(info.weight - 400));

        if (wantedStretch != 0)
            score += std::max(0, 100 - std::abs(info.stretch - wantedStretch) * 20);
        else if (info.stretch == 5)
            score += 50;

        if (wantedStyle.empty() && wantedWeight == 0 && !hasWantedItalic &&
            is_preferred_style(info.style))
            score += 500;

        if (!match || score > bestScore) {
            match = &info;
            bestScore = score;
        }
    }

    if (!match || match->paths.empty()) {
        lua_pushnil(L);
        return 1;
    }

    std::filesystem::path path = std::filesystem::u8path(match->paths[0]);
    std::vector<uint8_t> bytes = read_file_bytes(path);
    if (bytes.empty()) {
        lua_pushnil(L);
        return 1;
    }

    FT_Face face = nullptr;
    int sourceFaceIndex = faceIndex != 0 ? faceIndex : match->faceIndex;
    if (FT_New_Memory_Face(g_ft, bytes.data(), (FT_Long)bytes.size(), sourceFaceIndex, &face)) {
        lua_pushnil(L);
        return 1;
    }

    auto source =
        make_source_from_face(L, face, match->paths[0], std::move(bytes), sourceFaceIndex);
    FT_Done_Face(face);
    push_typeface(L, std::move(source));
    return 1;
}

static int font_list_system(lua_State* L) {
    int optionsIdx = lua_isnoneornil(L, 1) ? 0 : 1;
    const std::map<std::string, SystemFontInfo>& fonts = cached_system_fonts(L, optionsIdx);

    lua_createtable(L, (int)fonts.size(), 0);
    int i = 1;
    for (const auto& [_, info] : fonts) {
        push_system_font_info(L, info);
        lua_rawseti(L, -2, i++);
    }
    lua_setreadonly(L, -1, true);
    return 1;
}

static int font_list_system_families(lua_State* L) {
    int optionsIdx = lua_isnoneornil(L, 1) ? 0 : 1;
    const std::map<std::string, SystemFontInfo>& fonts = cached_system_fonts(L, optionsIdx);

    struct FamilyGroup {
        std::string family;
        std::vector<const SystemFontInfo*> faces;
    };

    std::map<std::string, FamilyGroup> groups;
    for (const auto& [_, info] : fonts) {
        std::string key = lower_ascii(info.family);
        auto& group = groups[key];
        if (group.family.empty()) group.family = info.family;
        group.faces.push_back(&info);
    }

    lua_createtable(L, (int)groups.size(), 0);
    int familyIndex = 1;
    for (const auto& [_, group] : groups) {
        lua_createtable(L, 0, 2);
        lua_pushlstring(L, group.family.data(), group.family.size());
        lua_setfield(L, -2, "family");

        lua_createtable(L, (int)group.faces.size(), 0);
        for (int i = 0; i < (int)group.faces.size(); ++i) {
            push_system_font_info(L, *group.faces[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setreadonly(L, -1, true);
        lua_setfield(L, -2, "faces");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, familyIndex++);
    }
    lua_setreadonly(L, -1, true);
    return 1;
}

static luaL_Reg typefaceMethods[] = {
    { "hasGlyph", typeface_has_glyph },    { "glyphId", typeface_glyph_id },
    { "hasText", typeface_has_text },      { "missingGlyphs", typeface_missing_glyphs },
    { "names", typeface_names },           { "table", typeface_table },
    { "codepoints", typeface_codepoints }, { "at", typeface_at },
    { "close", typeface_close },           { nullptr, nullptr },
};

static luaL_Reg typefaceMetamethods[] = {
    { "__tostring", typeface_tostring },
    { nullptr, nullptr },
};

static udataDef typefaceDef = {
    .name = "Typeface",
    .size = sizeof(TypefaceUD),
    .fields = nullptr,
    .indexFallback = typeface_index,
    .newindexFallback = nullptr,
    .metamethods = typefaceMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = typefaceMethods,
    .destructor = typeface_dtor,
};

static luaL_Reg fontMethods[] = {
    { "shape", font_shape },
    { "measure", font_measure },
    { "bounds", font_bounds },
    { "glyphMetrics", font_glyph_metrics },
    { "outlineGlyph", font_outline_glyph },
    { "rasterizeGlyph", font_rasterize_glyph },
    { "renderGlyph", font_render_glyph },
    { "render", font_render_text },
    { "close", font_close },
    { nullptr, nullptr },
};

static luaL_Reg fontMetamethods[] = {
    { "__tostring", font_tostring },
    { nullptr, nullptr },
};

static udataDef fontDef = {
    .name = "Font",
    .size = sizeof(FontUD),
    .fields = nullptr,
    .indexFallback = font_index,
    .newindexFallback = nullptr,
    .metamethods = fontMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = fontMethods,
    .destructor = font_dtor,
};

static luaL_Reg shapedRunMethods[] = {
    { "close", shaped_run_close },
    { nullptr, nullptr },
};

static luaL_Reg shapedRunMetamethods[] = {
    { "__tostring", shaped_run_tostring },
    { nullptr, nullptr },
};

static udataDef shapedRunDef = {
    .name = "ShapedRun",
    .size = sizeof(ShapedRunUD),
    .fields = nullptr,
    .indexFallback = shaped_run_index,
    .newindexFallback = nullptr,
    .metamethods = shapedRunMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = shapedRunMethods,
    .destructor = shaped_run_dtor,
};

LUAU_MODULE_EXPORT int luauopen_font(lua_State* L) {
    ensure_ft(L);
    FT_Library_SetLcdFilter(g_ft, FT_LCD_FILTER_DEFAULT);

    typefaceRef = eryxUdata_registerudata(L, &typefaceDef);
    fontRef = eryxUdata_registerudata(L, &fontDef);
    shapedRunRef = eryxUdata_registerudata(L, &shapedRunDef);

    lua_newtable(L);
    lua_pushcfunction(L, font_open_file, "openFile");
    lua_setfield(L, -2, "openFile");
    lua_pushcfunction(L, font_from_buffer, "fromBuffer");
    lua_setfield(L, -2, "fromBuffer");
    lua_pushcfunction(L, font_find_system, "findSystem");
    lua_setfield(L, -2, "findSystem");
    lua_pushcfunction(L, font_list_system, "listSystem");
    lua_setfield(L, -2, "listSystem");
    lua_pushcfunction(L, font_list_system_families, "listSystemFamilies");
    lua_setfield(L, -2, "listSystemFamilies");
    lua_pushcfunction(L, font_refresh_system, "refreshSystem");
    lua_setfield(L, -2, "refreshSystem");
    lua_setreadonly(L, -1, true);
    return 1;
}
