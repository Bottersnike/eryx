#pragma once
#include "pch.hpp"

extern const char *SOUND_METATABLE;

void sound_lib_register(lua_State* L);
void sound_destroy();
