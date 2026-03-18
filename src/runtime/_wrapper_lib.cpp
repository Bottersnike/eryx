#include "_wrapper_lib.hpp"

#include "lconfig.hpp"
#include "lexception.hpp"
#include "../vfs.hpp"
#include "embedded_modules.h"

// Analysis headers (available because LuauShared links Luau.Analysis)
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "Luau/AstQuery.h"
#include "Luau/Autocomplete.h"
#include "Luau/AutocompleteTypes.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Common.h"
#include "Luau/Config.h"
#include "Luau/ExperimentalFlags.h"
#include "Luau/Frontend.h"
#include "Luau/ModuleResolver.h"
#include "Luau/PrettyPrinter.h"
#include "Luau/ToString.h"
#include "Luau/TypeAttach.h"
#include "lprint.hpp"
#include "lrequire.hpp"
#include "lresolve.hpp"


// CLI args offset – default 1 (skip just the exe name)
static int g_cliargs_offset = 1;
static int g_cliargs_argc = 0;
static const char** g_cliargs_argv = nullptr;
ERYX_API void eryx_set_cliargs_offset(int offset) { g_cliargs_offset = offset; }
ERYX_API int eryx_get_cliargs_offset() { return g_cliargs_offset; }
ERYX_API void eryx_set_cliargs(int argc, const char** argv) { g_cliargs_argc = argc; g_cliargs_argv = argv; }
ERYX_API int eryx_get_cliargs_argc() { return g_cliargs_argc; }
ERYX_API const char** eryx_get_cliargs_argv() { return g_cliargs_argv; }

ERYX_API bool lua_codegen_isSupported() { return Luau::CodeGen::isSupported(); }
ERYX_API void lua_codegen_create(lua_State* L) { Luau::CodeGen::create(L); }
ERYX_API Luau::CodeGen::CodeGenCompilationResult lua_codegen_compile(
    lua_State* L, int idx, unsigned int flags, Luau::CodeGen::CompilationStats* stats) {
    Luau::CodeGen::CompilationResult res = Luau::CodeGen::compile(L, idx, flags, stats);

    return res.result;
}

ERYX_API void eryx_register_interrupt_callback(EryxRuntime* rt, EryxInterruptCallback cb,
                                               void* ctx) {
    if (!rt || !cb) return;
    rt->interruptCallbacks.emplace_back(cb, ctx);
}
ERYX_API void eryx_unregister_interrupt_callback(EryxRuntime* rt, EryxInterruptCallback cb,
                                                 void* ctx) {
    if (!rt) return;
    for (auto it = rt->interruptCallbacks.begin(); it != rt->interruptCallbacks.end(); ++it) {
        if (it->first == cb && it->second == ctx) {
            rt->interruptCallbacks.erase(it);
            break;
        }
    }
}

ERYX_API EryxRuntime* eryx_setup_runtime(uv_loop_t* loop, lua_State* GL) {
    EryxRuntime* rt = new EryxRuntime;
    rt->GL = GL;
    rt->loop = loop;
    rt->sigint = nullptr;
    return rt;
}
ERYX_API void eryx_push_thread(EryxRuntime* rt, int ref, int nargs, bool inError) {
    rt->threads.push_back({ ref, nargs, inError });
}
ERYX_API EryxThreadInfo eryx_pop_thread(EryxRuntime* rt) {
    EryxThreadInfo thread = rt->threads.front();
    rt->threads.pop_front();
    return thread;
}
ERYX_API bool eryx_cancel_thread(EryxRuntime* rt, lua_State* GL, lua_State* target) {
    // Check pending timers
    for (auto it = rt->pendingTimers.begin(); it != rt->pendingTimers.end(); ++it) {
        lua_getref(GL, it->first);
        lua_State* th = lua_tothread(GL, -1);
        lua_pop(GL, 1);
        if (th == target) {
            uv_timer_stop(it->second);
            uv_close((uv_handle_t*)it->second, [](uv_handle_t* h) {
                delete (char*)h->data;  // free the timer payload
                delete (uv_timer_t*)h;
            });
            lua_unref(GL, it->first);
            rt->pendingTimers.erase(it);
            return true;
        }
    }
    // Check deferred queue
    for (auto it = rt->threads.begin(); it != rt->threads.end(); ++it) {
        lua_getref(GL, it->threadRef);
        lua_State* th = lua_tothread(GL, -1);
        lua_pop(GL, 1);
        if (th == target) {
            lua_unref(GL, it->threadRef);
            rt->threads.erase(it);
            return true;
        }
    }
    return false;
}

ERYX_API void eryx_interrupt_runtime(EryxRuntime* rt) {
    if (!rt) return;

    // Stop and close any pending timers, and queue their threads with an error
    for (auto it = rt->pendingTimers.begin(); it != rt->pendingTimers.end();) {
        int ref = it->first;
        uv_timer_t* timer = it->second;
        it = rt->pendingTimers.erase(it);

        // Push an error string onto the target thread so lua_resumeerror can use it
        lua_getref(rt->GL, ref);
        lua_State* TL = lua_tothread(rt->GL, -1);
        lua_pop(rt->GL, 1);
        if (TL) {
            eryx_exception_push_keyboard_interrupt(TL);
        }

        // Queue the thread with inError = true and 1 arg (the error)
        eryx_push_thread(rt, ref, 1, true);

        if (timer && !uv_is_closing((uv_handle_t*)timer)) {
            uv_timer_stop(timer);
            uv_close((uv_handle_t*)timer, [](uv_handle_t* h) { delete (uv_timer_t*)h; });
        }
    }

    // Interrupt pending socket operations (poll-based)
    // Call any registered interrupt callbacks (module-specific cleanup)
    auto callbacks = rt->interruptCallbacks;  // copy to avoid mutation during iteration
    for (auto& cb : callbacks) {
        if (cb.first) cb.first(rt, cb.second);
    }

    // Mark already-deferred threads as in-error and push an error onto their stacks
    for (auto& ti : rt->threads) {
        lua_getref(rt->GL, ti.threadRef);
        lua_State* TL = lua_tothread(rt->GL, -1);
        lua_pop(rt->GL, 1);
        if (TL) {
            eryx_exception_push_keyboard_interrupt(TL);
            ti.nargs = 1;
            ti.inError = true;
        }
    }

    // Stop the loop so uv_loop_alive may return false
    if (rt->loop) uv_stop(rt->loop);

    // Close signal handle if we own one
    if (rt->sigint) {
        if (!uv_is_closing((uv_handle_t*)rt->sigint)) {
            uv_close((uv_handle_t*)rt->sigint, [](uv_handle_t* h) { delete (uv_signal_t*)h; });
        }
        rt->sigint = nullptr;
    }
}

static void analysis_push_position(lua_State* L, const Luau::Position& pos) {
    lua_createtable(L, 0, 2);
    lua_pushinteger(L, pos.line + 1);
    lua_setfield(L, -2, "line");
    lua_pushinteger(L, pos.column + 1);
    lua_setfield(L, -2, "column");
}
static void analysis_push_location(lua_State* L, const Luau::Location& loc) {
    lua_createtable(L, 0, 2);
    analysis_push_position(L, loc.begin);
    lua_setfield(L, -2, "start");
    analysis_push_position(L, loc.end);
    lua_setfield(L, -2, "end");
}

namespace fs = std::filesystem;

static int load_definition(Luau::Frontend& frontend, std::string_view source,
                           const std::string& packageName) {
    auto r1 = frontend.loadDefinitionFile(frontend.globals, frontend.globals.globalScope, source,
                                          packageName, false, false);
    auto r2 = frontend.loadDefinitionFile(frontend.globalsForAutocomplete,
                                          frontend.globalsForAutocomplete.globalScope, source,
                                          packageName, false, true);
    return r1.success && r2.success;
}

// -- Parse the common "mode" option string ----------------------------------

static Luau::Mode parse_mode_opt(lua_State* L, int idx, Luau::Mode fallback) {
    if (!lua_istable(L, idx)) return fallback;
    lua_getfield(L, idx, "mode");
    if (lua_isstring(L, -1)) {
        const char* s = lua_tostring(L, -1);
        if (strcmp(s, "strict") == 0)
            fallback = Luau::Mode::Strict;
        else if (strcmp(s, "nonstrict") == 0)
            fallback = Luau::Mode::Nonstrict;
        else if (strcmp(s, "nocheck") == 0)
            fallback = Luau::Mode::NoCheck;
    }
    lua_pop(L, 1);
    return fallback;
}

// -- Load definitions from options table ------------------------------------
//
// Reads options.definitions (a sequential table of strings or a table of
// {source=string, name?=string}) and loads each into the AnalysisContext.
// Must be called after AnalysisContext construction, before check().

static void load_definitions_opt(lua_State* L, int optIdx, Luau::Frontend& frontend) {
    if (!lua_istable(L, optIdx)) return;
    lua_getfield(L, optIdx, "definitions");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    int defTable = lua_gettop(L);
    int n = (int)lua_objlen(L, defTable);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, defTable, i);
        if (lua_isstring(L, -1)) {
            // Simple string: definition source, auto-name "@def<i>"
            size_t len = 0;
            const char* s = lua_tolstring(L, -1, &len);

            load_definition(frontend, std::string_view(s, len), "@def" + std::to_string(i));
        } else if (lua_istable(L, -1)) {
            // Table with {source, name?}
            lua_getfield(L, -1, "source");
            size_t len = 0;
            const char* s = lua_isstring(L, -1) ? lua_tolstring(L, -1, &len) : nullptr;
            lua_pop(L, 1);

            lua_getfield(L, -1, "name");
            const char* pkg = lua_isstring(L, -1) ? lua_tostring(L, -1) : nullptr;
            lua_pop(L, 1);

            if (s) {
                std::string pkgName = pkg ? std::string(pkg) : ("@def" + std::to_string(i));
                load_definition(frontend, std::string_view(s, len), pkgName);
            }
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);  // pop definitions table
}

// -- Read optional filePath from options table -------------------------------

static void read_file_path_opt(lua_State* L, int optIdx, const char*& filePath,
                               size_t& filePathLen) {
    filePath = nullptr;
    filePathLen = 0;
    if (!lua_istable(L, optIdx)) return;
    lua_getfield(L, optIdx, "filePath");
    if (lua_isstring(L, -1)) filePath = lua_tolstring(L, -1, &filePathLen);
    lua_pop(L, 1);
}

// -- Push a TypeError onto the Lua stack ------------------------------------

static void analysis_push_type_error(lua_State* L, const Luau::Frontend& fe,
                                     const Luau::TypeError& err) {
    lua_createtable(L, 0, 3);

    std::string msg = Luau::toString(err, Luau::TypeErrorToStringOptions{ fe.fileResolver });
    lua_pushlstring(L, msg.data(), msg.size());
    lua_setfield(L, -2, "message");

    analysis_push_location(L, err.location);
    lua_setfield(L, -2, "location");

    const char* category = "TypeError";
    if (Luau::get_if<Luau::SyntaxError>(&err.data)) category = "SyntaxError";
    lua_pushstring(L, category);
    lua_setfield(L, -2, "category");
}

struct EryxFileResolver : Luau::FileResolver {
    std::string mainSource;
    Luau::ModuleName mainModule;  // absolute path or "=main" fallback

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override {
        if (name == mainModule) return Luau::SourceCode{ mainSource, Luau::SourceCode::Module };

        // VFS modules (prefixed with @@vfs/)
        if (name.starts_with(CHUNK_PREFIX_VFS)) {
            std::string vfsPath = name.substr(CHUNK_PREFIX_VFS_LEN);
            auto data = vfs_read_file(vfsPath);
            if (data.empty()) return std::nullopt;
            std::string src(reinterpret_cast<const char*>(data.data()), data.size());
            return Luau::SourceCode{ std::move(src), Luau::SourceCode::Module };
        }

        // Embedded script modules (prefixed with @@eryx/)
        if (name.starts_with(CHUNK_PREFIX_ERYX)) {
            std::string key = name.substr(CHUNK_PREFIX_ERYX_LEN);
            auto* scripts = eryx_get_embedded_script_modules();
            if (scripts) {
                for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                    if (key == m->modulePath) {
                        return Luau::SourceCode{ std::string(m->source), Luau::SourceCode::Module };
                    }
                }
            }
            return std::nullopt;
        }

        // Filesystem modules
        try {
            if (!fs::exists(name)) return std::nullopt;
            std::ifstream f(name, std::ios::binary);
            if (!f) return std::nullopt;
            std::string src((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            return Luau::SourceCode{ std::move(src), Luau::SourceCode::Module };
        } catch (...) {
            return std::nullopt;
        }
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo* context,
                                                  Luau::AstExpr* node,
                                                  const Luau::TypeCheckLimits&) override {
        auto expr = node->as<Luau::AstExprConstantString>();
        if (!expr) {
            return std::nullopt;
        }
        std::string requirePath(expr->value.data, expr->value.size);

        lua_State* CL = eryx_initialise_environment(nullptr);
        auto resolved = eryx_resolve_module(CL, requirePath);
        lua_close(CL);

        if (!resolved) return std::nullopt;

        switch (resolved->type) {
            case LocatedModule::TYPE_FILE:
                return Luau::ModuleInfo{ resolved->path };
            case LocatedModule::TYPE_VFS:
                return Luau::ModuleInfo{ std::string(CHUNK_PREFIX_VFS) + resolved->path };
            case LocatedModule::TYPE_EMBEDDED_SCRIPT:
                return Luau::ModuleInfo{ std::string(CHUNK_PREFIX_ERYX) + resolved->path };
            case LocatedModule::TYPE_EMBEDDED_NATIVE:
                return std::nullopt;  // native modules have no analyzable source
        }
        return std::nullopt;
    }
};

struct EryxConfigResolver : Luau::ConfigResolver {
    Luau::Mode defaultMode;
    lua_State* L;
    mutable std::map<std::string, Luau::Config> cache;

    const Luau::Config& getConfig(const Luau::ModuleName& name,
                                  const Luau::TypeCheckLimits& limits) const override {
        if (name[0] == '=') {
            Luau::Config cfg;
            cfg.mode = defaultMode;
            auto [inserted, ok] = cache.emplace(name, std::move(cfg));
            return inserted->second;
        }

        fs::path dir;
        std::string vfsDir;
        try {
            // VFS modules have names like @@vfs/subdir/file.luau —
            // strip the prefix and use the VFS directory directly.
            if (name.starts_with(CHUNK_PREFIX_VFS)) {
                std::string vfsPath = name.substr(CHUNK_PREFIX_VFS_LEN);
                fs::path vfsParent = fs::path(vfsPath).parent_path();
                vfsDir = vfsParent.generic_string();
            } else {
                dir = fs::path(name).parent_path();
            }
        } catch (...) {
            Luau::Config cfg;
            cfg.mode = defaultMode;
            auto [inserted, ok] = cache.emplace(name, std::move(cfg));
            return inserted->second;
        }

        std::string key = vfsDir.empty() ? dir.string() : ("@@vfs/" + vfsDir);
        if (cache.contains(key)) {
            return cache.at(key);
        }

        lua_State* CL = eryx_initialise_environment(nullptr);

        auto info = eryx_locate_config(CL, dir, std::nullopt, vfsDir);

        if (info->found) {
            Luau::Config cfg;
            cfg.mode = defaultMode;
            cfg.enabledLint.warningMask = info->enabledLints;
            cfg.fatalLint.warningMask = info->fatalLints;
            cfg.lintErrors = info->lintErrors;
            cfg.typeErrors = info->typeErrors;
            cfg.globals = info->globals;

            for (const auto& [aliasKey, aliasValue] : info->aliases) {
                cfg.setAlias(aliasKey, aliasValue.path, aliasValue.configPath);
            }

            lua_close(CL);

            auto [inserted, ok] = cache.emplace(key, std::move(cfg));
            return inserted->second;
        }

        lua_close(CL);

        Luau::Config cfg;
        cfg.mode = defaultMode;
        auto [inserted, ok] = cache.emplace(key, std::move(cfg));
        return inserted->second;
    }
};
// static Luau::Frontend typecheck(const char* source, const char* fileName, bool annotate) {
//     return frontend;
// }

// ---------------------------------------------------------------------------
// eryx_luau_check(L)   –   lua_CFunction
//
// Args:  (source: string [, options: {mode?, annotate?}])
// Returns: { errors: {...}, annotated?: string }
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_check(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    Luau::Mode mode = Luau::Mode::Nonstrict;
    bool annotate = false;

    const char* filePath = nullptr;
    size_t filePathLen = 0;

    if (lua_istable(L, 2)) {
        mode = parse_mode_opt(L, 2, mode);
        lua_getfield(L, 2, "annotate");
        if (lua_isboolean(L, -1)) annotate = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
        read_file_path_opt(L, 2, filePath, filePathLen);
    }

    const char* mainModule = filePath ? filePath : "=main";

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = annotate;
    frontendOptions.runLintChecks = true;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    EryxConfigResolver configResolver;
    configResolver.L = L;
    configResolver.defaultMode = mode;

    // TODO: Why do we need that cast?
    Luau::Frontend frontend((Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);

    // Load optional definition files
    load_definitions_opt(L, 2, frontend);

    // Run a type check
    auto cr = frontend.check(mainModule);

    lua_createtable(L, 0, 3);

    // errors
    lua_createtable(L, (int)cr.errors.size(), 0);
    for (size_t i = 0; i < cr.errors.size(); i++) {
        analysis_push_type_error(L, frontend, cr.errors[i]);
        lua_rawseti(L, -2, (int)(i + 1));
    }
    lua_setfield(L, -2, "errors");

    // annotated source
    if (annotate) {
        Luau::SourceModule* sm = frontend.getSourceModule(mainModule);
        Luau::ModulePtr m = frontend.moduleResolver.getModule(mainModule);
        if (sm && m) {
            Luau::attachTypeData(*sm, *m);
            std::string annotated = Luau::prettyPrintWithTypes(*sm->root);
            lua_pushlstring(L, annotated.data(), annotated.size());
        } else {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "annotated");
    }

    return 1;
}

// ---------------------------------------------------------------------------
// eryx_luau_typeAt(L)   –   lua_CFunction
//
// Args:  (source: string, line: number, column: number [, options: {mode?}])
// Returns: string?
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_typeAt(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);
    int line = (int)luaL_checkinteger(L, 2);
    int col = (int)luaL_checkinteger(L, 3);

    Luau::Mode mode = parse_mode_opt(L, 4, Luau::Mode::Strict);
    const char* filePath = nullptr;
    size_t filePathLen = 0;
    read_file_path_opt(L, 4, filePath, filePathLen);

    Luau::Position pos{ (unsigned)(line - 1), (unsigned)(col - 1) };

    const char* mainModule = filePath ? filePath : "=main";

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = true;
    frontendOptions.runLintChecks = true;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    EryxConfigResolver configResolver;
    configResolver.defaultMode = mode;

    // TODO: Why do we need that cast?
    Luau::Frontend frontend((Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);

    load_definitions_opt(L, 4, frontend);
    frontend.check(mainModule);

    Luau::SourceModule* sm = frontend.getSourceModule(mainModule);
    Luau::ModulePtr m = frontend.moduleResolver.getModule(mainModule);

    if (!sm || !m) {
        lua_pushnil(L);
        return 1;
    }

    // Try expression type
    if (auto ty = Luau::findTypeAtPosition(*m, *sm, pos)) {
        Luau::ToStringOptions o;
        o.exhaustive = false;
        o.useLineBreaks = false;
        o.functionTypeArguments = true;
        o.ignoreSyntheticName = true;
        std::string s = Luau::toString(*ty, o);
        lua_pushlstring(L, s.data(), s.size());
        return 1;
    }

    // Try binding type
    if (auto binding = Luau::findBindingAtPosition(*m, *sm, pos)) {
        Luau::ToStringOptions o;
        o.exhaustive = false;
        o.functionTypeArguments = true;
        o.ignoreSyntheticName = true;
        std::string s = Luau::toString(binding->typeId, o);
        lua_pushlstring(L, s.data(), s.size());
        return 1;
    }

    // Fallback: scan scope bindings for a definition whose location
    // contains the queried position (handles `local x = 42` where
    // the cursor is on the LHS name, which is an AstLocal, not an
    // AstExpr, so the find* helpers above miss it).
    for (const auto& [scopeLoc, scope] : m->scopes) {
        for (auto it = scope->bindings.begin(); it != scope->bindings.end(); ++it) {
            if (it->second.location.containsClosed(pos)) {
                Luau::ToStringOptions o;
                o.exhaustive = false;
                o.functionTypeArguments = true;
                o.ignoreSyntheticName = true;
                std::string s = Luau::toString(it->second.typeId, o);
                lua_pushlstring(L, s.data(), s.size());
                return 1;
            }
        }
    }

    lua_pushnil(L);
    return 1;
}

// ---------------------------------------------------------------------------
// eryx_luau_autocomplete(L)   –   lua_CFunction
//
// Args:  (source: string, line: number, column: number [, options: {mode?}])
// Returns: { context: string, entries: { [name]: {...} } }
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_autocomplete(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);
    int line = (int)luaL_checkinteger(L, 2);
    int col = (int)luaL_checkinteger(L, 3);

    Luau::Mode mode = parse_mode_opt(L, 4, Luau::Mode::Strict);
    const char* filePath = nullptr;
    size_t filePathLen = 0;
    read_file_path_opt(L, 4, filePath, filePathLen);

    Luau::Position pos{ (unsigned)(line - 1), (unsigned)(col - 1) };

    const char* mainModule = filePath ? filePath : "=main";

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = true;
    frontendOptions.runLintChecks = true;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    EryxConfigResolver configResolver;
    configResolver.L = L;
    configResolver.defaultMode = mode;

    // TODO: Why do we need that cast?
    Luau::Frontend frontend((Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);
    Luau::freeze(frontend.globalsForAutocomplete.globalTypes);

    // Run autocomplete type check
    load_definitions_opt(L, 4, frontend);
    Luau::FrontendOptions acOpts = frontendOptions;
    acOpts.forAutocomplete = true;
    frontend.check(mainModule, acOpts);

    Luau::AutocompleteResult acResult = Luau::autocomplete(frontend, mainModule, pos, nullptr);

    lua_createtable(L, 0, 2);

    // context
    const char* ctxStr = "Unknown";
    switch (acResult.context) {
        case Luau::AutocompleteContext::Expression:
            ctxStr = "Expression";
            break;
        case Luau::AutocompleteContext::Statement:
            ctxStr = "Statement";
            break;
        case Luau::AutocompleteContext::Property:
            ctxStr = "Property";
            break;
        case Luau::AutocompleteContext::Type:
            ctxStr = "Type";
            break;
        case Luau::AutocompleteContext::Keyword:
            ctxStr = "Keyword";
            break;
        case Luau::AutocompleteContext::String:
            ctxStr = "String";
            break;
        default:
            break;
    }
    lua_pushstring(L, ctxStr);
    lua_setfield(L, -2, "context");

    // entries
    lua_createtable(L, 0, (int)acResult.entryMap.size());
    for (const auto& [name, entry] : acResult.entryMap) {
        lua_createtable(L, 0, 4);

        const char* kindStr = "Unknown";
        switch ((int)entry.kind) {
            case (int)Luau::AutocompleteEntryKind::Property:
                kindStr = "Property";
                break;
            case (int)Luau::AutocompleteEntryKind::Binding:
                kindStr = "Binding";
                break;
            case (int)Luau::AutocompleteEntryKind::Keyword:
                kindStr = "Keyword";
                break;
            case (int)Luau::AutocompleteEntryKind::String:
                kindStr = "String";
                break;
            case (int)Luau::AutocompleteEntryKind::Type:
                kindStr = "Type";
                break;
            case (int)Luau::AutocompleteEntryKind::Module:
                kindStr = "Module";
                break;
            case (int)Luau::AutocompleteEntryKind::GeneratedFunction:
                kindStr = "GeneratedFunction";
                break;
            case (int)Luau::AutocompleteEntryKind::RequirePath:
                kindStr = "RequirePath";
                break;
            default:
                break;
        }
        lua_pushstring(L, kindStr);
        lua_setfield(L, -2, "kind");

        if (entry.type) {
            Luau::ToStringOptions o;
            o.exhaustive = false;
            o.functionTypeArguments = true;
            std::string s = Luau::toString(*entry.type, o);
            lua_pushlstring(L, s.data(), s.size());
            lua_setfield(L, -2, "type");
        }

        if (entry.deprecated) {
            lua_pushboolean(L, true);
            lua_setfield(L, -2, "deprecated");
        }

        if (entry.typeCorrect != Luau::TypeCorrectKind::None) {
            const char* tc = entry.typeCorrect == Luau::TypeCorrectKind::Correct
                                 ? "Correct"
                                 : "CorrectFunctionResult";
            lua_pushstring(L, tc);
            lua_setfield(L, -2, "typeCorrect");
        }

        if (entry.insertText) {
            lua_pushlstring(L, entry.insertText->data(), entry.insertText->size());
            lua_setfield(L, -2, "insertText");
        }

        if (entry.parens != Luau::ParenthesesRecommendation::None) {
            const char* p = entry.parens == Luau::ParenthesesRecommendation::CursorAfter
                                ? "CursorAfter"
                                : "CursorInside";
            lua_pushstring(L, p);
            lua_setfield(L, -2, "parens");
        }

        lua_setfield(L, -2, name.c_str());
    }
    lua_setfield(L, -2, "entries");

    return 1;
}

static void enableAllLuauFlags() {
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next) {
        if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
            flag->value = true;
    }
}

#ifdef ERYX_EMBED
int luaG_isnative(lua_State* L, int level);
#else
LUA_API int luaG_isnative(lua_State* L, int level);
#endif
ERYX_API lua_State* eryx_initialise_environment(const char* sourceFilename) {
    enableAllLuauFlags();

    // Create Lua state
    lua_State* L = luaL_newstate();
    if (!L) {
        std::cerr << "Failed to create Lua state" << std::endl;
        return NULL;
    }

    // Register the handler for an Exception being raised in a pcall
    lua_callbacks(L)->debugprotectederror = [](lua_State* L) {
        void* p = lua_touserdata(L, -1);
        if (!p || ((LuaException*)p)->tag != LUA_EXCEPTION_TAG) return;
        auto* ex = (LuaException*)p;
        if (!ex->traceback.empty()) return;  // already populated

        lua_Debug ar;
        for (int level = 1; lua_getinfo(L, level, "sln", &ar); level++) {
            if (strcmp(ar.source, "=[C]") == 0) continue;
            ex->traceback.push_back({ ar.source, ar.short_src, ar.currentline,
                                      ar.name ? ar.name : "<top level>",
                                      getSourceLine(ar.source, ar.currentline) });
        }
    };

    // Enable Native CodeGen
    if (lua_codegen_isSupported()) {
        lua_codegen_create(L);
    } else {
        std::cerr << "Warning: Luau Native CodeGen not supported on this platform." << std::endl;
    }

    // Open standard libraries
    luaL_openlibs(L);

    // Install Ctrl+C handler + Luau VM interrupt so scripts can be stopped
    // SetConsoleCtrlHandler(main_ctrl_handler, TRUE);
    // lua_callbacks(L)->interrupt = [](lua_State* L, int /*gc*/) {
    //     if (g_main_interrupted) {
    //         g_main_interrupted = false;
    //         eryx_exception_push_keyboard_interrupt(L);
    //         lua_error(L);
    //     }
    // };

    // Exceptions are going to overwrite pcall and xpcall
    exception_lib_register(L);

    // Register our custom print
    lua_pushcfunction(L, eryx_lua_print, "print");
    lua_setglobal(L, "print");

    lua_pushcclosurek(
        L,
        [](lua_State* L) -> int {
            lua_pushboolean(L, luaG_isnative(L, 1));
            return 1;
        },
        "is_native", 0, nullptr);
    lua_setglobal(L, "is_native");

    // Provide our custom require function
    lua_pushcfunction(L, eryx_lua_require, "require");
    lua_setglobal(L, "require");

    // Set __DIR__ and __FILE__
    if (sourceFilename) {
        std::filesystem::path scriptPath = std::filesystem::absolute(sourceFilename);
        std::string scriptDir = scriptPath.parent_path().string();
        std::string scriptFile = scriptPath.string();

        lua_pushstring(L, scriptDir.c_str());
        lua_setglobal(L, "__DIR__");

        lua_pushstring(L, scriptFile.c_str());
        lua_setglobal(L, "__FILE__");
    }

    // Sandbox all libraries
    // ! REQUIRED FOR NATIVE CODE GEN
    luaL_sandbox(L);

    return L;
}
