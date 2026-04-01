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

static void dump_stack(lua_State* L) {
    int top = lua_gettop(L);
    printf("----- STACK DUMP (top = %d) -----\n", top);

    for (int i = 1; i <= top; i++) {
        int t = lua_type(L, i);
        printf("%d: %s", i, lua_typename(L, t));

        switch (t) {
            case LUA_TSTRING:
                printf(" = \"%s\"", lua_tostring(L, i));
                break;

            case LUA_TNUMBER:
                printf(" = %g", lua_tonumber(L, i));
                break;

            case LUA_TBOOLEAN:
                printf(" = %s", lua_toboolean(L, i) ? "true" : "false");
                break;

            case LUA_TTABLE:
                printf(" = table@%p", lua_topointer(L, i));
                break;

            case LUA_TFUNCTION:
                printf(" = function@%p", lua_topointer(L, i));
                break;
        }

        printf("\n");
    }

    printf("-------------------------------\n");
}

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
static void eryx_cache_registry_set_loader_thread(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");
    }

    // The loader thread object should be just below the top (at -2)
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, cacheKey);
    lua_pop(L, 1);  // pop _LOADED_THREADS table
}

static void eryx_cache_registry_clear_loader_thread(lua_State* L, const char* cacheKey) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED_THREADS");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    lua_pushnil(L);
    lua_setfield(L, -2, cacheKey);
    lua_pop(L, 1);
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

    // waiters table is at top
    size_t len = lua_objlen(L, -1);
    for (size_t i = 1; i <= len; ++i) {
        lua_rawgeti(L, -1, (int)i);
        if (lua_isthread(L, -1)) {
            lua_State* th = lua_tothread(L, -1);
            // resume waiter with 0 args; ignore result here
            int r = lua_resume(th, L, 0);
            (void)r;
        }
        lua_pop(L, 1);
    }

    // clear the waiters list for this key
    lua_pushnil(L);
    lua_setfield(L, -3, cacheKey);

    lua_pop(L, 1);  // pop _LOADED_WAITERS table
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
    if (lua_codegen_isSupported()) {
        Luau::CodeGen::CompilationStats stats = {};
        Luau::CodeGen::CodeGenCompilationResult res =
            lua_codegen_compile(L, -1, Luau::CodeGen::CodeGen_ColdFunctions, &stats);
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

    // TODO: Make these all exceptions
    if (status == LUA_OK) {
        if (lua_gettop(ML) != 1) {
            lua_pushfstring(ML, "Module %s must return a single value. Returned %d\n",
                            chunkName.c_str(), lua_gettop(ML));
        } else {
            ok = true;
        }
    } else if (status == LUA_YIELD) {
        // Mark this module as yielded and record the loader thread so it can
        // be resumed later when the module finishes its async work.
        eryx_cache_registry_set_status(L, cacheKey.c_str(), CACHE_STATUS_YIELDED);

        // The thread object for ML was moved onto L earlier and should be
        // positioned just below the result on the stack; stash it in the
        // registry so other code can find and resume it.
        eryx_cache_registry_set_loader_thread(L, cacheKey.c_str());

        // Indicate to the caller that the module yielded. We return -1 as a
        // sentinel; the caller (`eryx_lua_require`) will add the current
        // require() coroutine to the waiters list and yield.
        return -1;
    } else {
        // Any runtime error. Leave it on the stack where it is
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

    int nret = 0;
    std::string chunkName;

    switch (resolved->type) {
        case LocatedModule::TYPE_FILE: {
            // Native modules silently shadow a lua script.
            // Windows: [module].dll, Linux: lib[module].so, macOS: lib[module].dylib
            fs::path basePath = fs::path(resolved->path);
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
                std::ifstream f(resolved->path, std::ios::binary);
                if (!f) {
                    luaL_error(L, "Failed to read %s", resolved->path.c_str());
                }
                std::string source((std::istreambuf_iterator<char>(f)),
                                   std::istreambuf_iterator<char>());

                chunkName = "@" + resolved->path;
                nret = eryx_execute_module_script(L, source, chunkName, cacheKey);
            }
            break;
        }

        case LocatedModule::TYPE_VFS: {
            auto data = vfs_read_file(resolved->path);
            if (data.empty()) {
                luaL_error(L, "VFS file %s vanished during require", resolved->path.c_str());
            }
            std::string source(reinterpret_cast<const char*>(data.data()), data.size());
            chunkName = CHUNK_PREFIX_VFS + resolved->path;
            nret = eryx_execute_module_script(L, source, chunkName, cacheKey);
            break;
        }

        case LocatedModule::TYPE_EMBEDDED_SCRIPT: {
            chunkName = CHUNK_PREFIX_ERYX + resolved->path;
            auto* scripts = eryx_get_embedded_script_modules();
            bool found = false;
            if (scripts) {
                for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                    if (strcmp(m->modulePath, resolved->path.c_str()) == 0) {
                        nret = eryx_execute_module_script(L, m->source, chunkName, cacheKey);
                        found = true;
                        break;
                    }
                }
            }
            if (!found)
                luaL_error(L, "Embedded script %s vanished during require", resolved->path.c_str());
            break;
        }
        case LocatedModule::TYPE_EMBEDDED_NATIVE: {
            chunkName = CHUNK_PREFIX_ERYX + resolved->path;
            auto* natives = eryx_get_embedded_native_modules();
            bool found = false;
            if (natives) {
                for (auto m = natives; m->modulePath; ++m) {
                    if (strcmp(m->modulePath, resolved->path.c_str()) == 0) {
                        if (!m->entry) {
                            luaL_error(L, "Improperly defined native module %s (no entry)",
                                       resolved->path.c_str());
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
                           resolved->path.c_str());
            break;
        }

        default: {
            luaL_error(L, "Unsupported module type: %d", resolved->type);
        }
    }

    if (nret != 1) {
        // If the module yielded during loading, the executor returned -1 as
        // a sentinel. In that case, register the current coroutine as a
        // waiter and yield; it will be resumed when the module finishes.
        if (nret == -1) {
            eryx_cache_registry_add_waiter(L, cacheKey.c_str());
            return lua_yield(L, 0);
        }

        luaL_error(L, "%s didn't return exactly one value (%d)", chunkName.c_str(), nret);
    }

    eryx_cache_registry_cache(L, cacheKey.c_str());
    eryx_cache_registry_set_status(L, cacheKey.c_str(), CACHE_STATUS_LOADED);

    return nret;
}
