#pragma once
#include "pch.hpp"
#include "Texture.hpp"
#include "Font.hpp"

void gfx_lib_register(lua_State* L);

bool gfx_init();
void gfx_destroy();
