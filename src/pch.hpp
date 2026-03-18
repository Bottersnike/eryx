#pragma once

#ifndef LUAU_GIT_HASH
#error "LUAU_GIT_HASH must be defined by the build system"
#endif
#ifndef LUAU_APPROX_VERSION
#error "LUAU_APPROX_VERSION must be defined by the build system"
#endif

#ifdef _WIN32
#define _CRTDBG_MAP_ALLOC
#include <crtdbg.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
//
#include <Windows.h>
#endif
// uv is going to include Windows.h, so we need to make sure to include things in the right order
// ourselves. We don't link against UV here, but need a pointer for it, so use the full path.
#include <uv.h>
//

#include <algorithm>  // IWYU pragma: export
#include <cmath>      // IWYU pragma: export
#include <cstddef>    // IWYU pragma: export
#include <cstring>    // IWYU pragma: export
#include <deque>      // IWYU pragma: export
#include <fstream>    // IWYU pragma: export
#include <iostream>   // IWYU pragma: export
#include <map>        // IWYU pragma: export
#include <set>        // IWYU pragma: export
#include <sstream>    // IWYU pragma: export
#include <string>     // IWYU pragma: export
#include <vector>     // IWYU pragma: export

#include "Luau/Compiler.h"  // IWYU pragma: export
#include "lua.h"            // IWYU pragma: export
#include "luacode.h"        // IWYU pragma: export
#include "lualib.h"         // IWYU pragma: export

#ifdef _WIN32
#define PATH_PRINTF "%ls"
#else
#define PATH_PRINTF "%s"
#endif

// In embed mode everything lives in the same executable, so no dllexport/import.
#ifdef ERYX_EMBED
#define ERYX_API extern "C"
#else
#ifdef _WIN32
#define ERYX_API extern "C" __declspec(dllexport)
#else
#define ERYX_API extern "C" __attribute__((visibility("default")))
#endif
#endif
