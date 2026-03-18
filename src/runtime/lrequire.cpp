#include "lrequire.hpp"

#include <filesystem>
#ifndef _WIN32
#include <dlfcn.h>
#endif

#include "../vfs.hpp"
#include "Luau/CodeGen.h"
#include "_wrapper_lib.hpp"
#include "lexception.hpp"
#include "lrequire.hpp"
#include "lresolve.hpp"
#include "lua.h"

#include "embedded_modules.h"

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
                                          const std::string& chunkName) {
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
        lua_pushfstring(ML, "Module %s cannot yield\n", chunkName.c_str());
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
            lua_Debug ar;
            for (int level = 0; lua_getinfo(ML, level, "sln", &ar); level++) {
                if (strcmp(ar.source, "=[C]") == 0) {
                    // We're here because a require() failed, so no need to rub that in
                    if (level == 0 && strcmp(ar.name, "require") == 0) {
                        continue;
                    }

                    // Skip everything else too
                    continue;
                }
                // Otherwise, push this as a frame to the traceback
                LuaFrame frame = {
                    ar.source ? std::string(ar.source) : "",
                    ar.short_src ? std::string(ar.short_src) : "",
                    ar.currentline,
                    ar.name ? std::string(ar.name) : "<top level>",
                    getSourceLine(ar.source, ar.currentline),
                };
                parentException->traceback.push_back(frame);
            }

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

            // Start walking the frames to reconstruct the traceback
            lua_Debug ar;
            for (int level = 0; lua_getinfo(ML, level, "sln", &ar); level++) {
                // An =[C] at top level suggests we might have a unique type of error
                if (strcmp(ar.source, "=[C]") == 0) {
                    if (level == 0) {
                        if (strcmp(ar.name, "error") == 0) {
                            exception->type = ETYPE_THROWN;
                            continue;
                        }
                        if (strcmp(ar.name, "assert") == 0) {
                            exception->type = ETYPE_ASSERT;
                            continue;
                        }
                        if (strcmp(ar.name, "require") == 0) {
                            exception->type = ETYPE_REQUIRE;
                            continue;
                        }
                    }

                    // C function, but not an interesting one
                    continue;
                }

                // Otherwise, push this as a frame to the traceback
                LuaFrame frame = {
                    ar.source ? std::string(ar.source) : "",
                    ar.short_src ? std::string(ar.short_src) : "",
                    ar.currentline,
                    ar.name ? std::string(ar.name) : "<top level>",
                    getSourceLine(ar.source, ar.currentline),
                };
                exception->traceback.push_back(frame);
            }

            // remove ML thread from L stack
            lua_remove(L, -2);

            lua_error(L);
        }
    } else {
        // Move result over to main L
        lua_xmove(ML, L, 1);

        // remove ML thread from L stack
        lua_remove(L, -2);
    }

    return 1;
}

ERYX_API int eryx_execute_module_script(lua_State* L, const std::string source,
                                        const std::string& chunkName) {
    // Compile bytecode from source
    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    opts.debugLevel = 1;
    opts.typeInfoLevel = 1;

    std::string bytecode = Luau::compile(source, opts);

    return eryx_execute_module_bytecode(L, bytecode, chunkName);
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
    std::string path_str = luaL_checkstring(L, 1);

    auto resolved = eryx_resolve_module(L, path_str);
    if (!resolved) {
        luaL_error(L, "Unable to locate %s", path_str.c_str());
    }

    // Build a cache key that includes the type so different module types
    // with the same path don't collide (e.g. "@file:path" vs "@@eryx:path").
    std::string cacheKey = std::to_string(resolved->type) + ":" + resolved->path;

    // Check the _LOADED registry for a cached result
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }
    // Check for an existing value in the cache
    lua_getfield(L, -1, cacheKey.c_str());
    if (!lua_isnil(L, -1)) {
        lua_remove(L, -2);  // remove _LOADED table, cached value remains
        return 1;
    }
    lua_pop(L, 2);  // pop nil + _LOADED table

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
                nret = eryx_execute_module_script(L, source, chunkName);
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
            nret = eryx_execute_module_script(L, source, chunkName);
            break;
        }

        case LocatedModule::TYPE_EMBEDDED_SCRIPT: {
            chunkName = CHUNK_PREFIX_ERYX + resolved->path;
            auto* scripts = eryx_get_embedded_script_modules();
            bool found = false;
            if (scripts) {
                for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                    if (strcmp(m->modulePath, resolved->path.c_str()) == 0) {
                        nret = eryx_execute_module_script(L, m->source, chunkName);
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
        luaL_error(L, "%s didn't return exactly one value (%d)", chunkName.c_str(), nret);
    }

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }
    lua_pushvalue(L, -2);                   // copy the result
    lua_setfield(L, -2, cacheKey.c_str());  // _LOADED[type:path] = result
    lua_pop(L, 1);                          // pop _LOADED table

    return nret;
}
