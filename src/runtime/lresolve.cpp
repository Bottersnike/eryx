#include "lresolve.hpp"

#include <algorithm>
#include <filesystem>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

#include "../vfs.hpp"
#include "_wrapper_lib.hpp"
#include "embedded_modules.h"
#include "lconfig.hpp"
#include "lexception.hpp"
#include "lua.h"

namespace fs = std::filesystem;

namespace {

std::string path_to_string(const fs::path& p) {
    if (p.empty()) return std::string();
    auto u8 = p.generic_u8string();
    return std::string(reinterpret_cast<const char*>(u8.data()), u8.size());
}

std::string normalize_module_key(const fs::path& p) {
    return p.lexically_normal().generic_string();
}

bool is_requireable_script_path(const fs::path& path) {
    std::string filename = path.filename().string();
    std::string extension = path.extension().string();

    if (filename == ".config.luau") return false;
    return extension == ".luau" || extension == ".lua";
}

fs::path weakly_canonical_or_absolute(const fs::path& path) {
    std::error_code ec;
    fs::path resolved = fs::weakly_canonical(path, ec);
    if (!ec) return resolved;

    ec.clear();
    resolved = fs::absolute(path, ec);
    return ec ? path : resolved;
}

std::optional<std::string> module_base_key_for_script_path(const fs::path& path) {
    if (!is_requireable_script_path(path)) return std::nullopt;

    fs::path base =
        (path.stem() == "init") ? path.parent_path() : fs::path(path).replace_extension();

    return normalize_module_key(base);
}

std::string module_lookup_key_for_path(const fs::path& path) {
    if (auto baseKey = module_base_key_for_script_path(path)) return *baseKey;
    return normalize_module_key(path);
}

int module_priority(const LocatedModule& module) {
    switch (module.type) {
        case LocatedModule::TYPE_EMBEDDED_NATIVE:
            return 0;

        case LocatedModule::TYPE_EMBEDDED_SCRIPT:
            return module.path.ends_with("/init") ? 2 : 1;

        case LocatedModule::TYPE_FILE:
        case LocatedModule::TYPE_VFS:
            if (module.path.ends_with(".luau")) return module.path.ends_with("/init.luau") ? 2 : 0;
            if (module.path.ends_with(".lua")) return module.path.ends_with("/init.lua") ? 3 : 1;
            return 4;
    }

    return 4;
}

void insert_module_candidate(std::unordered_map<std::string, std::vector<LocatedModule>>& index,
                             const std::string& baseKey, LocatedModule module) {
    auto& modules = index[baseKey];

    for (const LocatedModule& existing : modules) {
        if (existing.type == module.type && existing.path == module.path) return;
    }

    auto insertAt = modules.begin();
    int priority = module_priority(module);
    while (insertAt != modules.end() && module_priority(*insertAt) <= priority) {
        ++insertAt;
    }

    modules.insert(insertAt, std::move(module));
}

struct ResolverVirtualFileSystem {
    std::mutex mutex;
    std::unordered_map<std::string, std::vector<LocatedModule>> filesystemModules;
    std::unordered_set<std::string> indexedFilesystemRoots;

    std::unordered_map<std::string, std::vector<LocatedModule>> bundledVfsModules;
    bool bundledVfsIndexed = false;

    std::unordered_map<std::string, std::vector<LocatedModule>> embeddedModules;
    bool embeddedIndexed = false;

    void ensure_filesystem_indexed(const fs::path& root) {
        if (root.empty()) return;

        fs::path canonicalRoot;
        try {
            canonicalRoot = fs::weakly_canonical(root);
        } catch (...) {
            return;
        }

        std::string rootKey = normalize_module_key(canonicalRoot);

        std::scoped_lock lock(mutex);
        if (!indexedFilesystemRoots.emplace(rootKey).second) return;

        try {
            for (const auto& entry : fs::recursive_directory_iterator(canonicalRoot)) {
                if (!entry.is_regular_file()) continue;

                const fs::path& entryPath = entry.path();
                auto baseKey = module_base_key_for_script_path(entryPath);
                if (!baseKey) continue;

                insert_module_candidate(
                    filesystemModules, *baseKey,
                    LocatedModule{ .path = path_to_string(fs::weakly_canonical(entryPath)),
                                   .type = LocatedModule::TYPE_FILE });
            }
        } catch (...) {
        }
    }

    void ensure_bundled_vfs_indexed() {
        std::scoped_lock lock(mutex);
        if (bundledVfsIndexed) return;
        bundledVfsIndexed = true;

        if (!vfs_open()) return;

        for (const std::string& path : vfs_list_dir("")) {
            auto baseKey = module_base_key_for_script_path(fs::path(path));
            if (!baseKey) continue;

            insert_module_candidate(bundledVfsModules, *baseKey,
                                    LocatedModule{ .path = path, .type = LocatedModule::TYPE_VFS });
        }
    }

    void ensure_embedded_indexed() {
        std::scoped_lock lock(mutex);
        if (embeddedIndexed) return;
        embeddedIndexed = true;

        if (auto* natives = eryx_get_embedded_native_modules()) {
            for (auto module = natives; module->modulePath; ++module) {
                insert_module_candidate(
                    embeddedModules, normalize_module_key(fs::path(module->modulePath)),
                    LocatedModule{ .path = module->modulePath,
                                   .type = LocatedModule::TYPE_EMBEDDED_NATIVE });
            }
        }

        if (auto* scripts = eryx_get_embedded_script_modules()) {
            for (const EmbeddedScriptModule* module = scripts; module->modulePath; ++module) {
                fs::path modulePath(module->modulePath);
                auto baseKey = (modulePath.filename() == "init")
                                   ? normalize_module_key(modulePath.parent_path())
                                   : normalize_module_key(modulePath);

                insert_module_candidate(
                    embeddedModules, baseKey,
                    LocatedModule{ .path = module->modulePath,
                                   .type = LocatedModule::TYPE_EMBEDDED_SCRIPT });
            }
        }
    }

    std::vector<LocatedModule> lookup_filesystem(const fs::path& base) {
        ensure_filesystem_indexed(base.parent_path());

        std::scoped_lock lock(mutex);
        auto it = filesystemModules.find(normalize_module_key(base));
        return it == filesystemModules.end() ? std::vector<LocatedModule>() : it->second;
    }

    std::vector<LocatedModule> lookup_bundled_vfs(const std::string& base) {
        ensure_bundled_vfs_indexed();

        std::scoped_lock lock(mutex);
        auto it = bundledVfsModules.find(normalize_module_key(fs::path(base)));
        return it == bundledVfsModules.end() ? std::vector<LocatedModule>() : it->second;
    }

    std::optional<LocatedModule> lookup_embedded(const std::string& key) {
        ensure_embedded_indexed();

        std::scoped_lock lock(mutex);
        auto it = embeddedModules.find(normalize_module_key(fs::path(key)));
        if (it == embeddedModules.end() || it->second.empty()) return std::nullopt;
        return it->second.front();
    }
};

ResolverVirtualFileSystem& resolver_vfs() {
    static ResolverVirtualFileSystem index;
    return index;
}

std::optional<LocatedModule> lookup_exact_filesystem_script(const fs::path& path) {
    if (!is_requireable_script_path(path)) return std::nullopt;

    std::error_code ec;
    if (!fs::is_regular_file(path, ec) || ec) return std::nullopt;

    return LocatedModule{ .path = path_to_string(weakly_canonical_or_absolute(path)),
                          .type = LocatedModule::TYPE_FILE };
}

std::vector<LocatedModule> lookup_filesystem_resolved_path(const fs::path& path) {
    if (auto exact = lookup_exact_filesystem_script(path)) return { *exact };
    return resolver_vfs().lookup_filesystem(path);
}

std::string join_require_path(std::string base, const std::string& suffix) {
    while (!base.empty() && base.back() == '/') base.pop_back();
    if (suffix.empty()) return base;
    if (base.empty()) return suffix;
    return base + "/" + suffix;
}

std::string format_alias_cycle(const std::vector<std::string>& aliasStack,
                               const std::string& alias) {
    std::string cycle;
    auto start = std::find(aliasStack.begin(), aliasStack.end(), alias);

    for (auto it = start; it != aliasStack.end(); ++it) {
        if (!cycle.empty()) cycle += " -> ";
        cycle += "@" + *it;
    }

    if (!cycle.empty()) cycle += " -> ";
    cycle += "@" + alias;
    return cycle;
}

}  // namespace

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
    return resolver_vfs().lookup_embedded(key);
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
    RequireContext ctx = eryx_get_require_context(L);
    return eryx_resolve_modules(L, ctx, path);
}

static std::vector<LocatedModule> eryx_resolve_modules_impl(lua_State* L, RequireContext& ctx,
                                                            const std::string path,
                                                            std::vector<std::string>& aliasStack) {
    std::vector<LocatedModule> locatedModules;

    fs::path resolvedPath;

    if (path.empty()) {
        luaL_error(L, "Require path must not be empty");
    }

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
            // Explicit config alias - always wins
            if (std::find(aliasStack.begin(), aliasStack.end(), alias) != aliasStack.end()) {
                std::string cycle = format_alias_cycle(aliasStack, alias);
                luaL_error(L, "Alias cycle detected while resolving %s: %s", path.c_str(),
                           cycle.c_str());
            }

            if (!it->second.path.empty() && it->second.path[0] == '@') {
                aliasStack.push_back(alias);
                std::string expandedPath = join_require_path(it->second.path, modulePath);
                auto modules = eryx_resolve_modules_impl(L, ctx, expandedPath, aliasStack);
                aliasStack.pop_back();
                return modules;
            }

            fs::path aliasPath = fs::path(it->second.qualified);
            fs::path candidate =
                modulePath.empty() ? aliasPath : aliasPath / fs::path(modulePath);
            resolvedPath = weakly_canonical_or_absolute(candidate);
        }
        // @self from a VFS module - try VFS first, fall through to filesystem
        else if (ctx.isVFS && alias == "self") {
            std::string key;
            if (modulePath.empty())
                key = ctx.vfsSelfDir;
            else if (ctx.vfsSelfDir.empty())
                key = modulePath;
            else
                key = ctx.vfsSelfDir + "/" + modulePath;

            locatedModules = resolver_vfs().lookup_bundled_vfs(key);
            if (!locatedModules.empty()) return locatedModules;
            // Fall through to filesystem @self resolution
            resolvedPath = weakly_canonical_or_absolute(ctx.root / fs::path(key));
        }
        // @eryx - try embedded modules first, then fall back to filesystem
        else if (alias == "eryx") {
            auto module = eryx_resolve_embedded(modulePath);
            if (module) {
                locatedModules.push_back(*module);
                return locatedModules;
            }
            // Fall back to [exe dir]/modules
            resolvedPath = weakly_canonical_or_absolute(getExecutableDir() / "modules" /
                                                        fs::path(modulePath));
        }
        // @self from an embedded module - try embedded first, fall through to filesystem
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
            resolvedPath = weakly_canonical_or_absolute(ctx.selfDir / fs::path(modulePath));
        } else if (alias == "self") {
            resolvedPath = weakly_canonical_or_absolute(ctx.selfDir / fs::path(modulePath));
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

            locatedModules = resolver_vfs().lookup_bundled_vfs(base);
            if (!locatedModules.empty()) return locatedModules;

            // VFS lookup failed - if not isolated, try filesystem from exe dir
            // for paths that resolve at or above the VFS root level.
            // Paths that stay inside a VFS subdirectory do not fall through.
            if (!vfs_is_isolated()) {
                bool atOrAboveRoot = base.starts_with("..") || base.find('/') == std::string::npos;
                if (atOrAboveRoot) {
                    resolvedPath = weakly_canonical_or_absolute(getExecutableDir() / fs::path(base));
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
            resolvedPath = weakly_canonical_or_absolute(ctx.callerDir / fs::path(path));
        } else {
            // Caller has no filesystem directory (e.g. purely embedded/VFS)
            // If we got here, neither VFS nor embedded found the module
            luaL_error(L, "Module %s not found", path.c_str());
        }
    }

    // VFS overlay - check virtual filesystem before the real one
    if (vfs_open()) {
        // Convert resolvedPath to a VFS-relative path (forward slashes, relative to root)
        std::error_code ec;
        fs::path relativePath = fs::relative(resolvedPath, ctx.root, ec);
        if (!ec) {
            std::string vfsBase = module_lookup_key_for_path(relativePath);
            locatedModules = resolver_vfs().lookup_bundled_vfs(vfsBase);
            if (!locatedModules.empty()) return locatedModules;
        }
    }

    return lookup_filesystem_resolved_path(resolvedPath);

    // if (!fs::exists(resolvedPath)) {
    //     return std::nullopt;
    // }
    // return LocatedModule{ .path = resolvedPath.string(), .type = LocatedModule::TYPE_FILE };
}

std::vector<LocatedModule> eryx_resolve_modules(lua_State* L, RequireContext& ctx,
                                                const std::string path) {
    std::vector<std::string> aliasStack;
    return eryx_resolve_modules_impl(L, ctx, path, aliasStack);
}

std::vector<LocatedModule> eryx_resolve_modules(RequireContext& ctx, const std::string path) {
    lua_State* L = eryx_initialise_environment(nullptr);
    auto modules = eryx_resolve_modules(L, ctx, path);
    lua_close(L);
    return modules;
}

std::optional<LocatedModule> eryx_resolve_module(lua_State* L, RequireContext& ctx,
                                                 const std::string path) {
    auto modules = eryx_resolve_modules(L, ctx, path);
    if (modules.size() > 1) {
        std::string err = "Multiple candidates for require found:\n";
        for (const auto& i : modules) {
            err += "- " + i.path + "\n";
        }

        luaL_error(L, "%s", err.c_str());
    }

    if (modules.size() == 1) {
        return modules[0];
    }
    return std::nullopt;
}

std::optional<LocatedModule> eryx_resolve_module(lua_State* L, const std::string path) {
    RequireContext ctx = eryx_get_require_context(L);
    return eryx_resolve_module(L, ctx, path);
}
