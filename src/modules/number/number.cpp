#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_number",
};
LUAU_MODULE_INFO()

LUAU_MODULE_EXPORT int luauopen_number(lua_State* L) {
    lua_newtable(L);
    lua_setreadonly(L, -1, true);
    return 1;
}
