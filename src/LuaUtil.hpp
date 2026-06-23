#pragma once
#include "pch.hpp"

static inline bool luaL_hasarg(lua_State* L, int numArg) {
    return (lua_gettop(L) >= numArg && !lua_isnil(L, numArg));
}

static std::string luaL_checkpathlike(lua_State* L, int idx) {
    idx = lua_absindex(L, idx);

    size_t len = 0;
    if (lua_isstring(L, idx)) {
        const char* s = lua_tolstring(L, idx, &len);
        return std::string(s, len);
    }

    if (lua_istable(L, idx) || lua_isuserdata(L, idx)) {
        if (lua_getmetatable(L, idx)) {
            lua_getfield(L, -1, "__fspath");
            if (lua_isfunction(L, -1)) {
                lua_pushvalue(L, idx);
                lua_call(L, 1, 1);
                const char* s = luaL_checklstring(L, -1, &len);
                std::string out(s, len);
                lua_pop(L, 2);  // result + metatable
                return out;
            }
            lua_pop(L, 2);  // __fspath + metatable
        }
    }

    luaL_typeerrorL(L, idx, "PathLike (string or Path)");
    return std::string();
}

static uint32_t luaL_checkcolour(lua_State* L, int numArg) {
    double colour = luaL_checknumber(L, numArg);

    if (colour != floor(colour)) {
        luaL_error(L, "Invalid colour (not integer)");
        return 0;
    }

    // Check range
    if (colour > 0xFFFFFFFF || colour < 0) {
        luaL_error(L, "Invalid colour (out of range)");
        return 0;
    }

    return (uint32_t)colour;
}
static void luaL_checkuv(lua_State* L, int numArg, double* uv) {
    luaL_checktype(L, numArg, LUA_TTABLE);

    lua_rawgeti(L, numArg, 1);
    uv[0] = luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_rawgeti(L, numArg, 2);
    uv[1] = luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_rawgeti(L, numArg, 3);
    uv[2] = luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_rawgeti(L, numArg, 4);
    uv[3] = luaL_checknumber(L, -1);
    lua_pop(L, 1);
}
static void luaL_checkvec2(lua_State* L, int numArg, double* vec2) {
    luaL_checktype(L, numArg, LUA_TTABLE);

    lua_rawgeti(L, numArg, 1);
    vec2[0] = luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_rawgeti(L, numArg, 2);
    vec2[1] = luaL_checknumber(L, -1);
    lua_pop(L, 1);
}

static void lua_pushvec2(lua_State* L, double x, double y) {
    lua_createtable(L, 2, 0);

    lua_pushnumber(L, x);
    lua_rawseti(L, -2, 1);

    lua_pushnumber(L, y);
    lua_rawseti(L, -2, 2);
}
