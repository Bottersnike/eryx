#pragma once

#include "../runtime/lua_helpers.hpp"
#include "module_api.h"

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
