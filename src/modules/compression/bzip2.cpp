#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "bzlib.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_bzip2",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// compress(data, block_size?) -> buffer
// block_size controls the work factor and compression ratio: 1 (fastest,
// least memory) to 9 (best compression, most memory). Default 9.
// ---------------------------------------------------------------------------
static int l_compress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int blockSize = (int)luaL_optinteger(L, 2, 9);

    if (blockSize < 1 || blockSize > 9)
        luaL_error(L, "bzip2: block_size must be 1–9");

    // bzip2 worst-case: n * 1.01 + 600 bytes
    unsigned int bound = (unsigned int)(srcLen * 1.01 + 700);
    std::vector<char> tmp(bound);
    unsigned int destLen = bound;

    int ret = BZ2_bzBuffToBuffCompress(
        tmp.data(), &destLen,
        (char*)src, (unsigned int)srcLen,
        blockSize, 0, 30);
    if (ret != BZ_OK)
        luaL_error(L, "bzip2: compress failed (%d)", ret);

    void* out = lua_newbuffer(L, destLen);
    memcpy(out, tmp.data(), destLen);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data, small?) -> buffer
// small=true activates bzip2's alternative decompression algorithm that
// uses ~2 MB instead of ~3.5 MB but runs at about half the speed.
// ---------------------------------------------------------------------------
static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int small = lua_toboolean(L, 2); // defaults to false

    std::vector<char> tmp(srcLen < 16 ? 64 : srcLen * 4);
    while (true) {
        unsigned int destLen = (unsigned int)tmp.size();
        int ret = BZ2_bzBuffToBuffDecompress(
            tmp.data(), &destLen,
            (char*)src, (unsigned int)srcLen,
            small, 0);
        if (ret == BZ_OK) {
            void* out = lua_newbuffer(L, destLen);
            memcpy(out, tmp.data(), destLen);
            return 1;
        } else if (ret == BZ_OUTBUFF_FULL) {
            tmp.resize(tmp.size() * 2);
        } else {
            luaL_error(L, "bzip2: decompress failed (%d)", ret);
        }
    }
}

// ---------------------------------------------------------------------------
// compress_bound(len) -> number
// Conservative upper bound on compressed output size.
// bzip2 has no exact formula; the worst case is roughly n * 1.01 + 600.
// ---------------------------------------------------------------------------
static int l_compress_bound(lua_State* L) {
    lua_Integer len = luaL_checkinteger(L, 1);
    lua_pushinteger(L, (lua_Integer)((double)len * 1.01 + 700));
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_bzip2(lua_State* L) {
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        {"compress",       l_compress},
        {"decompress",     l_decompress},
        {"compressBound", l_compress_bound},
        {nullptr, nullptr},
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Block size constants
    lua_pushinteger(L, 1); lua_setfield(L, -2, "BLOCK_FAST");
    lua_pushinteger(L, 9); lua_setfield(L, -2, "BLOCK_BEST");

    return 1;
}
