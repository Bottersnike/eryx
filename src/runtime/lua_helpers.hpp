#pragma once

#include "lua.h"
#include "lualib.h"

inline void* eryx_testudata(lua_State* L, int idx, const char* mt) {
    idx = lua_absindex(L, idx);
    void* userdata = lua_touserdata(L, idx);
    if (!userdata || !lua_getmetatable(L, idx)) return nullptr;

    luaL_getmetatable(L, mt);
    bool matches = lua_rawequal(L, -1, -2) != 0;
    lua_pop(L, 2);
    return matches ? userdata : nullptr;
}

template <typename T>
inline T* eryx_testudata(lua_State* L, int idx, const char* mt) {
    return static_cast<T*>(eryx_testudata(L, idx, mt));
}
