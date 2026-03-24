#pragma once
#include "Font.hpp"
#include "Texture.hpp"
#include "pch.hpp"

void gfx_lib_register(lua_State* L);

bool gfx_init();
void gfx_destroy();
