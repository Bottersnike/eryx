// Lightweight header for Luau native modules (DLLs).
// This is intentionally a C header with minimal dependencies so modules
// don't need to pull in the full engine PCH.
#pragma once

#include "../runtime/_wrapper_lib.hpp"

#ifndef LUAU_GIT_HASH
#error "LUAU_GIT_HASH must be defined by the build system"
#endif
#ifndef LUAU_APPROX_VERSION
#error "LUAU_APPROX_VERSION must be defined by the build system"
#endif

#define ABI_VERSION 1

typedef struct {
    unsigned int abiVersion;
    const char* luauVersion;
    const char* entry;
} LuauModuleInfo;

// In embed mode, luau_module_info() collides across modules since they all
// share the same link unit.  Suppress the export; the entrypoint function
// (luauopen_*) is the only symbol the embed table needs.
#ifdef ERYX_EMBED
#define LUAU_MODULE_EXPORT   extern "C"   /* no dllexport, but keep C linkage */
#define LUAU_MODULE_INFO()   /* suppressed in embed mode */
#else
#ifdef _WIN32
#define LUAU_MODULE_EXPORT   extern "C" __declspec(dllexport)
#define LUAU_MODULE_INFO()   extern "C" __declspec(dllexport) const LuauModuleInfo* luau_module_info() { return &INFO; }
#else
#define LUAU_MODULE_EXPORT   extern "C" __attribute__((visibility("default")))
#define LUAU_MODULE_INFO()   extern "C" __attribute__((visibility("default"))) const LuauModuleInfo* luau_module_info() { return &INFO; }
#endif
#endif
