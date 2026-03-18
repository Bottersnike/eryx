#include "lconfig.hpp"

#include "Luau/Config.h"
#include "Luau/LuauConfig.h"
#include "lrequire.hpp"
#include "../vfs.hpp"

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

// #region: Code lifted from luau/Config/src/LuauConfig.cpp
#define RETURN_WITH_ERROR(msg)   \
    do {                         \
        if (error) *error = msg; \
        return std::nullopt;     \
    } while (false)
struct ThreadPopper {
    explicit ThreadPopper(lua_State* L) : L(L) { LUAU_ASSERT(L); }

    ThreadPopper(const ThreadPopper&) = delete;
    ThreadPopper& operator=(const ThreadPopper&) = delete;

    ~ThreadPopper() { lua_pop(L, 1); }

    lua_State* L = nullptr;
};
static std::optional<Luau::ConfigTable> serializeTable(lua_State* L, std::string* error) {
    ThreadPopper popper(L);  // Remove table from stack after processing
    Luau::ConfigTable table;

    lua_pushnil(L);

    while (lua_next(L, -2) != 0) {
        ThreadPopper popper(L);  // Remove value from stack after processing

        // Process key
        Luau::ConfigTableKey key;
        switch (lua_type(L, -2)) {
            case LUA_TNUMBER:
                key = lua_tonumber(L, -2);
                break;
            case LUA_TSTRING:
                key = std::string{ lua_tostring(L, -2) };
                break;
            default:
                RETURN_WITH_ERROR("configuration table keys must be strings or numbers");
        }

        // Process value
        switch (lua_type(L, -1)) {
            case LUA_TNUMBER:
                table[key] = lua_tonumber(L, -1);
                break;
            case LUA_TSTRING:
                table[key] = std::string{ lua_tostring(L, -1) };
                break;
            case LUA_TBOOLEAN:
                table[key] = static_cast<bool>(lua_toboolean(L, -1));
                break;
            case LUA_TTABLE: {
                lua_pushvalue(L, -1);  // Copy table for recursive call
                if (std::optional<Luau::ConfigTable> nested = serializeTable(L, error))
                    table[key] = std::move(*nested);
                else
                    return std::nullopt;  // Error already set in recursive call
                break;
            }
            default:
                std::string msg = "configuration value for key \"" + key.toString() +
                                  "\" must be a string, number, boolean, or nested table";
                RETURN_WITH_ERROR(std::move(msg));
        }
    }

    return table;
}
static std::optional<std::string> createLuauConfigFromLuauTable(
    Luau::Config& config, const Luau::ConfigTable& luauTable,
    std::optional<Luau::ConfigOptions::AliasOptions> aliasOptions) {
    for (const auto& [k, v] : luauTable) {
        const std::string* key = k.get_if<std::string>();
        if (!key) return "configuration keys in \"luau\" table must be strings";

        if (*key == "languagemode") {
            const std::string* value = v.get_if<std::string>();
            if (!value) return "configuration value for key \"languagemode\" must be a string";

            if (std::optional<std::string> errorMessage = parseModeString(config.mode, *value))
                return errorMessage;
        }

        if (*key == "lint") {
            const Luau::ConfigTable* lint = v.get_if<Luau::ConfigTable>();
            if (!lint) return "configuration value for key \"lint\" must be a table";

            // Handle wildcard first to ensure overrides work as expected.
            if (const Luau::ConfigValue* value = lint->find("*")) {
                const bool* enabled = value->get_if<bool>();
                if (!enabled) return "configuration values in \"lint\" table must be booleans";

                if (std::optional<std::string> errorMessage = parseLintRuleString(
                        config.enabledLint, config.fatalLint, "*", *enabled ? "true" : "false"))
                    return errorMessage;
            }

            for (const auto& [k, v] : *lint) {
                const std::string* warningName = k.get_if<std::string>();
                if (!warningName) return "configuration keys in \"lint\" table must be strings";

                if (*warningName == "*") continue;  // Handled above

                const bool* enabled = v.get_if<bool>();
                if (!enabled) return "configuration values in \"lint\" table must be booleans";

                if (std::optional<std::string> errorMessage =
                        parseLintRuleString(config.enabledLint, config.fatalLint, *warningName,
                                            *enabled ? "true" : "false"))
                    return errorMessage;
            }
        }

        if (*key == "linterrors") {
            const bool* value = v.get_if<bool>();
            if (!value) return "configuration value for key \"linterrors\" must be a boolean";

            config.lintErrors = *value;
        }

        if (*key == "typeerrors") {
            const bool* value = v.get_if<bool>();
            if (!value) return "configuration value for key \"typeerrors\" must be a boolean";

            config.typeErrors = *value;
        }

        if (*key == "globals") {
            const Luau::ConfigTable* globalsTable = v.get_if<Luau::ConfigTable>();
            if (!globalsTable)
                return "configuration value for key \"globals\" must be an array of strings";

            std::vector<std::string> globals;
            globals.resize(globalsTable->size());

            for (const auto& [k, v] : *globalsTable) {
                const double* key = k.get_if<double>();
                if (!key) return "configuration array \"globals\" must only have numeric keys";

                const size_t index = static_cast<size_t>(*key);
                if (index < 1 || globalsTable->size() < index)
                    return "configuration array \"globals\" contains invalid numeric key";

                const std::string* global = v.get_if<std::string>();
                if (!global) return "configuration value in \"globals\" table must be a string";

                LUAU_ASSERT(0 <= index - 1 && index - 1 < globalsTable->size());
                globals[index - 1] = *global;
            }

            config.globals = std::move(globals);
        }

        if (*key == "aliases") {
            const Luau::ConfigTable* aliases = v.get_if<Luau::ConfigTable>();
            if (!aliases) return "configuration value for key \"aliases\" must be a table";

            for (const auto& [k, v] : *aliases) {
                const std::string* aliasKey = k.get_if<std::string>();
                if (!aliasKey) return "configuration keys in \"aliases\" table must be strings";

                const std::string* aliasValue = v.get_if<std::string>();
                if (!aliasValue) return "configuration values in \"aliases\" table must be strings";

                if (std::optional<std::string> errorMessage =
                        parseAlias(config, *aliasKey, *aliasValue, aliasOptions))
                    return errorMessage;
            }
        }
    }

    return std::nullopt;
}
// #endregion

static void runLuauConfig(lua_State* L, fs::path path, std::string source, fs::path directory,
                          Luau::Config& cfg) {
    // Execute in a fresh thread (keep it on GL's stack so GC doesn't collect it)
    lua_State* GL = lua_mainthread(L);
    lua_State* CL = lua_newthread(GL);

    int ok = eryx_execute_module_script(CL, source, std::string("@") + path.string());
    if (!ok) {
        luaL_error(L, "Error executing " PATH_PRINTF, path.c_str());
    }

    // Expect a table with an "aliases" sub-table
    if (!lua_istable(CL, -1)) {
        luaL_error(L, PATH_PRINTF " must return a table", path.c_str());
    }

    std::string error;
    auto table = serializeTable(CL, &error);

    if (!error.empty()) {
        luaL_error(L, error.c_str());
    }

    if (!table->contains("luau")) {
        lua_pop(GL, 1);  // pop thread
        return;
    }

    Luau::ConfigTable* luauTable = (*table)["luau"].get_if<Luau::ConfigTable>();
    if (!luauTable) {
        luaL_error(L, "configuration value for key \"luau\" must be a table");
    }

    auto aliasOptions = Luau::ConfigOptions::AliasOptions{
        .configLocation = directory.string(),
        .overwriteAliases = true,
    };
    auto maybeError = createLuauConfigFromLuauTable(cfg, *luauTable, aliasOptions);

    lua_pop(GL, 1);  // pop thread

    if (maybeError) {
        luaL_error(L, (*maybeError).c_str());
    }
}

// Walk from `startDir` upward to `stopDir` (inclusive), collecting all
// config files (.luaurc or *.config.luau).  Configs are merged parent-first
// so that inner (closer to startDir) configs take precedence.
//
// When `vfsStartDir` is non-empty the search begins inside the VFS at that
// path and walks upward to the VFS root before continuing to the real
// filesystem from CWD upward.
ERYX_API LocatedConfig* eryx_locate_config(lua_State* L, const fs::path& startDir,
                                 const std::optional<fs::path> stopDir,
                                 const std::string& vfsStartDir) {
    auto out = new LocatedConfig;
    out->found = false;

    // Phase 1: Collect all config locations.
    // Each entry is (directory, configFilePath, isLuaurc, isVFS).
    struct ConfigEntry {
        fs::path dir;        // filesystem directory (for non-VFS) or CWD-based equivalent
        fs::path file;       // display path
        bool isLuaurc;
        bool isVFS = false;
        std::string vfsPath; // only set when isVFS
    };
    std::vector<ConfigEntry> configs;

    bool hasVFS = vfs_open();
    fs::path root = fs::weakly_canonical(fs::current_path());

    // ── VFS walk ─────────────────────────────────────────────────────────
    // Walk VFS directories from vfsStartDir up to the VFS root ("").
    if (hasVFS && !vfsStartDir.empty()) {
        std::string vfsDir = vfsStartDir;
        while (true) {
            // Check for .luaurc in VFS
            std::string vfsLuaurc = vfsDir.empty() ? ".luaurc" : vfsDir + "/.luaurc";
            bool vfsHasLuaurc = !vfs_read_file(vfsLuaurc).empty();

            // Check for *.config.luau in VFS
            std::string vfsConfigLuau;
            auto vfsFiles = vfs_list_dir(vfsDir);
            for (auto& f : vfsFiles) {
                std::string_view relative = std::string_view(f).substr(
                    vfsDir.empty() ? 0 : vfsDir.size() + 1);
                if (relative.find('/') != std::string_view::npos) continue;
                if (f.size() >= 12 && f.substr(f.size() - 12) == ".config.luau") {
                    if (!vfsConfigLuau.empty()) {
                        luaL_error(L, "Found multiple .config.luau files in VFS directory %s",
                                   vfsDir.c_str());
                    }
                    vfsConfigLuau = f;
                }
            }
            bool vfsHasConfigLuau = !vfsConfigLuau.empty();

            if (vfsHasLuaurc && vfsHasConfigLuau) {
                luaL_error(L,
                           "Found both .luaurc and %s in VFS directory %s. "
                           "Only one config file is allowed per directory.",
                           vfsConfigLuau.c_str(), vfsDir.c_str());
            }

            // Compute a filesystem-equivalent dir for alias resolution
            fs::path fsDir = vfsDir.empty() ? root : root / vfsDir;

            if (vfsHasLuaurc) {
                configs.push_back({ fsDir, fs::path(vfsLuaurc), true, true, vfsLuaurc });
            } else if (vfsHasConfigLuau) {
                configs.push_back({ fsDir, fs::path(vfsConfigLuau), false, true, vfsConfigLuau });
            }

            // Walk up one level
            if (vfsDir.empty()) break;
            size_t slash = vfsDir.rfind('/');
            if (slash == std::string::npos) {
                vfsDir = "";  // one more iteration at the VFS root
            } else {
                vfsDir = vfsDir.substr(0, slash);
            }
        }
    }

    // ── Filesystem walk ──────────────────────────────────────────────────
    // Walk from startDir upward on the real filesystem.
    // If we came from VFS and isolation is disabled, start from the exe
    // directory so that configs next to the exe are found.
    // If isolated (or no VFS), fall back to CWD when startDir is empty.
    fs::path effectiveStart;
    if (!startDir.empty()) {
        effectiveStart = startDir.is_relative() ? fs::current_path() / startDir : startDir;
    } else if (hasVFS && !vfsStartDir.empty() && !vfs_is_isolated()) {
        effectiveStart = getExecutableDir();
    } else {
        effectiveStart = fs::current_path();
    }
    fs::path dir = fs::weakly_canonical(effectiveStart);
    fs::path stop;
    if (stopDir) {
        stop = fs::weakly_canonical(*stopDir);
    } else {
        stop = fs::weakly_canonical(effectiveStart.root_path());
    }

    {
        fs::path cur = dir;
        while (true) {
            fs::path luaurc = cur / ".luaurc";

            // Scan filesystem for *.config.luau files
            std::vector<fs::path> configLuaus;
            if (fs::exists(cur) && fs::is_directory(cur)) {
                for (auto& entry : fs::directory_iterator(cur)) {
                    if (!entry.is_regular_file()) continue;
                    std::string name = entry.path().filename().string();
                    if (name.size() >= 12 && name.substr(name.size() - 12) == ".config.luau") {
                        configLuaus.push_back(entry.path());
                        break;
                    }
                }
            }

            // Guard against duplicate *.config.luau
            fs::path configLuau;
            if (configLuaus.size() > 1) {
                luaL_error(L,
                           "Found multiple .config.luau files (" PATH_PRINTF ", " PATH_PRINTF ")",
                           configLuaus[0].c_str(), configLuaus[1].c_str());
            } else if (configLuaus.size() == 1) {
                configLuau = configLuaus[0];
            }

            bool hasLuaurc = fs::exists(luaurc);
            bool hasConfigLuau = !configLuau.empty();

            // Guard against .luaurc and *.config.luau in the same directory
            if (hasLuaurc && hasConfigLuau) {
                luaL_error(L,
                           "Found both .luaurc and " PATH_PRINTF " in " PATH_PRINTF
                           ". Only one config file is allowed per directory.",
                           configLuau.filename().c_str(), cur.c_str());
            }

            if (hasLuaurc) {
                configs.push_back({ cur, luaurc, true });
            } else if (hasConfigLuau) {
                configs.push_back({ cur, configLuau, false });
            } else if (hasVFS && vfsStartDir.empty()) {
                // Only check VFS overlay during filesystem walk if we didn't
                // already do a dedicated VFS walk above.
                std::string vfsDir = fs::relative(cur, root).generic_string();
                if (vfsDir == ".") vfsDir = "";

                std::string vfsLuaurc = vfsDir.empty() ? ".luaurc" : vfsDir + "/.luaurc";
                bool vfsHasLuaurc = !vfs_read_file(vfsLuaurc).empty();

                std::string vfsConfigLuau;
                auto vfsFiles = vfs_list_dir(vfsDir);
                for (auto& f : vfsFiles) {
                    std::string_view relative = std::string_view(f).substr(
                        vfsDir.empty() ? 0 : vfsDir.size() + 1);
                    if (relative.find('/') != std::string_view::npos) continue;
                    if (f.size() >= 12 && f.substr(f.size() - 12) == ".config.luau") {
                        if (!vfsConfigLuau.empty()) {
                            luaL_error(L,
                                       "Found multiple .config.luau files in VFS directory %s",
                                       vfsDir.c_str());
                        }
                        vfsConfigLuau = f;
                    }
                }
                bool vfsHasConfigLuau = !vfsConfigLuau.empty();

                if (vfsHasLuaurc && vfsHasConfigLuau) {
                    luaL_error(L,
                               "Found both .luaurc and %s in VFS directory %s. "
                               "Only one config file is allowed per directory.",
                               vfsConfigLuau.c_str(), vfsDir.c_str());
                }

                if (vfsHasLuaurc) {
                    configs.push_back({ cur, fs::path(vfsLuaurc), true, true, vfsLuaurc });
                } else if (vfsHasConfigLuau) {
                    configs.push_back({ cur, fs::path(vfsConfigLuau), false, true, vfsConfigLuau });
                }
            }

            // Reached the stop boundary
            if (cur == stop) break;

            // Move up one directory
            fs::path parent = cur.parent_path();
            if (parent == cur) break;  // filesystem root
            cur = parent;
        }
    }

    if (configs.empty()) {
        return out;  // No config found (not an error)
    }

    // Phase 2: Parse configs parent-first (reverse order) into a single Luau::Config.
    // This way child configs override parent values naturally.
    Luau::Config cfg;

    for (auto it = configs.rbegin(); it != configs.rend(); ++it) {
        // Read file contents — from VFS or filesystem
        std::string contents;
        if (it->isVFS) {
            auto data = vfs_read_file(it->vfsPath);
            if (data.empty()) {
                luaL_error(L, "Failed to read VFS config %s", it->vfsPath.c_str());
            }
            contents = std::string(reinterpret_cast<const char*>(data.data()), data.size());
        } else {
            std::ifstream f(it->file, std::ios::binary);
            if (!f) {
                luaL_error(L, "Failed to read " PATH_PRINTF, it->file.c_str());
            }
            contents = std::string(std::istreambuf_iterator<char>(f),
                                   std::istreambuf_iterator<char>());
        }

        // Determine the directory to use for alias resolution.
        // For VFS configs, derive it from root + the VFS path's parent,
        // since the filesystem walk directory may be empty in a pure VFS context.
        fs::path configDir;
        if (it->isVFS) {
            fs::path vfsParent = fs::path(it->vfsPath).parent_path();
            configDir = vfsParent.empty() ? root : root / vfsParent;
        } else {
            configDir = it->dir;
        }

        if (it->isLuaurc) {
            if (configDir.string().length() == 0) {
                luaL_error(L, "Config loading went drastically wrong. \"%ls\" has no directory!",
                           it->file.c_str());
            }

            Luau::ConfigOptions opts;
            opts.aliasOptions = Luau::ConfigOptions::AliasOptions{
                .configLocation = configDir.string(),
                .overwriteAliases = true,
            };
            auto err = Luau::parseConfig(contents, cfg, opts);
            if (err) {
                luaL_error(L, "Error parsing " PATH_PRINTF ": %s", it->file.c_str(),
                           (*err).c_str());
            }
        } else {
            runLuauConfig(L, it->file, contents, configDir, cfg);
        }
    }

    // Phase 3: Convert merged Luau::Config to LocatedConfig.
    // configDir is the innermost (closest to startDir) config directory.
    out->configDir = configs.front().dir;
    out->languageMode = cfg.mode;
    out->enabledLints = cfg.enabledLint.warningMask;
    out->fatalLints = cfg.fatalLint.warningMask;
    out->lintErrors = cfg.lintErrors;
    out->typeErrors = cfg.typeErrors;
    out->globals = cfg.globals;
    out->found = true;

    for (auto& [key, info] : cfg.aliases) {
        // Resolve alias value relative to the config file's directory
        fs::path configDir{ std::string{ info.configLocation } };
        std::error_code ec;
        fs::path candidate = configDir / info.value;
        fs::path resolved = fs::weakly_canonical(candidate, ec);
        if (ec) {
            ec.clear();
            resolved = fs::absolute(candidate, ec);
            if (ec) resolved = candidate;
        }

        AliasInfo ainfo = {
            resolved.string(),
            std::string(info.configLocation),
            info.value,
        };
        out->aliases.insert_or_assign(key, ainfo);
    }

    return out;
}
