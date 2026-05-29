#pragma once

#include "module_api.h"

inline void* eryx_testudata(lua_State* L, int idx, const char* mt) {
    idx = lua_absindex(L, idx);
    void* userdata = lua_touserdata(L, idx);
    if (!userdata || !lua_getmetatable(L, idx)) {
        return nullptr;
    }

    luaL_getmetatable(L, mt);
    bool matches = lua_rawequal(L, -1, -2) != 0;
    lua_pop(L, 2);
    return matches ? userdata : nullptr;
}

template <typename T>
inline T* eryx_testudata(lua_State* L, int idx, const char* mt) {
    return static_cast<T*>(eryx_testudata(L, idx, mt));
}

template <typename T>
inline T* eryx_newuserdata(lua_State* L, const char* mt) {
    auto* userdata = static_cast<T*>(lua_newuserdata(L, sizeof(T)));
    luaL_getmetatable(L, mt);
    lua_setmetatable(L, -2);
    return userdata;
}

template <typename T>
inline T* eryx_newuserdatadtor(lua_State* L, const char* mt, void (*dtor)(void*)) {
    auto* userdata = static_cast<T*>(lua_newuserdatadtor(L, sizeof(T), dtor));
    luaL_getmetatable(L, mt);
    lua_setmetatable(L, -2);
    return userdata;
}

inline int eryx_metatable_index(lua_State* L) {
    lua_getmetatable(L, 1);
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}
