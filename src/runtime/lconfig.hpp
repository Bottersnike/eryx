#pragma once
#include <filesystem>

#include "../pch.hpp"

struct AliasInfo {
    std::string qualified;
    std::string configPath;
    std::string path;
};

struct LocatedConfig {
    std::filesystem::path configDir;  // Directory where the config was found

    Luau::Mode languageMode;
    uint64_t enabledLints;
    uint64_t fatalLints;
    bool lintErrors;
    bool typeErrors;

    std::vector<std::string> globals;
    std::map<std::string, AliasInfo> aliases;  // alias name -> resolved path

    bool found = false;
};

ERYX_API LocatedConfig* eryx_locate_config(lua_State* L, const std::filesystem::path& startDir,
                                           const std::optional<std::filesystem::path> stopDir,
                                           const std::string& vfsStartDir = "");
