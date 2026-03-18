#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "brotli/encode.h"
#include "brotli/decode.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_brotli",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// compress(data, quality?, lgwin?, mode?) -> buffer
//   quality : 0 (fastest) – 11 (best). Default BROTLI_DEFAULT_QUALITY (11).
//   lgwin   : log2 of the LZ77 window size (10–24). Default BROTLI_DEFAULT_WINDOW (22).
//             Larger windows improve compression but use more memory.
//   mode    : MODE_GENERIC (0), MODE_TEXT (1), MODE_FONT (2).
//             TEXT enables context modelling for UTF-8; FONT is for WOFF2.
// ---------------------------------------------------------------------------
static int l_compress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int quality = (int)luaL_optinteger(L, 2, BROTLI_DEFAULT_QUALITY);
    int lgwin   = (int)luaL_optinteger(L, 3, BROTLI_DEFAULT_WINDOW);
    int mode    = (int)luaL_optinteger(L, 4, BROTLI_DEFAULT_MODE);

    size_t bound = BrotliEncoderMaxCompressedSize(srcLen);
    std::vector<uint8_t> tmp(bound);
    size_t destLen = bound;

    BROTLI_BOOL ok = BrotliEncoderCompress(
        quality, lgwin, (BrotliEncoderMode)mode,
        srcLen, (const uint8_t*)src,
        &destLen, tmp.data());
    if (!ok)
        luaL_error(L, "brotli: compress failed");

    void* out = lua_newbuffer(L, destLen);
    memcpy(out, tmp.data(), destLen);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data) -> buffer
// ---------------------------------------------------------------------------
static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);

    std::vector<uint8_t> tmp(srcLen < 16 ? 64 : srcLen * 4);
    while (true) {
        size_t destLen = tmp.size();
        BrotliDecoderResult result = BrotliDecoderDecompress(
            srcLen, (const uint8_t*)src, &destLen, tmp.data());
        if (result == BROTLI_DECODER_RESULT_SUCCESS) {
            void* out = lua_newbuffer(L, destLen);
            memcpy(out, tmp.data(), destLen);
            return 1;
        } else if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            tmp.resize(tmp.size() * 2);
        } else {
            luaL_error(L, "brotli: decompress failed (%d)", (int)result);
        }
    }
}

// ---------------------------------------------------------------------------
// max_compressed_size(len) -> number
// Upper bound on the output of compress() for an input of `len` bytes.
// Returns 0 if len is too large for brotli to handle.
// ---------------------------------------------------------------------------
static int l_max_compressed_size(lua_State* L) {
    lua_Integer len = luaL_checkinteger(L, 1);
    lua_pushinteger(L, (lua_Integer)BrotliEncoderMaxCompressedSize((size_t)len));
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_brotli(lua_State* L) {
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        {"compress",            l_compress},
        {"decompress",          l_decompress},
        {"maxCompressedSize", l_max_compressed_size},
        {nullptr, nullptr},
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Mode constants
    lua_pushinteger(L, BROTLI_MODE_GENERIC); lua_setfield(L, -2, "MODE_GENERIC");
    lua_pushinteger(L, BROTLI_MODE_TEXT);    lua_setfield(L, -2, "MODE_TEXT");
    lua_pushinteger(L, BROTLI_MODE_FONT);    lua_setfield(L, -2, "MODE_FONT");

    // Quality constants
    lua_pushinteger(L, BROTLI_MIN_QUALITY);     lua_setfield(L, -2, "QUALITY_MIN");
    lua_pushinteger(L, BROTLI_MAX_QUALITY);     lua_setfield(L, -2, "QUALITY_MAX");
    lua_pushinteger(L, BROTLI_DEFAULT_QUALITY); lua_setfield(L, -2, "QUALITY_DEFAULT");

    // Window size constants (log2 of bytes)
    lua_pushinteger(L, BROTLI_MIN_WINDOW_BITS);     lua_setfield(L, -2, "WINDOW_MIN");
    lua_pushinteger(L, BROTLI_MAX_WINDOW_BITS);     lua_setfield(L, -2, "WINDOW_MAX");
    lua_pushinteger(L, BROTLI_DEFAULT_WINDOW);      lua_setfield(L, -2, "WINDOW_DEFAULT");

    return 1;
}
