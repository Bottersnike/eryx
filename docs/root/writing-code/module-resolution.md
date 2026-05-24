# Module Resolution

Eryx resolves `require()` paths through three layers: **VFS** (virtual filesystem bundles), **embedded** modules (baked into the executable), and the **real filesystem**. All three can be active simultaneously - VFS and embedded are checked first, with the filesystem as the final fallback.

## Require Path Syntax

Every require path must start with one of:

| Prefix    | Meaning                                         |
| --------- | ----------------------------------------------- |
| `@alias/` | Named alias (config-defined or built-in)        |
| `./`      | Relative to the calling file's directory         |
| `../`     | Relative to the calling file's parent directory  |

Bare names like `require("foo")` are not allowed.

## File Candidates

For any resolved base path, eryx checks the following candidates in order:

1. `<path>.luau`
2. `<path>.lua`
3. `<path>/init.luau`
4. `<path>/init.lua`

`.luau` is always preferred over `.lua`. Files named `.config.luau` are always excluded from require resolution.

## Native Modules

Native modules are shared libraries (`.dll` on Windows, `.so` on Linux, `.dylib` on macOS) that expose a C entrypoint. They silently shadow script modules with the same base name - if both `foo.luau` and `foo.dll` exist, the native module is loaded.

### Filesystem Native Modules

When a `TYPE_FILE` module is resolved, eryx checks for a native library alongside it before reading the script:

| Platform | Naming convention       | Example                    |
| -------- | ----------------------- | -------------------------- |
| Windows  | `<stem>.dll`            | `_ffi.dll`                 |
| Linux    | `lib<stem>.so`          | `lib_ffi.so`               |
| macOS    | `lib<stem>.dylib`       | `lib_ffi.dylib`            |

If the native library exists, it is loaded instead of the `.luau` file.

### Native Module ABI

Every native module must export a `luau_module_info` function returning a `LuauModuleInfo` struct:

```c
typedef struct {
    unsigned int abiVersion;  // must match ABI_VERSION (currently 1)
    const char* luauVersion;  // must match the exact Luau git hash
    const char* entry;        // name of the entrypoint function (e.g. "luauopen_ffi")
} LuauModuleInfo;
```

Both `abiVersion` and `luauVersion` are checked at load time. A mismatch is a hard error -- this prevents subtle crashes from ABI drift between the runtime and the module.

The entrypoint function receives a fresh `lua_State*` thread and returns the number of values pushed:

```c
LUAU_MODULE_EXPORT int luauopen_mymod(lua_State* L) {
    lua_newtable(L);
    // ... populate table ...
    return 1;
}
```

### Embedded Native Modules

In an `ERYX_EMBED` build, native modules are compiled directly into the executable. They appear in the `g_embedded_native_modules` table and are resolved via `@eryx` like any other embedded module. The `luau_module_info` export is suppressed (not needed since the entrypoint is registered directly in the table).

## Resolution Order

### Alias paths (`@alias/module`)

Config aliases are checked first and always win over built-in aliases.

**1. Config aliases** - Walk up from the calling file's directory to the filesystem root, looking for `.luaurc` or `.config.luau` files. If the alias is defined in any discovered config, resolve the path relative to the config file's directory, then check VFS overlay, then filesystem.

**2. `@self`** - Resolves relative to the directory containing the calling file. The exact behavior depends on context:

| Caller context                   | Resolution                                                                    |
| -------------------------------- | ----------------------------------------------------------------------------- |
| Regular file `foo/bar.luau`      | `foo/` + module path                                                          |
| `init.luau` file `foo/init.luau` | `foo/` + module path (the directory the init file represents, not its parent) |
| VFS module                       | Try VFS first, then fall back to filesystem                                   |
| Embedded module                  | Try embedded first, then fall back to filesystem                              |

**3. `@eryx`** - Resolves to eryx's own standard library modules.

| Build mode     | Resolution                                                       |
| -------------- | ---------------------------------------------------------------- |
| Embedded build | Check embedded module table first                                |
| Any build      | Fall back to `<executable directory>/modules/` on the filesystem |

**4. Undefined alias** - Produces an error.

### Relative paths (`./` and `../`)

Relative paths resolve from the calling file's directory. For `init.luau` files, `./` refers to the **parent** of the directory the init file sits in (i.e. the directory containing the folder that the init module represents), not the directory containing the init file itself.

The resolution chain for relative paths:

1. **VFS** - If the caller is a VFS module, try resolving within the VFS namespace first.
2. **Embedded** - If the caller is an embedded module, try resolving within the embedded module table.
3. **Filesystem fallback** - If the caller has a filesystem directory (even if they are also VFS/embedded), resolve the path against that directory, then:
   a. **VFS overlay** - If a VFS bundle is open, convert the resolved path to a VFS-relative path and check the VFS.
   b. **Filesystem** - Check the real filesystem.

If the caller is purely VFS/embedded with no filesystem directory and steps 1-2 didn't find a match, resolution fails with an error.

## The Three Layers

### Filesystem

Standard file resolution. Paths are canonicalized and checked for existence. Native module shadowing applies here - a `.dll`/`.so`/`.dylib` next to the resolved script takes priority. This is the baseline that always works.

### VFS (Virtual Filesystem)

A VFS bundle is a set of files appended to the executable. VFS paths are relative to the project root using forward slashes (e.g. `src/utils/helper.luau`). When a VFS bundle is present:

- VFS modules are loaded with chunk names prefixed `@@vfs/` (e.g. `@@vfs/src/app.luau`)
- Relative requires from VFS modules resolve within the VFS namespace first
- The VFS acts as an overlay - if a VFS file exists, it takes priority over the same path on the filesystem
- Config files (`.luaurc`, `.config.luau`) are also found in the VFS
- Native module shadowing does **not** apply to VFS modules (VFS only contains scripts)

### Embedded

Embedded modules are eryx's own standard library, compiled directly into the executable. They are organized by key (e.g. `encoding/init`, `compression/zlib`). Embedded modules can be either **scripts** (Luau source) or **native** (C++ entrypoints compiled into the binary). When the build uses `ERYX_EMBED`:

- Embedded modules are loaded with chunk names prefixed `@@eryx/` (e.g. `@@eryx/encoding/init`)
- `@eryx` alias resolves to embedded modules before falling back to the filesystem
- Relative requires from embedded modules resolve within the embedded namespace first
- Native embedded modules are checked before script modules for the same key

### Combined Mode

In a fully bundled executable, both VFS and embedded are active simultaneously:

- **User code** lives in the VFS
- **Standard library** is embedded
- User code can `require("@eryx/...")` to reach embedded modules
- Embedded modules can require each other via relative paths
- The filesystem is still checked as a final fallback for both

## Config Resolution

Config files (`.luaurc` and `.config.luau`) are discovered by walking from a starting directory upward to the filesystem root. At each directory, eryx checks:

1. The real filesystem for `.luaurc` or `.config.luau`
2. The VFS (if open and no filesystem config was found in that directory)

Rules:

- Only one config file is allowed per directory (having both `.luaurc` and `.config.luau` in the same directory is an error)
- Configs are merged parent-first, so child configs override parent values
- `.luaurc` is a JSON file parsed directly
- `.config.luau` is a Luau script that is executed and must return a config table

### Config Alias Format

In `.luaurc`:

```json
{
    "aliases": {
        "mylib": "./path/to/lib"
    }
}
```

In `.config.luau`:

```luau
return {
    luau = {
        aliases = {
            mylib = "./path/to/lib",
        },
    },
}
```

Alias paths are resolved relative to the directory containing the config file.

## `init.luau` Semantics

A directory can act as a module by containing an `init.luau` (or `init.lua`) file. When you `require("./mydir")`, eryx finds `mydir/init.luau`.

Inside an `init.luau` file:

- `@self` refers to the directory the init file is in (`mydir/`)
- `./` refers to the **parent** directory (the directory containing `mydir/`)
- `../` goes up from the parent directory

This means `@self/sibling` from `mydir/init.luau` resolves to `mydir/sibling.luau`, while `./sibling` resolves to `<parent>/sibling.luau`.
