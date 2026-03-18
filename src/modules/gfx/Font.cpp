#include "Font.hpp"

#include "LuaUtil.hpp"
#include "LL_Font.hpp"

const char* FONT_METATABLE = "Font";

int font_tostring(lua_State* L) {
    LuaFont* font = (LuaFont*)luaL_checkudata(L, 1, FONT_METATABLE);
    lua_pushfstring(L, "Font(%s, size=%d)", font->name.c_str(), font->face->size->metrics.y_ppem);
    return 1;
}

int font_gc(lua_State* L) {
    LuaFont* font = (LuaFont*)luaL_checkudata(L, 1, FONT_METATABLE);
    if (font) {
        if (font->face) {
            FT_Done_Face(font->face);
            font->face = nullptr;
        }
        font->~LuaFont();  // Explicitly call destructor
    }
    return 0;
}

// Font::Measure(text: string) -> Vec2
int font_Measure(lua_State* L) {
    LuaFont* font = (LuaFont*)luaL_checkudata(L, 1, FONT_METATABLE);
    const char* text = luaL_checkstring(L, 2);

    if (!font || !font->face) {
        luaL_error(L, "Invalid font object");
        return 0;
    }

    double total_width = 0;
    int max_height = 0;

    for (int i = 0; text[i] != '\0'; i++) {
        GlyphBitmap glyph = getGlyphBitmap(font->face, text[i]);
        total_width += glyph.advance;
        max_height = std::max(max_height, glyph.height);
    }

    lua_pushvec2(L, total_width, max_height);
    return 1;
}

void font_lib_register(lua_State* L) {
    // Font methods
    luaL_newmetatable(L, FONT_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, font_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, font_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, font_Measure, "Measure");
    lua_setfield(L, -2, "Measure");

    lua_pop(L, 1);
}
