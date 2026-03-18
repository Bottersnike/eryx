#pragma once
#include "LL_Font.hpp" // IWYU pragma: export
#include "pch.hpp"

extern const char* FONT_METATABLE;

// Font userdata type
struct LuaFont {
    FT_Face face = nullptr;
    std::string name;
    GlyphAtlas atlas;

    LuaFont() : face(nullptr) {}
    ~LuaFont() {
        if (atlas.gpu_texture) wgpuTextureRelease(atlas.gpu_texture);
        if (atlas.gpu_view) wgpuTextureViewRelease(atlas.gpu_view);
    }
};

void font_lib_register(lua_State* L);
