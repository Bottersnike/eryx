#pragma once
#include "pch.hpp"

static inline bool luaL_hasarg(lua_State* L, int numArg) {
    return (lua_gettop(L) >= numArg && !lua_isnil(L, numArg));
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