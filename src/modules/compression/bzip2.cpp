#include "module_api.h"
//
#include "bzlib.h"
#include "lua.h"
#include "lualib.h"

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

    if (blockSize < 1 || blockSize > 9) luaL_error(L, "bzip2: block_size must be 1-9");

    // bzip2 worst-case: n * 1.01 + 600 bytes
    unsigned int bound = (unsigned int)(srcLen * 1.01 + 700);
    std::vector<char> tmp(bound);
    unsigned int destLen = bound;

    int ret = BZ2_bzBuffToBuffCompress(tmp.data(), &destLen, (char*)src, (unsigned int)srcLen,
                                       blockSize, 0, 30);
    if (ret != BZ_OK) luaL_error(L, "bzip2: compress failed (%d)", ret);

    void* out = lua_newbuffer(L, destLen);
    memcpy(out, tmp.data(), destLen);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data, small?) -> buffer
// small=true activates bzip2's alternative decompression algorithm that
// uses ~2 MB instead of ~3.5 MB but runs at about half the speed.
// ---------------------------------------------------------------------------

static constexpr size_t MAX_DECOMPRESS_SIZE = 256 * 1024 * 1024;  // 256 MB

static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int small = lua_toboolean(L, 2);  // defaults to false

    std::vector<char> tmp(srcLen < 16 ? 64 : srcLen * 4);
    while (true) {
        unsigned int destLen = (unsigned int)tmp.size();
        int ret = BZ2_bzBuffToBuffDecompress(tmp.data(), &destLen, (char*)src, (unsigned int)srcLen,
                                             small, 0);
        if (ret == BZ_OK) {
            void* out = lua_newbuffer(L, destLen);
            memcpy(out, tmp.data(), destLen);
            return 1;
        } else if (ret == BZ_OUTBUFF_FULL) {
            size_t newSize = tmp.size() * 2;
            if (newSize > MAX_DECOMPRESS_SIZE) {
                luaL_error(L, "bzip2: decompressed size exceeds limit (%d MB)",
                           (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
            }
            tmp.resize(newSize);
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
// Streaming Compress
// ---------------------------------------------------------------------------

static constexpr size_t STREAM_CHUNK_SIZE = 32 * 1024;  // 32 KB

static const char* MT_BZ2_COMPRESS = "bzip2.Compressor";
static const char* MT_BZ2_DECOMPRESS = "bzip2.Decompressor";

struct LuaBz2Compressor {
    bz_stream strm;
    bool closed;
};

static void bz2_compressor_dtor(void* ud) {
    auto* c = (LuaBz2Compressor*)ud;
    if (!c->closed) {
        BZ2_bzCompressEnd(&c->strm);
        c->closed = true;
    }
}

static LuaBz2Compressor* check_bz2_compressor(lua_State* L) {
    auto* c = (LuaBz2Compressor*)luaL_checkudata(L, 1, MT_BZ2_COMPRESS);
    if (c->closed) luaL_error(L, "bzip2: compressor is closed");
    return c;
}

// compressor:write(data) -> buffer
static int l_bz2_compressor_write(lua_State* L) {
    auto* c = check_bz2_compressor(L);
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    c->strm.next_in = (char*)src;
    c->strm.avail_in = (unsigned int)srcLen;

    std::vector<char> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen);

    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        c->strm.next_out = out.data() + used;
        c->strm.avail_out = (unsigned int)STREAM_CHUNK_SIZE;

        int ret = BZ2_bzCompress(&c->strm, BZ_RUN);
        if (ret != BZ_RUN_OK) luaL_error(L, "bzip2: compress stream error (%d)", ret);

        size_t produced = STREAM_CHUNK_SIZE - c->strm.avail_out;
        out.resize(used + produced);
    } while (c->strm.avail_in > 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:flush() -> buffer
static int l_bz2_compressor_flush(lua_State* L) {
    auto* c = check_bz2_compressor(L);

    c->strm.next_in = nullptr;
    c->strm.avail_in = 0;

    std::vector<char> out;
    int ret;
    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        c->strm.next_out = out.data() + used;
        c->strm.avail_out = (unsigned int)STREAM_CHUNK_SIZE;

        ret = BZ2_bzCompress(&c->strm, BZ_FLUSH);
        if (ret != BZ_RUN_OK && ret != BZ_FLUSH_OK) {
            luaL_error(L, "bzip2: flush error (%d)", ret);
        }

        size_t produced = STREAM_CHUNK_SIZE - c->strm.avail_out;
        out.resize(used + produced);
    } while (ret != BZ_RUN_OK);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:finish() -> buffer
static int l_bz2_compressor_finish(lua_State* L) {
    auto* c = check_bz2_compressor(L);

    c->strm.next_in = nullptr;
    c->strm.avail_in = 0;

    std::vector<char> out;
    int ret;
    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        c->strm.next_out = out.data() + used;
        c->strm.avail_out = (unsigned int)STREAM_CHUNK_SIZE;

        ret = BZ2_bzCompress(&c->strm, BZ_FINISH);
        if (ret != BZ_FINISH_OK && ret != BZ_STREAM_END) {
            luaL_error(L, "bzip2: finish error (%d)", ret);
        }

        size_t produced = STREAM_CHUNK_SIZE - c->strm.avail_out;
        out.resize(used + produced);
    } while (ret != BZ_STREAM_END);

    BZ2_bzCompressEnd(&c->strm);
    c->closed = true;

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

static int l_bz2_compressor_close(lua_State* L) {
    auto* c = (LuaBz2Compressor*)luaL_checkudata(L, 1, MT_BZ2_COMPRESS);
    if (!c->closed) {
        BZ2_bzCompressEnd(&c->strm);
        c->closed = true;
    }
    return 0;
}

static int l_bz2_compressor_tostring(lua_State* L) {
    auto* c = (LuaBz2Compressor*)luaL_checkudata(L, 1, MT_BZ2_COMPRESS);
    lua_pushfstring(L, "bzip2.Compressor(%s)", c->closed ? "closed" : "open");
    return 1;
}

// bzip2.createCompressor(blockSize?) -> Compressor
static int l_create_bz2_compressor(lua_State* L) {
    int blockSize = (int)luaL_optinteger(L, 1, 9);
    if (blockSize < 1 || blockSize > 9) luaL_error(L, "bzip2: block_size must be 1-9");

    auto* c =
        (LuaBz2Compressor*)lua_newuserdatadtor(L, sizeof(LuaBz2Compressor), bz2_compressor_dtor);
    memset(&c->strm, 0, sizeof(bz_stream));
    c->closed = false;

    int ret = BZ2_bzCompressInit(&c->strm, blockSize, 0, 30);
    if (ret != BZ_OK) {
        c->closed = true;
        luaL_error(L, "bzip2: compressInit failed (%d)", ret);
    }

    luaL_getmetatable(L, MT_BZ2_COMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Decompress
// ---------------------------------------------------------------------------

struct LuaBz2Decompressor {
    bz_stream strm;
    bool closed;
    bool finished;
};

static void bz2_decompressor_dtor(void* ud) {
    auto* d = (LuaBz2Decompressor*)ud;
    if (!d->closed) {
        BZ2_bzDecompressEnd(&d->strm);
        d->closed = true;
    }
}

static LuaBz2Decompressor* check_bz2_decompressor(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)luaL_checkudata(L, 1, MT_BZ2_DECOMPRESS);
    if (d->closed) luaL_error(L, "bzip2: decompressor is closed");
    return d;
}

// decompressor:write(data) -> buffer, finished
static int l_bz2_decompressor_write(lua_State* L) {
    auto* d = check_bz2_decompressor(L);
    if (d->finished) luaL_error(L, "bzip2: decompressor already finished");

    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    d->strm.next_in = (char*)src;
    d->strm.avail_in = (unsigned int)srcLen;

    std::vector<char> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen * 2);

    int ret = BZ_OK;
    do {
        size_t used = out.size();
        if (used + STREAM_CHUNK_SIZE > MAX_DECOMPRESS_SIZE) {
            luaL_error(L, "bzip2: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        out.resize(used + STREAM_CHUNK_SIZE);
        d->strm.next_out = out.data() + used;
        d->strm.avail_out = (unsigned int)STREAM_CHUNK_SIZE;

        ret = BZ2_bzDecompress(&d->strm);
        if (ret != BZ_OK && ret != BZ_STREAM_END) {
            luaL_error(L, "bzip2: decompress stream error (%d)", ret);
        }

        size_t produced = STREAM_CHUNK_SIZE - d->strm.avail_out;
        out.resize(used + produced);

        if (ret == BZ_STREAM_END) {
            d->finished = true;
            break;
        }
    } while (d->strm.avail_in > 0 || d->strm.avail_out == 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    lua_pushboolean(L, d->finished);
    return 2;
}

static int l_bz2_decompressor_close(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)luaL_checkudata(L, 1, MT_BZ2_DECOMPRESS);
    if (!d->closed) {
        BZ2_bzDecompressEnd(&d->strm);
        d->closed = true;
    }
    return 0;
}

static int l_bz2_decompressor_tostring(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)luaL_checkudata(L, 1, MT_BZ2_DECOMPRESS);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "bzip2.Decompressor(%s)", state);
    return 1;
}

// bzip2.createDecompressor(small?) -> Decompressor
static int l_create_bz2_decompressor(lua_State* L) {
    int small = lua_toboolean(L, 1);

    auto* d = (LuaBz2Decompressor*)lua_newuserdatadtor(L, sizeof(LuaBz2Decompressor),
                                                       bz2_decompressor_dtor);
    memset(&d->strm, 0, sizeof(bz_stream));
    d->closed = false;
    d->finished = false;

    int ret = BZ2_bzDecompressInit(&d->strm, 0, small);
    if (ret != BZ_OK) {
        d->closed = true;
        luaL_error(L, "bzip2: decompressInit failed (%d)", ret);
    }

    luaL_getmetatable(L, MT_BZ2_DECOMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_bzip2(lua_State* L) {
    // Register Compressor metatable
    luaL_newmetatable(L, MT_BZ2_COMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_bz2_compressor_write },
            { "flush", l_bz2_compressor_flush },
            { "finish", l_bz2_compressor_finish },
            { "close", l_bz2_compressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_bz2_compressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_bz2_compressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);

    // Register Decompressor metatable
    luaL_newmetatable(L, MT_BZ2_DECOMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_bz2_decompressor_write },
            { "close", l_bz2_decompressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_bz2_decompressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_bz2_decompressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        { "compress", l_compress },
        { "decompress", l_decompress },
        { "compressBound", l_compress_bound },
        { "createCompressor", l_create_bz2_compressor },
        { "createDecompressor", l_create_bz2_decompressor },
        { nullptr, nullptr },
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Block size constants
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "BLOCK_FAST");
    lua_pushinteger(L, 9);
    lua_setfield(L, -2, "BLOCK_BEST");

    return 1;
}
