# Eryx

Eryx is a standalone [Luau](https://luau-lang.org/) runtime with a broad standard library. It provides native libraries for networking, cryptography, compression, file formats, databases, FFI, basic graphics, and more, with the goal of making Luau viable for general-purpose programming outside of Roblox.

> [!NOTE]
> Eryx is pre-release software. APIs will change, likely drastically!

## Quick Example

```lua
local http = require("@eryx/http")
local json = require("@eryx/data/json")

http.serve({ port = 8080 }, function(req)
    return {
        status = 200,
        body = json.encode({ message = "hello" }),
    }
end)
```

## What version do I want?

Most users will want the **standard** build. This consists of the main Eryx executable, a shared library for all runtime operations, and every available library as individual files. Each library consists of either pure Luau scripts, or a single shared library with Luau scripts providing type stubs.

This build is generally recommended as it provides maximum flexibility, along with full type annotation.

For distribution, the **embedded** build is generally recommend. This build is a single executable, with no other files, providing the entire runtime along with all built in libraries. As the runtime is now part of the executable, instead of a separate shared library, external native libraries cannot be used with this build. Types will be unavailable in a development environment, though the type stubs from the standard build can be used.

When compiling a project to a single executable using a virtual filesystem, the embedded build will result in a truly single-file distribution. When using the standard build all of Eryx's files need distributed alongside the compiled file.

The **hybrid** build is similar to the embedded build, but the runtime is provided as a separate shared library. This build can be used if the single-file nature of the embedded build is desired, but external shared libraries are required.

## Building

Windows (x64), and Linux (GCC 14 or 15) are the currently validated build targets. macOS in theory has working code paths, but they're entirely untested due to a lack of hardware to test them with.

### Requirements

- MSVC (Tested against Visual Studio 2019), or GCC 14/15
- CMake
- Git (dependencies are vendored as submodules)

```bash
git clone --recursive https://github.com/Bottersnike/eryx
cd eryx

cmake --preset release
cmake --build build
```

For debugging on Windows

```bash
cmake -S . -B build-vs -G "Visual Studio 16 2019"
```

### Presets

| Preset    | Description                                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------------------------- |
| `default` | Debug build, libraries as separate shared libraries                                                               |
| `release` | Optimized release build                                                                                           |
| `embed`   | Single portable binary, all libraries statically linked                                                           |
| `hybrid`  | A binary with all libraries statically linked, alongside the shared runtime library required for external libraries |

### Build Options

All optional — each defaults to `ON`:

| Option                  | Description                     |
| ----------------------- | ------------------------------- |
| `ERYX_MODULE_GFX`       | Graphics library (SDL3 + WebGPU) |
| `ERYX_USE_CRYPTOGRAPHY` | Cryptography                    |
| `ERYX_USE_ZLIB`         | zlib / gzip                     |
| `ERYX_USE_ZSTD`         | Zstandard                       |
| `ERYX_USE_BROTLI`       | Brotli                          |
| `ERYX_USE_BZIP2`        | BZip2                           |
| `ERYX_USE_SQLITE3`      | SQLite3                         |
| `ERYX_USE_XML`          | XML (pugixml)                   |

### GMP

GMP takes a long time to compile on windows with MSVC, so pre-built sources are vendored into git. To recompile them, use:

> `cmake -S vendor/gmp -B build-vendor-gmp`
>
> `cmake -S vendor/mpfr -B build-vendor-mpfr`

## License

See individual vendored dependency licenses in [`vendor/`](vendor/).
