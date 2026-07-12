#include "module_api.h"
//
#include <cstring>
#include <vector>

#include "bzlib.h"
#include "lua.h"
#include "lualib.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_bzip2",
};
LUAU_MODULE_INFO()

udataRef* bzip2Compressor;
udataRef* bzip2Decompressor;

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

struct LuaBz2Compressor {
    bz_stream strm;
    bool closed;
};

static LuaBz2Compressor* check_bz2_compressor(lua_State* L) {
    auto* c = (LuaBz2Compressor*)eryxUdata_checkudata(L, bzip2Compressor, 1);
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

static void l_bz2_compressor_destructor(lua_State* L, void* ud) {
    auto* c = (LuaBz2Compressor*)ud;
    if (!c->closed) {
        BZ2_bzCompressEnd(&c->strm);
        c->closed = true;
    }
}

static int l_bz2_compressor_close(lua_State* L) {
    auto* c = (LuaBz2Compressor*)eryxUdata_checkudata(L, bzip2Compressor, 1);
    l_bz2_compressor_destructor(L, c);
    return 0;
}

static int l_bz2_compressor_tostring(lua_State* L) {
    auto* c = (LuaBz2Compressor*)eryxUdata_checkudata(L, bzip2Compressor, 1);
    lua_pushfstring(L, "bzip2.Compressor(%s)", c->closed ? "closed" : "open");
    return 1;
}

// bzip2.createCompressor(blockSize?) -> Compressor
static int l_create_bz2_compressor(lua_State* L) {
    int blockSize = (int)luaL_optinteger(L, 1, 9);
    if (blockSize < 1 || blockSize > 9) luaL_error(L, "bzip2: block_size must be 1-9");

    auto* c = (LuaBz2Compressor*)eryxUdata_pushudata(L, bzip2Compressor);
    memset(&c->strm, 0, sizeof(bz_stream));
    c->closed = false;

    int ret = BZ2_bzCompressInit(&c->strm, blockSize, 0, 30);
    if (ret != BZ_OK) {
        c->closed = true;
        luaL_error(L, "bzip2: compressInit failed (%d)", ret);
    }

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

static LuaBz2Decompressor* check_bz2_decompressor(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)eryxUdata_checkudata(L, bzip2Decompressor, 1);
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

static void l_bz2_decompressor_destructor(lua_State* L, void* ud) {
    auto* d = (LuaBz2Decompressor*)ud;
    if (!d->closed) {
        BZ2_bzDecompressEnd(&d->strm);
        d->closed = true;
    }
}

static int l_bz2_decompressor_close(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)eryxUdata_checkudata(L, bzip2Decompressor, 1);
    l_bz2_decompressor_destructor(L, d);
    return 0;
}

static int l_bz2_decompressor_tostring(lua_State* L) {
    auto* d = (LuaBz2Decompressor*)eryxUdata_checkudata(L, bzip2Decompressor, 1);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "bzip2.Decompressor(%s)", state);
    return 1;
}

// bzip2.createDecompressor(small?) -> Decompressor
static int l_create_bz2_decompressor(lua_State* L) {
    int small = lua_toboolean(L, 1);

    auto* d = (LuaBz2Decompressor*)eryxUdata_pushudata(L, bzip2Decompressor);
    memset(&d->strm, 0, sizeof(bz_stream));
    d->closed = false;
    d->finished = false;

    int ret = BZ2_bzDecompressInit(&d->strm, 0, small);
    if (ret != BZ_OK) {
        d->closed = true;
        luaL_error(L, "bzip2: decompressInit failed (%d)", ret);
    }

    return 1;
}

luaL_Reg bzip2CompressorMethods[] = {
    { "write", l_bz2_compressor_write },
    { "flush", l_bz2_compressor_flush },
    { "finish", l_bz2_compressor_finish },
    { "close", l_bz2_compressor_close },
    { nullptr, nullptr },
};

luaL_Reg bzip2CompressorMetamethods[] = {
    { "__tostring", l_bz2_compressor_tostring },
    { nullptr, nullptr },
};

udataDef bzip2CompressorDef = {
    .name = "Bzip2Compressor",
    .size = sizeof(LuaBz2Compressor),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = bzip2CompressorMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = bzip2CompressorMethods,
    .bothcallMethods = nullptr,
    .destructor = l_bz2_compressor_destructor,
};

luaL_Reg bzip2DecompressorMethods[] = {
    { "write", l_bz2_decompressor_write },
    { "close", l_bz2_decompressor_close },
    { nullptr, nullptr },
};

luaL_Reg bzip2DecompressorMetamethods[] = {
    { "__tostring", l_bz2_decompressor_tostring },
    { nullptr, nullptr },
};

udataDef bzip2DecompressorDef = {
    .name = "Bzip2Decompressor",
    .size = sizeof(LuaBz2Decompressor),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = bzip2DecompressorMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = bzip2DecompressorMethods,
    .bothcallMethods = nullptr,
    .destructor = l_bz2_decompressor_destructor,
};

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_bzip2(lua_State* L) {
    bzip2Compressor = eryxUdata_registerudata(L, &bzip2CompressorDef);
    bzip2Decompressor = eryxUdata_registerudata(L, &bzip2DecompressorDef);

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
