# Virtual File System (VFS)

The VFS lets you pack a Eryx project into a single self-contained executable. At build time, a file archive is appended to a copy of the Eryx runtime; at run time, the bundled executable reads scripts and assets directly from itself instead of from disk.

## Building a bundle

Use `vfs.build()` from a normal (filesystem) script:

```luau
local vfs = require("@eryx/vfs")
local fs = require("@eryx/fs")

vfs.build({
    -- The executable to produce.
    outputExe = "my_app.exe",

    -- Project root. All paths inside the bundle are stored
    -- relative to this directory.
    root = "C:/projects/my_app",

    -- Script that runs when the bundle is launched.
    -- Path is relative to `root`.
    entrypoint = "src/main.luau",

    -- Files and/or directories to include.
    -- Directories are expanded recursively.
    files = {
        "C:/projects/my_app/src",
        "C:/projects/my_app/.luaurc",
    },

    -- (Optional) Base executable to clone.
    -- Defaults to the currently running Eryx executable.
    -- sourceExe = "path/to/eryx.exe",
})
```

The resulting executable is a complete copy of the Eryx runtime with the file archive appended at the end. It can be distributed and run on its own - no separate Eryx install required.

> **Important:** The bundle executable must be able to find the shared libraries it needs (e.g. native libraries). The simplest approach is to place the bundle in the same directory as the original Eryx executable.

## How the bundle runs

When the bundle starts:

1. Eryx detects the appended archive and opens it automatically.
2. The entrypoint script is loaded from the archive and executed.
3. All `require` calls from VFS scripts resolve against the archive first.
4. `@eryx/*` libraries (built-in / native) remain available as usual.

No special flags or arguments are needed - just run the executable directly. Any command-line arguments are forwarded to the script.

## File paths inside the bundle

Paths in the VFS use forward slashes and are relative to the `root` that was specified at build time. For example, if `root` was `C:/projects/my_app` and you included `C:/projects/my_app/src/main.luau`, the VFS key is `src/main.luau`.

## Require resolution

### Relative requires (`./` and `../`)

From a VFS script, `./` and `../` resolve against the caller's directory **inside the archive**. The VFS is always checked first.

```luau
-- If the caller is at VFS key "src/main.luau",
-- this resolves to VFS key "src/utils.luau" (or "src/utils/init.luau").
local utils = require("./utils")
```

### Alias requires (`@eryx/*`, `@self`, config aliases)

- `@eryx/*` resolves to built-in / native libraries as normal.
- `@self` resolves relative to the caller's own directory inside the VFS.
- Config aliases (defined in `.luaurc` or `*.config.luau`) are resolved from config files found inside the archive, walking from the caller's directory up to the VFS root.

### VFS overlay for filesystem scripts

Even when running a normal filesystem script (not inside a bundle), if a VFS bundle is open the archive is checked as an overlay. Alias-resolved paths are looked up in the VFS before the real filesystem, so a bundle can shadow files on disk.

## Config resolution

Config files (`.luaurc` and `*.config.luau`) inside the archive participate in the normal parent-first merge. The VFS directory tree is walked from the caller's directory up to the VFS root. If isolation is disabled (see below), the walk then continues on the real filesystem starting from the executable's directory.

## Isolation

By default, VFS bundles run in **isolated** mode: scripts inside the archive cannot fall through to the real filesystem for requires or config resolution. This is the safe default for distribution.

Isolation can be toggled at runtime:

```luau
local vfs = require("@eryx/vfs")

-- Allow VFS scripts to reach the real filesystem.
vfs.setIsolated(false)

-- Check the current mode.
print(vfs.isIsolated()) -- false

-- Re-enable isolation.
vfs.setIsolated(true)
```

### What changes when isolation is disabled

1. **Config resolution** continues past the VFS root, walking up the real filesystem starting from the **executable's directory** (not the current working directory).

2. **Relative requires** that fail VFS lookup can fall through to the filesystem. The path is interpreted relative to the executable's directory, but only if the resolved path ends up **at or above** the VFS root level. A `./` from a script deep inside a VFS subdirectory never reaches the filesystem - you must `../` enough times to "escape" the VFS tree first.

    ```luau
    -- Example: entrypoint is at VFS key "app/main.luau".
    -- "../some_lib" normalises to "some_lib" (at VFS root level),
    -- so if it isn't found in the archive it is looked up next to the exe.

    -- But "./local_mod" normalises to "app/local_mod" (still inside a
    -- VFS subdirectory), so it is VFS-only even when not isolated.
    ```

## Introspection API

All functions are available via `require("@eryx/vfs")`.

| Function             | Returns    | Description                                           |
| -------------------- | ---------- | ----------------------------------------------------- |
| `vfs.isOpen()`       | `boolean`  | Whether a VFS archive is currently loaded.            |
| `vfs.entrypoint()`   | `string?`  | The entrypoint path, or `nil` if no bundle is open.   |
| `vfs.readFile(path)` | `string`   | Read a file from the archive. Errors if not found.    |
| `vfs.exists(path)`   | `boolean`  | Whether a file exists in the archive.                 |
| `vfs.isFile(path)`   | `boolean`  | Whether the path is a file (not a directory).         |
| `vfs.isDir(path)`    | `boolean`  | Whether the path is a directory (has files under it). |
| `vfs.listDir(dir)`   | `{string}` | Direct children (files and directories) of `dir`.     |
| `vfs.mtime(path)`    | `number`   | Modification time stored at bundle time.              |
| `vfs.isIsolated()`   | `boolean`  | Current isolation mode.                               |
| `vfs.setIsolated(v)` | -          | Toggle isolation mode.                                |
| `vfs.build(opts)`    | `boolean`  | Build a new bundle (see above).                       |

### `vfs.listDir`

Returns both files and (implicit) directories. Since the VFS is a flat file store, directories are inferred from path prefixes - if any file exists under `dir/foo/`, then `"foo"` appears in the listing.

```luau
-- Given VFS keys:
--   data/config.json
--   data/sprites/player.png
--   data/sprites/enemy.png
--
vfs.listDir("data") == { "config.json", "sprites" }
```

### `vfs.isFile` / `vfs.isDir`

A path is a **file** if it matches a VFS entry exactly. A path is a **directory** if any file exists with that path as a prefix (i.e. files exist "inside" it). A path can be neither (doesn't exist) but never both.

```luau
vfs.isFile("data/config.json")  -- true
vfs.isDir("data/config.json")   -- false
vfs.isFile("data/sprites")      -- false
vfs.isDir("data/sprites")       -- true
vfs.isFile("data/nope")         -- false
vfs.isDir("data/nope")          -- false
```
