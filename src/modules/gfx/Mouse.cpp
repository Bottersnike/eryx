#include "Mouse.hpp"

#include <SDL3/SDL_mouse.h>


// mouse.available() -> boolean
int mouse_available(lua_State* L) {
    lua_pushboolean(L, SDL_HasMouse());
    return 1;
}

// mouse.getPosition() -> (number, number)
int mouse_getPosition(lua_State* L) {
    float x, y;

    SDL_GetMouseState(&x, &y);

    lua_pushnumber(L, x);
    lua_pushnumber(L, y);

    return 2;
}

// mouse.getButtons() -> {left: boolean, right: boolean, middle: boolean, side1: boolean, side2: boolean}
int mouse_getButtons(lua_State* L) {
    SDL_MouseButtonFlags buttons = SDL_GetMouseState(NULL, NULL);

    lua_createtable(L, 0, 5);

    lua_pushstring(L, "left");
    lua_pushboolean(L, buttons & 1);
    lua_settable(L, -3);

    lua_pushstring(L, "right");
    lua_pushboolean(L, buttons & 2);
    lua_settable(L, -3);

    lua_pushstring(L, "middle");
    lua_pushboolean(L, buttons & 4);
    lua_settable(L, -3);

    lua_pushstring(L, "side1");
    lua_pushboolean(L, buttons & 8);
    lua_settable(L, -3);

    lua_pushstring(L, "side2");
    lua_pushboolean(L, buttons & 16);
    lua_settable(L, -3);

    return 1;
}

static const luaL_Reg mouse_lib[] = {
    { "available", mouse_available },
    { "getPosition", mouse_getPosition },
    { "getButtons", mouse_getButtons },
    { NULL, NULL },
};

void mouse_lib_register(lua_State* L) { luaL_register(L, "mouse", mouse_lib); }
