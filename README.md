# Eryx

Eryx is a standalone [Luau](https://luau-lang.org/) runtime with a broad standard library. It provides native modules for networking, cryptography, compression, file formats, databases, FFI, basic graphics, and more, with the goal of making Luau viable for general-purpose programming outside of Roblox.

> [!NOTE]
> Eryx is pre-release software. APIs will change, likely drastically!

## Quick Example

```lua
local http = require("@eryx/http")
local json = require("@eryx/encoding/json")

http.serve({ port = 8080 }, function(req)
    return {
        status = 200,
        body = json.encode({ message = "hello" }),
    }
end)
```

## Building

Windows (x64) is currently the only validated build target. Linux and macOS support is planned.

### Requirements

- MSVC (Tested against Visual Studio 2019)
- CMake
- Git (dependencies are vendored as submodules)

```bash
git clone --recursive https://github.com/Bottersnike/eryx
cd eryx

cmake --preset release
cmake --build build
```

For debugging

```bash
cmake -S . -B build-vs -G "Visual Studio 16 2019"

```

### Presets

| Preset    | Description                                           |
| --------- | ----------------------------------------------------- |
| `default` | Debug build, modules as separate DLLs                 |
| `release` | Optimized release build                               |
| `embed`   | Single portable binary, all modules statically linked |

### Build Options

All optional — each defaults to `ON`:

| Option                  | Description                     |
| ----------------------- | ------------------------------- |
| `ERYX_MODULE_GFX`       | Graphics module (SDL3 + WebGPU) |
| `ERYX_USE_CRYPTOGRAPHY` | Cryptography (MbedTLS)          |
| `ERYX_USE_ZLIB`         | zlib / gzip                     |
| `ERYX_USE_ZSTD`         | Zstandard                       |
| `ERYX_USE_BROTLI`       | Brotli                          |
| `ERYX_USE_BZIP2`        | BZip2                           |
| `ERYX_USE_SQLITE3`      | SQLite3                         |
| `ERYX_USE_XML`          | XML (pugixml)                   |

## License

See individual vendored dependency licenses in [`vendor/`](vendor/).
