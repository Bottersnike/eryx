#include "_wrapper_lib.hpp"

#include "../LuaLocation.hpp"
#include "../vfs.hpp"
#include "embedded_modules.h"
#include "lconfig.hpp"
#include "lexception.hpp"

// Analysis headers (available because LuauShared links Luau.Analysis)
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_set>

#include "Luau/AstQuery.h"
#include "Luau/Autocomplete.h"
#include "Luau/AutocompleteTypes.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Common.h"
#include "Luau/Config.h"
#include "Luau/Error.h"
#include "Luau/Frontend.h"
#include "Luau/ModuleResolver.h"
#include "Luau/PrettyPrinter.h"
#include "Luau/ToString.h"
#include "Luau/Type.h"
#include "Luau/TypeAttach.h"
#include "Luau/TypePack.h"
#include "lprint.hpp"
#include "lrequire.hpp"
#include "lresolve.hpp"

// CLI args offset – default 1 (skip just the exe name)
static int g_cliargs_offset = 1;
static int g_cliargs_argc = 0;
static const char** g_cliargs_argv = nullptr;
ERYX_API void eryx_set_cliargs_offset(int offset) { g_cliargs_offset = offset; }
ERYX_API int eryx_get_cliargs_offset() { return g_cliargs_offset; }
ERYX_API void eryx_set_cliargs(int argc, const char** argv) {
    g_cliargs_argc = argc;
    g_cliargs_argv = argv;
}
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
    eryx_lua_push_location(L, loc);
}

static Luau::ToStringOptions analysis_type_to_string_options() {
    Luau::ToStringOptions o;
    o.exhaustive = false;
    o.useLineBreaks = false;
    o.functionTypeArguments = true;
    o.ignoreSyntheticName = true;
    return o;
}

static bool analysis_set_fastflag_bool(const char* name, bool value) {
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next) {
        if (flag->name && strcmp(flag->name, name) == 0) {
            flag->value = value;
            return true;
        }
    }
    return false;
}

static bool analysis_set_fastint(const char* name, int value) {
    for (Luau::FValue<int>* flag = Luau::FValue<int>::list; flag; flag = flag->next) {
        if (flag->name && strcmp(flag->name, name) == 0) {
            flag->value = value;
            return true;
        }
    }
    return false;
}

static void analysis_apply_new_solver_flags() {
    // Ensure explicit new-solver selection isn't overridden by defaults.
    analysis_set_fastflag_bool("LuauSolverV2", true);
    analysis_set_fastflag_bool("DebugLuauForceOldSolver", false);

    // Type-function stability knobs used by upstream in new-solver scenarios.
    analysis_set_fastflag_bool("LuauTypeFunctionsCaptureNestedInstances", true);
    analysis_set_fastflag_bool("LuauBuiltinTypeFunctionsUseNewOverloadResolution", true);
    analysis_set_fastflag_bool("LuauOverloadGetsInstantiated", true);
    analysis_set_fastflag_bool("LuauReplacerRespectsReboundGenerics", true);
    analysis_set_fastflag_bool("LuauUnifyWithSubtyping2", true);
    analysis_set_fastflag_bool("LuauFollowGenericBeforeCheckingIfMapped", true);

    // Guard against runaway recursive type traversals in cyclic setmetatable<> graphs.
    analysis_set_fastint("LuauVisitRecursionLimit", 200);
    analysis_set_fastint("LuauSolverRecursionLimit", 300);
    analysis_set_fastint("LuauSubtypingRecursionLimit", 64);
    analysis_set_fastint("LuauSubtypingIterationLimit", 1500);
}

static void analysis_push_internal_error(lua_State* L, const char* message) {
    lua_createtable(L, 0, 3);
    lua_pushstring(L, message);
    lua_setfield(L, -2, "message");
    analysis_push_location(L, Luau::Location{ { 0, 0 }, { 0, 0 } });
    lua_setfield(L, -2, "location");
    lua_pushstring(L, "InternalError");
    lua_setfield(L, -2, "category");
}

static bool analysis_safe_check(Luau::Frontend& frontend, const char* mainModule,
                                Luau::CheckResult& out, std::string& crashMessage) {
    try {
        out = frontend.check(mainModule);
        return true;
    } catch (const std::exception& ex) {
        crashMessage = ex.what();
        return false;
    } catch (...) {
        crashMessage = "internal Luau checker fault";
        return false;
    }
}

static bool analysis_safe_check(Luau::Frontend& frontend, const char* mainModule,
                                std::string& crashMessage) {
    try {
        frontend.check(mainModule);
        return true;
    } catch (const std::exception& ex) {
        crashMessage = ex.what();
        return false;
    } catch (...) {
        crashMessage = "internal Luau checker fault";
        return false;
    }
}

static bool analysis_safe_check(Luau::Frontend& frontend, const char* mainModule,
                                const Luau::FrontendOptions& optionsOverride,
                                std::string& crashMessage) {
    try {
        frontend.check(mainModule, optionsOverride);
        return true;
    } catch (const std::exception& ex) {
        crashMessage = ex.what();
        return false;
    } catch (...) {
        crashMessage = "internal Luau checker fault";
        return false;
    }
}

static const char* analysis_primitive_to_string(Luau::PrimitiveType::Type type) {
    switch (type) {
        case Luau::PrimitiveType::NilType:
            return "nil";
        case Luau::PrimitiveType::Boolean:
            return "boolean";
        case Luau::PrimitiveType::Number:
            return "number";
        case Luau::PrimitiveType::String:
            return "string";
        case Luau::PrimitiveType::Thread:
            return "thread";
        case Luau::PrimitiveType::Function:
            return "function";
        case Luau::PrimitiveType::Table:
            return "table";
        case Luau::PrimitiveType::Buffer:
            return "buffer";
        default:
            return "unknown";
    }
}

struct AnalysisTypeSerdeCtx {
    std::unordered_set<Luau::TypeId> seenTypes;
    std::unordered_set<Luau::TypePackId> seenPacks;
    int maxDepth = 6;
};

static void analysis_push_typepack_id(lua_State* L, Luau::TypePackId tp, AnalysisTypeSerdeCtx& ctx,
                                      int depth);

static void analysis_push_type_id(lua_State* L, Luau::TypeId ty, AnalysisTypeSerdeCtx& ctx,
                                  int depth) {
    if (!ty) {
        lua_pushnil(L);
        return;
    }

    Luau::ToStringOptions o = analysis_type_to_string_options();

    lua_createtable(L, 0, 6);
    std::string display = Luau::toString(ty, o);
    lua_pushlstring(L, display.data(), display.size());
    lua_setfield(L, -2, "display");

    if (depth > ctx.maxDepth || ctx.seenTypes.contains(ty)) {
        lua_pushstring(L, "Truncated");
        lua_setfield(L, -2, "kind");
        return;
    }

    ctx.seenTypes.insert(ty);
    Luau::TypeId tf = Luau::follow(ty);

    if (const Luau::FreeType* t = Luau::get<Luau::FreeType>(tf)) {
        lua_pushstring(L, "Free");
        lua_setfield(L, -2, "kind");
        lua_pushinteger(L, t->index);
        lua_setfield(L, -2, "index");
    } else if (const Luau::GenericType* t = Luau::get<Luau::GenericType>(tf)) {
        lua_pushstring(L, "Generic");
        lua_setfield(L, -2, "kind");
        lua_pushlstring(L, t->name.data(), t->name.size());
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, t->index);
        lua_setfield(L, -2, "index");
    } else if (const Luau::PrimitiveType* t = Luau::get<Luau::PrimitiveType>(tf)) {
        lua_pushstring(L, "Primitive");
        lua_setfield(L, -2, "kind");
        lua_pushstring(L, analysis_primitive_to_string(t->type));
        lua_setfield(L, -2, "primitive");
        if (t->metatable) {
            analysis_push_type_id(L, *t->metatable, ctx, depth + 1);
            lua_setfield(L, -2, "metatable");
        }
    } else if (const Luau::SingletonType* t = Luau::get<Luau::SingletonType>(tf)) {
        lua_pushstring(L, "Singleton");
        lua_setfield(L, -2, "kind");
        if (const Luau::BooleanSingleton* b = Luau::get<Luau::BooleanSingleton>(t)) {
            lua_pushstring(L, "boolean");
            lua_setfield(L, -2, "singletonKind");
            lua_pushboolean(L, b->value);
            lua_setfield(L, -2, "value");
        } else if (const Luau::StringSingleton* s = Luau::get<Luau::StringSingleton>(t)) {
            lua_pushstring(L, "string");
            lua_setfield(L, -2, "singletonKind");
            lua_pushlstring(L, s->value.data(), s->value.size());
            lua_setfield(L, -2, "value");
        }
    } else if (const Luau::FunctionType* t = Luau::get<Luau::FunctionType>(tf)) {
        lua_pushstring(L, "Function");
        lua_setfield(L, -2, "kind");
        lua_pushboolean(L, t->hasSelf);
        lua_setfield(L, -2, "hasSelf");
        analysis_push_typepack_id(L, t->argTypes, ctx, depth + 1);
        lua_setfield(L, -2, "args");
        analysis_push_typepack_id(L, t->retTypes, ctx, depth + 1);
        lua_setfield(L, -2, "returns");
    } else if (const Luau::TableType* t = Luau::get<Luau::TableType>(tf)) {
        lua_pushstring(L, "Table");
        lua_setfield(L, -2, "kind");
        lua_createtable(L, 0, (int)t->props.size());
        for (const auto& [name, prop] : t->props) {
            lua_createtable(L, 0, 3);
            if (prop.readTy) {
                analysis_push_type_id(L, *prop.readTy, ctx, depth + 1);
                lua_setfield(L, -2, "read");
            }
            if (prop.writeTy) {
                analysis_push_type_id(L, *prop.writeTy, ctx, depth + 1);
                lua_setfield(L, -2, "write");
            }
            lua_pushboolean(L, prop.deprecated);
            lua_setfield(L, -2, "deprecated");
            lua_setfield(L, -2, name.c_str());
        }
        lua_setfield(L, -2, "props");
        if (t->indexer) {
            lua_createtable(L, 0, 2);
            analysis_push_type_id(L, t->indexer->indexType, ctx, depth + 1);
            lua_setfield(L, -2, "index");
            analysis_push_type_id(L, t->indexer->indexResultType, ctx, depth + 1);
            lua_setfield(L, -2, "result");
            lua_setfield(L, -2, "indexer");
        }
    } else if (const Luau::MetatableType* t = Luau::get<Luau::MetatableType>(tf)) {
        lua_pushstring(L, "Metatable");
        lua_setfield(L, -2, "kind");
        analysis_push_type_id(L, t->table, ctx, depth + 1);
        lua_setfield(L, -2, "table");
        analysis_push_type_id(L, t->metatable, ctx, depth + 1);
        lua_setfield(L, -2, "metatable");
    } else if (const Luau::ExternType* t = Luau::get<Luau::ExternType>(tf)) {
        lua_pushstring(L, "Extern");
        lua_setfield(L, -2, "kind");
        lua_pushlstring(L, t->name.data(), t->name.size());
        lua_setfield(L, -2, "name");
    } else if (Luau::get<Luau::AnyType>(tf)) {
        lua_pushstring(L, "Any");
        lua_setfield(L, -2, "kind");
    } else if (const Luau::UnionType* t = Luau::get<Luau::UnionType>(tf)) {
        lua_pushstring(L, "Union");
        lua_setfield(L, -2, "kind");
        lua_createtable(L, (int)t->options.size(), 0);
        for (size_t i = 0; i < t->options.size(); i++) {
            analysis_push_type_id(L, t->options[i], ctx, depth + 1);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "parts");
    } else if (const Luau::IntersectionType* t = Luau::get<Luau::IntersectionType>(tf)) {
        lua_pushstring(L, "Intersection");
        lua_setfield(L, -2, "kind");
        lua_createtable(L, (int)t->parts.size(), 0);
        for (size_t i = 0; i < t->parts.size(); i++) {
            analysis_push_type_id(L, t->parts[i], ctx, depth + 1);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "parts");
    } else if (Luau::get<Luau::UnknownType>(tf)) {
        lua_pushstring(L, "Unknown");
        lua_setfield(L, -2, "kind");
    } else if (Luau::get<Luau::NeverType>(tf)) {
        lua_pushstring(L, "Never");
        lua_setfield(L, -2, "kind");
    } else if (const Luau::NegationType* t = Luau::get<Luau::NegationType>(tf)) {
        lua_pushstring(L, "Negation");
        lua_setfield(L, -2, "kind");
        analysis_push_type_id(L, t->ty, ctx, depth + 1);
        lua_setfield(L, -2, "inner");
    } else if (Luau::get<Luau::NoRefineType>(tf)) {
        lua_pushstring(L, "NoRefine");
        lua_setfield(L, -2, "kind");
    } else if (const Luau::TypeFunctionInstanceType* t =
                   Luau::get<Luau::TypeFunctionInstanceType>(tf)) {
        lua_pushstring(L, "TypeFunctionInstance");
        lua_setfield(L, -2, "kind");
        lua_createtable(L, (int)t->typeArguments.size(), 0);
        for (size_t i = 0; i < t->typeArguments.size(); i++) {
            analysis_push_type_id(L, t->typeArguments[i], ctx, depth + 1);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "typeArguments");
    } else {
        lua_pushstring(L, "Other");
        lua_setfield(L, -2, "kind");
    }

    ctx.seenTypes.erase(ty);
}

static void analysis_push_typepack_id(lua_State* L, Luau::TypePackId tp, AnalysisTypeSerdeCtx& ctx,
                                      int depth) {
    if (!tp) {
        lua_pushnil(L);
        return;
    }

    lua_createtable(L, 0, 4);

    if (depth > ctx.maxDepth || ctx.seenPacks.contains(tp)) {
        lua_pushstring(L, "Truncated");
        lua_setfield(L, -2, "kind");
        return;
    }
    ctx.seenPacks.insert(tp);

    Luau::TypePackId tpf = Luau::follow(tp);
    if (const Luau::TypePack* p = Luau::get<Luau::TypePack>(tpf)) {
        lua_pushstring(L, "Pack");
        lua_setfield(L, -2, "kind");
        lua_createtable(L, (int)p->head.size(), 0);
        for (size_t i = 0; i < p->head.size(); i++) {
            analysis_push_type_id(L, p->head[i], ctx, depth + 1);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "head");
        if (p->tail) {
            analysis_push_typepack_id(L, *p->tail, ctx, depth + 1);
            lua_setfield(L, -2, "tail");
        }
    } else if (const Luau::VariadicTypePack* p = Luau::get<Luau::VariadicTypePack>(tpf)) {
        lua_pushstring(L, "Variadic");
        lua_setfield(L, -2, "kind");
        lua_pushboolean(L, p->hidden);
        lua_setfield(L, -2, "hidden");
        analysis_push_type_id(L, p->ty, ctx, depth + 1);
        lua_setfield(L, -2, "type");
    } else if (const Luau::GenericTypePack* p = Luau::get<Luau::GenericTypePack>(tpf)) {
        lua_pushstring(L, "Generic");
        lua_setfield(L, -2, "kind");
        lua_pushlstring(L, p->name.data(), p->name.size());
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, p->index);
        lua_setfield(L, -2, "index");
    } else if (const Luau::FreeTypePack* p = Luau::get<Luau::FreeTypePack>(tpf)) {
        lua_pushstring(L, "Free");
        lua_setfield(L, -2, "kind");
        lua_pushinteger(L, p->index);
        lua_setfield(L, -2, "index");
    } else {
        lua_pushstring(L, "Other");
        lua_setfield(L, -2, "kind");
    }

    ctx.seenPacks.erase(tp);
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
    lua_createtable(L, 0, 5);

    std::string msg;
    if (const auto* syntax = Luau::get_if<Luau::SyntaxError>(&err.data)) {
        msg = syntax->message;
    } else {
        msg = Luau::toString(err, Luau::TypeErrorToStringOptions{ fe.fileResolver });
    }

    lua_pushlstring(L, msg.data(), msg.size());
    lua_setfield(L, -2, "message");

    analysis_push_location(L, err.location);
    lua_setfield(L, -2, "location");

    const char* category = "TypeError";
    if (Luau::get_if<Luau::SyntaxError>(&err.data)) category = "SyntaxError";
    lua_pushstring(L, category);
    lua_setfield(L, -2, "category");

    std::string moduleName = fe.fileResolver->getHumanReadableModuleName(err.moduleName);
    if (!moduleName.empty()) {
        lua_pushlstring(L, moduleName.data(), moduleName.size());
        lua_setfield(L, -2, "moduleName");
    }

    lua_pushinteger(L, (lua_Integer)err.code());
    lua_setfield(L, -2, "code");
}

static std::optional<Luau::SolverMode> parse_solver_opt(lua_State* L, int idx) {
    if (!lua_istable(L, idx)) return std::nullopt;
    lua_getfield(L, idx, "solver");
    std::optional<Luau::SolverMode> out = std::nullopt;
    if (lua_isstring(L, -1)) {
        const char* s = lua_tostring(L, -1);
        if (strcmp(s, "new") == 0)
            out = Luau::SolverMode::New;
        else if (strcmp(s, "old") == 0)
            out = Luau::SolverMode::Old;
    }
    lua_pop(L, 1);
    return out;
}

static void analysis_push_lint_warning(lua_State* L, const Luau::LintWarning& warning,
                                       const char* severity) {
    lua_createtable(L, 0, 5);
    lua_pushstring(L, severity);
    lua_setfield(L, -2, "severity");
    lua_pushinteger(L, (lua_Integer)warning.code);
    lua_setfield(L, -2, "code");
    lua_pushstring(L, Luau::LintWarning::getName(warning.code));
    lua_setfield(L, -2, "name");
    lua_pushlstring(L, warning.text.data(), warning.text.size());
    lua_setfield(L, -2, "message");
    analysis_push_location(L, warning.location);
    lua_setfield(L, -2, "location");
}

struct EryxFileResolver : Luau::FileResolver {
    std::string mainSource;
    Luau::ModuleName mainModule;  // absolute path or "=main" fallback
    EryxAnalysisTimingStats* timingStats = nullptr;
    mutable lua_State* helperState = nullptr;

    ~EryxFileResolver() {
        if (helperState) lua_close(helperState);
    }

    lua_State* getHelperState() const {
        if (!helperState) helperState = eryx_initialise_environment(nullptr);
        return helperState;
    }

    static RequireContext requireContextForModuleName(const Luau::ModuleName& name) {
        RequireContext ctx;
        ctx.root = fs::current_path();

        if (name == "=main") {
            ctx.selfDir = ctx.root;
            ctx.callerDir = ctx.root;
            return ctx;
        }

        if (name.starts_with(CHUNK_PREFIX_ERYX)) {
            ctx.isEmbedded = true;
            std::string key = name.substr(CHUNK_PREFIX_ERYX_LEN);
            size_t lastSlash = key.rfind('/');
            ctx.embeddedSelfDir = (lastSlash != std::string::npos) ? key.substr(0, lastSlash) : "";

            std::string stem = (lastSlash != std::string::npos) ? key.substr(lastSlash + 1) : key;
            if (stem == "init") {
                ctx.isInit = true;
                size_t parentSlash = ctx.embeddedSelfDir.rfind('/');
                ctx.embeddedCallerDir = (parentSlash != std::string::npos)
                                            ? ctx.embeddedSelfDir.substr(0, parentSlash)
                                            : "";
            } else {
                ctx.embeddedCallerDir = ctx.embeddedSelfDir;
            }

            return ctx;
        }

        if (name.starts_with(CHUNK_PREFIX_VFS)) {
            ctx.isVFS = true;
            std::string key = name.substr(CHUNK_PREFIX_VFS_LEN);

            if (key.size() > 5 && key.substr(key.size() - 5) == ".luau")
                key.resize(key.size() - 5);
            else if (key.size() > 4 && key.substr(key.size() - 4) == ".lua")
                key.resize(key.size() - 4);

            size_t lastSlash = key.rfind('/');
            ctx.vfsSelfDir = (lastSlash != std::string::npos) ? key.substr(0, lastSlash) : "";

            std::string stem = (lastSlash != std::string::npos) ? key.substr(lastSlash + 1) : key;
            if (stem == "init") {
                ctx.isInit = true;
                size_t parentSlash = ctx.vfsSelfDir.rfind('/');
                ctx.vfsCallerDir =
                    (parentSlash != std::string::npos) ? ctx.vfsSelfDir.substr(0, parentSlash) : "";
            } else {
                ctx.vfsCallerDir = ctx.vfsSelfDir;
            }

            return ctx;
        }

        fs::path modulePath(name);
        ctx.selfDir = modulePath.parent_path();
        if (ctx.selfDir.empty()) ctx.selfDir = ctx.root;

        if (modulePath.stem().string() == "init") {
            ctx.isInit = true;
            ctx.callerDir = ctx.selfDir.parent_path();
        } else {
            ctx.callerDir = ctx.selfDir;
        }

        if (ctx.callerDir.empty()) ctx.callerDir = ctx.root;
        return ctx;
    }

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override {
        const EryxTimingClock::time_point start = EryxTimingClock::now();
        auto finish = [this, start]() {
            if (timingStats)
                timingStats->readSource.add(eryx_timing_elapsed_ms(start, EryxTimingClock::now()));
        };

        if (name == mainModule) {
            finish();
            return Luau::SourceCode{ mainSource, Luau::SourceCode::Module };
        }

        // VFS modules (prefixed with @@vfs/)
        if (name.starts_with(CHUNK_PREFIX_VFS)) {
            std::string vfsPath = name.substr(CHUNK_PREFIX_VFS_LEN);
            auto data = vfs_read_file(vfsPath);
            if (data.empty()) {
                finish();
                return std::nullopt;
            }
            std::string src(reinterpret_cast<const char*>(data.data()), data.size());
            finish();
            return Luau::SourceCode{ std::move(src), Luau::SourceCode::Module };
        }

        // Embedded script modules (prefixed with @@eryx/)
        if (name.starts_with(CHUNK_PREFIX_ERYX)) {
            std::string key = name.substr(CHUNK_PREFIX_ERYX_LEN);
            auto* scripts = eryx_get_embedded_script_modules();
            if (scripts) {
                for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                    if (key == m->modulePath) {
                        finish();
                        return Luau::SourceCode{ std::string(m->source), Luau::SourceCode::Module };
                    }
                }
            }
            finish();
            return std::nullopt;
        }

        // Filesystem modules
        try {
            if (!fs::exists(name)) {
                finish();
                return std::nullopt;
            }
            std::ifstream f(name, std::ios::binary);
            if (!f) {
                finish();
                return std::nullopt;
            }
            std::string src((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            finish();
            return Luau::SourceCode{ std::move(src), Luau::SourceCode::Module };
        } catch (...) {
            finish();
            return std::nullopt;
        }
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo* context,
                                                  Luau::AstExpr* node,
                                                  const Luau::TypeCheckLimits&) override {
        const EryxTimingClock::time_point start = EryxTimingClock::now();
        auto finish = [this, start]() {
            if (timingStats)
                timingStats->resolveModule.add(
                    eryx_timing_elapsed_ms(start, EryxTimingClock::now()));
        };

        auto expr = node->as<Luau::AstExprConstantString>();
        if (!expr) {
            finish();
            return std::nullopt;
        }
        std::string requirePath(expr->value.data, expr->value.size);

        lua_State* CL = getHelperState();
        RequireContext requireContext = context ? requireContextForModuleName(context->name)
                                                : requireContextForModuleName(mainModule);
        auto resolved = eryx_resolve_module(CL, requireContext, requirePath);

        if (!resolved) {
            finish();
            return std::nullopt;
        }

        switch (resolved->type) {
            case LocatedModule::TYPE_FILE:
                finish();
                return Luau::ModuleInfo{ resolved->path };
            case LocatedModule::TYPE_VFS:
                finish();
                return Luau::ModuleInfo{ std::string(CHUNK_PREFIX_VFS) + resolved->path };
            case LocatedModule::TYPE_EMBEDDED_SCRIPT:
                finish();
                return Luau::ModuleInfo{ std::string(CHUNK_PREFIX_ERYX) + resolved->path };
            case LocatedModule::TYPE_EMBEDDED_NATIVE:
                finish();
                return std::nullopt;  // native modules have no analyzable source
        }
        finish();
        return std::nullopt;
    }
};

struct EryxConfigResolver : Luau::ConfigResolver {
    Luau::Mode defaultMode;
    lua_State* L;
    mutable std::map<std::string, Luau::Config> cache;
    EryxAnalysisTimingStats* timingStats = nullptr;
    mutable lua_State* helperState = nullptr;

    ~EryxConfigResolver() {
        if (helperState) lua_close(helperState);
    }

    lua_State* getHelperState() const {
        if (!helperState) helperState = eryx_initialise_environment(nullptr);
        return helperState;
    }

    const Luau::Config& getConfig(const Luau::ModuleName& name,
                                  const Luau::TypeCheckLimits& limits) const override {
        const EryxTimingClock::time_point start = EryxTimingClock::now();
        auto finish = [this, start]() {
            if (timingStats)
                timingStats->getConfig.add(eryx_timing_elapsed_ms(start, EryxTimingClock::now()));
        };

        if (name[0] == '=') {
            Luau::Config cfg;
            cfg.mode = defaultMode;
            auto [inserted, ok] = cache.emplace(name, std::move(cfg));
            finish();
            return inserted->second;
        }

        fs::path dir;
        std::string vfsDir;
        try {
            // VFS modules have names like @@vfs/subdir/file.luau -
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
            finish();
            return inserted->second;
        }

        std::string key = vfsDir.empty() ? dir.string() : ("@@vfs/" + vfsDir);
        if (cache.contains(key)) {
            finish();
            return cache.at(key);
        }

        lua_State* CL = getHelperState();

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

            auto [inserted, ok] = cache.emplace(key, std::move(cfg));
            finish();
            return inserted->second;
        }

        Luau::Config cfg;
        cfg.mode = defaultMode;
        auto [inserted, ok] = cache.emplace(key, std::move(cfg));
        finish();
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
    const EryxTimingClock::time_point totalStart = EryxTimingClock::now();
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    Luau::Mode mode = Luau::Mode::Nonstrict;
    bool annotate = false;

    const char* filePath = nullptr;
    size_t filePathLen = 0;
    std::optional<Luau::SolverMode> solverMode = std::nullopt;

    if (lua_istable(L, 2)) {
        mode = parse_mode_opt(L, 2, mode);
        solverMode = parse_solver_opt(L, 2);
        lua_getfield(L, 2, "annotate");
        if (lua_isboolean(L, -1)) annotate = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
        read_file_path_opt(L, 2, filePath, filePathLen);
    }

    const char* mainModule = filePath ? filePath : "=main";

    if (solverMode && *solverMode == Luau::SolverMode::New) analysis_apply_new_solver_flags();

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = annotate;
    frontendOptions.runLintChecks = true;
    EryxAnalysisTimingStats timingStats;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    fileResolver.timingStats = &timingStats;
    EryxConfigResolver configResolver;
    configResolver.L = L;
    configResolver.defaultMode = mode;
    configResolver.timingStats = &timingStats;

    // TODO: Why do we need that cast?
    const EryxTimingClock::time_point setupStart = EryxTimingClock::now();
    std::unique_ptr<Luau::Frontend> frontendPtr;
    if (solverMode)
        frontendPtr = std::make_unique<Luau::Frontend>(
            *solverMode, (Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);
    else
        frontendPtr = std::make_unique<Luau::Frontend>((Luau::FileResolver*)&fileResolver,
                                                       &configResolver, frontendOptions);
    Luau::Frontend& frontend = *frontendPtr;

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);
    const double setupMs = eryx_timing_elapsed_ms(setupStart, EryxTimingClock::now());

    // Load optional definition files
    const EryxTimingClock::time_point definitionsStart = EryxTimingClock::now();
    load_definitions_opt(L, 2, frontend);
    const double definitionsMs = eryx_timing_elapsed_ms(definitionsStart, EryxTimingClock::now());

    // Run a type check
    Luau::CheckResult cr;
    std::string crashMessage;
    const EryxTimingClock::time_point checkStart = EryxTimingClock::now();
    bool checkOk = analysis_safe_check(frontend, mainModule, cr, crashMessage);
    const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());

    const EryxTimingClock::time_point serializeStart = EryxTimingClock::now();
    lua_createtable(L, 0, 3);

    // errors
    lua_createtable(L, checkOk ? (int)cr.errors.size() : 1, 0);
    if (!checkOk) {
        std::string msg = "luau.check failed: " + crashMessage;
        analysis_push_internal_error(L, msg.c_str());
        lua_rawseti(L, -2, 1);
    } else {
        for (size_t i = 0; i < cr.errors.size(); i++) {
            analysis_push_type_error(L, frontend, cr.errors[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
    }
    lua_setfield(L, -2, "errors");

    // lints
    lua_createtable(L, 0, 3);
    lua_createtable(L, checkOk ? (int)cr.lintResult.errors.size() : 0, 0);
    if (checkOk) {
        for (size_t i = 0; i < cr.lintResult.errors.size(); i++) {
            analysis_push_lint_warning(L, cr.lintResult.errors[i], "error");
            lua_rawseti(L, -2, (int)(i + 1));
        }
    }
    lua_setfield(L, -2, "errors");

    lua_createtable(L, checkOk ? (int)cr.lintResult.warnings.size() : 0, 0);
    if (checkOk) {
        for (size_t i = 0; i < cr.lintResult.warnings.size(); i++) {
            analysis_push_lint_warning(L, cr.lintResult.warnings[i], "warning");
            lua_rawseti(L, -2, (int)(i + 1));
        }
    }
    lua_setfield(L, -2, "warnings");

    lua_createtable(
        L, checkOk ? (int)(cr.lintResult.errors.size() + cr.lintResult.warnings.size()) : 0, 0);
    int allIndex = 1;
    if (checkOk) {
        for (size_t i = 0; i < cr.lintResult.errors.size(); i++) {
            analysis_push_lint_warning(L, cr.lintResult.errors[i], "error");
            lua_rawseti(L, -2, allIndex++);
        }
        for (size_t i = 0; i < cr.lintResult.warnings.size(); i++) {
            analysis_push_lint_warning(L, cr.lintResult.warnings[i], "warning");
            lua_rawseti(L, -2, allIndex++);
        }
    }
    lua_setfield(L, -2, "all");
    lua_setfield(L, -2, "lints");

    // annotated source
    if (annotate) {
        const double serializeMs = eryx_timing_elapsed_ms(serializeStart, EryxTimingClock::now());
        const EryxTimingClock::time_point annotateStart = EryxTimingClock::now();
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
        const double annotateMs = eryx_timing_elapsed_ms(annotateStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs - annotateMs;
        eryx_luau_timing_log(
            "check module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "serialize=%.3fms annotate=%.3fms luau_check_wall=%.3fms luau_check_internal=%.3fms "
            "callbacks=%.3fms readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu "
            "ok=%d errors=%zu lintErrors=%zu warnings=%zu",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, serializeMs, annotateMs,
            checkWallMs, estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, checkOk ? 1 : 0, checkOk ? cr.errors.size() : 0,
            checkOk ? cr.lintResult.errors.size() : 0, checkOk ? cr.lintResult.warnings.size() : 0);
        return 1;
    }

    const double serializeMs = eryx_timing_elapsed_ms(serializeStart, EryxTimingClock::now());
    const double callbackMs = timingStats.callbackTotalMs();
    const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
    const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
    const double ownMs = totalMs - estimatedLuauCheckMs;
    eryx_luau_timing_log(
        "check module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
        "serialize=%.3fms annotate=0.000ms luau_check_wall=%.3fms luau_check_internal=%.3fms "
        "callbacks=%.3fms readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu "
        "ok=%d errors=%zu lintErrors=%zu warnings=%zu",
        mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, serializeMs, checkWallMs,
        estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
        timingStats.readSource.calls, timingStats.resolveModule.totalMs,
        timingStats.resolveModule.calls, timingStats.getConfig.totalMs, timingStats.getConfig.calls,
        checkOk ? 1 : 0, checkOk ? cr.errors.size() : 0, checkOk ? cr.lintResult.errors.size() : 0,
        checkOk ? cr.lintResult.warnings.size() : 0);

    return 1;
}

// ---------------------------------------------------------------------------
// eryx_luau_typeAt(L)   –   lua_CFunction
//
// Args:  (source: string, line: number, column: number [, options: {mode?}])
// Returns: string?
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_typeAt(lua_State* L) {
    const EryxTimingClock::time_point totalStart = EryxTimingClock::now();
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);
    int line = (int)luaL_checkinteger(L, 2);
    int col = (int)luaL_checkinteger(L, 3);

    Luau::Mode mode = parse_mode_opt(L, 4, Luau::Mode::Strict);
    bool detailed = false;
    std::optional<Luau::SolverMode> solverMode = std::nullopt;
    if (lua_istable(L, 4)) {
        solverMode = parse_solver_opt(L, 4);
        lua_getfield(L, 4, "detailed");
        if (lua_isboolean(L, -1)) detailed = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }
    const char* filePath = nullptr;
    size_t filePathLen = 0;
    read_file_path_opt(L, 4, filePath, filePathLen);

    Luau::Position pos{ (unsigned)(line - 1), (unsigned)(col - 1) };

    const char* mainModule = filePath ? filePath : "=main";

    if (solverMode && *solverMode == Luau::SolverMode::New) analysis_apply_new_solver_flags();

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = true;
    frontendOptions.runLintChecks = true;
    EryxAnalysisTimingStats timingStats;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    fileResolver.timingStats = &timingStats;
    EryxConfigResolver configResolver;
    configResolver.defaultMode = mode;
    configResolver.timingStats = &timingStats;

    // TODO: Why do we need that cast?
    const EryxTimingClock::time_point setupStart = EryxTimingClock::now();
    std::unique_ptr<Luau::Frontend> frontendPtr;
    if (solverMode)
        frontendPtr = std::make_unique<Luau::Frontend>(
            *solverMode, (Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);
    else
        frontendPtr = std::make_unique<Luau::Frontend>((Luau::FileResolver*)&fileResolver,
                                                       &configResolver, frontendOptions);
    Luau::Frontend& frontend = *frontendPtr;

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);
    const double setupMs = eryx_timing_elapsed_ms(setupStart, EryxTimingClock::now());

    const EryxTimingClock::time_point definitionsStart = EryxTimingClock::now();
    load_definitions_opt(L, 4, frontend);
    const double definitionsMs = eryx_timing_elapsed_ms(definitionsStart, EryxTimingClock::now());
    std::string typeAtCrash;
    const EryxTimingClock::time_point checkStart = EryxTimingClock::now();
    if (!analysis_safe_check(frontend, mainModule, typeAtCrash)) {
        const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs;
        eryx_luau_timing_log(
            "typeAt module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "query=0.000ms luau_check_wall=%.3fms luau_check_internal=%.3fms callbacks=%.3fms "
            "readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu hit=0 detailed=%d "
            "ok=0",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, detailed ? 1 : 0);
        lua_pushnil(L);
        return 1;
    }
    const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());

    Luau::SourceModule* sm = frontend.getSourceModule(mainModule);
    Luau::ModulePtr m = frontend.moduleResolver.getModule(mainModule);

    if (!sm || !m) {
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs;
        eryx_luau_timing_log(
            "typeAt module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "query=0.000ms luau_check_wall=%.3fms luau_check_internal=%.3fms callbacks=%.3fms "
            "readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu hit=0 detailed=%d "
            "ok=1",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, detailed ? 1 : 0);
        lua_pushnil(L);
        return 1;
    }

    const EryxTimingClock::time_point queryStart = EryxTimingClock::now();
    auto logTypeAtResult = [&](bool hit) {
        const double queryMs = eryx_timing_elapsed_ms(queryStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs - queryMs;
        eryx_luau_timing_log(
            "typeAt module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "query=%.3fms luau_check_wall=%.3fms luau_check_internal=%.3fms callbacks=%.3fms "
            "readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu hit=%d "
            "detailed=%d ok=1",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, queryMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, hit ? 1 : 0, detailed ? 1 : 0);
    };

    // Try expression type
    if (auto ty = Luau::findTypeAtPosition(*m, *sm, pos)) {
        Luau::ToStringOptions o = analysis_type_to_string_options();
        std::string s = Luau::toString(*ty, o);
        if (detailed) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, s.data(), s.size());
            lua_setfield(L, -2, "display");
            lua_pushstring(L, "Expression");
            lua_setfield(L, -2, "source");
            AnalysisTypeSerdeCtx ctx;
            analysis_push_type_id(L, *ty, ctx, 0);
            lua_setfield(L, -2, "type");
        } else {
            lua_pushlstring(L, s.data(), s.size());
        }
        logTypeAtResult(true);
        return 1;
    }

    // Try binding type
    if (auto binding = Luau::findBindingAtPosition(*m, *sm, pos)) {
        Luau::ToStringOptions o = analysis_type_to_string_options();
        std::string s = Luau::toString(binding->typeId, o);
        if (detailed) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, s.data(), s.size());
            lua_setfield(L, -2, "display");
            lua_pushstring(L, "Binding");
            lua_setfield(L, -2, "source");
            AnalysisTypeSerdeCtx ctx;
            analysis_push_type_id(L, binding->typeId, ctx, 0);
            lua_setfield(L, -2, "type");
        } else {
            lua_pushlstring(L, s.data(), s.size());
        }
        logTypeAtResult(true);
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
                o = analysis_type_to_string_options();
                std::string s = Luau::toString(it->second.typeId, o);
                if (detailed) {
                    lua_createtable(L, 0, 3);
                    lua_pushlstring(L, s.data(), s.size());
                    lua_setfield(L, -2, "display");
                    lua_pushstring(L, "ScopeBinding");
                    lua_setfield(L, -2, "source");
                    AnalysisTypeSerdeCtx ctx;
                    analysis_push_type_id(L, it->second.typeId, ctx, 0);
                    lua_setfield(L, -2, "type");
                } else {
                    lua_pushlstring(L, s.data(), s.size());
                }
                logTypeAtResult(true);
                return 1;
            }
        }
    }

    lua_pushnil(L);
    logTypeAtResult(false);
    return 1;
}

// ---------------------------------------------------------------------------
// eryx_luau_autocomplete(L)   –   lua_CFunction
//
// Args:  (source: string, line: number, column: number [, options: {mode?}])
// Returns: { context: string, entries: { [name]: {...} } }
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_autocomplete(lua_State* L) {
    const EryxTimingClock::time_point totalStart = EryxTimingClock::now();
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);
    int line = (int)luaL_checkinteger(L, 2);
    int col = (int)luaL_checkinteger(L, 3);

    Luau::Mode mode = parse_mode_opt(L, 4, Luau::Mode::Strict);
    bool detailed = false;
    std::optional<Luau::SolverMode> solverMode = std::nullopt;
    if (lua_istable(L, 4)) {
        solverMode = parse_solver_opt(L, 4);
        lua_getfield(L, 4, "detailed");
        if (lua_isboolean(L, -1)) detailed = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }
    const char* filePath = nullptr;
    size_t filePathLen = 0;
    read_file_path_opt(L, 4, filePath, filePathLen);

    Luau::Position pos{ (unsigned)(line - 1), (unsigned)(col - 1) };

    const char* mainModule = filePath ? filePath : "=main";

    if (solverMode && *solverMode == Luau::SolverMode::New) analysis_apply_new_solver_flags();

    // Configure type checker
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = true;
    frontendOptions.runLintChecks = true;
    EryxAnalysisTimingStats timingStats;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    fileResolver.timingStats = &timingStats;
    EryxConfigResolver configResolver;
    configResolver.L = L;
    configResolver.defaultMode = mode;
    configResolver.timingStats = &timingStats;

    // TODO: Why do we need that cast?
    const EryxTimingClock::time_point setupStart = EryxTimingClock::now();
    std::unique_ptr<Luau::Frontend> frontendPtr;
    if (solverMode)
        frontendPtr = std::make_unique<Luau::Frontend>(
            *solverMode, (Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);
    else
        frontendPtr = std::make_unique<Luau::Frontend>((Luau::FileResolver*)&fileResolver,
                                                       &configResolver, frontendOptions);
    Luau::Frontend& frontend = *frontendPtr;

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);
    Luau::freeze(frontend.globalsForAutocomplete.globalTypes);
    const double setupMs = eryx_timing_elapsed_ms(setupStart, EryxTimingClock::now());

    // Run autocomplete type check
    const EryxTimingClock::time_point definitionsStart = EryxTimingClock::now();
    load_definitions_opt(L, 4, frontend);
    const double definitionsMs = eryx_timing_elapsed_ms(definitionsStart, EryxTimingClock::now());
    Luau::FrontendOptions acOpts = frontendOptions;
    acOpts.forAutocomplete = true;
    std::string acCrash;
    const EryxTimingClock::time_point checkStart = EryxTimingClock::now();
    if (!analysis_safe_check(frontend, mainModule, acOpts, acCrash)) {
        const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs;
        eryx_luau_timing_log(
            "autocomplete module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "autocomplete=0.000ms serialize=0.000ms luau_check_wall=%.3fms "
            "luau_check_internal=%.3fms callbacks=%.3fms readSource=%.3fms/%zu "
            "resolveModule=%.3fms/%zu getConfig=%.3fms/%zu entries=0 detailed=%d ok=0",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, detailed ? 1 : 0);
        lua_createtable(L, 0, 2);
        lua_pushstring(L, "Unknown");
        lua_setfield(L, -2, "context");
        lua_createtable(L, 0, 0);
        lua_setfield(L, -2, "entries");
        return 1;
    }
    const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());

    const EryxTimingClock::time_point autocompleteStart = EryxTimingClock::now();
    Luau::AutocompleteResult acResult = Luau::autocomplete(frontend, mainModule, pos, nullptr);
    const double autocompleteMs = eryx_timing_elapsed_ms(autocompleteStart, EryxTimingClock::now());

    const EryxTimingClock::time_point serializeStart = EryxTimingClock::now();
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
            Luau::ToStringOptions o = analysis_type_to_string_options();
            std::string s = Luau::toString(*entry.type, o);
            lua_pushlstring(L, s.data(), s.size());
            lua_setfield(L, -2, "type");
            if (detailed) {
                AnalysisTypeSerdeCtx ctx;
                analysis_push_type_id(L, *entry.type, ctx, 0);
                lua_setfield(L, -2, "typeDetail");
            }
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

    const double serializeMs = eryx_timing_elapsed_ms(serializeStart, EryxTimingClock::now());
    const double callbackMs = timingStats.callbackTotalMs();
    const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
    const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
    const double ownMs = totalMs - estimatedLuauCheckMs - autocompleteMs;
    eryx_luau_timing_log(
        "autocomplete module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
        "autocomplete=%.3fms serialize=%.3fms luau_check_wall=%.3fms luau_check_internal=%.3fms "
        "callbacks=%.3fms readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu "
        "entries=%zu detailed=%d ok=1",
        mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, autocompleteMs, serializeMs,
        checkWallMs, estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
        timingStats.readSource.calls, timingStats.resolveModule.totalMs,
        timingStats.resolveModule.calls, timingStats.getConfig.totalMs, timingStats.getConfig.calls,
        acResult.entryMap.size(), detailed ? 1 : 0);

    return 1;
}

// ---------------------------------------------------------------------------
// eryx_luau_typeofModule(L)   –   lua_CFunction
//
// Args:  (source: string [, options: {mode?, detailed?, filePath?}])
// Returns: string? | { display: string, source: "Module", typePack: table, moduleName?: string }
// ---------------------------------------------------------------------------
ERYX_API int eryx_luau_typeofModule(lua_State* L) {
    const EryxTimingClock::time_point totalStart = EryxTimingClock::now();
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    Luau::Mode mode = parse_mode_opt(L, 2, Luau::Mode::Strict);
    bool detailed = false;
    std::optional<Luau::SolverMode> solverMode = std::nullopt;
    if (lua_istable(L, 2)) {
        solverMode = parse_solver_opt(L, 2);
        lua_getfield(L, 2, "detailed");
        if (lua_isboolean(L, -1)) detailed = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }
    const char* filePath = nullptr;
    size_t filePathLen = 0;
    read_file_path_opt(L, 2, filePath, filePathLen);

    const char* mainModule = filePath ? filePath : "=main";

    if (solverMode && *solverMode == Luau::SolverMode::New) analysis_apply_new_solver_flags();

    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = detailed;
    frontendOptions.runLintChecks = true;
    EryxAnalysisTimingStats timingStats;

    EryxFileResolver fileResolver;
    fileResolver.mainSource = src;
    fileResolver.mainModule = mainModule;
    fileResolver.timingStats = &timingStats;
    EryxConfigResolver configResolver;
    configResolver.L = L;
    configResolver.defaultMode = mode;
    configResolver.timingStats = &timingStats;

    const EryxTimingClock::time_point setupStart = EryxTimingClock::now();
    std::unique_ptr<Luau::Frontend> frontendPtr;
    if (solverMode)
        frontendPtr = std::make_unique<Luau::Frontend>(
            *solverMode, (Luau::FileResolver*)&fileResolver, &configResolver, frontendOptions);
    else
        frontendPtr = std::make_unique<Luau::Frontend>((Luau::FileResolver*)&fileResolver,
                                                       &configResolver, frontendOptions);
    Luau::Frontend& frontend = *frontendPtr;

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);
    const double setupMs = eryx_timing_elapsed_ms(setupStart, EryxTimingClock::now());

    const EryxTimingClock::time_point definitionsStart = EryxTimingClock::now();
    load_definitions_opt(L, 2, frontend);
    const double definitionsMs = eryx_timing_elapsed_ms(definitionsStart, EryxTimingClock::now());
    std::string crashMessage;
    const EryxTimingClock::time_point checkStart = EryxTimingClock::now();
    if (!analysis_safe_check(frontend, mainModule, crashMessage)) {
        const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs;
        eryx_luau_timing_log(
            "typeofModule module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "moduleType=0.000ms serialize=0.000ms luau_check_wall=%.3fms "
            "luau_check_internal=%.3fms callbacks=%.3fms readSource=%.3fms/%zu "
            "resolveModule=%.3fms/%zu getConfig=%.3fms/%zu detailed=%d ok=0",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, detailed ? 1 : 0);
        lua_pushnil(L);
        return 1;
    }
    const double checkWallMs = eryx_timing_elapsed_ms(checkStart, EryxTimingClock::now());

    const EryxTimingClock::time_point moduleTypeStart = EryxTimingClock::now();
    Luau::ModulePtr m = frontend.moduleResolver.getModule(mainModule);
    if (!m || !m->returnType) {
        const double moduleTypeMs = eryx_timing_elapsed_ms(moduleTypeStart, EryxTimingClock::now());
        const double callbackMs = timingStats.callbackTotalMs();
        const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
        const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
        const double ownMs = totalMs - estimatedLuauCheckMs - moduleTypeMs;
        eryx_luau_timing_log(
            "typeofModule module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
            "moduleType=%.3fms serialize=0.000ms luau_check_wall=%.3fms luau_check_internal=%.3fms "
            "callbacks=%.3fms readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu "
            "detailed=%d ok=1 hasType=0",
            mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, moduleTypeMs, checkWallMs,
            estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
            timingStats.readSource.calls, timingStats.resolveModule.totalMs,
            timingStats.resolveModule.calls, timingStats.getConfig.totalMs,
            timingStats.getConfig.calls, detailed ? 1 : 0);
        lua_pushnil(L);
        return 1;
    }

    Luau::ToStringOptions o = analysis_type_to_string_options();
    std::string s = Luau::toString(m->returnType, o);
    const double moduleTypeMs = eryx_timing_elapsed_ms(moduleTypeStart, EryxTimingClock::now());

    const EryxTimingClock::time_point serializeStart = EryxTimingClock::now();
    if (detailed) {
        lua_createtable(L, 0, 4);
        lua_pushlstring(L, s.data(), s.size());
        lua_setfield(L, -2, "display");
        lua_pushstring(L, "Module");
        lua_setfield(L, -2, "source");
        AnalysisTypeSerdeCtx ctx;
        analysis_push_typepack_id(L, m->returnType, ctx, 0);
        lua_setfield(L, -2, "typePack");

        std::string moduleName = frontend.fileResolver->getHumanReadableModuleName(m->name);
        if (!moduleName.empty()) {
            lua_pushlstring(L, moduleName.data(), moduleName.size());
            lua_setfield(L, -2, "moduleName");
        }
    } else {
        lua_pushlstring(L, s.data(), s.size());
    }

    const double serializeMs = eryx_timing_elapsed_ms(serializeStart, EryxTimingClock::now());
    const double callbackMs = timingStats.callbackTotalMs();
    const double estimatedLuauCheckMs = std::max(0.0, checkWallMs - callbackMs);
    const double totalMs = eryx_timing_elapsed_ms(totalStart, EryxTimingClock::now());
    const double ownMs = totalMs - estimatedLuauCheckMs - moduleTypeMs;
    eryx_luau_timing_log(
        "typeofModule module=%s bytes=%zu total=%.3fms own=%.3fms setup=%.3fms defs=%.3fms "
        "moduleType=%.3fms serialize=%.3fms luau_check_wall=%.3fms luau_check_internal=%.3fms "
        "callbacks=%.3fms readSource=%.3fms/%zu resolveModule=%.3fms/%zu getConfig=%.3fms/%zu "
        "detailed=%d ok=1 hasType=1",
        mainModule, srcLen, totalMs, ownMs, setupMs, definitionsMs, moduleTypeMs, serializeMs,
        checkWallMs, estimatedLuauCheckMs, callbackMs, timingStats.readSource.totalMs,
        timingStats.readSource.calls, timingStats.resolveModule.totalMs,
        timingStats.resolveModule.calls, timingStats.getConfig.totalMs, timingStats.getConfig.calls,
        detailed ? 1 : 0);

    return 1;
}

#ifdef ERYX_EMBED
int luaG_isnative(lua_State* L, int level);
#else
LUA_API int luaG_isnative(lua_State* L, int level);
#endif
ERYX_API lua_State* eryx_initialise_environment(const char* sourceFilename) {
    eryx_enable_all_luau_flags();

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

        eryx_exception_populate_tb(L, ex, 1);
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
    // TODO: Bring this back once it's not bugged to all hell
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

    // Set _DIR and _FILE
    if (sourceFilename) {
        std::filesystem::path scriptPath = std::filesystem::absolute(sourceFilename);
        std::string scriptDir = scriptPath.parent_path().string();
        std::string scriptFile = scriptPath.string();

        lua_pushstring(L, scriptDir.c_str());
        lua_setglobal(L, "_DIR");

        lua_pushstring(L, scriptFile.c_str());
        lua_setglobal(L, "_FILE");
    }

    // Set _VERSION
    std::string version = "erxy ";
    version += LUAU_APPROX_VERSION;
    version += "-";
    version += LUAU_GIT_HASH;
    lua_pushstring(L, version.c_str());
    lua_setglobal(L, "_VERSION");

    // Sandbox all libraries
    // ! REQUIRED FOR NATIVE CODE GEN
    luaL_sandbox(L);

    return L;
}
