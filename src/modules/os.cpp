// os.cpp -- OS utilities module
//
//   Environment:
//     os.getenv(key)          -> string?
//     os.setenv(key, value?)  (nil value unsets)
//     os.environ()            -> {[string]: string}
//
//   System info:
//     os.platform()           -> string
//     os.arch()               -> string
//     os.hostname()           -> string
//     os.tmpdir()             -> string
//     os.homedir()            -> string
//     os.cpucount()           -> number
//     os.totalmem()           -> number
//     os.freemem()            -> number
//     os.uptime()             -> number
//     os.pid()                -> number
//
//   Misc:
//     os.exit(code?)
//     os.clock()              -> number (high-res monotonic)
//     os.cwd()                -> string
//     os.chdir(path)
//     os.cliargs()            -> {string}  (user args only, exe/cmd/script stripped)
//
//   Child processes:
//     os.exec(cmd, args?, opts?)   -> yields, returns {stdout, stderr, code}
//     os.spawn(cmd, args?, opts?)  -> ProcessHandle
//     os.shell(cmd, opts?)         -> yields, returns exit code (stdio inherited)
// ---------------------------------------------------------------------------

#include "module_api.h"
#ifdef _WIN32
// This comment forces module API above shellapi
#include <shellapi.h>
#else
#include <sys/utsname.h>

#include <csignal>

#endif

#include <deque>
#include <string>
#include <vector>

#include "../runtime/lexception.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_os",
};
LUAU_MODULE_INFO()

// ===========================================================================
// Environment
// ===========================================================================

static int os_getenv(lua_State* L) {
    const char* key = luaL_checkstring(L, 1);
#ifdef _WIN32
    // Use _dupenv_s for thread safety on Windows
    char* val = nullptr;
    size_t len = 0;
    if (_dupenv_s(&val, &len, key) == 0 && val) {
        lua_pushlstring(L, val, len > 0 ? len - 1 : 0);  // len includes null terminator
        free(val);
    } else {
        lua_pushnil(L);
    }
#else
    const char* val = ::getenv(key);
    if (val) {
        lua_pushstring(L, val);
    } else {
        lua_pushnil(L);
    }
#endif
    return 1;
}

static int os_setenv(lua_State* L) {
    const char* key = luaL_checkstring(L, 1);
    if (lua_isnoneornil(L, 2)) {
#ifdef _WIN32
        if (_putenv_s(key, "") != 0) {
#else
        if (unsetenv(key) != 0) {
#endif
            luaL_error(L, "failed to unset environment variable '%s'", key);
        }
    } else {
        const char* val = luaL_checkstring(L, 2);
#ifdef _WIN32
        if (_putenv_s(key, val) != 0) {
#else
        if (setenv(key, val, 1) != 0) {
#endif
            luaL_error(L, "failed to set environment variable '%s'", key);
        }
    }
    return 0;
}

static int os_environ(lua_State* L) {
    lua_newtable(L);

#ifdef _WIN32
    // Get the environment block
    LPWCH envBlock = GetEnvironmentStringsW();
    if (!envBlock) return 1;

    LPWCH ptr = envBlock;
    while (*ptr) {
        std::wstring entry(ptr);
        size_t eqPos = entry.find(L'=');
        if (eqPos != std::wstring::npos && eqPos > 0) {
            std::wstring wkey = entry.substr(0, eqPos);
            std::wstring wval = entry.substr(eqPos + 1);

            // Convert key
            int ksize = WideCharToMultiByte(CP_UTF8, 0, wkey.c_str(), -1, NULL, 0, NULL, NULL);
            std::string key(ksize - 1, '\0');
            WideCharToMultiByte(CP_UTF8, 0, wkey.c_str(), -1, key.data(), ksize, NULL, NULL);

            // Convert value
            int vsize = WideCharToMultiByte(CP_UTF8, 0, wval.c_str(), -1, NULL, 0, NULL, NULL);
            std::string val(vsize - 1, '\0');
            WideCharToMultiByte(CP_UTF8, 0, wval.c_str(), -1, val.data(), vsize, NULL, NULL);

            lua_pushlstring(L, val.data(), val.size());
            lua_setfield(L, -2, key.c_str());
        }
        ptr += entry.size() + 1;
    }

    FreeEnvironmentStringsW(envBlock);
#else
    extern char** environ;
    for (char** env = environ; *env; ++env) {
        const char* entry = *env;
        const char* eq = strchr(entry, '=');
        if (eq && eq != entry) {
            lua_pushlstring(L, entry, eq - entry);  // key
            lua_pushstring(L, eq + 1);              // value
            lua_settable(L, -3);
        }
    }
#endif
    return 1;
}

// ===========================================================================
// System info
// ===========================================================================

static int os_luauversion(lua_State* L) {
    lua_createtable(L, 0, 1);
    lua_pushstring(L, LUAU_APPROX_VERSION);
    lua_setfield(L, -2, "release");
    lua_pushstring(L, LUAU_GIT_HASH);
    lua_setfield(L, -2, "hash");
    return 1;
}

static int os_platform(lua_State* L) {
#if defined(_WIN32)
    lua_pushstring(L, "windows");
#elif defined(__APPLE__)
    lua_pushstring(L, "macos");
#elif defined(__linux__)
    lua_pushstring(L, "linux");
#else
    lus_pushnil(L);
#endif
    return 1;
}

static int os_arch(lua_State* L) {
#ifdef _WIN32
    SYSTEM_INFO si;
    GetNativeSystemInfo(&si);
    switch (si.wProcessorArchitecture) {
        case PROCESSOR_ARCHITECTURE_AMD64:
            lua_pushstring(L, "x64");
            break;
        case PROCESSOR_ARCHITECTURE_ARM64:
            lua_pushstring(L, "arm64");
            break;
        case PROCESSOR_ARCHITECTURE_ARM:
            lua_pushstring(L, "arm");
            break;
        case PROCESSOR_ARCHITECTURE_INTEL:
            lua_pushstring(L, "x86");
            break;
        default:
            lua_pushnil(L);
            break;
    }
#else
    struct utsname info;
    if (uname(&info) == 0) {
        const char* machine = info.machine;
        // Normalize common machine strings
        if (strcmp(machine, "x86_64") == 0 || strcmp(machine, "amd64") == 0)
            lua_pushstring(L, "x64");
        else if (strcmp(machine, "aarch64") == 0 || strcmp(machine, "arm64") == 0)
            lua_pushstring(L, "arm64");
        else if (strcmp(machine, "armv7l") == 0 || strcmp(machine, "armv6l") == 0)
            lua_pushstring(L, "arm");
        else if (strcmp(machine, "i686") == 0 || strcmp(machine, "i386") == 0)
            lua_pushstring(L, "x86");
        else
            lua_pushstring(L, machine);
    } else {
        lua_pushnil(L);
    }
#endif
    return 1;
}

static int os_hostname(lua_State* L) {
    char buf[256];
    size_t size = sizeof(buf);
    if (uv_os_gethostname(buf, &size) == 0) {
        lua_pushlstring(L, buf, size);
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

static int os_tmpdir(lua_State* L) {
    char buf[1024];
    size_t size = sizeof(buf);
    if (uv_os_tmpdir(buf, &size) == 0) {
        lua_pushlstring(L, buf, size);
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

static int os_homedir(lua_State* L) {
    char buf[1024];
    size_t size = sizeof(buf);
    if (uv_os_homedir(buf, &size) == 0) {
        lua_pushlstring(L, buf, size);
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

static int os_cpucount(lua_State* L) {
    uv_cpu_info_t* cpus;
    int count;
    if (uv_cpu_info(&cpus, &count) == 0) {
        uv_free_cpu_info(cpus, count);
        lua_pushinteger(L, count);
    } else {
        lua_pushinteger(L, 1);
    }
    return 1;
}

static int os_totalmem(lua_State* L) {
    lua_pushnumber(L, ((double)uv_get_total_memory()) / 1024);
    return 1;
}

static int os_freemem(lua_State* L) {
    lua_pushnumber(L, ((double)uv_get_free_memory()) / 1024);
    return 1;
}

static int os_uptime(lua_State* L) {
    double uptime;
    if (uv_uptime(&uptime) == 0) {
        lua_pushnumber(L, uptime);
    } else {
        lua_pushnumber(L, 0);
    }
    return 1;
}

static int os_pid(lua_State* L) {
    lua_pushinteger(L, uv_os_getpid());
    return 1;
}

// ===========================================================================
// Misc utilities
// ===========================================================================

static int os_exit(lua_State* L) {
    int code = (int)luaL_optinteger(L, 1, 0);

    void* extra = (void*)(intptr_t)code;

    eryx_exception_push_exception(L, ETYPE_SYSTEM_EXIT, "os.exit()", extra);
    lua_error(L);

    return 0;
}

static int os_clock(lua_State* L) {
    lua_pushnumber(L, (double)uv_hrtime() / 1e9);
    return 1;
}

static int os_cwd(lua_State* L) {
    char buf[4096];
    size_t size = sizeof(buf);
    if (uv_cwd(buf, &size) == 0) {
        lua_pushlstring(L, buf, size);
    } else {
        luaL_error(L, "failed to get current working directory");
    }
    return 1;
}

static int os_chdir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    int r = uv_chdir(path);
    if (r != 0) {
        luaL_error(L, "failed to change directory to '%s': %s", path, uv_strerror(r));
    }
    return 0;
}

static int os_cliargs(lua_State* L) {
    int offset = eryx_get_cliargs_offset();

#ifdef _WIN32
    int argc;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    if (offset > argc) offset = argc;

    int userArgc = argc - offset;
    lua_createtable(L, userArgc, 0);

    if (!argv) return 1;

    for (int i = offset; i < argc; i++) {
        int size = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, NULL, 0, NULL, NULL);
        std::string utf8(size - 1, '\0');
        WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, utf8.data(), size, NULL, NULL);

        lua_pushlstring(L, utf8.data(), utf8.size());
        lua_rawseti(L, -2, (i - offset) + 1);
    }

    LocalFree(argv);
#else
    int argc = eryx_get_cliargs_argc();
    const char** argv = eryx_get_cliargs_argv();

    if (offset > argc) offset = argc;

    int userArgc = argc - offset;
    lua_createtable(L, userArgc, 0);

    if (!argv) return 1;

    for (int i = offset; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, (i - offset) + 1);
    }
#endif
    return 1;
}

// ===========================================================================
// Child processes
// ===========================================================================

// Data attached to a spawned process
struct ProcessData {
    EryxRuntime* rt;
    uv_process_t process;
    uv_pipe_t stdinPipe;
    uv_pipe_t stdoutPipe;
    uv_pipe_t stderrPipe;

    // For exec mode: accumulate all output
    std::string stdoutBuf;
    std::string stderrBuf;

    // For spawn mode: chunk queues for incremental reading
    std::deque<std::string> stdoutChunks;
    std::deque<std::string> stderrChunks;
    int stdoutReaderRef;  // coroutine waiting for stdout data
    int stderrReaderRef;  // coroutine waiting for stderr data

    int threadRef;   // ref to the waiting coroutine (for exec/wait)
    int processRef;  // self-ref to prevent GC (for spawn)
    int64_t exitStatus;
    int termSignal;
    bool exited;
    bool stdoutClosed;
    bool stderrClosed;
    bool isExec;   // true for os.exec (auto-collect output), false for os.spawn
    bool isShell;  // true for os.shell (inherit stdio, return code only)
};

static void alloc_cb(uv_handle_t*, size_t suggested, uv_buf_t* buf) {
    buf->base = new char[suggested];
    buf->len = (decltype(buf->len))suggested;
}

// Try to resume the exec coroutine once process has exited AND both pipes are closed
static void try_resume_exec(ProcessData* pd) {
    if (!pd->isExec) return;
    if (!pd->exited || !pd->stdoutClosed || !pd->stderrClosed) return;

    EryxRuntime* rt = pd->rt;
    lua_State* GL = rt->GL;

    // Get the waiting thread
    lua_getref(GL, pd->threadRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    // Push result table onto TL: {stdout, stderr, code}
    lua_newtable(TL);

    lua_pushlstring(TL, pd->stdoutBuf.data(), pd->stdoutBuf.size());
    lua_setfield(TL, -2, "stdout");

    lua_pushlstring(TL, pd->stderrBuf.data(), pd->stderrBuf.size());
    lua_setfield(TL, -2, "stderr");

    lua_pushinteger(TL, (int)pd->exitStatus);
    lua_setfield(TL, -2, "code");

    eryx_push_thread(rt, pd->threadRef, 1, false);

    // Clean up - close stdin pipe too
    if (!uv_is_closing((uv_handle_t*)&pd->stdinPipe))
        uv_close((uv_handle_t*)&pd->stdinPipe, nullptr);
    // pd will be freed when process handle closes
}

// Resume a coroutine that is waiting for a read, pushing `data` (or nil if closed)
static void resume_reader(ProcessData* pd, int& readerRef, const char* data, size_t len) {
    if (readerRef == LUA_NOREF) return;
    EryxRuntime* rt = pd->rt;
    lua_State* GL = rt->GL;

    lua_getref(GL, readerRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    if (data) {
        lua_pushlstring(TL, data, len);
    } else {
        lua_pushnil(TL);
    }

    int ref = readerRef;
    readerRef = LUA_NOREF;
    eryx_push_thread(rt, ref, 1, false);
}

static void stdout_read_cb(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {
    auto* pd = (ProcessData*)stream->data;
    if (nread > 0) {
        if (pd->isExec) {
            pd->stdoutBuf.append(buf->base, nread);
        } else if (pd->stdoutReaderRef != LUA_NOREF) {
            // A coroutine is waiting — resume it directly with this chunk
            resume_reader(pd, pd->stdoutReaderRef, buf->base, nread);
        } else {
            // Queue the chunk for later readStdout() calls
            pd->stdoutChunks.emplace_back(buf->base, nread);
        }
    }
    if (buf->base) delete[] buf->base;
    if (nread < 0) {
        uv_read_stop(stream);
        pd->stdoutClosed = true;
        if (!uv_is_closing((uv_handle_t*)stream)) uv_close((uv_handle_t*)stream, nullptr);
        // Wake up any waiting reader with nil (EOF)
        resume_reader(pd, pd->stdoutReaderRef, nullptr, 0);
        try_resume_exec(pd);
    }
}

static void stderr_read_cb(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {
    auto* pd = (ProcessData*)stream->data;
    if (nread > 0) {
        if (pd->isExec) {
            pd->stderrBuf.append(buf->base, nread);
        } else if (pd->stderrReaderRef != LUA_NOREF) {
            resume_reader(pd, pd->stderrReaderRef, buf->base, nread);
        } else {
            pd->stderrChunks.emplace_back(buf->base, nread);
        }
    }
    if (buf->base) delete[] buf->base;
    if (nread < 0) {
        uv_read_stop(stream);
        pd->stderrClosed = true;
        if (!uv_is_closing((uv_handle_t*)stream)) uv_close((uv_handle_t*)stream, nullptr);
        resume_reader(pd, pd->stderrReaderRef, nullptr, 0);
        try_resume_exec(pd);
    }
}

static void try_resume_shell(ProcessData* pd) {
    if (!pd->isShell) return;
    if (!pd->exited) return;

    EryxRuntime* rt = pd->rt;
    lua_State* GL = rt->GL;

    lua_getref(GL, pd->threadRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    lua_pushinteger(TL, (int)pd->exitStatus);
    eryx_push_thread(rt, pd->threadRef, 1, false);
}

static void process_exit_cb(uv_process_t* proc, int64_t exitStatus, int termSignal) {
    auto* pd = (ProcessData*)proc->data;
    pd->exitStatus = exitStatus;
    pd->termSignal = termSignal;
    pd->exited = true;

    uv_close((uv_handle_t*)proc, nullptr);

    if (pd->isShell) {
        try_resume_shell(pd);
    } else if (pd->isExec) {
        try_resume_exec(pd);
    }
}

// Parse the opts table (at stack index `idx`) for args, cwd, env, shell
// Returns a vector of C strings for args (including cmd as args[0])
struct SpawnOpts {
    std::vector<std::string> args;
    std::string cwd;
    std::vector<std::string> envStrings;
    bool shell;
};

// Helper: parse args array from stack index, returns vector with cmd as first element
static std::vector<std::string> parse_args(lua_State* L, const char* cmd, int argsIdx) {
    std::vector<std::string> args;
    args.push_back(cmd);
    if (argsIdx > 0 && lua_istable(L, argsIdx)) {
        int n = lua_objlen(L, argsIdx);
        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, argsIdx, i);
            if (lua_isstring(L, -1)) args.push_back(lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }
    return args;
}

// Determine if table at `idx` is an args array (has element at [1]) vs an opts table
static bool is_args_array(lua_State* L, int idx) {
    lua_rawgeti(L, idx, 1);
    bool isArray = !lua_isnil(L, -1);
    lua_pop(L, 1);
    return isArray;
}

static SpawnOpts parse_spawn_opts(lua_State* L, int optsIdx) {
    SpawnOpts opts;
    opts.shell = false;

    if (optsIdx > 0 && lua_istable(L, optsIdx)) {
        // cwd
        lua_getfield(L, optsIdx, "cwd");
        if (lua_isstring(L, -1)) {
            opts.cwd = lua_tostring(L, -1);
        }
        lua_pop(L, 1);

        // env
        lua_getfield(L, optsIdx, "env");
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2)) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    std::string entry =
                        std::string(lua_tostring(L, -2)) + "=" + lua_tostring(L, -1);
                    opts.envStrings.push_back(entry);
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        // shell
        lua_getfield(L, optsIdx, "shell");
        if (lua_isboolean(L, -1)) {
            opts.shell = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);
    }

    return opts;
}

static ProcessData* spawn_process(lua_State* L, const char* cmd, SpawnOpts& opts, bool isExec) {
    auto rt = eryx_get_runtime(L);

    auto* pd = new ProcessData();
    pd->rt = rt;
    pd->exited = false;
    pd->stdoutClosed = false;
    pd->stderrClosed = false;
    pd->exitStatus = 0;
    pd->termSignal = 0;
    pd->threadRef = LUA_NOREF;
    pd->processRef = LUA_NOREF;
    pd->stdoutReaderRef = LUA_NOREF;
    pd->stderrReaderRef = LUA_NOREF;
    pd->isExec = isExec;
    pd->isShell = false;

    // Init pipes
    uv_pipe_init(rt->loop, &pd->stdinPipe, 0);
    uv_pipe_init(rt->loop, &pd->stdoutPipe, 0);
    uv_pipe_init(rt->loop, &pd->stderrPipe, 0);

    pd->stdoutPipe.data = pd;
    pd->stderrPipe.data = pd;

    // Set up stdio containers
    uv_stdio_container_t stdio[3];
    stdio[0].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_READABLE_PIPE);
    stdio[0].data.stream = (uv_stream_t*)&pd->stdinPipe;
    stdio[1].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_WRITABLE_PIPE);
    stdio[1].data.stream = (uv_stream_t*)&pd->stdoutPipe;
    stdio[2].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_WRITABLE_PIPE);
    stdio[2].data.stream = (uv_stream_t*)&pd->stderrPipe;

    // Build args array for uv_spawn
    std::string actualCmd;
    std::vector<std::string> actualArgs;

    if (opts.shell) {
#ifdef _WIN32
        actualCmd = "cmd.exe";
        actualArgs.push_back("cmd.exe");
        actualArgs.push_back("/C");
#else
        actualCmd = "/bin/sh";
        actualArgs.push_back("/bin/sh");
        actualArgs.push_back("-c");
#endif
        // Join all args into a single command string
        std::string fullCmd = cmd;
        for (size_t i = 1; i < opts.args.size(); i++) {
            fullCmd += " " + opts.args[i];
        }
        actualArgs.push_back(fullCmd);
    } else {
        actualCmd = cmd;
        actualArgs = opts.args;
    }

    std::vector<char*> argv;
    for (auto& a : actualArgs) {
        argv.push_back(a.data());
    }
    argv.push_back(nullptr);

    // Build env array
    std::vector<char*> envp;
    if (!opts.envStrings.empty()) {
        for (auto& e : opts.envStrings) {
            envp.push_back(e.data());
        }
        envp.push_back(nullptr);
    }

    uv_process_options_t procOpts = {};
    procOpts.exit_cb = process_exit_cb;
    procOpts.file = actualCmd.c_str();
    procOpts.args = argv.data();
    procOpts.stdio = stdio;
    procOpts.stdio_count = 3;
    if (!opts.cwd.empty()) procOpts.cwd = opts.cwd.c_str();
    if (!envp.empty()) procOpts.env = envp.data();

    pd->process.data = pd;

    int r = uv_spawn(rt->loop, &pd->process, &procOpts);
    if (r != 0) {
        // Clean up pipes
        uv_close((uv_handle_t*)&pd->stdinPipe, nullptr);
        uv_close((uv_handle_t*)&pd->stdoutPipe, nullptr);
        uv_close((uv_handle_t*)&pd->stderrPipe, nullptr);
        delete pd;
        luaL_error(L, "failed to spawn process '%s': %s", cmd, uv_strerror(r));
        return nullptr;
    }

    // Start reading stdout/stderr
    uv_read_start((uv_stream_t*)&pd->stdoutPipe, alloc_cb, stdout_read_cb);
    uv_read_start((uv_stream_t*)&pd->stderrPipe, alloc_cb, stderr_read_cb);

    return pd;
}

// ---------------------------------------------------------------------------
// os.exec(cmd, opts?) -> yields -> {stdout, stderr, code}
// ---------------------------------------------------------------------------
static int os_exec(lua_State* L) {
    const char* cmd = luaL_checkstring(L, 1);

    int argsIdx = 0;
    int optsIdx = 0;

    if (lua_istable(L, 2)) {
        if (is_args_array(L, 2)) {
            argsIdx = 2;
            optsIdx = lua_istable(L, 3) ? 3 : 0;
        } else {
            optsIdx = 2;
        }
    }

    auto opts = parse_spawn_opts(L, optsIdx);
    opts.args = parse_args(L, cmd, argsIdx);

    ProcessData* pd = spawn_process(L, cmd, opts, true);

    // Close stdin immediately for exec (we don't write to it)
    uv_close((uv_handle_t*)&pd->stdinPipe, nullptr);

    // Ref the current thread so we can resume it later
    lua_pushthread(L);
    pd->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// os.shell(cmd, opts?) -> yields -> number (exit code)
//   Runs cmd through the system shell with inherited stdio.
//   stdout/stderr go directly to the console.
// ---------------------------------------------------------------------------
static int os_shell(lua_State* L) {
    const char* cmd = luaL_checkstring(L, 1);
    int optsIdx = lua_istable(L, 2) ? 2 : 0;
    auto opts = parse_spawn_opts(L, optsIdx);

    opts.shell = true;
    opts.args.push_back(cmd);

    auto rt = eryx_get_runtime(L);

    auto* pd = new ProcessData();
    pd->rt = rt;
    pd->exited = false;
    pd->stdoutClosed = true;  // no pipes to wait on
    pd->stderrClosed = true;
    pd->exitStatus = 0;
    pd->termSignal = 0;
    pd->threadRef = LUA_NOREF;
    pd->processRef = LUA_NOREF;
    pd->stdoutReaderRef = LUA_NOREF;
    pd->stderrReaderRef = LUA_NOREF;
    pd->isExec = false;
    pd->isShell = true;

    // We don't need pipes — inherit parent stdio
    uv_stdio_container_t stdio[3];
    stdio[0].flags = UV_INHERIT_FD;
    stdio[0].data.fd = 0;
    stdio[1].flags = UV_INHERIT_FD;
    stdio[1].data.fd = 1;
    stdio[2].flags = UV_INHERIT_FD;
    stdio[2].data.fd = 2;

    // Build shell command
#ifdef _WIN32
    std::string actualCmd = "cmd.exe";
    std::string fullCmd = cmd;
    std::vector<std::string> actualArgs = { "cmd.exe", "/C", fullCmd };
#else
    std::string actualCmd = "/bin/sh";
    std::string fullCmd = cmd;
    std::vector<std::string> actualArgs = { "/bin/sh", "-c", fullCmd };
#endif

    std::vector<char*> argv;
    for (auto& a : actualArgs) argv.push_back(a.data());
    argv.push_back(nullptr);

    // Build env array
    std::vector<char*> envp;
    if (!opts.envStrings.empty()) {
        for (auto& e : opts.envStrings) envp.push_back(e.data());
        envp.push_back(nullptr);
    }

    uv_process_options_t procOpts = {};
    procOpts.exit_cb = process_exit_cb;
    procOpts.file = actualCmd.c_str();
    procOpts.args = argv.data();
    procOpts.stdio = stdio;
    procOpts.stdio_count = 3;
    if (!opts.cwd.empty()) procOpts.cwd = opts.cwd.c_str();
    if (!envp.empty()) procOpts.env = envp.data();

    pd->process.data = pd;

    int r = uv_spawn(rt->loop, &pd->process, &procOpts);
    if (r != 0) {
        delete pd;
        luaL_error(L, "failed to spawn shell command '%s': %s", cmd, uv_strerror(r));
        return 0;
    }

    lua_pushthread(L);
    pd->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// os.spawn(cmd, args?, opts?) -> ProcessHandle userdata
// ---------------------------------------------------------------------------

static const char* PROCESS_HANDLE_MT = "ProcessHandle";

struct ProcessHandle {
    ProcessData* pd;
};

static ProcessData* check_process(lua_State* L, int idx) {
    auto* h = (ProcessHandle*)luaL_checkudata(L, idx, PROCESS_HANDLE_MT);
    if (!h->pd) luaL_error(L, "process handle is invalid");
    return h->pd;
}

// ProcessHandle:wait() -> yields -> {stdout, stderr, code}
static int process_wait(lua_State* L) {
    auto* pd = check_process(L, 1);

    if (pd->exited && pd->stdoutClosed && pd->stderrClosed) {
        // Already done, return immediately
        lua_newtable(L);
        lua_pushlstring(L, pd->stdoutBuf.data(), pd->stdoutBuf.size());
        lua_setfield(L, -2, "stdout");
        lua_pushlstring(L, pd->stderrBuf.data(), pd->stderrBuf.size());
        lua_setfield(L, -2, "stderr");
        lua_pushinteger(L, (int)pd->exitStatus);
        lua_setfield(L, -2, "code");
        return 1;
    }

    // Yield until process completes
    pd->isExec = true;  // reuse exec resume path
    lua_pushthread(L);
    pd->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    return lua_yield(L, 0);
}

// ProcessHandle:kill(signal?)
static int process_kill(lua_State* L) {
    auto* pd = check_process(L, 1);
    int signum = (int)luaL_optinteger(L, 2, SIGTERM);
    if (!pd->exited) {
        uv_process_kill(&pd->process, signum);
    }
    return 0;
}

// ProcessHandle:write(data) - write to stdin
static void write_cb(uv_write_t* req, int) {
    auto* buf = (uv_buf_t*)req->data;
    delete[] buf->base;
    delete buf;
    delete req;
}

static int process_write(lua_State* L) {
    auto* pd = check_process(L, 1);
    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);

    auto* req = new uv_write_t;
    auto* buf = new uv_buf_t;
    char* copy = new char[len];
    memcpy(copy, data, len);
    buf->base = copy;
    buf->len = (decltype(buf->len))len;
    req->data = buf;

    int r = uv_write(req, (uv_stream_t*)&pd->stdinPipe, buf, 1, write_cb);
    if (r != 0) {
        delete[] copy;
        delete buf;
        delete req;
        luaL_error(L, "failed to write to process stdin: %s", uv_strerror(r));
    }
    return 0;
}

// ProcessHandle:closeStdin()
static int process_close_stdin(lua_State* L) {
    auto* pd = check_process(L, 1);
    if (!uv_is_closing((uv_handle_t*)&pd->stdinPipe)) {
        uv_close((uv_handle_t*)&pd->stdinPipe, nullptr);
    }
    return 0;
}

// ProcessHandle:readStdout() -> yields -> string? (nil on EOF)
static int process_read_stdout(lua_State* L) {
    auto* pd = check_process(L, 1);

    // If there are queued chunks, return the first one immediately
    if (!pd->stdoutChunks.empty()) {
        auto& chunk = pd->stdoutChunks.front();
        lua_pushlstring(L, chunk.data(), chunk.size());
        pd->stdoutChunks.pop_front();
        return 1;
    }

    // If pipe is closed, return nil (EOF)
    if (pd->stdoutClosed) {
        lua_pushnil(L);
        return 1;
    }

    // Yield until data arrives
    lua_pushthread(L);
    pd->stdoutReaderRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return lua_yield(L, 0);
}

// ProcessHandle:readStderr() -> yields -> string? (nil on EOF)
static int process_read_stderr(lua_State* L) {
    auto* pd = check_process(L, 1);

    if (!pd->stderrChunks.empty()) {
        auto& chunk = pd->stderrChunks.front();
        lua_pushlstring(L, chunk.data(), chunk.size());
        pd->stderrChunks.pop_front();
        return 1;
    }

    if (pd->stderrClosed) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushthread(L);
    pd->stderrReaderRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return lua_yield(L, 0);
}

// ProcessHandle.pid
static int process_index(lua_State* L) {
    auto* pd = check_process(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "pid") == 0) {
        lua_pushinteger(L, pd->process.pid);
        return 1;
    }

    if (strcmp(key, "status") == 0) {
        if (pd->exited) {
            lua_pushinteger(L, (int)pd->exitStatus);
        } else {
            lua_pushnil(L);
        }
        return 1;
    }

    // Check methods in the metatable
    luaL_getmetatable(L, PROCESS_HANDLE_MT);
    lua_getfield(L, -1, key);
    return 1;
}

static int process_gc(lua_State* L) {
    auto* h = (ProcessHandle*)luaL_checkudata(L, 1, PROCESS_HANDLE_MT);
    if (h->pd && !h->pd->exited) {
        uv_process_kill(&h->pd->process, SIGTERM);
    }
    // Note: pd is cleaned up by libuv close callbacks
    h->pd = nullptr;
    return 0;
}

static void register_process_metatable(lua_State* L) {
    if (luaL_newmetatable(L, PROCESS_HANDLE_MT)) {
        lua_pushcfunction(L, process_wait, "Wait");
        lua_setfield(L, -2, "Wait");

        lua_pushcfunction(L, process_kill, "Kill");
        lua_setfield(L, -2, "Kill");

        lua_pushcfunction(L, process_write, "Write");
        lua_setfield(L, -2, "Write");

        lua_pushcfunction(L, process_close_stdin, "CloseStdin");
        lua_setfield(L, -2, "CloseStdin");

        lua_pushcfunction(L, process_read_stdout, "ReadStdout");
        lua_setfield(L, -2, "ReadStdout");

        lua_pushcfunction(L, process_read_stderr, "ReadStderr");
        lua_setfield(L, -2, "ReadStderr");

        lua_pushcfunction(L, process_index, "__index");
        lua_setfield(L, -2, "__index");

        lua_pushcfunction(L, process_gc, "__gc");
        lua_setfield(L, -2, "__gc");

        lua_pushstring(L, PROCESS_HANDLE_MT);
        lua_setfield(L, -2, "__type");
    }
    lua_pop(L, 1);
}

static int os_spawn(lua_State* L) {
    const char* cmd = luaL_checkstring(L, 1);

    int argsIdx = 0;
    int optsIdx = 0;

    if (lua_istable(L, 2)) {
        if (is_args_array(L, 2)) {
            argsIdx = 2;
            optsIdx = lua_istable(L, 3) ? 3 : 0;
        } else {
            optsIdx = 2;
        }
    }

    auto opts = parse_spawn_opts(L, optsIdx);
    opts.args = parse_args(L, cmd, argsIdx);

    ProcessData* pd = spawn_process(L, cmd, opts, false);

    // Create userdata
    auto* h = (ProcessHandle*)lua_newuserdata(L, sizeof(ProcessHandle));
    h->pd = pd;
    luaL_getmetatable(L, PROCESS_HANDLE_MT);
    lua_setmetatable(L, -2);

    return 1;
}

// ===========================================================================
// Module entry
// ===========================================================================

LUAU_MODULE_EXPORT int luauopen_os(lua_State* L) {
    register_process_metatable(L);

    lua_newtable(L);

    // Environment
    lua_pushcfunction(L, os_getenv, "getenv");
    lua_setfield(L, -2, "getenv");
    lua_pushcfunction(L, os_setenv, "setenv");
    lua_setfield(L, -2, "setenv");
    lua_pushcfunction(L, os_environ, "environ");
    lua_setfield(L, -2, "environ");

    // System info
    lua_pushcfunction(L, os_luauversion, "luauVersion");
    lua_setfield(L, -2, "luauVersion");
    lua_pushcfunction(L, os_platform, "platform");
    lua_setfield(L, -2, "platform");
    lua_pushcfunction(L, os_arch, "arch");
    lua_setfield(L, -2, "arch");
    lua_pushcfunction(L, os_hostname, "hostname");
    lua_setfield(L, -2, "hostname");
    lua_pushcfunction(L, os_tmpdir, "tmpdir");
    lua_setfield(L, -2, "tmpdir");
    lua_pushcfunction(L, os_homedir, "homedir");
    lua_setfield(L, -2, "homedir");
    lua_pushcfunction(L, os_cpucount, "cpucount");
    lua_setfield(L, -2, "cpucount");
    lua_pushcfunction(L, os_totalmem, "totalmem");
    lua_setfield(L, -2, "totalmem");
    lua_pushcfunction(L, os_freemem, "freemem");
    lua_setfield(L, -2, "freemem");
    lua_pushcfunction(L, os_uptime, "uptime");
    lua_setfield(L, -2, "uptime");
    lua_pushcfunction(L, os_pid, "pid");
    lua_setfield(L, -2, "pid");

    // Misc
    lua_pushcfunction(L, os_exit, "exit");
    lua_setfield(L, -2, "exit");
    lua_pushcfunction(L, os_clock, "clock");
    lua_setfield(L, -2, "clock");
    lua_pushcfunction(L, os_cwd, "cwd");
    lua_setfield(L, -2, "cwd");
    lua_pushcfunction(L, os_chdir, "chdir");
    lua_setfield(L, -2, "chdir");
    lua_pushcfunction(L, os_cliargs, "cliargs");
    lua_setfield(L, -2, "cliargs");

    // Child processes
    lua_pushcfunction(L, os_exec, "exec");
    lua_setfield(L, -2, "exec");
    lua_pushcfunction(L, os_shell, "shell");
    lua_setfield(L, -2, "shell");
    lua_pushcfunction(L, os_spawn, "spawn");
    lua_setfield(L, -2, "spawn");

    return 1;
}
