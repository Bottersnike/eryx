#include "module_api.h"
#include "native.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_vm_native",
};
LUAU_MODULE_INFO()

LUAU_MODULE_EXPORT int luauopen_vm_native(lua_State* L) { return eryx_luau_open_vm_native(L); }
