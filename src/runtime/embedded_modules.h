// Header for embedded module tables.
// When modules are embedded (ERYX_EMBED or ERYX_HYBRID), their entrypoints
// and script sources are registered at startup via eryx_register_embedded_modules().
// The runtime code always compiles the lookup paths but checks for null at runtime.
#pragma once

struct lua_State;

typedef int (*EmbeddedModuleEntry)(lua_State* L);

struct EmbeddedNativeModule {
    const char* modulePath;   // e.g. "task", "compression/zlib", "gfx/_gfx"
    EmbeddedModuleEntry entry;
};

struct EmbeddedScriptModule {
    const char* modulePath;   // e.g. "http", "encoding/init", "gfx/window"
    const char* source;       // raw Luau source code
};

// ---------------------------------------------------------------------------
// Registration API
// ---------------------------------------------------------------------------

// Call once at startup (before any require()) to register the embedded tables.
// Both arrays must be null-terminated.
void eryx_register_embedded_modules(
    const EmbeddedNativeModule* native,
    const EmbeddedScriptModule* scripts);

// Returns the registered tables, or nullptr if not registered.
const EmbeddedNativeModule*  eryx_get_embedded_native_modules();
const EmbeddedScriptModule*  eryx_get_embedded_script_modules();

// Convenience: true when embedded tables have been registered.
bool eryx_has_embedded_modules();
