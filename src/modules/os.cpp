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
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <aclapi.h>
#include <sddl.h>
#include <shellapi.h>
#include <windows.h>
#else
#include <grp.h>
#include <pwd.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <csignal>

#endif

#include <algorithm>
#include <cctype>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <sstream>
#include <string>
#include <vector>

#include "../LuaUtil.hpp"
#include "../runtime/lexception.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_os",
};
LUAU_MODULE_INFO()

struct SignalEntry {
    const char* name;
    int value;
};

static std::string normalize_signal_name(const char* in) {
    std::string out;
    for (const char* p = in; *p; ++p) {
        char c = *p;
        if (c == '-' || c == '_' || c == ' ') continue;
        out.push_back((char)std::toupper((unsigned char)c));
    }
    if (out.rfind("SIG", 0) == 0) {
        out = out.substr(3);
    }
    return out;
}

static const std::vector<SignalEntry>& supported_signals() {
    static std::vector<SignalEntry> entries = [] {
        std::vector<SignalEntry> out;
#ifdef SIGHUP
        out.push_back({ "HUP", SIGHUP });
#endif
#ifdef SIGINT
        out.push_back({ "INT", SIGINT });
#endif
#ifdef SIGQUIT
        out.push_back({ "QUIT", SIGQUIT });
#endif
#ifdef SIGKILL
        out.push_back({ "KILL", SIGKILL });
#endif
#ifdef SIGTERM
        out.push_back({ "TERM", SIGTERM });
#endif
#ifdef SIGABRT
        out.push_back({ "ABRT", SIGABRT });
#endif
#ifdef SIGUSR1
        out.push_back({ "USR1", SIGUSR1 });
#endif
#ifdef SIGUSR2
        out.push_back({ "USR2", SIGUSR2 });
#endif
#ifdef SIGPIPE
        out.push_back({ "PIPE", SIGPIPE });
#endif
#ifdef SIGCHLD
        out.push_back({ "CHLD", SIGCHLD });
#endif
        return out;
    }();
    return entries;
}

static bool parse_signal_arg(lua_State* L, int idx, int* outSignal) {
    if (lua_isnoneornil(L, idx)) {
        *outSignal = SIGTERM;
        return true;
    }
    if (lua_isnumber(L, idx)) {
        *outSignal = (int)lua_tointeger(L, idx);
        return true;
    }
    if (lua_isstring(L, idx)) {
        std::string normalized = normalize_signal_name(lua_tostring(L, idx));
        for (const auto& sig : supported_signals()) {
            if (normalized == sig.name) {
                *outSignal = sig.value;
                return true;
            }
        }
    }
    return false;
}

#ifdef _WIN32
static bool sid_to_string(PSID sid, std::string& out) {
    LPSTR sidStr = nullptr;
    if (!ConvertSidToStringSidA(sid, &sidStr) || sidStr == nullptr) return false;
    out.assign(sidStr);
    LocalFree(sidStr);
    return true;
}

static bool open_current_process_token(HANDLE* outToken) {
    return OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, outToken) == TRUE;
}

static bool get_current_token_sid(TOKEN_INFORMATION_CLASS klass, std::string& sidOut) {
    HANDLE token = nullptr;
    if (!open_current_process_token(&token)) return false;
    DWORD needed = 0;
    GetTokenInformation(token, klass, nullptr, 0, &needed);
    if (needed == 0) {
        CloseHandle(token);
        return false;
    }
    std::vector<unsigned char> buffer(needed);
    if (!GetTokenInformation(token, klass, buffer.data(), needed, &needed)) {
        CloseHandle(token);
        return false;
    }
    bool ok = false;
    if (klass == TokenUser) {
        auto* user = (TOKEN_USER*)buffer.data();
        ok = sid_to_string(user->User.Sid, sidOut);
    } else if (klass == TokenPrimaryGroup) {
        auto* group = (TOKEN_PRIMARY_GROUP*)buffer.data();
        ok = sid_to_string(group->PrimaryGroup, sidOut);
    }
    CloseHandle(token);
    return ok;
}

static bool lookup_account_from_sid_string(const std::string& sidString, std::string& accountName,
                                           std::string& domain) {
    PSID sid = nullptr;
    if (!ConvertStringSidToSidA(sidString.c_str(), &sid)) return false;
    DWORD nameLen = 0;
    DWORD domainLen = 0;
    SID_NAME_USE use = SidTypeUnknown;
    LookupAccountSidA(nullptr, sid, nullptr, &nameLen, nullptr, &domainLen, &use);
    if (nameLen == 0) {
        LocalFree(sid);
        return false;
    }
    std::vector<char> name(nameLen);
    std::vector<char> dom(domainLen > 0 ? domainLen : 1);
    if (!LookupAccountSidA(nullptr, sid, name.data(), &nameLen, dom.data(), &domainLen, &use)) {
        LocalFree(sid);
        return false;
    }
    accountName.assign(name.data());
    domain.assign(domainLen > 0 ? dom.data() : "");
    LocalFree(sid);
    return true;
}

static bool lookup_sid_string_from_name(const char* name, std::string& sidOut) {
    DWORD sidSize = 0;
    DWORD domainSize = 0;
    SID_NAME_USE use = SidTypeUnknown;
    LookupAccountNameA(nullptr, name, nullptr, &sidSize, nullptr, &domainSize, &use);
    if (sidSize == 0) return false;
    std::vector<unsigned char> sidBuf(sidSize);
    std::vector<char> domain(domainSize > 0 ? domainSize : 1);
    if (!LookupAccountNameA(nullptr, name, sidBuf.data(), &sidSize, domain.data(), &domainSize,
                            &use)) {
        return false;
    }
    return sid_to_string((PSID)sidBuf.data(), sidOut);
}

static std::string read_profile_path_from_registry_sid(const std::string& sidString) {
    std::string key = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\" + sidString;
    DWORD type = 0;
    DWORD bytes = 0;
    if (RegGetValueA(HKEY_LOCAL_MACHINE, key.c_str(), "ProfileImagePath",
                     RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ, &type, nullptr,
                     &bytes) != ERROR_SUCCESS) {
        return "";
    }
    std::vector<char> buf(bytes > 1 ? bytes : 2, '\0');
    if (RegGetValueA(HKEY_LOCAL_MACHINE, key.c_str(), "ProfileImagePath",
                     RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ, &type, buf.data(),
                     &bytes) != ERROR_SUCCESS) {
        return "";
    }
    std::string value(buf.data());
    if (type == REG_EXPAND_SZ) {
        DWORD needed = ExpandEnvironmentStringsA(value.c_str(), nullptr, 0);
        if (needed > 0) {
            std::vector<char> expanded(needed);
            ExpandEnvironmentStringsA(value.c_str(), expanded.data(), needed);
            return std::string(expanded.data());
        }
    }
    return value;
}
#endif

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
    lua_pushnil(L);
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

static int os_uid(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (!get_current_token_sid(TokenUser, sid)) {
        luaL_error(L, "failed to resolve current user SID");
    }
    lua_pushlstring(L, sid.data(), sid.size());
#else
    lua_pushinteger(L, (lua_Integer)getuid());
#endif
    return 1;
}

static int os_gid(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (!get_current_token_sid(TokenPrimaryGroup, sid)) {
        luaL_error(L, "failed to resolve current primary group SID");
    }
    lua_pushlstring(L, sid.data(), sid.size());
#else
    lua_pushinteger(L, (lua_Integer)getgid());
#endif
    return 1;
}

static int os_euid(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (!get_current_token_sid(TokenUser, sid)) {
        luaL_error(L, "failed to resolve effective user SID");
    }
    lua_pushlstring(L, sid.data(), sid.size());
#else
    lua_pushinteger(L, (lua_Integer)geteuid());
#endif
    return 1;
}

static int os_egid(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (!get_current_token_sid(TokenPrimaryGroup, sid)) {
        luaL_error(L, "failed to resolve effective group SID");
    }
    lua_pushlstring(L, sid.data(), sid.size());
#else
    lua_pushinteger(L, (lua_Integer)getegid());
#endif
    return 1;
}

#ifndef _WIN32
static bool parse_uid_subject(lua_State* L, int idx, uid_t* outUid) {
    if (lua_isnoneornil(L, idx)) {
        *outUid = geteuid();
        return true;
    }
    if (lua_isnumber(L, idx)) {
        *outUid = (uid_t)lua_tointeger(L, idx);
        return true;
    }
    const char* value = luaL_checkstring(L, idx);
    passwd* pwByName = getpwnam(value);
    if (pwByName) {
        *outUid = pwByName->pw_uid;
        return true;
    }
    char* end = nullptr;
    long parsed = strtol(value, &end, 10);
    if (end && *end == '\0' && parsed >= 0) {
        *outUid = (uid_t)parsed;
        return true;
    }
    return false;
}

static bool parse_gid_subject(lua_State* L, int idx, gid_t* outGid) {
    if (lua_isnoneornil(L, idx)) {
        *outGid = getegid();
        return true;
    }
    if (lua_isnumber(L, idx)) {
        *outGid = (gid_t)lua_tointeger(L, idx);
        return true;
    }
    const char* value = luaL_checkstring(L, idx);
    group* grByName = getgrnam(value);
    if (grByName) {
        *outGid = grByName->gr_gid;
        return true;
    }
    char* end = nullptr;
    long parsed = strtol(value, &end, 10);
    if (end && *end == '\0' && parsed >= 0) {
        *outGid = (gid_t)parsed;
        return true;
    }
    return false;
}
#endif

static int os_userInfo(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (lua_isnoneornil(L, 1)) {
        if (!get_current_token_sid(TokenUser, sid)) {
            luaL_error(L, "failed to resolve current user SID");
        }
    } else if (lua_isstring(L, 1)) {
        sid = lua_tostring(L, 1);
        if (sid.rfind("S-", 0) != 0) {
            if (!lookup_sid_string_from_name(sid.c_str(), sid)) {
                luaL_error(L, "unable to resolve user '%s' to SID", lua_tostring(L, 1));
            }
        }
    } else {
        luaL_error(L, "userInfo subject must be SID string, account name, or nil");
    }

    std::string account;
    std::string domain;
    lookup_account_from_sid_string(sid, account, domain);

    lua_newtable(L);
    lua_pushliteral(L, "user");
    lua_setfield(L, -2, "kind");
    lua_pushliteral(L, "windows");
    lua_setfield(L, -2, "platform");
    lua_pushlstring(L, sid.data(), sid.size());
    lua_setfield(L, -2, "id");
    lua_pushlstring(L, sid.data(), sid.size());
    lua_setfield(L, -2, "sid");
    if (!account.empty()) {
        lua_pushlstring(L, account.data(), account.size());
        lua_setfield(L, -2, "name");
        lua_pushlstring(L, account.data(), account.size());
        lua_setfield(L, -2, "accountName");
    }
    if (!domain.empty()) {
        lua_pushlstring(L, domain.data(), domain.size());
        lua_setfield(L, -2, "domain");
    }
    std::string home = read_profile_path_from_registry_sid(sid);
    if (!home.empty()) {
        lua_pushlstring(L, home.data(), home.size());
        lua_setfield(L, -2, "home");
    }
    return 1;
#else
    uid_t uid = 0;
    if (!parse_uid_subject(L, 1, &uid)) {
        luaL_error(L, "unable to resolve user subject");
    }
    passwd* pw = getpwuid(uid);
    if (!pw) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    lua_pushliteral(L, "user");
    lua_setfield(L, -2, "kind");
#if defined(__APPLE__)
    lua_pushliteral(L, "macos");
#else
    lua_pushliteral(L, "linux");
#endif
    lua_setfield(L, -2, "platform");
    lua_pushinteger(L, (lua_Integer)pw->pw_uid);
    lua_setfield(L, -2, "id");
    lua_pushinteger(L, (lua_Integer)pw->pw_uid);
    lua_setfield(L, -2, "uid");
    lua_pushinteger(L, (lua_Integer)pw->pw_gid);
    lua_setfield(L, -2, "gid");
    if (pw->pw_name) {
        lua_pushstring(L, pw->pw_name);
        lua_setfield(L, -2, "name");
    }
    if (pw->pw_dir) {
        lua_pushstring(L, pw->pw_dir);
        lua_setfield(L, -2, "home");
    }
    if (pw->pw_shell) {
        lua_pushstring(L, pw->pw_shell);
        lua_setfield(L, -2, "shell");
    }
    return 1;
#endif
}

static int os_groupInfo(lua_State* L) {
#ifdef _WIN32
    std::string sid;
    if (lua_isnoneornil(L, 1)) {
        if (!get_current_token_sid(TokenPrimaryGroup, sid)) {
            luaL_error(L, "failed to resolve current primary group SID");
        }
    } else if (lua_isstring(L, 1)) {
        sid = lua_tostring(L, 1);
        if (sid.rfind("S-", 0) != 0) {
            if (!lookup_sid_string_from_name(sid.c_str(), sid)) {
                luaL_error(L, "unable to resolve group '%s' to SID", lua_tostring(L, 1));
            }
        }
    } else {
        luaL_error(L, "groupInfo subject must be SID string, account name, or nil");
    }

    std::string account;
    std::string domain;
    lookup_account_from_sid_string(sid, account, domain);

    lua_newtable(L);
    lua_pushliteral(L, "group");
    lua_setfield(L, -2, "kind");
    lua_pushliteral(L, "windows");
    lua_setfield(L, -2, "platform");
    lua_pushlstring(L, sid.data(), sid.size());
    lua_setfield(L, -2, "id");
    lua_pushlstring(L, sid.data(), sid.size());
    lua_setfield(L, -2, "sid");
    if (!account.empty()) {
        lua_pushlstring(L, account.data(), account.size());
        lua_setfield(L, -2, "name");
        lua_pushlstring(L, account.data(), account.size());
        lua_setfield(L, -2, "accountName");
    }
    if (!domain.empty()) {
        lua_pushlstring(L, domain.data(), domain.size());
        lua_setfield(L, -2, "domain");
    }
    return 1;
#else
    gid_t gid = 0;
    if (!parse_gid_subject(L, 1, &gid)) {
        luaL_error(L, "unable to resolve group subject");
    }
    group* gr = getgrgid(gid);
    if (!gr) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    lua_pushliteral(L, "group");
    lua_setfield(L, -2, "kind");
#if defined(__APPLE__)
    lua_pushliteral(L, "macos");
#else
    lua_pushliteral(L, "linux");
#endif
    lua_setfield(L, -2, "platform");
    lua_pushinteger(L, (lua_Integer)gr->gr_gid);
    lua_setfield(L, -2, "id");
    lua_pushinteger(L, (lua_Integer)gr->gr_gid);
    lua_setfield(L, -2, "gid");
    if (gr->gr_name) {
        lua_pushstring(L, gr->gr_name);
        lua_setfield(L, -2, "name");
    }
    return 1;
#endif
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
        lua_pushpath(L, std::string(buf, size));
    } else {
        luaL_error(L, "failed to get current working directory");
    }
    return 1;
}

static int os_chdir(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    int r = uv_chdir(path.c_str());
    if (r != 0) {
        luaL_error(L, "failed to change directory to '%s': %s", path.c_str(), uv_strerror(r));
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
    bool stdoutReaderWantsBuffer;
    bool stderrReaderWantsBuffer;

    int threadRef;   // ref to the waiting coroutine (for exec/wait)
    int processRef;  // self-ref to prevent GC (for spawn)
    int64_t exitStatus;
    int termSignal;
    bool exited;
    bool stdoutClosed;
    bool stderrClosed;
    bool isExec;   // true for os.exec (auto-collect output), false for os.spawn
    bool isShell;  // true for os.shell (inherit stdio, return code only)
    bool ownerAlive;
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

    bool wantsBuffer = false;
    if (&readerRef == &pd->stdoutReaderRef) {
        wantsBuffer = pd->stdoutReaderWantsBuffer;
        pd->stdoutReaderWantsBuffer = false;
    } else if (&readerRef == &pd->stderrReaderRef) {
        wantsBuffer = pd->stderrReaderWantsBuffer;
        pd->stderrReaderWantsBuffer = false;
    }

    if (data) {
        if (wantsBuffer) {
            void* out = lua_newbuffer(TL, len);
            if (len > 0) memcpy(out, data, len);
        } else {
            lua_pushlstring(TL, data, len);
        }
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
        pd->stdoutBuf.append(buf->base, nread);
        if (!pd->isExec && pd->stdoutReaderRef != LUA_NOREF) {
            // A coroutine is waiting - resume it directly with this chunk
            resume_reader(pd, pd->stdoutReaderRef, buf->base, nread);
        } else if (!pd->isExec) {
            // Queue the chunk for later stdout:read() calls
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
        pd->stderrBuf.append(buf->base, nread);
        if (!pd->isExec && pd->stderrReaderRef != LUA_NOREF) {
            resume_reader(pd, pd->stderrReaderRef, buf->base, nread);
        } else if (!pd->isExec) {
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
        if (!lua_isnil(L, -1)) {
            opts.cwd = luaL_checkpathlike(L, -1);
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
    pd->stdoutReaderWantsBuffer = false;
    pd->stderrReaderWantsBuffer = false;
    pd->isExec = isExec;
    pd->isShell = false;
    pd->ownerAlive = true;

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
    pd->stdoutReaderWantsBuffer = false;
    pd->stderrReaderWantsBuffer = false;
    pd->isExec = false;
    pd->isShell = true;
    pd->ownerAlive = true;

    // We don't need pipes - inherit parent stdio
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
static const char* PROCESS_STDIN_STREAM_MT = "ProcessStdinStream";
static const char* PROCESS_STDOUT_STREAM_MT = "ProcessStdoutStream";
static const char* PROCESS_STDERR_STREAM_MT = "ProcessStderrStream";

struct ProcessHandle {
    ProcessData* pd;
};

struct ProcessStdinStreamHandle {
    ProcessData* pd;
};

struct ProcessStdoutStreamHandle {
    ProcessData* pd;
};

struct ProcessStderrStreamHandle {
    ProcessData* pd;
};

static const char* check_bytes_arg(lua_State* L, int idx, size_t* len) {
    const void* bufData = lua_tobuffer(L, idx, len);
    if (bufData) return (const char*)bufData;
    return luaL_checklstring(L, idx, len);
}

static ProcessData* check_process(lua_State* L, int idx) {
    auto* h = (ProcessHandle*)luaL_checkudata(L, idx, PROCESS_HANDLE_MT);
    if (!h->pd) luaL_error(L, "process handle is invalid");
    return h->pd;
}

static ProcessData* check_stdin_stream(lua_State* L, int idx) {
    auto* h = (ProcessStdinStreamHandle*)luaL_checkudata(L, idx, PROCESS_STDIN_STREAM_MT);
    if (!h->pd || !h->pd->ownerAlive) luaL_error(L, "process stream is invalid");
    return h->pd;
}

static ProcessData* check_stdout_stream(lua_State* L, int idx) {
    auto* h = (ProcessStdoutStreamHandle*)luaL_checkudata(L, idx, PROCESS_STDOUT_STREAM_MT);
    if (!h->pd || !h->pd->ownerAlive) luaL_error(L, "process stream is invalid");
    return h->pd;
}

static ProcessData* check_stderr_stream(lua_State* L, int idx) {
    auto* h = (ProcessStderrStreamHandle*)luaL_checkudata(L, idx, PROCESS_STDERR_STREAM_MT);
    if (!h->pd || !h->pd->ownerAlive) luaL_error(L, "process stream is invalid");
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
    int signum = SIGTERM;
    if (!parse_signal_arg(L, 2, &signum)) {
        luaL_error(L, "invalid signal; expected number or signal name like TERM/SIGTERM");
    }
    if (!pd->exited) {
        uv_process_kill(&pd->process, signum);
    }
    return 0;
}

// stdin:write(data)
static void write_cb(uv_write_t* req, int) {
    auto* buf = (uv_buf_t*)req->data;
    delete[] buf->base;
    delete buf;
    delete req;
}

static int process_stdin_write(lua_State* L) {
    auto* pd = check_stdin_stream(L, 1);
    size_t len;
    const char* data = check_bytes_arg(L, 2, &len);

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
    lua_pushinteger(L, (int)len);
    return 1;
}

static int process_stdin_write_sync(lua_State* L) { return process_stdin_write(L); }

// stdin:close()
static int process_stdin_close(lua_State* L) {
    auto* pd = check_stdin_stream(L, 1);
    if (!uv_is_closing((uv_handle_t*)&pd->stdinPipe)) {
        uv_close((uv_handle_t*)&pd->stdinPipe, nullptr);
    }
    return 0;
}

static int process_stdin_close_sync(lua_State* L) { return process_stdin_close(L); }

static int process_stream_read_impl(lua_State* L, std::deque<std::string>& chunks, bool& isClosed,
                                    int& readerRef, bool& readerWantsBuffer, bool canYield,
                                    bool returnBuffer) {
    if (!chunks.empty()) {
        auto& chunk = chunks.front();
        if (returnBuffer) {
            void* out = lua_newbuffer(L, chunk.size());
            if (chunk.size() > 0) memcpy(out, chunk.data(), chunk.size());
        } else {
            lua_pushlstring(L, chunk.data(), chunk.size());
        }
        chunks.pop_front();
        return 1;
    }

    if (isClosed) {
        lua_pushnil(L);
        return 1;
    }

    if (!canYield) {
        lua_pushnil(L);
        return 1;
    }

    if (readerRef != LUA_NOREF) {
        luaL_error(L, "a read is already pending on this process stream");
    }

    lua_pushthread(L);
    readerRef = lua_ref(L, -1);
    readerWantsBuffer = returnBuffer;
    lua_pop(L, 1);
    return lua_yield(L, 0);
}

// stdout:read(size?) -> yields -> string?
static int process_stdout_read(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    return process_stream_read_impl(L, pd->stdoutChunks, pd->stdoutClosed, pd->stdoutReaderRef,
                                    pd->stdoutReaderWantsBuffer, true, false);
}

// stdout:readSync(size?) -> string?
static int process_stdout_read_sync(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    return process_stream_read_impl(L, pd->stdoutChunks, pd->stdoutClosed, pd->stdoutReaderRef,
                                    pd->stdoutReaderWantsBuffer, false, false);
}

// stdout:readBuffer(size?) -> yields -> buffer?
static int process_stdout_read_buffer(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    return process_stream_read_impl(L, pd->stdoutChunks, pd->stdoutClosed, pd->stdoutReaderRef,
                                    pd->stdoutReaderWantsBuffer, true, true);
}

// stdout:readBufferSync(size?) -> buffer?
static int process_stdout_read_buffer_sync(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    return process_stream_read_impl(L, pd->stdoutChunks, pd->stdoutClosed, pd->stdoutReaderRef,
                                    pd->stdoutReaderWantsBuffer, false, true);
}

static int process_stdout_close(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    if (!pd->stdoutClosed) {
        pd->stdoutClosed = true;
        if (!uv_is_closing((uv_handle_t*)&pd->stdoutPipe)) {
            uv_read_stop((uv_stream_t*)&pd->stdoutPipe);
            uv_close((uv_handle_t*)&pd->stdoutPipe, nullptr);
        }
    }
    resume_reader(pd, pd->stdoutReaderRef, nullptr, 0);
    return 0;
}

static int process_stdout_close_sync(lua_State* L) { return process_stdout_close(L); }

// stderr:read(size?) -> yields -> string?
static int process_stderr_read(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    return process_stream_read_impl(L, pd->stderrChunks, pd->stderrClosed, pd->stderrReaderRef,
                                    pd->stderrReaderWantsBuffer, true, false);
}

// stderr:readSync(size?) -> string?
static int process_stderr_read_sync(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    return process_stream_read_impl(L, pd->stderrChunks, pd->stderrClosed, pd->stderrReaderRef,
                                    pd->stderrReaderWantsBuffer, false, false);
}

// stderr:readBuffer(size?) -> yields -> buffer?
static int process_stderr_read_buffer(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    return process_stream_read_impl(L, pd->stderrChunks, pd->stderrClosed, pd->stderrReaderRef,
                                    pd->stderrReaderWantsBuffer, true, true);
}

// stderr:readBufferSync(size?) -> buffer?
static int process_stderr_read_buffer_sync(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    return process_stream_read_impl(L, pd->stderrChunks, pd->stderrClosed, pd->stderrReaderRef,
                                    pd->stderrReaderWantsBuffer, false, true);
}

static int process_stderr_close(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    if (!pd->stderrClosed) {
        pd->stderrClosed = true;
        if (!uv_is_closing((uv_handle_t*)&pd->stderrPipe)) {
            uv_read_stop((uv_stream_t*)&pd->stderrPipe);
            uv_close((uv_handle_t*)&pd->stderrPipe, nullptr);
        }
    }
    resume_reader(pd, pd->stderrReaderRef, nullptr, 0);
    return 0;
}

static int process_stderr_close_sync(lua_State* L) { return process_stderr_close(L); }

static int process_stdin_index(lua_State* L) {
    auto* pd = check_stdin_stream(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, uv_is_closing((uv_handle_t*)&pd->stdinPipe));
        return 1;
    }

    luaL_getmetatable(L, PROCESS_STDIN_STREAM_MT);
    lua_getfield(L, -1, key);
    return 1;
}

static int process_stdout_index(lua_State* L) {
    auto* pd = check_stdout_stream(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, pd->stdoutClosed);
        return 1;
    }

    luaL_getmetatable(L, PROCESS_STDOUT_STREAM_MT);
    lua_getfield(L, -1, key);
    return 1;
}

static int process_stderr_index(lua_State* L) {
    auto* pd = check_stderr_stream(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, pd->stderrClosed);
        return 1;
    }

    luaL_getmetatable(L, PROCESS_STDERR_STREAM_MT);
    lua_getfield(L, -1, key);
    return 1;
}

static void push_process_stdin_stream(lua_State* L, ProcessData* pd) {
    auto* h = (ProcessStdinStreamHandle*)lua_newuserdata(L, sizeof(ProcessStdinStreamHandle));
    h->pd = pd;
    luaL_getmetatable(L, PROCESS_STDIN_STREAM_MT);
    lua_setmetatable(L, -2);
}

static void push_process_stdout_stream(lua_State* L, ProcessData* pd) {
    auto* h = (ProcessStdoutStreamHandle*)lua_newuserdata(L, sizeof(ProcessStdoutStreamHandle));
    h->pd = pd;
    luaL_getmetatable(L, PROCESS_STDOUT_STREAM_MT);
    lua_setmetatable(L, -2);
}

static void push_process_stderr_stream(lua_State* L, ProcessData* pd) {
    auto* h = (ProcessStderrStreamHandle*)lua_newuserdata(L, sizeof(ProcessStderrStreamHandle));
    h->pd = pd;
    luaL_getmetatable(L, PROCESS_STDERR_STREAM_MT);
    lua_setmetatable(L, -2);
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

    if (strcmp(key, "stdin") == 0) {
        push_process_stdin_stream(L, pd);
        return 1;
    }

    if (strcmp(key, "stdout") == 0) {
        push_process_stdout_stream(L, pd);
        return 1;
    }

    if (strcmp(key, "stderr") == 0) {
        push_process_stderr_stream(L, pd);
        return 1;
    }

    // Check methods in the metatable
    luaL_getmetatable(L, PROCESS_HANDLE_MT);
    lua_getfield(L, -1, key);
    return 1;
}

static int process_gc(lua_State* L) {
    auto* h = (ProcessHandle*)luaL_checkudata(L, 1, PROCESS_HANDLE_MT);
    if (h->pd) {
        h->pd->ownerAlive = false;
    }
    if (h->pd && !h->pd->exited) {
        uv_process_kill(&h->pd->process, SIGTERM);
    }
    // Note: pd is cleaned up by libuv close callbacks
    h->pd = nullptr;
    return 0;
}

static void register_process_metatable(lua_State* L) {
    if (luaL_newmetatable(L, PROCESS_HANDLE_MT)) {
        lua_pushcfunction(L, process_wait, "wait");
        lua_setfield(L, -2, "wait");

        lua_pushcfunction(L, process_kill, "kill");
        lua_setfield(L, -2, "kill");

        lua_pushcfunction(L, process_index, "__index");
        lua_setfield(L, -2, "__index");

        lua_pushcfunction(L, process_gc, "__gc");
        lua_setfield(L, -2, "__gc");

        lua_pushstring(L, PROCESS_HANDLE_MT);
        lua_setfield(L, -2, "__type");
    }
    lua_pop(L, 1);
}

static void register_process_stream_metatables(lua_State* L) {
    if (luaL_newmetatable(L, PROCESS_STDIN_STREAM_MT)) {
        lua_pushcfunction(L, process_stdin_write, "write");
        lua_setfield(L, -2, "write");
        lua_pushcfunction(L, process_stdin_write_sync, "writeSync");
        lua_setfield(L, -2, "writeSync");
        lua_pushcfunction(L, process_stdin_close, "close");
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, process_stdin_close_sync, "closeSync");
        lua_setfield(L, -2, "closeSync");
        lua_pushcfunction(L, process_stdin_index, "__index");
        lua_setfield(L, -2, "__index");
        lua_pushstring(L, PROCESS_STDIN_STREAM_MT);
        lua_setfield(L, -2, "__type");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, PROCESS_STDOUT_STREAM_MT)) {
        lua_pushcfunction(L, process_stdout_read, "read");
        lua_setfield(L, -2, "read");
        lua_pushcfunction(L, process_stdout_read_sync, "readSync");
        lua_setfield(L, -2, "readSync");
        lua_pushcfunction(L, process_stdout_read_buffer, "readBuffer");
        lua_setfield(L, -2, "readBuffer");
        lua_pushcfunction(L, process_stdout_read_buffer_sync, "readBufferSync");
        lua_setfield(L, -2, "readBufferSync");
        lua_pushcfunction(L, process_stdout_close, "close");
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, process_stdout_close_sync, "closeSync");
        lua_setfield(L, -2, "closeSync");
        lua_pushcfunction(L, process_stdout_index, "__index");
        lua_setfield(L, -2, "__index");
        lua_pushstring(L, PROCESS_STDOUT_STREAM_MT);
        lua_setfield(L, -2, "__type");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, PROCESS_STDERR_STREAM_MT)) {
        lua_pushcfunction(L, process_stderr_read, "read");
        lua_setfield(L, -2, "read");
        lua_pushcfunction(L, process_stderr_read_sync, "readSync");
        lua_setfield(L, -2, "readSync");
        lua_pushcfunction(L, process_stderr_read_buffer, "readBuffer");
        lua_setfield(L, -2, "readBuffer");
        lua_pushcfunction(L, process_stderr_read_buffer_sync, "readBufferSync");
        lua_setfield(L, -2, "readBufferSync");
        lua_pushcfunction(L, process_stderr_close, "close");
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, process_stderr_close_sync, "closeSync");
        lua_setfield(L, -2, "closeSync");
        lua_pushcfunction(L, process_stderr_index, "__index");
        lua_setfield(L, -2, "__index");
        lua_pushstring(L, PROCESS_STDERR_STREAM_MT);
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

static void push_signal_constants(lua_State* L) {
    lua_newtable(L);
    const auto& entries = supported_signals();
    for (const auto& sig : entries) {
        lua_pushinteger(L, sig.value);
        lua_setfield(L, -2, sig.name);

        std::string sigAlias = std::string("SIG") + sig.name;
        lua_pushinteger(L, sig.value);
        lua_setfield(L, -2, sigAlias.c_str());
    }
    lua_setreadonly(L, -1, true);
}

// ===========================================================================
// Module entry
// ===========================================================================

LUAU_MODULE_EXPORT int luauopen_os(lua_State* L) {
    register_process_metatable(L);
    register_process_stream_metatables(L);

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
    lua_pushcfunction(L, os_uid, "uid");
    lua_setfield(L, -2, "uid");
    lua_pushcfunction(L, os_gid, "gid");
    lua_setfield(L, -2, "gid");
    lua_pushcfunction(L, os_euid, "euid");
    lua_setfield(L, -2, "euid");
    lua_pushcfunction(L, os_egid, "egid");
    lua_setfield(L, -2, "egid");
    lua_pushcfunction(L, os_userInfo, "userInfo");
    lua_setfield(L, -2, "userInfo");
    lua_pushcfunction(L, os_groupInfo, "groupInfo");
    lua_setfield(L, -2, "groupInfo");
    push_signal_constants(L);
    lua_setfield(L, -2, "signals");

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

    lua_setreadonly(L, -1, true);
    return 1;
}
