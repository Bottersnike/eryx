#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_fs",
};
LUAU_MODULE_INFO()

namespace fs = std::filesystem;

// fs.readFile(path) -> string
static int fs_readFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        luaL_error(L, "Failed to open file: %s", path);
        return 0;
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<char> buffer(size);
    if (file.read(buffer.data(), size)) {
        lua_pushlstring(L, buffer.data(), size);
        return 1;
    }

    luaL_error(L, "Failed to read file: %s", path);
    return 0;
}

// fs.writeFile(path, content)
static int fs_writeFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t len;
    const char* content = luaL_checklstring(L, 2, &len);

    std::ofstream file(path, std::ios::binary);
    if (!file.is_open()) {
        luaL_error(L, "Failed to open file for writing: %s", path);
        return 0;
    }

    file.write(content, len);
    return 0;
}

// fs.appendFile(path, content)
static int fs_appendFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t len;
    const char* content = luaL_checklstring(L, 2, &len);

    std::ofstream file(path, std::ios::binary | std::ios::app);
    if (!file.is_open()) {
        luaL_error(L, "Failed to open file for appending: %s", path);
        return 0;
    }

    file.write(content, len);
    return 0;
}

// fs.exists(path) -> bool
static int fs_exists(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool exists = fs::exists(path, ec);
    lua_pushboolean(L, exists && !ec);
    return 1;
}

// fs.isFile(path) -> bool
static int fs_isFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool is_file = fs::is_regular_file(path, ec);
    lua_pushboolean(L, is_file && !ec);
    return 1;
}

// fs.isDirectory(path) -> bool
static int fs_isDirectory(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool is_dir = fs::is_directory(path, ec);
    lua_pushboolean(L, is_dir && !ec);
    return 1;
}

// fs.mkdir(path) -> bool
static int fs_mkdir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool success = fs::create_directories(path, ec);
    lua_pushboolean(L, success);
    return 1;
}

// fs.remove(path) -> bool
static int fs_remove(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    // remove_all implements "rm -rf", remove is for empty dirs or files
    uintmax_t count = fs::remove_all(path, ec);
    lua_pushboolean(L, count > 0 && !ec);
    return 1;
}

// fs.listDir(path) -> {string}
static int fs_listDir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    lua_newtable(L);
    int index = 1;

    std::error_code ec;
    if (fs::is_directory(path, ec)) {
        for (const auto& entry : fs::directory_iterator(path, ec)) {
            if (ec) break;

            // We return just the filename, not full path
            std::string filename = entry.path().filename().string();
            lua_pushinteger(L, index++);
            lua_pushstring(L, filename.c_str());
            lua_settable(L, -3);
        }
    }

    return 1;
}

// fs.dirname(path) -> string
static int fs_dirname(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string parent = fs::path(path).parent_path().string();
    lua_pushstring(L, parent.c_str());
    return 1;
}

// fs.basename(path) -> string
static int fs_basename(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string name = fs::path(path).filename().string();
    lua_pushstring(L, name.c_str());
    return 1;
}

// fs.stem(path) -> string (filename without extension)
static int fs_stem(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string stem = fs::path(path).stem().string();
    lua_pushstring(L, stem.c_str());
    return 1;
}

// fs.extension(path) -> string (includes the leading dot)
static int fs_extension(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string ext = fs::path(path).extension().string();
    lua_pushstring(L, ext.c_str());
    return 1;
}

// fs.canonicalize(path) -> string
static int fs_canonicalize(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    fs::path canon = fs::canonical(path, ec);
    if (ec) {
        luaL_error(L, "Failed to canonicalize path: %s (%s)", path, ec.message().c_str());
        return 0;
    }
    std::string result = canon.string();
    lua_pushstring(L, result.c_str());
    return 1;
}

// fs.join(path, ...) -> string
static int fs_join(lua_State* L) {
    int n = lua_gettop(L);
    if (n < 1) {
        luaL_error(L, "fs.join requires at least one argument");
        return 0;
    }
    fs::path result(luaL_checkstring(L, 1));
    for (int i = 2; i <= n; i++) {
        result /= luaL_checkstring(L, i);
    }
    std::string str = result.string();
    lua_pushstring(L, str.c_str());
    return 1;
}

// fs.stat(path) -> { size, mtime, isFile, isDirectory }
static int fs_stat(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    fs::path p(path);
    lua_newtable(L);
    if (fs::exists(p, ec) && !ec) {
        // size
        if (fs::is_regular_file(p, ec)) {
            lua_pushstring(L, "size");
            lua_pushinteger(L, fs::file_size(p, ec));
            lua_settable(L, -3);
        }
        // mtime
        auto ftime = fs::last_write_time(p, ec);
        if (!ec) {
            auto sctp = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
                ftime - fs::file_time_type::clock::now() + std::chrono::system_clock::now());
            lua_pushstring(L, "mtime");
            lua_pushinteger(
                L,
                std::chrono::duration_cast<std::chrono::seconds>(sctp.time_since_epoch()).count());
            lua_settable(L, -3);
        }
        // isFile
        lua_pushstring(L, "isFile");
        lua_pushboolean(L, fs::is_regular_file(p, ec));
        lua_settable(L, -3);
        // isDirectory
        lua_pushstring(L, "isDirectory");
        lua_pushboolean(L, fs::is_directory(p, ec));
        lua_settable(L, -3);
    }
    return 1;
}

LUAU_MODULE_EXPORT int luauopen_fs(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, fs_readFile, "readFile");
    lua_setfield(L, -2, "readFile");
    lua_pushcfunction(L, fs_writeFile, "writeFile");
    lua_setfield(L, -2, "writeFile");
    lua_pushcfunction(L, fs_appendFile, "appendFile");
    lua_setfield(L, -2, "appendFile");
    lua_pushcfunction(L, fs_exists, "exists");
    lua_setfield(L, -2, "exists");
    lua_pushcfunction(L, fs_isFile, "isFile");
    lua_setfield(L, -2, "isFile");
    lua_pushcfunction(L, fs_isDirectory, "isDirectory");
    lua_setfield(L, -2, "isDirectory");
    lua_pushcfunction(L, fs_mkdir, "mkdir");
    lua_setfield(L, -2, "mkdir");
    lua_pushcfunction(L, fs_remove, "remove");
    lua_setfield(L, -2, "remove");
    lua_pushcfunction(L, fs_listDir, "listDir");
    lua_setfield(L, -2, "listDir");
    lua_pushcfunction(L, fs_dirname, "dirname");
    lua_setfield(L, -2, "dirname");
    lua_pushcfunction(L, fs_basename, "basename");
    lua_setfield(L, -2, "basename");
    lua_pushcfunction(L, fs_stem, "stem");
    lua_setfield(L, -2, "stem");
    lua_pushcfunction(L, fs_extension, "extension");
    lua_setfield(L, -2, "extension");
    lua_pushcfunction(L, fs_canonicalize, "canonicalize");
    lua_setfield(L, -2, "canonicalize");
    lua_pushcfunction(L, fs_join, "join");
    lua_setfield(L, -2, "join");
    lua_pushcfunction(L, fs_stat, "stat");
    lua_setfield(L, -2, "stat");

    return 1;
}
