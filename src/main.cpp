#ifdef _WIN32
#define _CRTDBG_MAP_ALLOC
#include <crtdbg.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#include <cctype>
#include <cerrno>
#include <cstdarg>
#include <filesystem>

#include "isocline.h"

// Module API is going to include Windows and UV so needs to come high up
#include "./modules/module_api.h"
// [I exist to stop reordering]

#include "Luau/ExperimentalFlags.h"
// #include "Luau/Profiler.h"

#include "pch.hpp"
#include "runtime/_wrapper_lib.hpp"
#include "runtime/lexception.hpp"
#include "runtime/lrequire.hpp"
#include "runtime/embedded_modules.h"
#include "vfs.hpp"

#ifdef ERYX_EMBED
// Generated tables — defined in embedded_modules.cpp / embedded_sources.cpp
extern const EmbeddedNativeModule  g_embedded_native_modules[];
extern const EmbeddedScriptModule  g_embedded_script_modules[];
#endif

// ---------------------------------------------------------------------------
// Enable ANSI escape-code processing on Windows 10+
// ---------------------------------------------------------------------------
#ifdef _WIN32
static void enable_ansi_colors() {
    for (DWORD id : { STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }) {
        HANDLE h = GetStdHandle(id);
        if (h == INVALID_HANDLE_VALUE) continue;
        DWORD mode = 0;
        if (GetConsoleMode(h, &mode)) SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}
#endif

// ---------------------------------------------------------------------------
// Ctrl+C / Ctrl+Break handler
// ---------------------------------------------------------------------------
static volatile bool g_main_interrupted = false;

#ifdef _WIN32
static BOOL WINAPI main_ctrl_handler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT) {
        g_main_interrupted = true;
        return TRUE;
    }
    return FALSE;
}
// TODO: Re-register this handler so it actually works again
#else
static void main_sigint_handler(int) { g_main_interrupted = true; }
#endif

void eryx_print_error(lua_State* L, int idx) {
    fprintf(stderr, "%s\n", eryx_format_exception(L, idx).c_str());
}

bool eryx_has_work(EryxRuntime* rt) { return !rt->threads.empty() || uv_loop_alive(rt->loop); }

enum class ERYX_RUN_ONCE_STATE { kNoThreads = 0, kError, kSuccess };
ERYX_RUN_ONCE_STATE eryx_run_once(lua_State* GL, EryxRuntime* rt, lua_State** runningLua) {
    uv_run(rt->loop, !rt->threads.empty() ? UV_RUN_NOWAIT : UV_RUN_ONCE);

    if (rt->threads.empty()) {
        return ERYX_RUN_ONCE_STATE::kNoThreads;
    }

    EryxThreadInfo thread = eryx_pop_thread(rt);

    lua_getref(GL, thread.threadRef);
    lua_State* L = lua_tothread(GL, -1);
    if (L == nullptr) {
        fprintf(stderr, "%s found non-thread on threads queue (ref: %d)\n", __func__,
                thread.threadRef);
        return ERYX_RUN_ONCE_STATE::kError;
    }
    *runningLua = L;
    lua_pop(GL, 1);

    // Skip threads that are already dead (e.g. force-spawned while deferred)
    int coStatus = lua_costatus(GL, L);
    if (coStatus != LUA_COSUS) {
        lua_unref(GL, thread.threadRef);
        return ERYX_RUN_ONCE_STATE::kSuccess;
    }

    int status;
    if (thread.inError) {
        status = lua_resumeerror(L, nullptr);
    } else {
        status = lua_resume(L, nullptr, thread.nargs);
    }

    switch (status) {
        case LUA_YIELD:
        case LUA_OK:
            return ERYX_RUN_ONCE_STATE::kSuccess;
        default:
            // Wrap raw string errors into LuaException before the coroutine's
            // frames are discarded. Must happen here while the dead coroutine's
            // call stack is still introspectable via lua_getinfo.
            eryx_coerce_to_exception(L);
            return ERYX_RUN_ONCE_STATE::kError;
    }
}

typedef struct {
    int runOk;
    int exitCode;
} RunState;
RunState eryx_run_to_completion(lua_State* GL, EryxRuntime* rt) {
    while (eryx_has_work(rt)) {
        lua_State* runningLua = NULL;
        auto status = eryx_run_once(GL, rt, &runningLua);
        if (status == ERYX_RUN_ONCE_STATE::kError) {
            if (runningLua) {
                LuaException* exception = eryx_get_exception(runningLua, -1);
                if (exception && strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
                    return RunState{ 2, (int)(intptr_t)(exception->extra) };
                }

                eryx_print_error(runningLua, -1);
            } else {
                fprintf(stderr, "Failed to identify running lua instance for error reporting\n");
            }

            if (!eryx_has_work(rt)) return RunState{ 0, 0 };
        }
    }
    // No work left, and we didn't hit an error path, so we must be good!
    return RunState{ 1, 0 };
}

int main_script(const char* filename, const std::string luauCode) {
    int exitCode = 0;

    uv_loop_t loop;
    try {
        lua_State* GL = eryx_initialise_environment(filename);

        uv_loop_init(&loop);
        EryxRuntime* rt = eryx_setup_runtime(&loop, GL);
        lua_setthreaddata(GL, rt);

        // Set up Ctrl+C handler for the UV loop (unref'd so it won't keep the loop alive)
        uv_signal_t* sigint = new uv_signal_t;
        uv_signal_init(rt->loop, sigint);
        uv_unref((uv_handle_t*)sigint);
        sigint->data = rt;
        rt->sigint = sigint;
        uv_signal_start(
            sigint,
            [](uv_signal_t* handle, int) {
                EryxRuntime* r = (EryxRuntime*)handle->data;
                eryx_interrupt_runtime(r);
            },
            SIGINT);

        // Make thread for the root module
        lua_State* L = lua_newthread(GL);
        luaL_sandboxthread(L);

        if (!eryx_load_and_prepare_script(L, luauCode, std::string("@") + filename)) {
            // Script loading failed!
            eryx_print_error(L, -1);
            lua_pop(GL, 1);

            exitCode = 1;
        } else {
            lua_rawcheckstack(L, 1);
            lua_pushthread(L);
            eryx_push_thread(rt, lua_ref(L, -1), 0, false);
            lua_pop(L, 1);

            RunState ran = eryx_run_to_completion(GL, rt);
            if (ran.runOk == 2) {
                // A system exit error, specifically, was thrown
                exitCode = ran.exitCode;
            } else if (ran.runOk == 0) {
                // Some error was thrown
                exitCode = 1;
            }
        }

        // Close Lua state - GC will collect userdata (Window, Shader, etc.)
        // releasing their GPU resources. Subsystem cleanup (SDL, WGPU, FreeType,
        // miniaudio) is handled by the _gfx module's atexit handler which runs
        // after main() returns.
        lua_close(GL);
        GL = nullptr;

        return exitCode;
    } catch (const std::exception& e) {
        std::cerr << "Unhandled exception: " << e.what() << std::endl;
        return 1;
    }
}

void
#if _WIN32
    __declspec(noreturn)
#else
    __attribute__((noreturn))
#endif
    main_raise_usage(const char* argv[], const char* format, ...) {
    va_list args;
    va_start(args, format);

    fprintf(stderr, "Usage: %s ", argv[0]);
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");

    va_end(args);
    exit(-1);
}

// TODO: This!
static bool is_line_complete(lua_State* L, int status) {
    if (status != LUA_ERRSYNTAX) return false;

    const char* msg = lua_tostring(L, -1);
    if (!msg) return true;

    // Luau/Lua parser uses <eof> marker for incomplete chunks
    return strstr(msg, "<eof>") == nullptr;
}

typedef struct {
    bool ok;
    bool systemExit;
    int exitCode;
    std::string error;
} ReplRunResult;

static bool repl_is_ident_start(char c) {
    unsigned char uc = (unsigned char)c;
    return std::isalpha(uc) || c == '_';
}

static bool repl_is_ident_continue(char c) {
    unsigned char uc = (unsigned char)c;
    return std::isalnum(uc) || c == '_';
}

static bool repl_matches_token(const char* s, long len, const char* token) {
    size_t tlen = strlen(token);
    return len == (long)tlen && strncmp(s, token, tlen) == 0;
}

static bool repl_long_bracket_open(const char* input, long i, int* eqCount, long* contentStart) {
    if (input[i] != '[') return false;

    long j = i + 1;
    int eq = 0;
    while (input[j] == '=') {
        eq++;
        j++;
    }

    if (input[j] != '[') return false;

    *eqCount = eq;
    *contentStart = j + 1;
    return true;
}

static long repl_find_long_bracket_close(const char* input, long i, int eqCount) {
    while (input[i] != '\0') {
        if (input[i] == ']') {
            long j = i + 1;
            int seenEq = 0;
            while (input[j] == '=') {
                seenEq++;
                j++;
            }

            if (seenEq == eqCount && input[j] == ']') {
                return j + 1;
            }
        }
        i++;
    }

    return i;
}

static void repl_highlight(ic_highlight_env_t* henv, const char* input, void* /*arg*/) {
    long i = 0;

    while (input[i] != '\0') {
        // -- line comments and --[[ block comments ]]
        if (input[i] == '-' && input[i + 1] == '-') {
            long start = i;
            i += 2;

            int eqCount = 0;
            long contentStart = 0;
            if (repl_long_bracket_open(input, i, &eqCount, &contentStart)) {
                i = repl_find_long_bracket_close(input, contentStart, eqCount);
            } else {
                while (input[i] != '\0' && input[i] != '\n') i++;
            }

            ic_highlight(henv, start, i - start, "comment");
            continue;
        }

        // Strings: "..." and '...'
        if (input[i] == '"' || input[i] == '\'') {
            char quote = input[i];
            long start = i++;

            while (input[i] != '\0') {
                if (input[i] == '\\' && input[i + 1] != '\0') {
                    i += 2;
                    continue;
                }
                if (input[i] == quote) {
                    i++;
                    break;
                }
                i++;
            }

            ic_highlight(henv, start, i - start, "string");
            continue;
        }

        // Long bracket strings: [[...]] and [=[...]=] etc.
        {
            int eqCount = 0;
            long contentStart = 0;
            if (repl_long_bracket_open(input, i, &eqCount, &contentStart)) {
                long start = i;
                i = repl_find_long_bracket_close(input, contentStart, eqCount);
                ic_highlight(henv, start, i - start, "string");
                continue;
            }
        }

        // Numbers (decimal/hex with separators, fractions, and exponents)
        if (std::isdigit((unsigned char)input[i]) ||
            (input[i] == '.' && std::isdigit((unsigned char)input[i + 1]))) {
            long start = i;

            if (input[i] == '.') i++;

            if (input[i] == '0' && (input[i + 1] == 'x' || input[i + 1] == 'X')) {
                i += 2;
                while (std::isxdigit((unsigned char)input[i]) || input[i] == '_') i++;

                if (input[i] == '.') {
                    i++;
                    while (std::isxdigit((unsigned char)input[i]) || input[i] == '_') i++;
                }

                if (input[i] == 'p' || input[i] == 'P') {
                    i++;
                    if (input[i] == '+' || input[i] == '-') i++;
                    while (std::isdigit((unsigned char)input[i]) || input[i] == '_') i++;
                }
            } else {
                while (std::isdigit((unsigned char)input[i]) || input[i] == '_') i++;
                if (input[i] == '.') {
                    i++;
                    while (std::isdigit((unsigned char)input[i]) || input[i] == '_') i++;
                }
                if (input[i] == 'e' || input[i] == 'E') {
                    i++;
                    if (input[i] == '+' || input[i] == '-') i++;
                    while (std::isdigit((unsigned char)input[i]) || input[i] == '_') i++;
                }
            }

            ic_highlight(henv, start, i - start, "number");
            continue;
        }

        // Keywords/constants
        if (repl_is_ident_start(input[i])) {
            long start = i++;
            while (repl_is_ident_continue(input[i])) i++;

            long len = i - start;
            const char* tok = input + start;

            if (repl_matches_token(tok, len, "and") || repl_matches_token(tok, len, "break") ||
                repl_matches_token(tok, len, "do") || repl_matches_token(tok, len, "else") ||
                repl_matches_token(tok, len, "elseif") || repl_matches_token(tok, len, "end") ||
                repl_matches_token(tok, len, "for") || repl_matches_token(tok, len, "function") ||
                repl_matches_token(tok, len, "if") || repl_matches_token(tok, len, "in") ||
                repl_matches_token(tok, len, "local") || repl_matches_token(tok, len, "not") ||
                repl_matches_token(tok, len, "or") || repl_matches_token(tok, len, "repeat") ||
                repl_matches_token(tok, len, "return") || repl_matches_token(tok, len, "then") ||
                repl_matches_token(tok, len, "until") || repl_matches_token(tok, len, "while")) {
                ic_highlight(henv, start, len, "keyword");
            } else if (repl_matches_token(tok, len, "nil") ||
                       repl_matches_token(tok, len, "true") ||
                       repl_matches_token(tok, len, "false")) {
                ic_highlight(henv, start, len, "constant");
            }

            continue;
        }

        i++;
    }
}

static ReplRunResult repl_run_snippet(lua_State* L, const std::string& source) {
    lua_checkstack(L, LUA_MINSTACK);
    const int base = lua_gettop(L);

    Luau::CompileOptions opts;
    opts.optimizationLevel = 2;
    opts.debugLevel = 1;
    opts.typeInfoLevel = 1;

    std::string bytecode = Luau::compile(source, opts);

    if (luau_load(L, "=stdin", bytecode.data(), bytecode.size(), 0) != 0) {
        std::string error = eryx_format_exception(L, -1);
        lua_settop(L, base);
        return ReplRunResult{ false, false, 0, error };
    }

    int status = lua_pcall(L, 0, LUA_MULTRET, 0);

    if (status == LUA_OK) {
        int n = lua_gettop(L) - base;

        if (n) {
            luaL_checkstack(L, LUA_MINSTACK, "too many results to print");

            lua_getglobal(L, "print");
            lua_insert(L, base + 1);

            if (lua_pcall(L, n, 0, 0) != LUA_OK) {
                LuaException* exception = eryx_get_exception(L, -1);
                if (exception && strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
                    int code = (int)(intptr_t)(exception->extra);
                    lua_settop(L, base);
                    return ReplRunResult{ false, true, code, std::string() };
                }

                std::string error = eryx_format_exception(L, -1);

                lua_settop(L, base);
                return ReplRunResult{ false, false, 0, error };
            }
        }

        lua_settop(L, base);
        return ReplRunResult{ true, false, 0, std::string() };
    } else {
        if (status == LUA_YIELD) {
            lua_settop(L, base);
            return ReplRunResult{ false, false, 0, "thread yielded unexpectedly" };
        }

        LuaException* exception = eryx_get_exception(L, -1);
        if (exception && strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
            int code = (int)(intptr_t)(exception->extra);
            lua_settop(L, base);
            return ReplRunResult{ false, true, code, std::string() };
        }

        std::string error = eryx_format_exception(L, -1);

        lua_settop(L, base);
        return ReplRunResult{ false, false, 0, error };
    }
}

int main_repl() {
    fprintf(stdout, "Erxy (Luau %s, %.8s)\n", LUAU_APPROX_VERSION, LUAU_GIT_HASH);
    std::cout << "Type \"help\" for help" << std::endl;

    lua_State* GL = eryx_initialise_environment(nullptr);

    // Run REPL in a persistent sandboxed thread so writes go to thread globals,
    // while inheriting readonly sandboxed base globals from the main state.
    lua_State* L = lua_newthread(GL);
    luaL_sandboxthread(L);

    // We could yoink this from the Luau Repl later, but for now we won't
    // ic_set_default_completer(completeRepl, L);

    setlocale(LC_ALL, "C");
    ic_set_prompt_marker("", "");
    ic_set_default_highlighter(repl_highlight, nullptr);
    ic_enable_highlight(true);
    ic_style_def("keyword", "ansi-blue");
    ic_style_def("constant", "ansi-cyan");
    ic_style_def("number", "ansi-yellow");
    ic_style_def("string", "ansi-red");
    ic_style_def("comment", "ansi-green");
    ic_style_def("ic-bracematch", "teal");
    ic_enable_brace_insertion(false);

    // loadHistory(".luau_history");

    int exitCode = 0;
    bool ctrlCArmed = false;
    std::string buffer;

    while (1) {
        const char* prompt = buffer.empty() ? ">> " : ".. ";
        std::unique_ptr<char, void (*)(void*)> line(ic_readline(prompt), free);

        if (!line) {
            bool interrupted = g_main_interrupted || errno == EINTR;
            g_main_interrupted = false;

            if (!interrupted && feof(stdin)) {
                break;
            }

            if (!ctrlCArmed) {
                std::cerr << "Press ctrl+C again to exit" << std::endl;
                ctrlCArmed = true;
                buffer.clear();
                clearerr(stdin);
                continue;
            }

            exitCode = 130;
            break;
        }

        ctrlCArmed = false;

        if (buffer.empty()) {
            ReplRunResult exprResult = repl_run_snippet(L, std::string("return ") + line.get());
            if (exprResult.systemExit) {
                exitCode = exprResult.exitCode;
                break;
            }
            if (exprResult.ok) {
                ic_history_add(line.get());
                continue;
            }
        }

        if (!buffer.empty()) buffer += "\n";
        buffer += line.get();

        ReplRunResult result = repl_run_snippet(L, buffer);

        if (result.systemExit) {
            exitCode = result.exitCode;
            break;
        }

        if (result.error.find("<eof>") != std::string::npos) {
            continue;
        }

        if (!result.ok && result.error.length()) {
            fprintf(stdout, "%s\n", result.error.c_str());
        }

        ic_history_add(buffer.c_str());
        buffer.clear();
    }

    lua_close(GL);

    return exitCode;
}

static std::filesystem::path getScriptsDir() {
    namespace fs = std::filesystem;
#if defined(_WIN32)
    wchar_t exebuf[MAX_PATH];
    DWORD exelen = GetModuleFileNameW(nullptr, exebuf, MAX_PATH);
    return fs::path(std::wstring(exebuf, exelen)).parent_path() / "scripts";
#elif defined(__APPLE__)
    char exebuf[4096];
    uint32_t exelen = sizeof(exebuf);
    _NSGetExecutablePath(exebuf, &exelen);
    return fs::canonical(exebuf).parent_path() / "scripts";
#else
    return fs::canonical("/proc/self/exe").parent_path() / "scripts";
#endif
}

// Try to run a built-in script from the scripts/ directory next to the executable.
// Returns -1 if the script doesn't exist (caller should fall through).
int main_builtin_script(int argc, const char* argv[], const char* name) {
    namespace fs = std::filesystem;
    fs::path scriptPath = getScriptsDir() / (std::string(name) + ".luau");

    if (!fs::exists(scriptPath)) return -1;

    std::ifstream f(scriptPath, std::ios::binary);
    if (!f) {
        std::cerr << "Failed to read " << scriptPath << std::endl;
        return 1;
    }
    std::string source((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    // "eryx <command> [args...]" -> user args start at argv[2]
    eryx_set_cliargs_offset(2);
    return main_script(scriptPath.string().c_str(), source);
}

int main_run(const char* filename) {
    std::ifstream script_file(filename);
    if (!script_file.is_open()) {
        std::cerr << "Failed to open " << filename << std::endl;
        std::cerr << std::filesystem::current_path() << std::endl;

        while (1);
        return 1;
    }
    std::string luaScript((std::istreambuf_iterator<char>(script_file)),
                          std::istreambuf_iterator<char>());
    script_file.close();

    return main_script(filename, luaScript);
}

int main(int argc, const char* argv[]) {
    eryx_set_cliargs(argc, argv);
#ifdef ERYX_EMBED
    eryx_register_embedded_modules(g_embedded_native_modules, g_embedded_script_modules);
#endif
#ifdef _WIN32
    // On windows, we're going to force ANSI escape sequences in CMD
    enable_ansi_colors();
#endif

    // VFS entrypoint execution
    if (vfs_open()) {
        auto entry = vfs_get_entrypoint();
        auto entryData = vfs_read_file(std::string(entry));

        if (!entry.ends_with(".luau")) {
            std::cerr << "Entrypoint " << entry << " not a luau source file!";
            return -1;
        }

        // VFS: skip just the exe (argv[0]), user args start at argv[1]
        eryx_set_cliargs_offset(1);

        // Build the chunk name with the @@vfs/ prefix.
        // main_script prepends "@" to its filename argument, so we pass
        // the entry prefixed with just "@vfs/" — the outer "@" produces "@@vfs/…".
        std::string vfsChunkName = std::string("@vfs/") + std::string(entry);
        return main_script(
            vfsChunkName.c_str(),
            std::string(std::string_view((char*)entryData.data(), entryData.size())));
    }

    if (argc < 2) {
        return main_repl();
    }
    const char* command = argv[1];
    const char* filename = argv[1];

    if (strcmp(command, "run") == 0) {
        if (argc < 3) {
            main_raise_usage(argv, "run <script>");
            return -1;
        }
        // "eryx run script.luau ..." -> skip exe, "run", and script path
        eryx_set_cliargs_offset(3);
        return main_run(argv[2]);
    }

    // If the argument has no file extension and no file with that exact name
    // exists in the cwd, try to run a built-in script from scripts/<command>.luau
    namespace fs = std::filesystem;
    std::string cmdStr(command);
    if (cmdStr.find('.') == std::string::npos && !fs::exists(cmdStr)) {
        int result = main_builtin_script(argc, argv, command);
        if (result != -1) return result;
    }

    // "eryx script.luau ..." -> skip exe and script path
    eryx_set_cliargs_offset(2);
    return main_run(command);
}
