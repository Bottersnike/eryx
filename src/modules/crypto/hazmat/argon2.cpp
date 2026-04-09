#include "argon2.h"

#include <cstdint>
#include <cstring>
#include <string>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_argon2",
};
LUAU_MODULE_INFO()

static void argon2_lua_error(lua_State* L, const char* op, int code) {
    luaL_error(L, "%s: %s", op, argon2_error_message(code));
}

static uint32_t check_u32(lua_State* L, int index, const char* name) {
    lua_Number n = luaL_checknumber(L, index);
    if (n < 0 || n > 4294967295.0) luaL_error(L, "%s out of range for uint32", name);
    return (uint32_t)n;
}

static size_t check_size(lua_State* L, int index, const char* name) {
    lua_Number n = luaL_checknumber(L, index);
    if (n < 0) luaL_error(L, "%s must be non-negative", name);
    return (size_t)n;
}

static int check_version(lua_State* L, int index) {
    int version = (int)luaL_optinteger(L, index, ARGON2_VERSION_NUMBER);
    if (version != ARGON2_VERSION_10 && version != ARGON2_VERSION_13)
        luaL_error(L, "unsupported Argon2 version");
    return version;
}

static int hash_raw_impl(lua_State* L, argon2_type type, const char* op) {
    size_t pwd_len = 0;
    const void* pwd = luaL_checkbuffer(L, 1, &pwd_len);
    size_t salt_len = 0;
    const void* salt = luaL_checkbuffer(L, 2, &salt_len);
    uint32_t time_cost = check_u32(L, 3, "time_cost");
    uint32_t memory_kib = check_u32(L, 4, "memory_kib");
    uint32_t parallelism = check_u32(L, 5, "parallelism");
    size_t hash_len = check_size(L, 6, "hash_len");
    int version = check_version(L, 7);

    void* out = lua_newbuffer(L, hash_len);
    int rc = argon2_hash(time_cost, memory_kib, parallelism, pwd, pwd_len, salt, salt_len, out,
                         hash_len, nullptr, 0, type, (uint32_t)version);
    if (rc != ARGON2_OK) argon2_lua_error(L, op, rc);
    return 1;
}

static int hash_encoded_impl(lua_State* L, argon2_type type, const char* op) {
    size_t pwd_len = 0;
    const void* pwd = luaL_checkbuffer(L, 1, &pwd_len);
    size_t salt_len = 0;
    const void* salt = luaL_checkbuffer(L, 2, &salt_len);
    uint32_t time_cost = check_u32(L, 3, "time_cost");
    uint32_t memory_kib = check_u32(L, 4, "memory_kib");
    uint32_t parallelism = check_u32(L, 5, "parallelism");
    size_t hash_len = check_size(L, 6, "hash_len");
    int version = check_version(L, 7);

    size_t encoded_len = argon2_encodedlen(time_cost, memory_kib, parallelism, (uint32_t)salt_len,
                                           (uint32_t)hash_len, type);
    std::string encoded(encoded_len, '\0');

    int rc = argon2_hash(time_cost, memory_kib, parallelism, pwd, pwd_len, salt, salt_len, nullptr,
                         hash_len, encoded.data(), encoded.size(), type, (uint32_t)version);
    if (rc != ARGON2_OK) argon2_lua_error(L, op, rc);

    lua_pushstring(L, encoded.c_str());
    return 1;
}

static argon2_type type_from_encoded(lua_State* L, const char* encoded) {
    if (strncmp(encoded, "$argon2id$", 10) == 0) return Argon2_id;
    if (strncmp(encoded, "$argon2i$", 9) == 0) return Argon2_i;
    if (strncmp(encoded, "$argon2d$", 9) == 0) return Argon2_d;

    luaL_error(L, "encoded hash does not start with a supported Argon2 prefix");
}

static int argon2d_hash_raw(lua_State* L) { return hash_raw_impl(L, Argon2_d, "argon2d_hash_raw"); }
static int argon2i_hash_raw(lua_State* L) { return hash_raw_impl(L, Argon2_i, "argon2i_hash_raw"); }
static int argon2id_hash_raw(lua_State* L) {
    return hash_raw_impl(L, Argon2_id, "argon2id_hash_raw");
}

static int argon2d_hash_encoded(lua_State* L) {
    return hash_encoded_impl(L, Argon2_d, "argon2d_hash_encoded");
}
static int argon2i_hash_encoded(lua_State* L) {
    return hash_encoded_impl(L, Argon2_i, "argon2i_hash_encoded");
}
static int argon2id_hash_encoded(lua_State* L) {
    return hash_encoded_impl(L, Argon2_id, "argon2id_hash_encoded");
}

static int verify_encoded(lua_State* L) {
    const char* encoded = luaL_checkstring(L, 1);
    size_t pwd_len = 0;
    const void* pwd = luaL_checkbuffer(L, 2, &pwd_len);

    argon2_type type = type_from_encoded(L, encoded);
    int rc = argon2_verify(encoded, pwd, pwd_len, type);
    lua_pushboolean(L, rc == ARGON2_OK);
    return 1;
}

static int encoded_len(lua_State* L) {
    uint32_t time_cost = check_u32(L, 1, "time_cost");
    uint32_t memory_kib = check_u32(L, 2, "memory_kib");
    uint32_t parallelism = check_u32(L, 3, "parallelism");
    uint32_t salt_len = check_u32(L, 4, "salt_len");
    uint32_t hash_len = check_u32(L, 5, "hash_len");
    const char* variant = luaL_checkstring(L, 6);

    argon2_type type;
    if (strcmp(variant, "argon2d") == 0)
        type = Argon2_d;
    else if (strcmp(variant, "argon2i") == 0)
        type = Argon2_i;
    else if (strcmp(variant, "argon2id") == 0)
        type = Argon2_id;
    else
        luaL_error(L, "unsupported Argon2 variant '%s'", variant);

    lua_pushnumber(L, (lua_Number)argon2_encodedlen(time_cost, memory_kib, parallelism, salt_len,
                                                    hash_len, type));
    return 1;
}

LUAU_MODULE_EXPORT int luauopen_argon2(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, argon2d_hash_raw, "argon2d_hash_raw");
    lua_setfield(L, -2, "argon2d_hash_raw");
    lua_pushcfunction(L, argon2i_hash_raw, "argon2i_hash_raw");
    lua_setfield(L, -2, "argon2i_hash_raw");
    lua_pushcfunction(L, argon2id_hash_raw, "argon2id_hash_raw");
    lua_setfield(L, -2, "argon2id_hash_raw");

    lua_pushcfunction(L, argon2d_hash_encoded, "argon2d_hash_encoded");
    lua_setfield(L, -2, "argon2d_hash_encoded");
    lua_pushcfunction(L, argon2i_hash_encoded, "argon2i_hash_encoded");
    lua_setfield(L, -2, "argon2i_hash_encoded");
    lua_pushcfunction(L, argon2id_hash_encoded, "argon2id_hash_encoded");
    lua_setfield(L, -2, "argon2id_hash_encoded");

    lua_pushcfunction(L, verify_encoded, "verify_encoded");
    lua_setfield(L, -2, "verify_encoded");
    lua_pushcfunction(L, encoded_len, "encoded_len");
    lua_setfield(L, -2, "encoded_len");

    lua_pushinteger(L, ARGON2_VERSION_10);
    lua_setfield(L, -2, "VERSION_10");
    lua_pushinteger(L, ARGON2_VERSION_13);
    lua_setfield(L, -2, "VERSION_13");
    lua_pushinteger(L, ARGON2_VERSION_NUMBER);
    lua_setfield(L, -2, "VERSION_NUMBER");

    return 1;
}
