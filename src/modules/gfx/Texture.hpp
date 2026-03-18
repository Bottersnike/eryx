#pragma once
#include "LL_Texture.hpp"
#include "pch.hpp"  // IWYU pragma: export


extern const char* TEXTURE_METATABLE;

// Texture userdata type
struct LuaTexture {
    Image image;
    std::string name;

    LuaTexture() = default;
};

void texture_lib_register(lua_State* L);
