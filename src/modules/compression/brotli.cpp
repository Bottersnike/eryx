#include <cstring>
#include <vector>

#include "brotli/decode.h"
#include "brotli/encode.h"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

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
    int lgwin = (int)luaL_optinteger(L, 3, BROTLI_DEFAULT_WINDOW);
    int mode = (int)luaL_optinteger(L, 4, BROTLI_DEFAULT_MODE);

    size_t bound = BrotliEncoderMaxCompressedSize(srcLen);
    std::vector<uint8_t> tmp(bound);
    size_t destLen = bound;

    BROTLI_BOOL ok = BrotliEncoderCompress(quality, lgwin, (BrotliEncoderMode)mode, srcLen,
                                           (const uint8_t*)src, &destLen, tmp.data());
    if (!ok) luaL_error(L, "brotli: compress failed");

    void* out = lua_newbuffer(L, destLen);
    memcpy(out, tmp.data(), destLen);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data) -> buffer
// ---------------------------------------------------------------------------

static constexpr size_t MAX_DECOMPRESS_SIZE = 256 * 1024 * 1024;  // 256 MB

static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);

    std::vector<uint8_t> tmp(srcLen < 16 ? 64 : srcLen * 4);
    while (true) {
        size_t destLen = tmp.size();
        BrotliDecoderResult result =
            BrotliDecoderDecompress(srcLen, (const uint8_t*)src, &destLen, tmp.data());
        if (result == BROTLI_DECODER_RESULT_SUCCESS) {
            void* out = lua_newbuffer(L, destLen);
            memcpy(out, tmp.data(), destLen);
            return 1;
        } else if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            size_t newSize = tmp.size() * 2;
            if (newSize > MAX_DECOMPRESS_SIZE) {
                luaL_error(L, "brotli: decompressed size exceeds limit (%d MB)",
                           (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
            }
            tmp.resize(newSize);
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
// Streaming Compress
// ---------------------------------------------------------------------------

static constexpr size_t STREAM_CHUNK_SIZE = 32 * 1024;  // 32 KB

static const char* MT_BROTLI_COMPRESS = "brotli.Compressor";
static const char* MT_BROTLI_DECOMPRESS = "brotli.Decompressor";

struct LuaBrotliCompressor {
    BrotliEncoderState* state;
    bool closed;
};

static void brotli_compressor_dtor(void* ud) {
    auto* c = (LuaBrotliCompressor*)ud;
    if (!c->closed && c->state) {
        BrotliEncoderDestroyInstance(c->state);
        c->state = nullptr;
        c->closed = true;
    }
}

static LuaBrotliCompressor* check_brotli_compressor(lua_State* L) {
    auto* c = (LuaBrotliCompressor*)luaL_checkudata(L, 1, MT_BROTLI_COMPRESS);
    if (c->closed) luaL_error(L, "brotli: compressor is closed");
    return c;
}

// compressor:write(data) -> buffer
static int l_brotli_compressor_write(lua_State* L) {
    auto* c = check_brotli_compressor(L);
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    const uint8_t* next_in = (const uint8_t*)src;
    size_t avail_in = srcLen;

    std::vector<uint8_t> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen);

    while (avail_in > 0 || BrotliEncoderHasMoreOutput(c->state)) {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        uint8_t* next_out = out.data() + used;
        size_t avail_out = STREAM_CHUNK_SIZE;

        if (!BrotliEncoderCompressStream(c->state, BROTLI_OPERATION_PROCESS, &avail_in, &next_in,
                                         &avail_out, &next_out, nullptr)) {
            luaL_error(L, "brotli: compress stream error");
        }

        out.resize(used + (STREAM_CHUNK_SIZE - avail_out));
    }

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:flush() -> buffer
static int l_brotli_compressor_flush(lua_State* L) {
    auto* c = check_brotli_compressor(L);

    const uint8_t* next_in = nullptr;
    size_t avail_in = 0;

    std::vector<uint8_t> out;

    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        uint8_t* next_out = out.data() + used;
        size_t avail_out = STREAM_CHUNK_SIZE;

        if (!BrotliEncoderCompressStream(c->state, BROTLI_OPERATION_FLUSH, &avail_in, &next_in,
                                         &avail_out, &next_out, nullptr)) {
            luaL_error(L, "brotli: flush error");
        }

        out.resize(used + (STREAM_CHUNK_SIZE - avail_out));
    } while (BrotliEncoderHasMoreOutput(c->state));

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:finish() -> buffer
static int l_brotli_compressor_finish(lua_State* L) {
    auto* c = check_brotli_compressor(L);

    const uint8_t* next_in = nullptr;
    size_t avail_in = 0;

    std::vector<uint8_t> out;

    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        uint8_t* next_out = out.data() + used;
        size_t avail_out = STREAM_CHUNK_SIZE;

        if (!BrotliEncoderCompressStream(c->state, BROTLI_OPERATION_FINISH, &avail_in, &next_in,
                                         &avail_out, &next_out, nullptr)) {
            luaL_error(L, "brotli: finish error");
        }

        out.resize(used + (STREAM_CHUNK_SIZE - avail_out));
    } while (!BrotliEncoderIsFinished(c->state));

    BrotliEncoderDestroyInstance(c->state);
    c->state = nullptr;
    c->closed = true;

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

static int l_brotli_compressor_close(lua_State* L) {
    auto* c = (LuaBrotliCompressor*)luaL_checkudata(L, 1, MT_BROTLI_COMPRESS);
    if (!c->closed && c->state) {
        BrotliEncoderDestroyInstance(c->state);
        c->state = nullptr;
        c->closed = true;
    }
    return 0;
}

static int l_brotli_compressor_tostring(lua_State* L) {
    auto* c = (LuaBrotliCompressor*)luaL_checkudata(L, 1, MT_BROTLI_COMPRESS);
    lua_pushfstring(L, "brotli.Compressor(%s)", c->closed ? "closed" : "open");
    return 1;
}

// brotli.createCompressor(quality?, lgwin?, mode?) -> Compressor
static int l_create_brotli_compressor(lua_State* L) {
    int quality = (int)luaL_optinteger(L, 1, BROTLI_DEFAULT_QUALITY);
    int lgwin = (int)luaL_optinteger(L, 2, BROTLI_DEFAULT_WINDOW);
    int mode = (int)luaL_optinteger(L, 3, BROTLI_DEFAULT_MODE);

    auto* c = (LuaBrotliCompressor*)lua_newuserdatadtor(L, sizeof(LuaBrotliCompressor),
                                                        brotli_compressor_dtor);
    c->state = BrotliEncoderCreateInstance(nullptr, nullptr, nullptr);
    c->closed = false;

    if (!c->state) {
        c->closed = true;
        luaL_error(L, "brotli: failed to create encoder");
    }

    BrotliEncoderSetParameter(c->state, BROTLI_PARAM_QUALITY, (uint32_t)quality);
    BrotliEncoderSetParameter(c->state, BROTLI_PARAM_LGWIN, (uint32_t)lgwin);
    BrotliEncoderSetParameter(c->state, BROTLI_PARAM_MODE, (uint32_t)mode);

    luaL_getmetatable(L, MT_BROTLI_COMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Decompress
// ---------------------------------------------------------------------------

struct LuaBrotliDecompressor {
    BrotliDecoderState* state;
    bool closed;
    bool finished;
};

static void brotli_decompressor_dtor(void* ud) {
    auto* d = (LuaBrotliDecompressor*)ud;
    if (!d->closed && d->state) {
        BrotliDecoderDestroyInstance(d->state);
        d->state = nullptr;
        d->closed = true;
    }
}

static LuaBrotliDecompressor* check_brotli_decompressor(lua_State* L) {
    auto* d = (LuaBrotliDecompressor*)luaL_checkudata(L, 1, MT_BROTLI_DECOMPRESS);
    if (d->closed) luaL_error(L, "brotli: decompressor is closed");
    return d;
}

// decompressor:write(data) -> buffer, finished
static int l_brotli_decompressor_write(lua_State* L) {
    auto* d = check_brotli_decompressor(L);
    if (d->finished) luaL_error(L, "brotli: decompressor already finished");

    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    const uint8_t* next_in = (const uint8_t*)src;
    size_t avail_in = srcLen;

    std::vector<uint8_t> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen * 2);

    while (avail_in > 0 || BrotliDecoderHasMoreOutput(d->state)) {
        size_t used = out.size();
        if (used + STREAM_CHUNK_SIZE > MAX_DECOMPRESS_SIZE) {
            luaL_error(L, "brotli: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        out.resize(used + STREAM_CHUNK_SIZE);
        uint8_t* next_out = out.data() + used;
        size_t avail_out = STREAM_CHUNK_SIZE;

        BrotliDecoderResult result = BrotliDecoderDecompressStream(d->state, &avail_in, &next_in,
                                                                   &avail_out, &next_out, nullptr);

        out.resize(used + (STREAM_CHUNK_SIZE - avail_out));

        if (result == BROTLI_DECODER_RESULT_SUCCESS) {
            d->finished = true;
            break;
        } else if (result == BROTLI_DECODER_RESULT_ERROR) {
            luaL_error(L, "brotli: decompress stream error (%d)",
                       (int)BrotliDecoderGetErrorCode(d->state));
        }
        // BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT or NEEDS_MORE_OUTPUT: continue
    }

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    lua_pushboolean(L, d->finished);
    return 2;
}

static int l_brotli_decompressor_close(lua_State* L) {
    auto* d = (LuaBrotliDecompressor*)luaL_checkudata(L, 1, MT_BROTLI_DECOMPRESS);
    if (!d->closed && d->state) {
        BrotliDecoderDestroyInstance(d->state);
        d->state = nullptr;
        d->closed = true;
    }
    return 0;
}

static int l_brotli_decompressor_tostring(lua_State* L) {
    auto* d = (LuaBrotliDecompressor*)luaL_checkudata(L, 1, MT_BROTLI_DECOMPRESS);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "brotli.Decompressor(%s)", state);
    return 1;
}

// brotli.createDecompressor() -> Decompressor
static int l_create_brotli_decompressor(lua_State* L) {
    auto* d = (LuaBrotliDecompressor*)lua_newuserdatadtor(L, sizeof(LuaBrotliDecompressor),
                                                          brotli_decompressor_dtor);
    d->state = BrotliDecoderCreateInstance(nullptr, nullptr, nullptr);
    d->closed = false;
    d->finished = false;

    if (!d->state) {
        d->closed = true;
        luaL_error(L, "brotli: failed to create decoder");
    }

    luaL_getmetatable(L, MT_BROTLI_DECOMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_brotli(lua_State* L) {
    // Register Compressor metatable
    luaL_newmetatable(L, MT_BROTLI_COMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_brotli_compressor_write },
            { "flush", l_brotli_compressor_flush },
            { "finish", l_brotli_compressor_finish },
            { "close", l_brotli_compressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_brotli_compressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_brotli_compressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);

    // Register Decompressor metatable
    luaL_newmetatable(L, MT_BROTLI_DECOMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_brotli_decompressor_write },
            { "close", l_brotli_decompressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_brotli_decompressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_brotli_decompressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        { "compress", l_compress },
        { "decompress", l_decompress },
        { "maxCompressedSize", l_max_compressed_size },
        { "createCompressor", l_create_brotli_compressor },
        { "createDecompressor", l_create_brotli_decompressor },
        { nullptr, nullptr },
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Mode constants
    lua_pushinteger(L, BROTLI_MODE_GENERIC);
    lua_setfield(L, -2, "MODE_GENERIC");
    lua_pushinteger(L, BROTLI_MODE_TEXT);
    lua_setfield(L, -2, "MODE_TEXT");
    lua_pushinteger(L, BROTLI_MODE_FONT);
    lua_setfield(L, -2, "MODE_FONT");

    // Quality constants
    lua_pushinteger(L, BROTLI_MIN_QUALITY);
    lua_setfield(L, -2, "QUALITY_MIN");
    lua_pushinteger(L, BROTLI_MAX_QUALITY);
    lua_setfield(L, -2, "QUALITY_MAX");
    lua_pushinteger(L, BROTLI_DEFAULT_QUALITY);
    lua_setfield(L, -2, "QUALITY_DEFAULT");

    // Window size constants (log2 of bytes)
    lua_pushinteger(L, BROTLI_MIN_WINDOW_BITS);
    lua_setfield(L, -2, "WINDOW_MIN");
    lua_pushinteger(L, BROTLI_MAX_WINDOW_BITS);
    lua_setfield(L, -2, "WINDOW_MAX");
    lua_pushinteger(L, BROTLI_DEFAULT_WINDOW);
    lua_setfield(L, -2, "WINDOW_DEFAULT");

    return 1;
}
