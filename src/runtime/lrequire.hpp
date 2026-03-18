#pragma once
#include "../modules/module_api.h"
#include "../pch.hpp"

typedef const LuauModuleInfo* (*p_luau_module_info)();
typedef int (*p_luau_module_entry)(lua_State*);

ERYX_API bool eryx_load_and_prepare_bytecode(lua_State* L, const std::string& bytecode,
                                             const std::string& scriptName);
ERYX_API bool eryx_load_and_prepare_script(lua_State* L, const std::string source,
                                           const std::string& scriptName);

ERYX_API int eryx_execute_module_bytecode(lua_State* L, const std::string& bytecode,
                                          const std::string& scriptName);
ERYX_API int eryx_execute_module_script(lua_State* L, const std::string source,
                                        const std::string& scriptName);
ERYX_API int eryx_lua_require(lua_State* L);
