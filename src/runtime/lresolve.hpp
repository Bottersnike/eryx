#pragma once
#include <filesystem>
#include <optional>

#include "../pch.hpp"

struct LocatedModule {
    std::string path;
    enum {
        // "path" is a real path on the filesystem
        TYPE_FILE,
        // "path" is an embedded vfs file path
        TYPE_VFS,

        // These two are used when embedded modules are registered

        // "path" is an embedded dll file key
        TYPE_EMBEDDED_NATIVE,
        // "path" is an embedded script file key
        TYPE_EMBEDDED_SCRIPT,
    } type;
};

struct RequireContext {
    std::filesystem::path callerDir;  // For "./" requires - parent dir for init files
    std::filesystem::path selfDir;    // The actual directory the file is in (for @self)
    std::filesystem::path root;
    bool isInit = false;

    bool isVFS = false;        // true when caller is a @@vfs/ chunk
    std::string vfsSelfDir;    // e.g. "docgen" for key "docgen/modules.luau"
    std::string vfsCallerDir;  // same as vfsSelfDir, or parent for init files

    bool isEmbedded = false;        // true when caller is a @@eryx/ chunk
    std::string embeddedSelfDir;    // e.g. "encoding" for key "encoding/init"
    std::string embeddedCallerDir;  // same as selfDir, or parent for init files
};

RequireContext eryx_get_require_context(lua_State* L);

std::vector<LocatedModule> eryx_resolve_modules(RequireContext& ctx, const std::string path);
std::vector<LocatedModule> eryx_resolve_modules(lua_State* L, const std::string path);
std::optional<LocatedModule> eryx_resolve_module(lua_State* L, const std::string path);
