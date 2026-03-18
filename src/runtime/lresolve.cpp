#include "lresolve.hpp"

#include <filesystem>

#include "lconfig.hpp"
#include "lexception.hpp"
#include "lua.h"
#include "../vfs.hpp"
#include "embedded_modules.h"

namespace fs = std::filesystem;

static fs::path getExecutableDir() {
#if defined(_WIN32)
    wchar_t buf[MAX_PATH];
    DWORD len = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    return fs::path(std::wstring(buf, len)).parent_path();
#elif defined(__APPLE__)
    char buf[4096];
    uint32_t len = sizeof(buf);
    _NSGetExecutablePath(buf, &len);
    return fs::canonical(buf).parent_path();
#else
    return fs::canonical("/proc/self/exe").parent_path();
#endif
}

static EmbeddedModuleEntry eryx_find_embedded_native(const char* modulePath) {
    auto* modules = eryx_get_embedded_native_modules();
    if (!modules) return nullptr;
    for (auto m = modules; m->modulePath; ++m) {
        if (strcmp(m->modulePath, modulePath) == 0) return m->entry;
    }
    return nullptr;
}
static const char* eryx_find_embedded_script(const char* modulePath) {
    auto* modules = eryx_get_embedded_script_modules();
    if (!modules) return nullptr;
    for (const EmbeddedScriptModule* m = modules; m->modulePath; ++m) {
        if (strcmp(m->modulePath, modulePath) == 0) return m->source;
    }
    return nullptr;
}
/**
 * We trust that all embedded scripts have been structured properly.
 *
 * Specifically, we will match on exactly one file. If multiple files
 * match, we do not raise an error.
 *
 * This conflicts with the specification, but as all embedded scripts
 * are authored by us we can ensure that this condition is impossible.
 *
 * In the off-chance it does occur, `foo` is resolved before `foo/init`.
 */
static std::optional<LocatedModule> eryx_resolve_embedded(std::string key) {
    if (!eryx_has_embedded_modules()) return std::nullopt;

    // Try native first (mirrors DLL-before-script priority)
    if (eryx_find_embedded_native(key.c_str()))
        return LocatedModule{ .path = key, .type = LocatedModule::TYPE_EMBEDDED_NATIVE };

    // Try script
    if (eryx_find_embedded_script(key.c_str()))
        return LocatedModule{ .path = key, .type = LocatedModule::TYPE_EMBEDDED_SCRIPT };

    // Try init pattern for directory-style modules
    std::string init_key = key + "/init";
    if (eryx_find_embedded_script(init_key.c_str()))
        return LocatedModule{ .path = init_key, .type = LocatedModule::TYPE_EMBEDDED_SCRIPT };

    return std::nullopt;
}

RequireContext eryx_get_require_context(lua_State* L) {
    RequireContext ctx;
    ctx.root = fs::current_path();

    lua_Debug ar;
    std::string caller_path;
    for (int level = 1;; level++) {
        if (lua_getinfo(L, level, "s", &ar)) {
            // Work up the stack until we find something that's actually a file
            if (!ar.source || ar.source[0] != '@') {
                continue;
            }

            // Detect @@eryx/ chunk names (embedded modules)
            if (strncmp(ar.source, CHUNK_PREFIX_ERYX, CHUNK_PREFIX_ERYX_LEN) == 0) {
                ctx.isEmbedded = true;
                std::string key = ar.source + 7;  // e.g. "encoding/init"

                // selfDir = directory portion of the key
                size_t lastSlash = key.rfind('/');
                ctx.embeddedSelfDir =
                    (lastSlash != std::string::npos) ? key.substr(0, lastSlash) : "";

                // Check if this is an init module
                std::string stem =
                    (lastSlash != std::string::npos) ? key.substr(lastSlash + 1) : key;
                if (stem == "init") {
                    ctx.isInit = true;
                    // For init files, callerDir is the parent of selfDir
                    size_t parentSlash = ctx.embeddedSelfDir.rfind('/');
                    ctx.embeddedCallerDir = (parentSlash != std::string::npos)
                                                ? ctx.embeddedSelfDir.substr(0, parentSlash)
                                                : "";
                } else {
                    ctx.embeddedCallerDir = ctx.embeddedSelfDir;
                }
                return ctx;
            }

            // Detect @@vfs/ chunk names (VFS modules)
            if (strncmp(ar.source, CHUNK_PREFIX_VFS, CHUNK_PREFIX_VFS_LEN) == 0) {
                ctx.isVFS = true;
                std::string key = ar.source + 6;  // e.g. "docgen/modules.luau"

                // Strip extension (.lua / .luau)
                if (key.size() > 5 && key.substr(key.size() - 5) == ".luau")
                    key = key.substr(0, key.size() - 5);
                else if (key.size() > 4 && key.substr(key.size() - 4) == ".lua")
                    key = key.substr(0, key.size() - 4);

                // selfDir = directory portion of the key
                size_t lastSlash = key.rfind('/');
                ctx.vfsSelfDir = (lastSlash != std::string::npos) ? key.substr(0, lastSlash) : "";

                // Check if this is an init module
                std::string stem =
                    (lastSlash != std::string::npos) ? key.substr(lastSlash + 1) : key;
                if (stem == "init") {
                    ctx.isInit = true;
                    size_t parentSlash = ctx.vfsSelfDir.rfind('/');
                    ctx.vfsCallerDir = (parentSlash != std::string::npos)
                                           ? ctx.vfsSelfDir.substr(0, parentSlash)
                                           : "";
                } else {
                    ctx.vfsCallerDir = ctx.vfsSelfDir;
                }
                return ctx;
            }

            // Remove the leading "@"
            caller_path = ar.source + 1;
            break;
        } else {
            break;
        }
    }

    ctx.selfDir = caller_path.empty() ? ctx.root : fs::path(caller_path).parent_path();
    // If the chunk name was just a filename (e.g. "run_tests.luau"), parent_path() is empty.
    // Fall back to cwd so relative requires still work.
    if (ctx.selfDir.empty()) ctx.selfDir = ctx.root;

    // Check if the caller is an init.luau / init.lua file
    if (!caller_path.empty()) {
        if (fs::path(caller_path).stem().string() == "init") {
            ctx.isInit = true;
            // In an init file, "./" refers to the parent directory
            // (the directory containing the folder this init file represents)
            ctx.callerDir = ctx.selfDir.parent_path();
            return ctx;
        }
    }

    ctx.callerDir = ctx.selfDir;
    return ctx;
}

std::vector<LocatedModule> eryx_resolve_modules(lua_State* L, const std::string path) {
    // Figure out our current context
    RequireContext ctx = eryx_get_require_context(L);

    std::vector<LocatedModule> locatedModules;

    fs::path resolvedPath;

    // Alias resolution
    if (path[0] == '@') {
        std::string alias, modulePath;

        size_t firstSlash = path.find('/', 1);
        if (firstSlash == std::string::npos) {
            alias = path.substr(1);
            modulePath = "";
        } else {
            alias = path.substr(1, firstSlash - 1);
            modulePath = path.substr(firstSlash + 1);
        }

        // Strip trailing slashes (e.g. "@self/" produces empty modulePath)
        while (!modulePath.empty() && modulePath.back() == '/') modulePath.pop_back();

        // Config aliases take priority over all built-in alias behavior
        fs::path configSearchStart;
        std::string vfsConfigDir;
        if (!ctx.callerDir.empty()) {
            configSearchStart = ctx.callerDir;
        } else if (ctx.isVFS) {
            vfsConfigDir = ctx.vfsCallerDir;
        } else {
            configSearchStart = ctx.root;
        }
        auto cfg = eryx_locate_config(L, configSearchStart, std::nullopt, vfsConfigDir);
        auto it = cfg->aliases.find(alias);

        if (it != cfg->aliases.end()) {
            // Explicit config alias — always wins
            resolvedPath = fs::weakly_canonical(fs::path(it->second.qualified) / fs::path(modulePath));
        }
        // @self from a VFS module — try VFS first, fall through to filesystem
        else if (ctx.isVFS && alias == "self") {
            std::string key;
            if (modulePath.empty())
                key = ctx.vfsSelfDir;
            else if (ctx.vfsSelfDir.empty())
                key = modulePath;
            else
                key = ctx.vfsSelfDir + "/" + modulePath;

            std::string vfsCandidates[] = {
                key + ".luau",
                key + ".lua",
                key + "/init.luau",
                key + "/init.lua",
            };
            for (auto& c : vfsCandidates) {
                if (c.ends_with(".config.luau")) continue;
                if (!vfs_read_file(c).empty()) {
                    locatedModules.push_back(
                        LocatedModule{ .path = c, .type = LocatedModule::TYPE_VFS });
                }
            }
            if (!locatedModules.empty()) return locatedModules;
            // Fall through to filesystem @self resolution
            resolvedPath = fs::weakly_canonical(ctx.root / fs::path(key));
        }
        // @eryx — try embedded modules first, then fall back to filesystem
        else if (alias == "eryx") {
            auto module = eryx_resolve_embedded(modulePath);
            if (module) {
                locatedModules.push_back(*module);
                return locatedModules;
            }
            // Fall back to [exe dir]/modules
            resolvedPath = fs::weakly_canonical(getExecutableDir() / "modules" / fs::path(modulePath));
        }
        // @self from an embedded module — try embedded first, fall through to filesystem
        else if (ctx.isEmbedded && alias == "self") {
            std::string key;
            if (modulePath.empty())
                key = ctx.embeddedSelfDir;
            else if (ctx.embeddedSelfDir.empty())
                key = modulePath;
            else
                key = ctx.embeddedSelfDir + "/" + modulePath;
            auto module = eryx_resolve_embedded(key);
            if (module) {
                locatedModules.push_back(*module);
                return locatedModules;
            }
            // Fall through to filesystem @self resolution
            resolvedPath = fs::weakly_canonical(ctx.selfDir / fs::path(modulePath));
        }
        else if (alias == "self") {
            resolvedPath = fs::weakly_canonical(ctx.selfDir / fs::path(modulePath));
        } else {
            luaL_error(L, "Require %s used undefined alias '@%s'", path.c_str(), alias.c_str());
        }

    } else if (!(path.starts_with("./") || path.starts_with("../"))) {
        luaL_error(L, "Require path must always start with @, ./ or ../");
    } else {
        // Try VFS first for relative requires from VFS modules
        if (ctx.isVFS) {
            fs::path combined = fs::path(ctx.vfsCallerDir) / fs::path(path);
            std::string base = combined.lexically_normal().generic_string();

            std::string vfsCandidates[] = {
                base + ".luau",
                base + ".lua",
                base + "/init.luau",
                base + "/init.lua",
            };
            for (auto& c : vfsCandidates) {
                if (c.ends_with(".config.luau")) continue;
                if (!vfs_read_file(c).empty()) {
                    locatedModules.push_back(
                        LocatedModule{ .path = c, .type = LocatedModule::TYPE_VFS });
                }
            }
            if (!locatedModules.empty()) return locatedModules;

            // VFS lookup failed — if not isolated, try filesystem from exe dir
            // for paths that resolve at or above the VFS root level.
            // Paths that stay inside a VFS subdirectory do not fall through.
            if (!vfs_is_isolated()) {
                bool atOrAboveRoot = base.starts_with("..") || base.find('/') == std::string::npos;
                if (atOrAboveRoot) {
                    resolvedPath = fs::weakly_canonical(getExecutableDir() / fs::path(base));
                }
            }
        }

        // Try embedded modules for relative requires from embedded modules
        if (ctx.isEmbedded) {
            fs::path combined = fs::path(ctx.embeddedCallerDir) / fs::path(path);
            std::string key = combined.lexically_normal().generic_string();
            auto module = eryx_resolve_embedded(key);
            if (module) {
                locatedModules.push_back(*module);
                return locatedModules;
            }
        }
        // Fall back to filesystem resolution
        if (!resolvedPath.empty()) {
            // Already set (e.g. by non-isolated VFS fallthrough)
        } else if (!ctx.callerDir.empty()) {
            resolvedPath = fs::weakly_canonical(ctx.callerDir / fs::path(path));
        } else {
            // Caller has no filesystem directory (e.g. purely embedded/VFS)
            // If we got here, neither VFS nor embedded found the module
            luaL_error(L, "Module %s not found", path.c_str());
        }
    }

    // VFS overlay — check virtual filesystem before the real one
    if (vfs_open()) {
        // Convert resolvedPath to a VFS-relative path (forward slashes, relative to root)
        std::string vfsBase = fs::relative(resolvedPath, ctx.root).generic_string();

        std::string vfsCandidates[] = {
            vfsBase + ".luau",
            vfsBase + ".lua",
            vfsBase + "/init.luau",
            vfsBase + "/init.lua",
        };

        for (auto& c : vfsCandidates) {
            if (c.ends_with(".config.luau")) continue;

            if (!vfs_read_file(c).empty()) {
                locatedModules.push_back(
                    LocatedModule{ .path = c, .type = LocatedModule::TYPE_VFS });
            }
        }

        if (!locatedModules.empty()) return locatedModules;
    }

    // Filesystem resolution
    fs::path candidates[] = {
        fs::path(resolvedPath).replace_extension(".luau"),
        fs::path(resolvedPath).replace_extension(".lua"),
        resolvedPath / "init.luau",
        resolvedPath / "init.lua",
    };

    for (int i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        // .config.luau files cannot be required!
        if (candidates[i].string().ends_with(".config.luau")) {
            continue;
        }

        if (fs::exists(candidates[i])) {
            // We always want to get a unicode string from our paths!
            auto u8 = candidates[i].u8string();

            locatedModules.push_back(LocatedModule{
                .path = std::string(reinterpret_cast<const char*>(u8.data()), u8.size()),
                .type = LocatedModule::TYPE_FILE });
        }
    }
    return locatedModules;

    // if (!fs::exists(resolvedPath)) {
    //     return std::nullopt;
    // }
    // return LocatedModule{ .path = resolvedPath.string(), .type = LocatedModule::TYPE_FILE };
}

std::optional<LocatedModule> eryx_resolve_module(lua_State* L, const std::string path) {
    auto modules = eryx_resolve_modules(L, path);
    if (modules.size() > 1) {
        std::string err = "Multiple candidates for require found:\n";
        for (const auto& i : modules) {
            err += "- " + i.path + "\n";
        }

        luaL_error(L, err.c_str());
    }

    if (modules.size() == 1) {
        return modules[0];
    }
    return std::nullopt;
}
