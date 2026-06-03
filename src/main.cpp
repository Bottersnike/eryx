#ifdef _WIN32
#define _CRTDBG_MAP_ALLOC
#include <crtdbg.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
// clang-format off
#include <windows.h>
#include <shellapi.h>
// clang-format on
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdarg>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string_view>
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
// Crash handler (Windows only)
// ---------------------------------------------------------------------------
#ifdef _WIN32
#include <dbghelp.h>

// WriteFile directly — safe in crash context, guaranteed to flush, no heap.
static void eryx_crash_write(const char* s, DWORD len) {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    if (h && h != INVALID_HANDLE_VALUE) WriteFile(h, s, len, nullptr, nullptr);
}

static void eryx_crash_puts(const char* s) { eryx_crash_write(s, static_cast<DWORD>(strlen(s))); }

static void eryx_crash_printf(const char* fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0)
        eryx_crash_write(buf, static_cast<DWORD>(n < (int)sizeof(buf) ? n : sizeof(buf) - 1));
}

static void eryx_print_stack_trace(CONTEXT* ctx) {
    HANDLE process = GetCurrentProcess();
    HANDLE thread = GetCurrentThread();

    SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
    SymInitialize(process, nullptr, TRUE);

    STACKFRAME64 frame = {};
#ifdef _M_AMD64
    DWORD machine = IMAGE_FILE_MACHINE_AMD64;
    frame.AddrPC.Offset = ctx->Rip;
    frame.AddrFrame.Offset = ctx->Rbp;
    frame.AddrStack.Offset = ctx->Rsp;
#else
    DWORD machine = IMAGE_FILE_MACHINE_I386;
    frame.AddrPC.Offset = ctx->Eip;
    frame.AddrFrame.Offset = ctx->Ebp;
    frame.AddrStack.Offset = ctx->Esp;
#endif
    frame.AddrPC.Mode = frame.AddrFrame.Mode = frame.AddrStack.Mode = AddrModeFlat;

    char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
    SYMBOL_INFO* sym = reinterpret_cast<SYMBOL_INFO*>(symBuf);
    sym->SizeOfStruct = sizeof(SYMBOL_INFO);
    sym->MaxNameLen = MAX_SYM_NAME;

    IMAGEHLP_LINE64 line;
    line.SizeOfStruct = sizeof(IMAGEHLP_LINE64);

    eryx_crash_puts("Stack trace:\n");
    for (int i = 0; i < 48; ++i) {
        if (!StackWalk64(machine, process, thread, &frame, ctx, nullptr, SymFunctionTableAccess64,
                         SymGetModuleBase64, nullptr))
            break;
        if (!frame.AddrPC.Offset) break;

        DWORD64 symOff = 0;
        DWORD lineOff = 0;
        if (SymFromAddr(process, frame.AddrPC.Offset, &symOff, sym)) {
            if (SymGetLineFromAddr64(process, frame.AddrPC.Offset, &lineOff, &line))
                eryx_crash_printf("  #%-2d  %s (%s:%lu)\n", i, sym->Name, line.FileName,
                                  line.LineNumber);
            else
                eryx_crash_printf("  #%-2d  %s+0x%llx\n", i, sym->Name,
                                  static_cast<unsigned long long>(symOff));
        } else {
            eryx_crash_printf("  #%-2d  0x%016llx\n", i,
                              static_cast<unsigned long long>(frame.AddrPC.Offset));
        }
    }

    SymCleanup(process);
}

static volatile LONG g_crash_entered = 0;

static void eryx_do_crash(EXCEPTION_POINTERS* ep) {
    // Re-entrancy guard: if the crash handler itself crashes, just die immediately.
    if (InterlockedCompareExchange(&g_crash_entered, 1, 0) != 0)
        TerminateProcess(GetCurrentProcess(), 3);

    eryx_crash_printf("\n*** ERYX CRASH: exception 0x%08lX at 0x%p ***\n",
                      ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress);

    // SymInitialize and StackWalk64 may themselves crash on heap corruption,
    // so protect the entire trace with an SEH frame.
    __try {
        eryx_print_stack_trace(ep->ContextRecord);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        eryx_crash_puts("  (stack trace unavailable)\n");
    }
}

// Fires for truly unhandled exceptions (after all frame-based handlers pass).
static LONG WINAPI eryx_unhandled_exception_filter(EXCEPTION_POINTERS* ep) {
    eryx_do_crash(ep);
    return EXCEPTION_EXECUTE_HANDLER;
}

// Vectored handler: fires before frame-based handlers, so DLLs overriding
// SetUnhandledExceptionFilter can't suppress us. Only act on non-continuable
// exceptions so we don't interfere with normal C++ try/catch.
static LONG WINAPI eryx_vectored_exception_handler(EXCEPTION_POINTERS* ep) {
    if (ep->ExceptionRecord->ExceptionFlags & EXCEPTION_NONCONTINUABLE) {
        // Skip C++ exceptions (0xE06D7363) — those are always non-continuable
        // but will be handled by catch blocks or the unhandled filter.
        if (ep->ExceptionRecord->ExceptionCode != 0xE06D7363U) {
            eryx_do_crash(ep);
            TerminateProcess(GetCurrentProcess(), 1);
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void eryx_abort_signal_handler(int) {
    eryx_crash_puts("\n*** ERYX CRASH: abort() ***\n");
    CONTEXT ctx = {};
    ctx.ContextFlags = CONTEXT_FULL;
    RtlCaptureContext(&ctx);
    __try {
        eryx_print_stack_trace(&ctx);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        eryx_crash_puts("  (stack trace unavailable)\n");
    }
    _exit(3);
}

static void install_crash_handler() {
    // Suppress the Windows "Abort / Retry / Ignore" and WER crash popup.
    SetErrorMode(SEM_NOGPFAULTERRORBOX | SEM_FAILCRITICALERRORS);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

    // Belt-and-suspenders: VEH fires before any frame handler and can't be
    // overridden by DLLs; SetUnhandledExceptionFilter catches the rest.
    AddVectoredExceptionHandler(1, eryx_vectored_exception_handler);
    SetUnhandledExceptionFilter(eryx_unhandled_exception_filter);
    std::signal(SIGABRT, eryx_abort_signal_handler);
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
        eryx_request_process_interrupt();
        return TRUE;
    }
    return FALSE;
}

static void main_signal_handler(int) {
    g_main_interrupted = true;
    eryx_request_process_interrupt();
}
#else
static void main_sigint_handler(int) {
    g_main_interrupted = true;
    eryx_request_process_interrupt();
}
#endif

static void install_main_interrupt_handler() {
#ifdef _WIN32
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    if (h != INVALID_HANDLE_VALUE && GetConsoleMode(h, &mode)) {
        SetConsoleMode(h, mode | ENABLE_PROCESSED_INPUT);
    }

    SetConsoleCtrlHandler(main_ctrl_handler, TRUE);
    std::signal(SIGINT, main_signal_handler);
#ifdef SIGBREAK
    std::signal(SIGBREAK, main_signal_handler);
#endif
#else
    std::signal(SIGINT, main_sigint_handler);
#endif
}

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

static constexpr const char* ERYX_FORWARD_RUNTIME_ARGS_ENV = "ERYX_FORWARD_RUNTIME_ARGS";

struct RuntimeCliOverrides {
    std::optional<int> optimizationLevel;
    std::optional<EryxNativeCodegenMode> nativeCodegenMode;
};

struct RuntimeExecutionConfig {
    int optimizationLevel = 2;
    EryxNativeCodegenMode nativeCodegenMode = EryxNativeCodegenMode::All;
};

struct RuntimeCliParseResult {
    bool ok = true;
    int nextIndex = 0;
    RuntimeCliOverrides overrides;
    std::string error;
};

struct ProcessCliArgs {
    std::vector<std::string> storage;
    std::vector<const char*> argv;

    int argc() const { return int(argv.size()); }
    const char** data() { return argv.empty() ? nullptr : argv.data(); }
};

#ifdef _WIN32
static std::string wide_to_utf8(std::wstring_view value) {
    if (value.empty()) return "";

    int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), int(value.size()), nullptr, 0, nullptr,
                                   nullptr);
    if (size <= 0) return "";

    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), int(value.size()), utf8.data(), size, nullptr,
                        nullptr);
    return utf8;
}
#endif

static void finalize_process_cli_args(ProcessCliArgs& args) {
    args.argv.clear();
    args.argv.reserve(args.storage.size());
    for (const std::string& arg : args.storage) {
        args.argv.push_back(arg.c_str());
    }
}

static ProcessCliArgs build_process_cli_args(int argc, const char* argv[]) {
    ProcessCliArgs args;

#ifdef _WIN32
    int wideArgc = 0;
    LPWSTR* wideArgv = CommandLineToArgvW(GetCommandLineW(), &wideArgc);
    if (wideArgv) {
        args.storage.reserve(wideArgc);
        for (int i = 0; i < wideArgc; ++i) {
            args.storage.push_back(wide_to_utf8(wideArgv[i]));
        }
        LocalFree(wideArgv);
        finalize_process_cli_args(args);
        return args;
    }
#endif

    args.storage.reserve(argc);
    for (int i = 0; i < argc; ++i) {
        args.storage.push_back(argv[i] ? argv[i] : "");
    }
    finalize_process_cli_args(args);
    return args;
}

static std::vector<std::string> make_script_cli_args(const std::string& invokedName, int argc,
                                                     const char* const* argv,
                                                     int scriptArgsStartIndex) {
    std::vector<std::string> cliArgs;
    cliArgs.reserve(std::max(1, argc - scriptArgsStartIndex + 1));
    cliArgs.push_back(invokedName);
    for (int i = scriptArgsStartIndex; i < argc; ++i) {
        cliArgs.push_back(argv[i]);
    }
    return cliArgs;
}

static std::vector<std::string> make_script_cli_args(int argc, const char* const* argv,
                                                     int scriptIndex) {
    return make_script_cli_args(argv[scriptIndex], argc, argv, scriptIndex + 1);
}

static std::vector<std::string> make_script_cli_args(const std::string& invokedName,
                                                     const std::vector<std::string>& args,
                                                     int scriptArgsStartIndex) {
    std::vector<std::string> cliArgs;
    cliArgs.reserve(std::max(1, int(args.size()) - scriptArgsStartIndex + 1));
    cliArgs.push_back(invokedName);
    for (int i = scriptArgsStartIndex; i < int(args.size()); ++i) {
        cliArgs.push_back(args[i]);
    }
    return cliArgs;
}

template <typename GetArg>
static RuntimeCliParseResult parse_runtime_cli_overrides(int count, int startIndex, GetArg getArg) {
    RuntimeCliParseResult result;
    result.nextIndex = startIndex;

    while (result.nextIndex < count) {
        std::string_view arg = getArg(result.nextIndex);

        if (arg == "--") {
            result.nextIndex += 1;
            break;
        }

        if (arg == "-O0" || arg == "-O1" || arg == "-O2") {
            result.overrides.optimizationLevel = int(arg[2] - '0');
            result.nextIndex += 1;
            continue;
        }

        if (arg == "--native") {
            result.overrides.nativeCodegenMode = EryxNativeCodegenMode::All;
            result.nextIndex += 1;
            continue;
        }

        if (arg == "--no-native") {
            result.overrides.nativeCodegenMode = EryxNativeCodegenMode::Disabled;
            result.nextIndex += 1;
            continue;
        }

        if (arg == "--native-only-specified") {
            result.overrides.nativeCodegenMode = EryxNativeCodegenMode::OnlySpecified;
            result.nextIndex += 1;
            continue;
        }

        if (arg.size() >= 2 && arg[0] == '-' && arg[1] == 'O') {
            result.ok = false;
            result.error = "Unsupported optimization level '" + std::string(arg) +
                           "' (expected -O0, -O1, or -O2)";
            return result;
        }

        break;
    }

    return result;
}

static RuntimeCliOverrides merge_runtime_cli_overrides(const RuntimeCliOverrides& base,
                                                       const RuntimeCliOverrides& override) {
    RuntimeCliOverrides merged = base;
    if (override.optimizationLevel.has_value()) {
        merged.optimizationLevel = override.optimizationLevel;
    }
    if (override.nativeCodegenMode.has_value()) {
        merged.nativeCodegenMode = override.nativeCodegenMode;
    }
    return merged;
}

static RuntimeExecutionConfig resolve_runtime_execution_config(
    const RuntimeCliOverrides& overrides) {
    RuntimeExecutionConfig config;
    if (overrides.optimizationLevel.has_value()) {
        config.optimizationLevel = *overrides.optimizationLevel;
    }
    if (overrides.nativeCodegenMode.has_value()) {
        config.nativeCodegenMode = *overrides.nativeCodegenMode;
    }
    return config;
}

static std::vector<std::string> render_runtime_cli_flags(const RuntimeCliOverrides& overrides) {
    std::vector<std::string> flags;
    if (overrides.optimizationLevel.has_value()) {
        flags.push_back("-O" + std::to_string(*overrides.optimizationLevel));
    }
    if (overrides.nativeCodegenMode.has_value()) {
        switch (*overrides.nativeCodegenMode) {
            case EryxNativeCodegenMode::Disabled:
                flags.push_back("--no-native");
                break;
            case EryxNativeCodegenMode::OnlySpecified:
                flags.push_back("--native-only-specified");
                break;
            case EryxNativeCodegenMode::All:
            default:
                flags.push_back("--native");
                break;
        }
    }
    return flags;
}

static std::string render_runtime_cli_env_value(const RuntimeCliOverrides& overrides) {
    std::vector<std::string> flags = render_runtime_cli_flags(overrides);
    std::string out;
    for (size_t i = 0; i < flags.size(); ++i) {
        if (i > 0) out += "\n";
        out += flags[i];
    }
    return out;
}

static void apply_runtime_execution_config(EryxRuntime* rt, const RuntimeExecutionConfig& config) {
    if (!rt) return;
    rt->nativeCodegenMode = config.nativeCodegenMode;
    rt->luauOptimizationLevel = config.optimizationLevel;
    rt->luauDebugLevel = 1;
    rt->luauTypeInfoLevel = 1;
}

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

int main_script(const char* filename, const std::string luauCode,
                const RuntimeExecutionConfig& runtimeConfig,
                const std::vector<std::string>& cliArgs) {
    int exitCode = 0;
    try {
        EryxRuntimeHost host;
        if (!eryx_runtime_host_init(&host, filename)) {
            std::cerr << "Failed to create Lua state" << std::endl;
            return 1;
        }
        apply_runtime_execution_config(host.rt, runtimeConfig);
        host.rt->hasCliArgs = true;
        host.rt->cliArgs = cliArgs;
        eryx_runtime_host_install_sigint(&host);
#ifdef _WIN32
        // libuv installs its own console handler for SIGINT. Re-register our
        // handler after it so Ctrl+C can set the VM interrupt flag immediately
        // even while Lua is running and the uv loop cannot tick.
        install_main_interrupt_handler();
#endif

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

static void print_version() {
    std::cout << "Eryx (Luau " << LUAU_APPROX_VERSION << ", "
              << std::string(LUAU_GIT_HASH).substr(0, 8) << ")" << std::endl;
}

static void print_main_help(const char* programName) {
    std::cout << "Usage:\n";
    std::cout << "  " << programName << " [options] [script.luau [args...]]\n";
    std::cout << "  " << programName << " [options] run [options] <script> [args...]\n";
    std::cout << "  " << programName << " completion <bash|zsh|fish|powershell>\n";
    std::cout << "  " << programName << " --help\n";
    std::cout << "  " << programName << " --version\n";
    std::cout << "\n";
    std::cout << "Options:\n";
    std::cout << "  -h, --help                   Show this help text\n";
    std::cout << "  --version                    Print version information\n";
    std::cout << "  -O0, -O1, -O2                Set Luau optimization level\n";
    std::cout << "  --native                     Enable native codegen for all eligible chunks\n";
    std::cout << "  --no-native                  Disable native codegen\n";
    std::cout
        << "  --native-only-specified      Only native-compile chunks marked with --!native\n";
    std::cout << "\n";
    std::cout << "Commands:\n";
    std::cout << "  run                          Resolve and run project/dependency scripts\n";
    std::cout << "  completion                   Generate shell completion scripts\n";
    std::cout << "\n";
    std::cout << "Use -- after options to pass a script name that begins with -.\n";
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

static ReplRunResult repl_run_snippet(lua_State* L, const std::string& source,
                                      const RuntimeExecutionConfig& runtimeConfig) {
    lua_checkstack(L, LUA_MINSTACK);
    const int base = lua_gettop(L);

    Luau::CompileOptions opts;
    opts.optimizationLevel = runtimeConfig.optimizationLevel;
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

int main_repl(const RuntimeExecutionConfig& runtimeConfig) {
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
            ReplRunResult exprResult =
                repl_run_snippet(L, std::string("return ") + line.get(), runtimeConfig);
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

        ReplRunResult result = repl_run_snippet(L, buffer, runtimeConfig);

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
                                       const std::vector<std::string>& cliArgs, const char* shell,
                                       const RuntimeExecutionConfig& runtimeConfig) {
    if (source.find("@eryx/argparse") == std::string::npos) {
        completion_debug_log("main_complete_script: script does not use @eryx/argparse");
        return 0;
    }

    completion_debug_log("main_complete_script: invoking script in completion mode");

    ScopedEnvVar completionMode("ERYX_ARGPARSE_COMPLETE", "1");
    ScopedEnvVar completionShell("ERYX_ARGPARSE_COMPLETE_SHELL", shell ? shell : "");

    return main_script(displayName.c_str(), source, runtimeConfig, cliArgs);
}

static int main_complete_script(const std::filesystem::path& scriptPath,
                                const std::vector<std::string>& cliArgs, const char* shell,
                                const RuntimeExecutionConfig& runtimeConfig) {
    namespace fs = std::filesystem;

    completion_debug_log("main_complete_script: path=" + scriptPath.string() +
                         " shell=" + (shell ? shell : ""));

    std::error_code ec;
    if (fs::is_directory(scriptPath, ec)) {
        completion_debug_log("main_complete_script: script path is a directory");
        return 0;
    }

    std::ifstream f(scriptPath, std::ios::binary);
    if (!f) {
        completion_debug_log("main_complete_script: failed to read script");
        std::cerr << "Failed to read " << scriptPath << std::endl;
        return 1;
    }

    std::string source((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return main_complete_script_source(scriptPath.string(), source, cliArgs, shell, runtimeConfig);
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

    auto parseWords = [&](int startIndex) {
        return parse_runtime_cli_overrides(
            (int)words.size(), startIndex,
            [&](int index) -> std::string_view { return words[index]; });
    };

    RuntimeCliParseResult globalParse = parseWords(0);
    if (!globalParse.ok) return 0;
    RuntimeExecutionConfig globalConfig = resolve_runtime_execution_config(globalParse.overrides);

    if (globalParse.nextIndex >= (int)words.size()) {
        auto builtins = list_builtin_scripts();
        builtins.push_back("-h");
        builtins.push_back("--help");
        builtins.push_back("--version");
        builtins.push_back("completion");
        builtins.push_back("run");
        builtins.push_back("-O0");
        builtins.push_back("-O1");
        builtins.push_back("-O2");
        builtins.push_back("--native");
        builtins.push_back("--no-native");
        builtins.push_back("--native-only-specified");
        completion_debug_log("main_complete: returning top-level candidates");
        print_completion_candidates(builtins);
        return 0;
    }

    const std::string& command = words[globalParse.nextIndex];

    if (command == "run") {
        RuntimeCliParseResult runParse = parseWords(globalParse.nextIndex + 1);
        if (!runParse.ok) return 0;
        if (runParse.nextIndex >= (int)words.size()) return 0;

        RuntimeExecutionConfig runConfig = resolve_runtime_execution_config(
            merge_runtime_cli_overrides(globalParse.overrides, runParse.overrides));

        fs::path scriptPath = words[runParse.nextIndex];
        if (fs::exists(scriptPath)) {
            completion_debug_log("main_complete: dispatching to run script " + scriptPath.string());
            return main_complete_script(
                scriptPath,
                make_script_cli_args(words[runParse.nextIndex], words, runParse.nextIndex + 1),
                shell.c_str(), runConfig);
        }
        completion_debug_log("main_complete: run script does not exist");
        return 0;
    }

    if (command == "completion") {
        if (globalParse.nextIndex + 1 < (int)words.size()) return 0;
        completion_debug_log("main_complete: returning completion shell names");
        print_completion_candidates({ "bash", "fish", "powershell", "zsh" });
        return 0;
    }

    if (command.find('.') == std::string::npos && !fs::exists(command)) {
        if (const EmbeddedScriptModule* builtin = find_embedded_builtin_script(command)) {
            std::string displayName = "@eryx/scripts/" + command;
            completion_debug_log("main_complete: dispatching to embedded builtin script " +
                                 displayName);
            return main_complete_script_source(
                displayName, builtin->source,
                make_script_cli_args(command, words, globalParse.nextIndex + 1), shell.c_str(),
                globalConfig);
        }

        fs::path builtinPath = getScriptsDir() / (command + ".luau");
        if (fs::exists(builtinPath)) {
            completion_debug_log("main_complete: dispatching to builtin script " +
                                 builtinPath.string());
            return main_complete_script(
                builtinPath, make_script_cli_args(command, words, globalParse.nextIndex + 1),
                shell.c_str(), globalConfig);
        }
        completion_debug_log("main_complete: builtin script not found for " + command);
    }

    fs::path scriptPath = command;
    if (fs::exists(scriptPath)) {
        completion_debug_log("main_complete: dispatching to explicit script " +
                             scriptPath.string());
        return main_complete_script(scriptPath,
                                    make_script_cli_args(command, words, globalParse.nextIndex + 1),
                                    shell.c_str(), globalConfig);
    }

    completion_debug_log("main_complete: no completion target matched");
    return 0;
}

// Try to run a built-in script from the scripts/ directory next to the executable.
// Returns -1 if the script doesn't exist (caller should fall through).
int main_builtin_script(const char* name, const std::vector<std::string>& cliArgs,
                        const RuntimeExecutionConfig& runtimeConfig) {
    namespace fs = std::filesystem;

    if (const EmbeddedScriptModule* builtin = find_embedded_builtin_script(name)) {
        std::string displayName = std::string("@eryx/scripts/") + name;
        return main_script(displayName.c_str(), builtin->source, runtimeConfig, cliArgs);
    }

    fs::path scriptPath = getScriptsDir() / (std::string(name) + ".luau");

    if (!fs::exists(scriptPath)) return -1;

    std::ifstream f(scriptPath, std::ios::binary);
    if (!f) {
        std::cerr << "Failed to read " << scriptPath << std::endl;
        return 1;
    }
    std::string source((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    return main_script(scriptPath.string().c_str(), source, runtimeConfig, cliArgs);
}

int main_run(const char* filename, const RuntimeExecutionConfig& runtimeConfig,
             const std::vector<std::string>& cliArgs) {
    namespace fs = std::filesystem;

    std::error_code ec;
    if (fs::is_directory(filename, ec)) {
        std::cerr << "Failed to open file \"" << filename << "\": is a directory" << std::endl;
        return 1;
    }

    std::ifstream script_file(filename);
    if (!script_file.is_open()) {
        std::cerr << "Failed to open file \"" << filename << "\"" << std::endl;
        return 1;
    }
    std::string luaScript((std::istreambuf_iterator<char>(script_file)),
                          std::istreambuf_iterator<char>());
    script_file.close();

    return main_script(filename, luaScript, runtimeConfig, cliArgs);
}

int main(int argc, const char* argv[]) {
    // puts("Wait for debugger");
    // while (!IsDebuggerPresent());
    // puts("go");

#ifdef _WIN32
    install_crash_handler();
#endif

    ProcessCliArgs processCliArgs = build_process_cli_args(argc, argv);
    argc = processCliArgs.argc();
    argv = processCliArgs.data();
#ifdef ERYX_EMBED
    eryx_register_embedded_modules(g_embedded_native_modules, g_embedded_script_modules);
#endif
#ifdef _WIN32
    // On windows, we're going to force ANSI escape sequences in CMD
    enable_ansi_colors();
#endif
    install_main_interrupt_handler();

    // VFS entrypoint execution
    if (vfs_open()) {
        auto entry = vfs_get_entrypoint();
        auto entryData = vfs_read_file(std::string(entry));

        if (!entry.ends_with(".luau")) {
            std::cerr << "Entrypoint " << entry << " not a luau source file!";
            return -1;
        }

        std::vector<std::string> cliArgs;
        cliArgs.reserve(std::max(1, argc));
        cliArgs.push_back(std::string(entry));
        for (int i = 1; i < argc; ++i) {
            cliArgs.push_back(argv[i]);
        }

        // Build the chunk name with the @@vfs/ prefix.
        // main_script prepends "@" to its filename argument, so we pass
        // the entry prefixed with just "@vfs/" - the outer "@" produces "@@vfs/…".
        std::string vfsChunkName = std::string("@vfs/") + std::string(entry);
        return main_script(vfsChunkName.c_str(),
                           std::string(std::string_view((char*)entryData.data(), entryData.size())),
                           RuntimeExecutionConfig{}, cliArgs);
    }

    RuntimeCliParseResult globalParse = parse_runtime_cli_overrides(
        argc, 1, [&](int index) -> std::string_view { return argv[index]; });
    if (!globalParse.ok) {
        std::cerr << globalParse.error << std::endl;
        return 1;
    }

    RuntimeExecutionConfig globalConfig = resolve_runtime_execution_config(globalParse.overrides);

    if (globalParse.nextIndex >= argc) {
        return main_repl(globalConfig);
    }

    int commandIndex = globalParse.nextIndex;
    const char* command = argv[commandIndex];

    if (strcmp(command, "-h") == 0 || strcmp(command, "--help") == 0) {
        print_main_help(argv[0]);
        return 0;
    }

    if (strcmp(command, "--version") == 0) {
        print_version();
        return 0;
    }

    if (strcmp(command, "__complete") == 0) {
        return main_complete(argc, argv);
    }

    if (strcmp(command, "completion") == 0) {
        if (commandIndex + 1 >= argc) {
            main_raise_usage(argv, "completion <bash|zsh|fish|powershell>");
            return -1;
        }

        std::string output = render_completion_script(argv[0], argv[commandIndex + 1]);
        if (output.empty()) {
            std::cerr << "Unsupported shell '" << argv[commandIndex + 1] << "'" << std::endl;
            return 1;
        }

        std::cout << output;
        return 0;
    }

    if (strcmp(command, "run") == 0) {
        RuntimeCliParseResult runParse = parse_runtime_cli_overrides(
            argc, commandIndex + 1, [&](int index) -> std::string_view { return argv[index]; });
        if (!runParse.ok) {
            std::cerr << runParse.error << std::endl;
            return 1;
        }
        if (runParse.nextIndex >= argc) {
            main_raise_usage(argv, "run <script>");
            return -1;
        }

        RuntimeExecutionConfig runConfig = resolve_runtime_execution_config(
            merge_runtime_cli_overrides(globalParse.overrides, runParse.overrides));

        std::string inheritedRuntimeArgs = render_runtime_cli_env_value(globalParse.overrides);
        ScopedEnvVar exePath("ERYX_EXE_PATH", getExecutablePath().string().c_str());
        ScopedEnvVar inheritedRuntimeEnv(
            ERYX_FORWARD_RUNTIME_ARGS_ENV,
            inheritedRuntimeArgs.empty() ? nullptr : inheritedRuntimeArgs.c_str());
        int result =
            main_builtin_script("run", make_script_cli_args(argc, argv, commandIndex), runConfig);
        if (result != -1) return result;

        // Fallback for distributions missing scripts/run.luau.
        return main_run(argv[runParse.nextIndex], runConfig,
                        make_script_cli_args(argc, argv, runParse.nextIndex));
    }

    // If the argument has no file extension and no file with that exact name
    // exists in the cwd, try to run a built-in script from scripts/<command>.luau
    namespace fs = std::filesystem;
    std::string cmdStr(command);
    if (cmdStr.find('.') == std::string::npos && !fs::exists(cmdStr)) {
        int result = main_builtin_script(command, make_script_cli_args(argc, argv, commandIndex),
                                         globalConfig);
        if (result != -1) return result;
    }

    return main_run(command, globalConfig, make_script_cli_args(argc, argv, commandIndex));
}
