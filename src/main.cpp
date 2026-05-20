#ifdef _WIN32
#define _CRTDBG_MAP_ALLOC
#include <crtdbg.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdarg>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>

#include "isocline.h"

// Module API is going to include Windows and UV so needs to come high up
#include "./modules/module_api.h"
// [I exist to stop reordering]

#include "Luau/ExperimentalFlags.h"
// #include "Luau/Profiler.h"

#include "pch.hpp"
#include "runtime/_wrapper_lib.hpp"
#include "runtime/embedded_modules.h"
#include "runtime/lexception.hpp"
#include "runtime/lrequire.hpp"
#include "runtime/runtime_host.hpp"
#include "vfs.hpp"

#ifdef ERYX_EMBED
// Generated tables - defined in embedded_modules.cpp / embedded_sources.cpp
extern const EmbeddedNativeModule g_embedded_native_modules[];
extern const EmbeddedScriptModule g_embedded_script_modules[];
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

static bool should_use_ansi_for_fd(int fd) {
    if (std::getenv("NO_COLOR")) return false;
    if (std::getenv("FORCE_COLOR")) return true;
    return uv_guess_handle(fd) == UV_TTY;
}

void eryx_print_error(lua_State* L, int idx) {
    fprintf(stderr, "%s\n", eryx_format_exception(L, idx, should_use_ansi_for_fd(2)).c_str());
}

typedef struct {
    int runOk;
    int exitCode;
} RunState;
RunState eryx_run_to_completion(EryxRuntimeHost* host) {
    while (eryx_runtime_has_work(host->rt)) {
        lua_State* runningLua = NULL;
        auto status = eryx_runtime_run_once(host, &runningLua);
        if (status == EryxRuntimeRunResult::Error) {
            if (runningLua) {
                LuaException* exception = eryx_get_exception(runningLua, -1);
                if (exception && strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
                    return RunState{ 2, (int)(intptr_t)(exception->extra) };
                }

                eryx_print_error(runningLua, -1);
            } else {
                fprintf(stderr, "Failed to identify running lua instance for error reporting\n");
            }

            if (!eryx_runtime_has_work(host->rt)) return RunState{ 0, 0 };
        }
    }
    // No work left, and we didn't hit an error path, so we must be good!
    return RunState{ 1, 0 };
}

int main_script(const char* filename, const std::string luauCode) {
    int exitCode = 0;
    try {
        EryxRuntimeHost host;
        if (!eryx_runtime_host_init(&host, filename)) {
            std::cerr << "Failed to create Lua state" << std::endl;
            return 1;
        }
        eryx_runtime_host_install_sigint(&host);

        // Make thread for the root module
        lua_State* L = eryx_runtime_host_create_thread(&host);

        if (!eryx_load_and_prepare_script(L, luauCode, std::string("@") + filename)) {
            // Script loading failed!
            eryx_print_error(L, -1);
            lua_pop(host.GL, 1);

            exitCode = 1;
        } else {
            eryx_runtime_host_enqueue_thread(&host, L, 0, false);

            RunState ran = eryx_run_to_completion(&host);
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
        eryx_runtime_host_close(&host);

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
        std::string error = eryx_format_exception(L, -1, should_use_ansi_for_fd(1));
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

                std::string error = eryx_format_exception(L, -1, should_use_ansi_for_fd(1));

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

        std::string error = eryx_format_exception(L, -1, should_use_ansi_for_fd(1));

        lua_settop(L, base);
        return ReplRunResult{ false, false, 0, error };
    }
}

int main_repl() {
    fprintf(stdout, "Eryx (Luau %s, %.8s)\n", LUAU_APPROX_VERSION, LUAU_GIT_HASH);
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

static std::filesystem::path getExecutablePath() {
    namespace fs = std::filesystem;
#if defined(_WIN32)
    wchar_t exebuf[MAX_PATH];
    DWORD exelen = GetModuleFileNameW(nullptr, exebuf, MAX_PATH);
    return fs::path(std::wstring(exebuf, exelen));
#elif defined(__APPLE__)
    char exebuf[4096];
    uint32_t exelen = sizeof(exebuf);
    _NSGetExecutablePath(exebuf, &exelen);
    return fs::canonical(exebuf);
#else
    return fs::canonical("/proc/self/exe");
#endif
}

static std::filesystem::path getScriptsDir() {
    return getExecutablePath().parent_path() / "scripts";
}

static const EmbeddedScriptModule* find_embedded_builtin_script(const std::string& name) {
#ifdef ERYX_EMBED
    std::string key = "scripts/" + name;
    auto* scripts = eryx_get_embedded_script_modules();
    if (scripts) {
        for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
            if (key == m->modulePath) return m;
        }
    }
#else
    (void)name;
#endif
    return nullptr;
}

static std::string shell_single_quote(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        if (ch == '\'') {
            out += "'\"'\"'";
        } else {
            out += ch;
        }
    }
    return out;
}

static std::string powershell_single_quote(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 4);
    for (char ch : value) {
        if (ch == '\'') {
            out += "''";
        } else {
            out += ch;
        }
    }
    return out;
}

static bool is_completion_shell(const std::string& shell) {
    return shell == "bash" || shell == "zsh" || shell == "fish" || shell == "powershell";
}

static std::filesystem::path completion_debug_log_path() {
    const char* env = std::getenv("ERYX_COMPLETION_DEBUG");
    if (!env || !*env) return {};

    if (strcmp(env, "1") == 0) {
        return std::filesystem::temp_directory_path() / "eryx-completion.log";
    }

    return std::filesystem::path(env);
}

static void completion_debug_log(const std::string& message) {
    std::filesystem::path path = completion_debug_log_path();
    if (path.empty()) return;

    std::ofstream out(path, std::ios::app | std::ios::binary);
    if (!out) return;

    out << message << "\n";
}

static std::vector<std::string> list_builtin_scripts() {
    namespace fs = std::filesystem;
    std::vector<std::string> names;

#ifdef ERYX_EMBED
    auto* scripts = eryx_get_embedded_script_modules();
    if (scripts) {
        constexpr const char* prefix = "scripts/";
        constexpr size_t prefixLen = 8;
        for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
            if (strncmp(m->modulePath, prefix, prefixLen) == 0) {
                names.emplace_back(m->modulePath + prefixLen);
            }
        }
    }
#endif

    fs::path scriptsDir = getScriptsDir();

    if (fs::exists(scriptsDir) && fs::is_directory(scriptsDir)) {
        for (const auto& entry : fs::directory_iterator(scriptsDir)) {
            if (!entry.is_regular_file()) continue;
            fs::path path = entry.path();
            if (path.extension() == ".luau") {
                names.push_back(path.stem().string());
            }
        }
    }

    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    return names;
}

static void print_completion_candidates(std::vector<std::string> values) {
    std::sort(values.begin(), values.end());
    values.erase(std::unique(values.begin(), values.end()), values.end());
    for (const std::string& value : values) {
        std::cout << value << "\n";
    }
}

static void set_process_env(const char* key, const char* value) {
#ifdef _WIN32
    _putenv_s(key, value ? value : "");
#else
    if (value) {
        setenv(key, value, 1);
    } else {
        unsetenv(key);
    }
#endif
}

struct ScopedEnvVar {
    std::string key;
    bool hadValue = false;
    std::string previousValue;

    ScopedEnvVar(const char* envKey, const char* envValue) : key(envKey) {
        const char* existing = std::getenv(envKey);
        if (existing) {
            hadValue = true;
            previousValue = existing;
        }
        set_process_env(envKey, envValue);
    }

    ~ScopedEnvVar() {
        if (hadValue) {
            set_process_env(key.c_str(), previousValue.c_str());
        } else {
            set_process_env(key.c_str(), nullptr);
        }
    }
};

static int main_complete_script_source(const std::string& displayName, const std::string& source,
                                       int cliOffset, const char* shell) {
    if (source.find("@eryx/argparse") == std::string::npos) {
        completion_debug_log("main_complete_script: script does not use @eryx/argparse");
        return 0;
    }
    completion_debug_log("main_complete_script: invoking script in completion mode");
    ScopedEnvVar completionMode("ERYX_ARGPARSE_COMPLETE", "1");
    ScopedEnvVar completionShell("ERYX_ARGPARSE_COMPLETE_SHELL", shell ? shell : "");

    eryx_set_cliargs_offset(cliOffset);
    return main_script(displayName.c_str(), source);
}

static int main_complete_script(const std::filesystem::path& scriptPath, int cliOffset,
                                const char* shell) {
    completion_debug_log("main_complete_script: path=" + scriptPath.string() + " cliOffset=" +
                         std::to_string(cliOffset) + " shell=" + (shell ? shell : ""));

    std::ifstream f(scriptPath, std::ios::binary);
    if (!f) {
        completion_debug_log("main_complete_script: failed to read script");
        std::cerr << "Failed to read " << scriptPath << std::endl;
        return 1;
    }

    std::string source((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return main_complete_script_source(scriptPath.string(), source, cliOffset, shell);
}

static std::string render_completion_script(const std::string& programName,
                                            const std::string& shell) {
    const std::string shellProgram = shell_single_quote(programName);
    const std::string powershellProgram = powershell_single_quote(programName);

    if (shell == "bash") {
        return "__eryx_dynamic_complete() {\n"
               "    local cur i\n"
               "    local -a words suggestions\n"
               "    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n"
               "    words=()\n"
               "    for ((i = 1; i < COMP_CWORD; i++)); do\n"
               "        words+=(\"${COMP_WORDS[i]}\")\n"
               "    done\n"
               "    mapfile -t suggestions < <('" +
               shellProgram +
               "' __complete bash \"${words[@]}\" 2>/dev/null)\n"
               "    if (( ${#suggestions[@]} > 0 )); then\n"
               "        COMPREPLY=( $(compgen -W \"$(printf '%s ' \"${suggestions[@]}\")\" -- "
               "\"$cur\") )\n"
               "    else\n"
               "        COMPREPLY=( $(compgen -f -- \"$cur\") )\n"
               "    fi\n"
               "    return 0\n"
               "}\n"
               "complete -o bashdefault -o default -F __eryx_dynamic_complete '" +
               shellProgram + "'\n";
    }

    if (shell == "zsh") {
        return "__eryx_dynamic_complete() {\n"
               "    local -a tokens suggestions filtered\n"
               "    local cur\n"
               "    local debug_path\n"
               "    cur=${words[CURRENT]}\n"
               "    tokens=(${words[2,CURRENT-1]})\n"
               "    debug_path=${ERYX_COMPLETION_DEBUG:-}\n"
               "    if [[ -n \"$debug_path\" ]]; then\n"
               "        if [[ \"$debug_path\" == \"1\" ]]; then\n"
               "            debug_path=${TMPDIR:-/tmp}/eryx-completion.log\n"
               "        fi\n"
               "        print -r -- \"zsh wrapper: cur=$cur tokens=${(j: :)tokens}\" >> "
               "\"$debug_path\"\n"
               "    fi\n"
               "    suggestions=(${(f)\"$('" +
               shellProgram +
               "' __complete zsh ${tokens[@]} 2>/dev/null)\"})\n"
               "    if [[ -n \"$debug_path\" ]]; then\n"
               "        print -r -- \"zsh wrapper: suggestions=${(j:,:)suggestions}\" >> "
               "\"$debug_path\"\n"
               "    fi\n"
               "    filtered=(${(M)suggestions:#" +
               "${cur}" +
               "*})\n"
               "    if (( ${#filtered[@]} > 0 )); then\n"
               "        compadd -Q -- ${filtered[@]}\n"
               "    else\n"
               "        _files\n"
               "    fi\n"
               "}\n"
               "compdef __eryx_dynamic_complete '" +
               shellProgram + "'\n";
    }

    if (shell == "fish") {
        return "function __eryx_dynamic_complete\n"
               "    set -l tokens (commandline -opc)\n"
               "    if test (count $tokens) -gt 0\n"
               "        set -e tokens[1]\n"
               "    end\n"
               "    '" +
               shellProgram +
               "' __complete fish $tokens 2>/dev/null\n"
               "end\n"
               "complete -c '" +
               shellProgram + "' -a '(__eryx_dynamic_complete)'\n";
    }

    if (shell == "powershell") {
        return "$__eryxCommandNames = "
               "[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::"
               "OrdinalIgnoreCase)\n"
               "$null = $__eryxCommandNames.Add('" +
               powershellProgram +
               "')\n"
               "$__eryxLeaf = [System.IO.Path]::GetFileName('" +
               powershellProgram +
               "')\n"
               "if ($__eryxLeaf) {\n"
               "    $null = $__eryxCommandNames.Add($__eryxLeaf)\n"
               "    $null = $__eryxCommandNames.Add('.\\' + $__eryxLeaf)\n"
               "    if ($__eryxLeaf.EndsWith('.exe', "
               "[System.StringComparison]::OrdinalIgnoreCase)) {\n"
               "        $__eryxStem = [System.IO.Path]::GetFileNameWithoutExtension($__eryxLeaf)\n"
               "        if ($__eryxStem) {\n"
               "            $null = $__eryxCommandNames.Add($__eryxStem)\n"
               "            $null = $__eryxCommandNames.Add('.\\' + $__eryxStem)\n"
               "        }\n"
               "    }\n"
               "}\n"
               "$__eryxScriptBlock = {\n"
               "    param($wordToComplete, $commandAst, $cursorPosition)\n"
               "\n"
               "    $tokens = @()\n"
               "    foreach ($element in $commandAst.CommandElements | Select-Object -Skip 1) {\n"
               "        if ($element.Extent.EndOffset -lt $cursorPosition) {\n"
               "            $tokens += $element.Extent.Text\n"
               "        }\n"
               "    }\n"
               "\n"
               "    $__eryxDebugPath = $env:ERYX_COMPLETION_DEBUG\n"
               "    if ($__eryxDebugPath) {\n"
               "        if ($__eryxDebugPath -eq '1') {\n"
               "            $__eryxDebugPath = Join-Path $env:TEMP 'eryx-completion.log'\n"
               "        }\n"
               "        Add-Content -LiteralPath $__eryxDebugPath -Value (\"pwsh wrapper: word=\" "
               "+ $wordToComplete + \" tokens=\" + ($tokens -join ' '))\n"
               "    }\n"
               "\n"
               "    $candidates = & '" +
               powershellProgram +
               "' __complete powershell @tokens 2>$null\n"
               "    if ($__eryxDebugPath) {\n"
               "        Add-Content -LiteralPath $__eryxDebugPath -Value (\"pwsh wrapper: "
               "candidates=\" + ($candidates -join ','))\n"
               "    }\n"
               "    foreach ($candidate in $candidates) {\n"
               "        if ($candidate -like \"$wordToComplete*\") {\n"
               "            [System.Management.Automation.CompletionResult]::new($candidate, "
               "$candidate, 'ParameterValue', $candidate)\n"
               "        }\n"
               "    }\n"
               "}\n"
               "foreach ($__eryxName in $__eryxCommandNames) {\n"
               "    Register-ArgumentCompleter -Native -CommandName $__eryxName -ScriptBlock "
               "$__eryxScriptBlock\n"
               "}\n";
    }

    return "";
}

static int main_complete(int argc, const char* argv[]) {
    namespace fs = std::filesystem;

    if (argc < 2) {
        main_raise_usage(argv, "__complete [shell] [words...]");
        return -1;
    }

    std::string shell = "generic";
    int wordsStart = 2;
    if (argc >= 3 && is_completion_shell(argv[2])) {
        shell = argv[2];
        wordsStart = 3;
    }

    std::vector<std::string> words;
    for (int i = wordsStart; i < argc; ++i) {
        words.emplace_back(argv[i]);
    }
    {
        std::ostringstream ss;
        ss << "main_complete: shell=" << shell << " words=";
        for (size_t i = 0; i < words.size(); ++i) {
            if (i) ss << " ";
            ss << words[i];
        }
        completion_debug_log(ss.str());
    }

    if (words.empty()) {
        auto builtins = list_builtin_scripts();
        builtins.push_back("completion");
        builtins.push_back("run");
        completion_debug_log("main_complete: returning top-level candidates");
        print_completion_candidates(builtins);
        return 0;
    }

    if (words[0] == "run") {
        if (words.size() < 2) return 0;

        fs::path scriptPath = words[1];
        if (fs::exists(scriptPath)) {
            completion_debug_log("main_complete: dispatching to run script " + scriptPath.string());
            return main_complete_script(scriptPath, wordsStart + 2, shell.c_str());
        }
        completion_debug_log("main_complete: run script does not exist");
        return 0;
    }

    if (words[0] == "completion") {
        completion_debug_log("main_complete: returning completion shell names");
        print_completion_candidates({ "bash", "fish", "powershell", "zsh" });
        return 0;
    }

    if (words[0].find('.') == std::string::npos && !fs::exists(words[0])) {
        if (const EmbeddedScriptModule* builtin = find_embedded_builtin_script(words[0])) {
            std::string displayName = "@eryx/scripts/" + words[0];
            completion_debug_log("main_complete: dispatching to embedded builtin script " +
                                 displayName);
            return main_complete_script_source(displayName, builtin->source, wordsStart + 1,
                                               shell.c_str());
        }

        fs::path builtinPath = getScriptsDir() / (words[0] + ".luau");
        if (fs::exists(builtinPath)) {
            completion_debug_log("main_complete: dispatching to builtin script " +
                                 builtinPath.string());
            return main_complete_script(builtinPath, wordsStart + 1, shell.c_str());
        }
        completion_debug_log("main_complete: builtin script not found for " + words[0]);
    }

    fs::path scriptPath = words[0];
    if (fs::exists(scriptPath)) {
        completion_debug_log("main_complete: dispatching to explicit script " +
                             scriptPath.string());
        return main_complete_script(scriptPath, wordsStart + 1, shell.c_str());
    }

    completion_debug_log("main_complete: no completion target matched");
    return 0;
}

// Try to run a built-in script from the scripts/ directory next to the executable.
// Returns -1 if the script doesn't exist (caller should fall through).
int main_builtin_script(int argc, const char* argv[], const char* name) {
    namespace fs = std::filesystem;
    (void)argc;
    (void)argv;

    if (const EmbeddedScriptModule* builtin = find_embedded_builtin_script(name)) {
        std::string displayName = std::string("@eryx/scripts/") + name;
        // "eryx <command> [args...]" -> user args start at argv[2]
        eryx_set_cliargs_offset(2);
        return main_script(displayName.c_str(), builtin->source);
    }

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
        std::cerr << "Failed to open file \"" << filename << "\"" << std::endl;
        return 1;
    }
    std::string luaScript((std::istreambuf_iterator<char>(script_file)),
                          std::istreambuf_iterator<char>());
    script_file.close();

    return main_script(filename, luaScript);
}

int main(int argc, const char* argv[]) {
    // puts("Wait for debugger");
    // while (!IsDebuggerPresent());
    // puts("go");

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
        // the entry prefixed with just "@vfs/" - the outer "@" produces "@@vfs/…".
        std::string vfsChunkName = std::string("@vfs/") + std::string(entry);
        return main_script(vfsChunkName.c_str(), std::string(std::string_view(
                                                     (char*)entryData.data(), entryData.size())));
    }

    if (argc < 2) {
        return main_repl();
    }
    const char* command = argv[1];
    const char* filename = argv[1];

    if (strcmp(command, "__complete") == 0) {
        return main_complete(argc, argv);
    }

    if (strcmp(command, "completion") == 0) {
        if (argc < 3) {
            main_raise_usage(argv, "completion <bash|zsh|fish|powershell>");
            return -1;
        }

        std::string output = render_completion_script(argv[0], argv[2]);
        if (output.empty()) {
            std::cerr << "Unsupported shell '" << argv[2] << "'" << std::endl;
            return 1;
        }

        std::cout << output;
        return 0;
    }

    if (strcmp(command, "__run-file") == 0) {
        if (argc < 3) {
            main_raise_usage(argv, "__run-file <script>");
            return -1;
        }
        // Internal helper used by scripts/run.luau after it has resolved a
        // project script name to a concrete file path.
        eryx_set_cliargs_offset(3);
        return main_run(argv[2]);
    }

    if (strcmp(command, "run") == 0) {
        if (argc < 3) {
            main_raise_usage(argv, "run <script>");
            return -1;
        }
        ScopedEnvVar exePath("ERYX_EXE_PATH", getExecutablePath().string().c_str());
        int result = main_builtin_script(argc, argv, "run");
        if (result != -1) return result;

        // Fallback for distributions missing scripts/run.luau.
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
