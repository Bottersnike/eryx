#include "lrequire.hpp"

#include <filesystem>
#ifndef _WIN32
#include <dlfcn.h>
#endif

#include "../vfs.hpp"
#include "Luau/CodeGen.h"
#include "_wrapper_lib.hpp"
#include "embedded_modules.h"
#include "lexception.hpp"
#include "lrequire.hpp"
#include "lresolve.hpp"
#include "lua.h"

namespace fs = std::filesystem;

// Cache status values stored in a parallel registry table named "_LOADED_STATUS".
static const int CACHE_STATUS_UNSEEN = 0;
static const int CACHE_STATUS_LOADING = 1;
static const int CACHE_STATUS_LOADED = 2;
static const int CACHE_STATUS_YIELDED = 3;

static void eryx_cache_registry_ensure_status_table(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_STATUS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_STATUS");
    }
}

static int eryx_cache_registry_get_status(lua_State* L, const char* cacheKey) {
    eryx_cache_registry_ensure_status_table(L);
    // _LOADED_STATUS is now on top of the stack
    lua_getfield(L, -1, cacheKey);
    int status = CACHE_STATUS_UNSEEN;
    if (!lua_isnil(L, -1) && lua_isnumber(L, -1)) {
        status = (int)lua_tointeger(L, -1);
    }
    lua_pop(L, 2);  // pop value + _LOADED_STATUS
    return status;
}

static void eryx_cache_registry_set_status(lua_State* L, const char* cacheKey, int status) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_STATUS");

    // Create the registry, if not present
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_STATUS");
    }

    lua_pushinteger(L, status);
    lua_setfield(L, -2, cacheKey);
    lua_pop(L, 1);  // pop _LOADED_STATUS table
}

// Store the loader thread (the coroutine actually executing the module)
static void eryx_cache_registry_set_loader_thread(lua_State* L, lua_State* loaderThread,
                                                  const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");
    }

    lua_pushlightuserdata(L, loaderThread);
    lua_setfield(L, -2, cacheKey);
    lua_pop(L, 1);  // pop _LOADED_THREADS table

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREAD_KEYS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_THREAD_KEYS");
    }

    lua_pushlightuserdata(L, loaderThread);
    lua_pushstring(L, cacheKey);
    lua_settable(L, -3);
    lua_pop(L, 1);  // pop _LOADED_THREAD_KEYS table
}

static void eryx_cache_registry_clear_loader_thread(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    lua_getfield(L, -1, cacheKey);
    bool hasThread = lua_islightuserdata(L, -1);

    lua_pushnil(L);
    lua_setfield(L, -3, cacheKey);

    lua_remove(L, -2);  // remove _LOADED_THREADS table, leave thread ptr/nil on top

    if (hasThread) {
        lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREAD_KEYS");
        if (!lua_isnil(L, -1)) {
            lua_pushvalue(L, -2);
            lua_pushnil(L);
            lua_settable(L, -3);
        }
        lua_pop(L, 1);  // pop _LOADED_THREAD_KEYS table or nil
    }

    lua_pop(L, 1);  // pop thread/nil
}

static bool eryx_cache_registry_get_loader_key(lua_State* GL, lua_State* targetThread,
                                               std::string* cacheKey) {
    lua_getfield(GL, LUA_REGISTRYINDEX, "_LOADED_THREAD_KEYS");
    if (lua_isnil(GL, -1)) {
        lua_pop(GL, 1);
        return false;
    }

    lua_pushlightuserdata(GL, targetThread);
    lua_gettable(GL, -2);

    bool found = lua_isstring(GL, -1);
    if (found && cacheKey) {
        cacheKey->assign(lua_tostring(GL, -1));
    }

    lua_pop(GL, 2);
    return found;
}

static std::string eryx_chunk_name_from_cache_key(const std::string& cacheKey) {
    size_t separator = cacheKey.find(':');
    if (separator == std::string::npos || separator + 1 >= cacheKey.size()) {
        return cacheKey;
    }

    int type = atoi(cacheKey.substr(0, separator).c_str());
    std::string path = cacheKey.substr(separator + 1);

    switch (type) {
        case LocatedModule::TYPE_FILE:
            return "@" + path;
        case LocatedModule::TYPE_VFS:
            return std::string(CHUNK_PREFIX_VFS) + path;
        case LocatedModule::TYPE_EMBEDDED_NATIVE:
        case LocatedModule::TYPE_EMBEDDED_SCRIPT:
            return std::string(CHUNK_PREFIX_ERYX) + path;
        default:
            return path;
    }
}

static void eryx_push_module_arity_exception(lua_State* L, const std::string& chunkName,
                                             int returnedCount) {
    LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
    new (exception) LuaException();
    luaL_getmetatable(L, EXCEPTION_METATABLE);
    lua_setmetatable(L, -2);
    exception->type = ETYPE_RUNTIME;
    exception->message = "Module " + chunkName + " must return a single value. Returned " +
                         std::to_string(returnedCount);

    std::string shortSrc = chunkName;
    if (!shortSrc.empty() && shortSrc[0] == '@') {
        shortSrc.erase(0, 1);
    }

    exception->traceback.push_back({
        .source = chunkName,
        .short_src = shortSrc,
        .line = 1,
        .function = "<top level>",
        .lineContext = getSourceLine(chunkName.c_str(), 1),
    });
}

// Waiters: store a list of threads waiting for a module to finish loading
static void eryx_cache_registry_add_waiter(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    }

    // ensure sub-table for this key
    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, -3, cacheKey);
        // leave the new table on stack
    }

    // at this point the waiters table for key is on top
    // append current thread
    lua_pushthread(L);  // pushes the current thread object
    size_t len = lua_objlen(L, -2);
    lua_rawseti(L, -2, (int)len + 1);

    // pop waiters table and _LOADED_WAITERS table
    lua_pop(L, 2);
}

static void eryx_cache_registry_wake_waiters(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 2);
        return;
    }

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 3);
        return;
    }

    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 4);
        return;
    }

    auto rt = eryx_get_runtime(L);
    int resultIndex = lua_gettop(L);

    // waiters table is at -3, _LOADED at -2, cached value at -1
    size_t len = lua_objlen(L, -3);
    for (size_t i = 1; i <= len; ++i) {
        lua_rawgeti(L, -3, (int)i);
        if (lua_isthread(L, -1)) {
            lua_State* th = lua_tothread(L, -1);
            lua_pushvalue(L, resultIndex);
            lua_xmove(L, th, 1);

            lua_pushvalue(L, -1);
            int waiterRef = lua_ref(L, -1);
            eryx_push_thread(rt, waiterRef, 1, false);
        }
        lua_pop(L, 1);
    }

    // clear the waiters list for this key
    lua_pushnil(L);
    lua_setfield(L, -5, cacheKey);

    lua_pop(L, 4);  // pop cached value + _LOADED + waiters + _LOADED_WAITERS
}

static void eryx_require_push_exception_copy(lua_State* L, const LuaException* source) {
    lua_checkstack(L, 2);

    LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
    new (exception) LuaException();
    luaL_getmetatable(L, EXCEPTION_METATABLE);
    lua_setmetatable(L, -2);

    exception->type = source->type;
    exception->message = source->message;
    exception->traceback = source->traceback;
    exception->extra = source->extra;

    std::unique_ptr<LuaExceptionSnapshot> snapshot = eryx_copy_exception(source);
    if (snapshot) {
        exception->parent = std::move(snapshot->parent);
    }
}

static void eryx_cache_registry_fail_waiters_with_module_arity(lua_State* L, const char* cacheKey,
                                                               int returnedCount) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 2);
        return;
    }

    auto rt = eryx_get_runtime(L);
    std::string chunkName = eryx_chunk_name_from_cache_key(cacheKey);
    size_t len = lua_objlen(L, -1);
    for (size_t i = 1; i <= len; ++i) {
        lua_rawgeti(L, -1, (int)i);
        if (lua_isthread(L, -1)) {
            lua_State* th = lua_tothread(L, -1);
            eryx_push_module_arity_exception(th, chunkName, returnedCount);

            lua_pushvalue(L, -1);
            int waiterRef = lua_ref(L, -1);
            eryx_push_thread(rt, waiterRef, 1, true);
        }
        lua_pop(L, 1);
    }

    lua_pushnil(L);
    lua_setfield(L, -3, cacheKey);
    lua_pop(L, 2);
}

static void eryx_cache_registry_fail_waiters(lua_State* L, const char* cacheKey,
                                             const char* message) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 2);
        return;
    }

    auto rt = eryx_get_runtime(L);
    size_t len = lua_objlen(L, -1);
    for (size_t i = 1; i <= len; ++i) {
        lua_rawgeti(L, -1, (int)i);
        if (lua_isthread(L, -1)) {
            lua_State* th = lua_tothread(L, -1);
            eryx_exception_push_exception(th, ETYPE_REQUIRE, message, nullptr);

            lua_pushvalue(L, -1);
            int waiterRef = lua_ref(L, -1);
            eryx_push_thread(rt, waiterRef, 1, true);
        }
        lua_pop(L, 1);
    }

    lua_pushnil(L);
    lua_setfield(L, -3, cacheKey);
    lua_pop(L, 2);
}

static void eryx_cache_registry_fail_waiters_with_exception(lua_State* L, const char* cacheKey,
                                                            const LuaException* exception) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_WAITERS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_getfield(L, -1, cacheKey);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 2);
        return;
    }

    auto rt = eryx_get_runtime(L);
    size_t len = lua_objlen(L, -1);
    for (size_t i = 1; i <= len; ++i) {
        lua_rawgeti(L, -1, (int)i);
        if (lua_isthread(L, -1)) {
            lua_State* th = lua_tothread(L, -1);
            eryx_require_push_exception_copy(th, exception);

            lua_pushvalue(L, -1);
            int waiterRef = lua_ref(L, -1);
            eryx_push_thread(rt, waiterRef, 1, true);
        }
        lua_pop(L, 1);
    }

    lua_pushnil(L);
    lua_setfield(L, -3, cacheKey);
    lua_pop(L, 2);
}

/**
 * @brief Check for a cached module in the registry. Leave it on the Lua stack if found.
 */
static bool eryx_cache_registry_check(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");

    // Create the registry, if not present
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }

    // Check for an existing value in the cache
    lua_getfield(L, -1, cacheKey);
    if (!lua_isnil(L, -1)) {
        lua_remove(L, -2);  // remove _LOADED table, cached value remains
        return true;
    }

    lua_pop(L, 2);  // pop nil + _LOADED table
    return false;
}
/**
 * @brief Cache a module in the registry. Expects the module value to the at the top of the stack.
 */
static void eryx_cache_registry_cache(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");

    // Create the registry, if not present
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }

    lua_pushvalue(L, -2);           // copy the result
    lua_setfield(L, -2, cacheKey);  // _LOADED[type:path] = result
    // Mark this cache key as loaded in the parallel status table
    eryx_cache_registry_set_status(L, cacheKey, CACHE_STATUS_LOADED);

    // Clear any stored loader thread and wake waiters waiting on this key
    eryx_cache_registry_clear_loader_thread(L, cacheKey);
    eryx_cache_registry_wake_waiters(L, cacheKey);

    lua_pop(L, 1);  // pop _LOADED table
}

static void eryx_require_reset_load_state(lua_State* L, const char* cacheKey) {
    eryx_cache_registry_clear_loader_thread(L, cacheKey);
    eryx_cache_registry_set_status(L, cacheKey, CACHE_STATUS_UNSEEN);
}

ERYX_API bool eryx_require_maybe_finalize_loader(lua_State* GL, lua_State* L, int status) {
    if (status == LUA_YIELD) return false;

    std::string cacheKey;
    if (!eryx_cache_registry_get_loader_key(GL, L, &cacheKey)) {
        return false;
    }

    if (status == LUA_OK) {
        if (lua_gettop(L) == 1) {
            eryx_cache_registry_cache(L, cacheKey.c_str());
        } else {
            eryx_cache_registry_clear_loader_thread(GL, cacheKey.c_str());
            eryx_cache_registry_set_status(GL, cacheKey.c_str(), CACHE_STATUS_UNSEEN);
            eryx_cache_registry_fail_waiters_with_module_arity(GL, cacheKey.c_str(), lua_gettop(L));
        }

        return true;
    }

    if (!eryx_get_exception(L, -1)) {
        eryx_coerce_to_exception(L);
    }
    eryx_cache_registry_clear_loader_thread(GL, cacheKey.c_str());
    eryx_cache_registry_set_status(GL, cacheKey.c_str(), CACHE_STATUS_UNSEEN);
    if (LuaException* exception = eryx_get_exception(L, -1)) {
        eryx_cache_registry_fail_waiters_with_exception(GL, cacheKey.c_str(), exception);
    } else {
        std::string message = eryx_format_exception(L, -1, false);
        eryx_cache_registry_fail_waiters(GL, cacheKey.c_str(), message.c_str());
    }
    return true;
}

typedef struct ErrorParts {
    std::string filename;
    int line;
    std::string message;
} ErrorParts;
ErrorParts _extract_error_message(const std::string& err) {
    ErrorParts parts;
    // Safe defaults
    parts.line = 0;
    parts.message = err;

    // Find ": " before the message
    size_t colon2 = err.find(": ");
    if (colon2 == std::string::npos) return parts;

    // Find the colon before the line number
    size_t colon1 = err.rfind(':', colon2 - 1);
    if (colon1 == std::string::npos) return parts;

    parts.filename = err.substr(0, colon1);

    std::string line_str = err.substr(colon1 + 1, colon2 - colon1 - 1);
    std::istringstream iss(line_str);
    iss >> parts.line;

    if (colon2 + 2 < err.size())
        parts.message = err.substr(colon2 + 2);
    else
        parts.message = "";

    return parts;
}

static int lua_push_exception(lua_State* L, const char* message) {
    LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
    new (exception) LuaException();

    exception->message = message;

    return 1;
}

static EryxRuntime* eryx_runtime_or_null(lua_State* L) {
    return (EryxRuntime*)lua_getthreaddata(lua_mainthread(L));
}

static void eryx_apply_runtime_compile_options(lua_State* L, Luau::CompileOptions& opts) {
    if (EryxRuntime* rt = eryx_runtime_or_null(L)) {
        opts.optimizationLevel = rt->luauOptimizationLevel;
        opts.debugLevel = rt->luauDebugLevel;
        opts.typeInfoLevel = rt->luauTypeInfoLevel;
    }
}

static unsigned int eryx_runtime_native_codegen_flags(lua_State* L) {
    EryxRuntime* rt = eryx_runtime_or_null(L);
    if (!rt) return Luau::CodeGen::CodeGen_ColdFunctions;

    switch (rt->nativeCodegenMode) {
        case EryxNativeCodegenMode::Disabled:
            return 0;
        case EryxNativeCodegenMode::OnlySpecified:
            return Luau::CodeGen::CodeGen_OnlyNativeModules | Luau::CodeGen::CodeGen_ColdFunctions;
        case EryxNativeCodegenMode::All:
        default:
            return Luau::CodeGen::CodeGen_ColdFunctions;
    }
}

ERYX_API bool eryx_load_and_prepare_bytecode(lua_State* L, const std::string& bytecode,
                                             const std::string& chunkName) {
    // Load bytecode into VM
    int status = luau_load(L, chunkName.c_str(), bytecode.data(), bytecode.size(), 0);
    if (status != LUA_OK) {
        const char* msg = lua_tostring(L, -1);

        // Create a new exception on the parent lua (L, not ML)
        LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
        new (exception) LuaException();
        luaL_getmetatable(L, EXCEPTION_METATABLE);
        lua_setmetatable(L, -2);

        exception->type = ETYPE_SYNTAX;
        if (msg) {
            ErrorParts parts = _extract_error_message(std::string(msg));
            exception->message = parts.message;
            exception->traceback.push_back({
                // TODO: Which name?
                .source = chunkName,
                .short_src = parts.filename,

                .line = parts.line,
                .lineContext = getSourceLine(chunkName.c_str(), parts.line),
            });
        } else {
            exception->message = "<unknown>";
        }

        return false;
    }

    // Attempt native codegen if we can
    unsigned int nativeFlags = eryx_runtime_native_codegen_flags(L);
    if (nativeFlags != 0 && lua_codegen_isSupported()) {
        Luau::CodeGen::CompilationStats stats = {};
        Luau::CodeGen::CodeGenCompilationResult res =
            lua_codegen_compile(L, -1, nativeFlags, &stats);
    }

    if (EryxRuntime* rt = eryx_runtime_or_null(L)) {
        if (rt->debugFunctionLoaded) {
            rt->debugFunctionLoaded(L, -1, chunkName.c_str(), rt->debugFunctionLoadedContext);
        }
    }

    return true;
}

ERYX_API bool eryx_load_and_prepare_script(lua_State* L, const std::string source,
                                           const std::string& chunkName) {
    // Compile bytecode from source
    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    opts.debugLevel = 1;
    opts.typeInfoLevel = 1;
    eryx_apply_runtime_compile_options(L, opts);

    std::string bytecode = Luau::compile(source, opts);

    return eryx_load_and_prepare_bytecode(L, bytecode, chunkName);
}

ERYX_API int eryx_execute_module_bytecode(lua_State* L, const std::string& bytecode,
                                          const std::string& chunkName,
                                          const std::string& cacheKey) {
    // Make a new state for loading this module
    lua_State* GL = lua_mainthread(L);
    lua_checkstack(GL, 1);
    lua_State* ML = lua_newthread(GL);

    lua_xmove(GL, L, 1);
    luaL_sandboxthread(ML);

    if (!eryx_load_and_prepare_bytecode(ML, bytecode, chunkName)) {
        // Move the error from ML to L before we destroy ML
        lua_xmove(ML, L, 1);

        // Remove ML from the stack
        lua_remove(L, -2);

        lua_error(L);
    }

    // Create a per-module environment table with `_DIR` and `_FILE` set.
    // The table falls back to the global `_G` so existing globals remain
    // accessible. We set this as the chunk's `_ENV` upvalue (upvalue #1)
    // so the module sees these values as globals without mutating `_G`.
    std::string dirStr;
    std::string fileStr;
    if (!chunkName.empty()) {
        if (chunkName[0] == '@') {
            std::string p = chunkName.substr(1);
            try {
                fs::path sp = fs::path(p);
                dirStr = sp.parent_path().generic_string();
                fileStr = sp.generic_string();
            } catch (...) {
            }
        } else if (chunkName.rfind(CHUNK_PREFIX_VFS, 0) == 0) {
            std::string p = chunkName.substr(CHUNK_PREFIX_VFS_LEN);
            try {
                fs::path sp = fs::path(p);
                dirStr = std::string(CHUNK_PREFIX_VFS) + sp.parent_path().generic_string();
                fileStr = std::string(CHUNK_PREFIX_VFS) + p;
            } catch (...) {
            }
        } else if (chunkName.rfind(CHUNK_PREFIX_ERYX, 0) == 0) {
            std::string p = chunkName.substr(CHUNK_PREFIX_ERYX_LEN);
            try {
                fs::path sp = fs::path(p);
                dirStr = std::string(CHUNK_PREFIX_ERYX) + sp.parent_path().generic_string();
                fileStr = std::string(CHUNK_PREFIX_ERYX) + p;
            } catch (...) {
            }
        }
    }

    if (!dirStr.empty() || !fileStr.empty()) {
        lua_newtable(ML);  // env

        // env.__index = _G
        lua_getglobal(ML, "_G");
        lua_setfield(ML, -2, "__index");

        lua_newtable(ML);                 // metatable
        lua_getglobal(ML, "_G");          // fallback
        lua_setfield(ML, -2, "__index");  // mt.__index = _G
        lua_setmetatable(ML, -2);         // setmetatable(env, mt)

        if (!fileStr.empty()) {
            lua_pushstring(ML, fileStr.c_str());
            lua_setfield(ML, -2, "_FILE");
        }
        if (!dirStr.empty()) {
            lua_pushstring(ML, dirStr.c_str());
            lua_setfield(ML, -2, "_DIR");
        }

        // set as environment for chunk
        lua_setfenv(ML, -2);
    }

    int status = lua_resume(ML, L, 0);

    bool ok = false;
    bool badReturnCount = false;
    int returnedCount = 0;
    if (status == LUA_OK) {
        if (lua_gettop(ML) != 1) {
            badReturnCount = true;
            returnedCount = lua_gettop(ML);
        } else {
            ok = true;
        }
    } else if (status == LUA_YIELD) {
        // Mark this module as yielded and record the loader thread so it can
        // be resumed later when the module finishes its async work.
        eryx_cache_registry_set_status(L, cacheKey.c_str(), CACHE_STATUS_YIELDED);

        // Stash the loader coroutine in the registry, then remove the copied
        // thread object from the caller stack before we yield require().
        eryx_cache_registry_set_loader_thread(L, ML, cacheKey.c_str());
        lua_pop(L, 1);

        // Indicate to the caller that the module yielded. We return -1 as a
        // sentinel; the caller (`eryx_lua_require`) will add the current
        // require() coroutine to the waiters list and yield.
        return -1;
    } else {
        // Any runtime error. Leave it on the stack where it is
    }

    if (badReturnCount) {
        eryx_push_module_arity_exception(L, chunkName, returnedCount);

        // remove ML thread from L stack
        lua_remove(L, -2);

        lua_error(L);
    }

    if (!ok) {
        LuaException* parentException = NULL;
        void* p = lua_touserdata(ML, -1);
        if (p != NULL) {
            // lua_getmetatable isn't safe to use here, so we're going to use a custom tag
            if (((LuaException*)p)->tag == LUA_EXCEPTION_TAG) {
                parentException = (LuaException*)p;
            }
        }

        if (parentException) {
            eryx_exception_populate_tb(ML, parentException, 0);

            // Move exception from ML to L
            lua_xmove(ML, L, 1);

            // remove ML thread from L stack
            lua_remove(L, -2);

            lua_error(L);
        } else {
            // Create an exception, on the parent L stack (not ML!)
            LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
            new (exception) LuaException();
            luaL_getmetatable(L, EXCEPTION_METATABLE);
            lua_setmetatable(L, -2);
            exception->type = ETYPE_RUNTIME;

            std::string extractedMessage;
            if (lua_isstring(ML, -1)) {
                exception->message =
                    _extract_error_message(std::string(lua_tostring(ML, -1))).message;
            }

            // Remove the old error string
            lua_remove(ML, -1);

            eryx_exception_populate_tb(ML, exception, 0);

            // remove ML thread from L stack
            lua_remove(L, -2);

            lua_error(L);
        }
    } else {
        // Move result over to main L
        lua_xmove(ML, L, 1);

        // remove ML thread from L stack
        lua_remove(L, -2);

        return 1;
    }
}

ERYX_API int eryx_execute_module_script(lua_State* L, const std::string source,
                                        const std::string& chunkName, const std::string& cacheKey) {
    // Compile bytecode from source
    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    opts.debugLevel = 1;
    opts.typeInfoLevel = 1;
    eryx_apply_runtime_compile_options(L, opts);

    std::string bytecode = Luau::compile(source, opts);

    return eryx_execute_module_bytecode(L, bytecode, chunkName, cacheKey);
}

#ifdef ERYX_EMBED
static int eryx_require_native(lua_State* L, const char* szLibrary) {
    luaL_error(L,
               "DLL modules are not supported in this build (all modules are statically linked). "
               "Tried to load: %s",
               szLibrary);
    return 0;
}
#else
static int eryx_require_native(lua_State* L, const char* szLibrary) {
#ifdef _WIN32
    HMODULE hLib = LoadLibraryA(szLibrary);
    if (hLib == NULL) {
        luaL_error(L, "Unable to load %s (%d)\n", szLibrary, GetLastError());
        return 0;
    }

    p_luau_module_info pModInfo = (p_luau_module_info)GetProcAddress(hLib, "luau_module_info");
    if (!pModInfo) {
        luaL_error(L, "Module missing information\n");
        return 0;
    }

    const LuauModuleInfo* pInfo = pModInfo();
    if (pInfo == NULL) {
        luaL_error(L, "Module reported nil information\n");
        return 0;
    }
    if (pInfo->abiVersion != ABI_VERSION) {
        luaL_error(L, "Module ABI mismatch. Expected %d, got %d\n", ABI_VERSION, pInfo->abiVersion);
        return 0;
    }
    if (strcmp(pInfo->luauVersion, LUAU_GIT_HASH) != 0) {
        luaL_error(L, "Module Luau version mismatch. Expected %s, got %s\n", LUAU_GIT_HASH,
                   pInfo->luauVersion);
        return 0;
    }

    p_luau_module_entry pModEntry = (p_luau_module_entry)GetProcAddress(hLib, pInfo->entry);
    if (pModEntry == NULL) {
        luaL_error(L, "Module missing entrypoint\n");
        return 0;
    }

    // Run on a separate thread for stack isolation so a buggy module
    // can't corrupt the caller's stack.
    lua_checkstack(L, 1);
    lua_State* ML = lua_newthread(L);
    int nresults = pModEntry(ML);
    if (nresults > 0) {
        lua_xmove(ML, L, nresults);
    }
    lua_remove(L, -nresults - 1);  // remove ML thread
    return nresults;
#else
    void* hLib = dlopen(szLibrary, RTLD_NOW | RTLD_LOCAL);
    if (!hLib) {
        luaL_error(L, "Unable to load %s (%s)\n", szLibrary, dlerror());
        return 0;
    }

    p_luau_module_info pModInfo = (p_luau_module_info)dlsym(hLib, "luau_module_info");
    if (!pModInfo) {
        luaL_error(L, "Module missing information\n");
        return 0;
    }

    const LuauModuleInfo* pInfo = pModInfo();
    if (pInfo == NULL) {
        luaL_error(L, "Module reported nil information\n");
        return 0;
    }
    if (pInfo->abiVersion != ABI_VERSION) {
        luaL_error(L, "Module ABI mismatch. Expected %d, got %d\n", ABI_VERSION, pInfo->abiVersion);
        return 0;
    }
    if (strcmp(pInfo->luauVersion, LUAU_GIT_HASH) != 0) {
        luaL_error(L, "Module Luau version mismatch. Expected %s, got %s\n", LUAU_GIT_HASH,
                   pInfo->luauVersion);
        return 0;
    }

    p_luau_module_entry pModEntry = (p_luau_module_entry)dlsym(hLib, pInfo->entry);
    if (pModEntry == NULL) {
        luaL_error(L, "Module missing entrypoint\n");
        return 0;
    }

    lua_checkstack(L, 1);
    lua_State* ML = lua_newthread(L);
    int nresults = pModEntry(ML);
    if (nresults > 0) {
        lua_xmove(ML, L, nresults);
    }
    lua_remove(L, -nresults - 1);  // remove ML thread
    return nresults;
#endif
}
#endif

static int eryx_lua_require_resolved(lua_State* L) {
    int moduleType = (int)luaL_checkinteger(L, 1);
    std::string modulePath = luaL_checkstring(L, 2);
    std::string cacheKey = luaL_checkstring(L, 3);

    int nret = 0;
    std::string chunkName;

    switch (moduleType) {
        case LocatedModule::TYPE_FILE: {
            // Native modules silently shadow a lua script.
            // Windows: [module].dll, Linux: lib[module].so, macOS: lib[module].dylib
            fs::path basePath = fs::path(modulePath);
            fs::path nativePath;
#if defined(_WIN32)
            nativePath = basePath.parent_path() / (basePath.stem().string() + ".dll");
#elif defined(__APPLE__)
            nativePath = basePath.parent_path() / ("lib" + basePath.stem().string() + ".dylib");
#else
            nativePath = basePath.parent_path() / ("lib" + basePath.stem().string() + ".so");
#endif

            if (fs::exists(nativePath)) {
                chunkName = "@" + nativePath.string();
                nret = eryx_require_native(L, nativePath.string().c_str());
            } else {
                std::ifstream f(modulePath, std::ios::binary);
                if (!f) {
                    luaL_error(L, "Failed to read %s", modulePath.c_str());
                }
                std::string source((std::istreambuf_iterator<char>(f)),
                                   std::istreambuf_iterator<char>());

                chunkName = "@" + modulePath;
                nret = eryx_execute_module_script(L, source, chunkName, cacheKey);
            }
            break;
        }

        case LocatedModule::TYPE_VFS: {
            auto data = vfs_read_file(modulePath);
            if (data.empty()) {
                luaL_error(L, "VFS file %s vanished during require", modulePath.c_str());
            }
            std::string source(reinterpret_cast<const char*>(data.data()), data.size());
            chunkName = CHUNK_PREFIX_VFS + modulePath;
            nret = eryx_execute_module_script(L, source, chunkName, cacheKey);
            break;
        }

        case LocatedModule::TYPE_EMBEDDED_SCRIPT: {
            chunkName = CHUNK_PREFIX_ERYX + modulePath;
            auto* scripts = eryx_get_embedded_script_modules();
            bool found = false;
            if (scripts) {
                for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                    if (strcmp(m->modulePath, modulePath.c_str()) == 0) {
                        nret = eryx_execute_module_script(L, m->source, chunkName, cacheKey);
                        found = true;
                        break;
                    }
                }
            }
            if (!found)
                luaL_error(L, "Embedded script %s vanished during require", modulePath.c_str());
            break;
        }
        case LocatedModule::TYPE_EMBEDDED_NATIVE: {
            chunkName = CHUNK_PREFIX_ERYX + modulePath;
            auto* natives = eryx_get_embedded_native_modules();
            bool found = false;
            if (natives) {
                for (auto m = natives; m->modulePath; ++m) {
                    if (strcmp(m->modulePath, modulePath.c_str()) == 0) {
                        if (!m->entry) {
                            luaL_error(L, "Improperly defined native module %s (no entry)",
                                       modulePath.c_str());
                        }

                        lua_checkstack(L, 1);
                        lua_State* ML = lua_newthread(L);
                        int nresults = m->entry(ML);
                        if (nresults > 0) {
                            lua_xmove(ML, L, nresults);
                        }
                        lua_remove(L, -nresults - 1);  // remove ML thread
                        nret = nresults;
                        found = true;
                        break;
                    }
                }
            }
            if (!found)
                luaL_error(L, "Embedded native module %s vanished during require",
                           modulePath.c_str());
            break;
        }

        default: {
            luaL_error(L, "Unsupported module type: %d", moduleType);
        }
    }

    if (nret == -1) {
        lua_pushinteger(L, CACHE_STATUS_YIELDED);
        return 1;
    }

    if (nret != 1) {
        luaL_error(L, "%s didn't return exactly one value (%d)", chunkName.c_str(), nret);
    }

    lua_pushinteger(L, CACHE_STATUS_LOADED);
    lua_insert(L, -2);
    return 2;
}

ERYX_API int eryx_lua_require(lua_State* L) {
    // auto __start = lua_clock();
    std::string path_str = luaL_checkstring(L, 1);

    auto resolved = eryx_resolve_module(L, path_str);
    if (!resolved) {
        luaL_error(L, "Unable to locate %s", path_str.c_str());
    }

    // printf("Resolution %s took %f\n", path_str.c_str(), lua_clock() - __start);
    // __start = lua_clock();

    // Build a cache key that includes the type so different module types
    // with the same path don't collide (e.g. "@file:path" vs "@@eryx:path").
    std::string cacheKey = std::to_string(resolved->type) + ":" + resolved->path;

    // First, check if we have a fully loaded version of this module ready
    if (eryx_cache_registry_check(L, cacheKey.c_str())) {
        // printf("Using cache for %s took %f\n", cacheKey.c_str(), lua_clock() - __start);
        return 1;
    }
    // If it's still loading (not yielded), that's cyclic
    if (eryx_cache_registry_get_status(L, cacheKey.c_str()) == CACHE_STATUS_LOADING) {
        luaL_error(L, "cyclic dependency detected");
    }
    // Finally, mark it as loading
    eryx_cache_registry_set_status(L, cacheKey.c_str(), CACHE_STATUS_LOADING);
    int topBeforeLoad = lua_gettop(L);
    lua_pushcfunction(L, eryx_lua_require_resolved, nullptr);
    lua_pushinteger(L, resolved->type);
    lua_pushstring(L, resolved->path.c_str());
    lua_pushstring(L, cacheKey.c_str());

    if (eryx_pcall(L, 3, LUA_MULTRET, 0) != LUA_OK) {
        eryx_require_reset_load_state(L, cacheKey.c_str());
        lua_error(L);
        return 0;
    }

    int resultCount = lua_gettop(L) - topBeforeLoad;
    if (resultCount == 1 && lua_isnumber(L, -1) && lua_tointeger(L, -1) == CACHE_STATUS_YIELDED) {
        lua_pop(L, 1);
        eryx_cache_registry_add_waiter(L, cacheKey.c_str());
        return lua_yield(L, 0);
    }

    if (resultCount != 2 || !lua_isnumber(L, -2) || lua_tointeger(L, -2) != CACHE_STATUS_LOADED) {
        eryx_require_reset_load_state(L, cacheKey.c_str());
        luaL_error(L, "require loader returned an unexpected result");
    }

    lua_remove(L, -2);  // remove status marker, leave module result on top
    eryx_cache_registry_cache(L, cacheKey.c_str());

    return 1;
}
