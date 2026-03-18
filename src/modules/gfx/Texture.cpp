#include "Texture.hpp"
#include "LL_Texture.hpp"
#include "LuaUtil.hpp"

const char* TEXTURE_METATABLE = "Texture";

int texture_tostring(lua_State* L) {
    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 1, TEXTURE_METATABLE);
    lua_pushfstring(L, "Texture(%s, %dx%d)", texture->name.c_str(), texture->image.width,
                    texture->image.height);
    return 1;
}

int texture_gc(lua_State* L) {
    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 1, TEXTURE_METATABLE);
    if (texture) {
        texture->~LuaTexture();  // Explicitly call destructor to free inner memory
    }
    return 0;
}

// Texture.size: Vec2
int texture_size(lua_State* L) {
    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 1, TEXTURE_METATABLE);
    if (!texture) {
        luaL_error(L, "Invalid texture object");
        return 0;
    }

    lua_pushvec2(L, texture->image.width, texture->image.height);
    return 1;
}

void texture_lib_register(lua_State* L) {
    luaL_newmetatable(L, TEXTURE_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, texture_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, texture_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, texture_size, "size");
    lua_setfield(L, -2, "size");

    lua_pop(L, 1);
}
