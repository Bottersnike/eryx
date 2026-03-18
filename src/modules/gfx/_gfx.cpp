// _gfx.dll - Native Luau module that consolidates all graphics, audio,
// and input subsystems (SDL3, WGPU, FreeType, miniaudio).
//
// On first require, this module auto-initialises SDL, WGPU and FreeType.
// It registers all necessary metatables (Window, Texture, Font, Shader,
// Sound, ParticleSystem) and returns a flat table of factory / utility
// functions that the per-topic Luau wrappers re-export.

#include "../module_api.h"

// Pull in the engine precompiled header (SDL3, WGPU, Luau, FreeType, …)
#include "pch.hpp"

// Subsystem headers - needed for struct definitions and init/destroy decls
#include "Font.hpp"
#include "GFX.hpp"
#include "GPU.hpp"
#include "Mouse.hpp"
#include "Particles.hpp"
#include "Shader.hpp"
#include "Sound.hpp"
#include "Texture.hpp"
#include "Window.hpp"


// ---------------------------------------------------------------------------
// Forward-declare the C functions we want to expose to Luau.
// These are defined in the respective .cpp files which are compiled into
// this same DLL target, so the linker can resolve them.
// ---------------------------------------------------------------------------

// Window
extern int window_create(lua_State* L);

// GFX (image / font loading)
extern int gfx_loadImage(lua_State* L);
extern int gfx_loadFont(lua_State* L);

// Shader
extern int shader_load(lua_State* L);

// Sound
extern int sound_init(lua_State* L);
extern int sound_load(lua_State* L);

// Mouse
extern int mouse_available(lua_State* L);
extern int mouse_getPosition(lua_State* L);
extern int mouse_getButtons(lua_State* L);

// Particles
extern int particles_createSystem(lua_State* L);

// ---------------------------------------------------------------------------
// Module metadata (consumed by lrequire.cpp's native loader)
// ---------------------------------------------------------------------------

static const LuauModuleInfo INFO = {
    .abiVersion = ABI_VERSION,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__gfx",
};

LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Cleanup - registered via atexit() so it runs after main() returns
// (and therefore after lua_close() has already GC'd all userdata).
// ---------------------------------------------------------------------------
static bool s_initialised = false;

static void gfx_atexit() {
    if (!s_initialised) return;
    s_initialised = false;

    sound_destroy();
    gfx_destroy();
    gpu_destroy();
    SDL_Quit();
}

// Manual shutdown callable from Luau (for scripts that want explicit control)
static int gfx_shutdown(lua_State* L) {
    gfx_atexit();
    return 0;
}

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen__gfx(lua_State* L) {
    if (s_initialised) {
        // Already initialised - just return the cached table
        // (shouldn't happen due to require caching, but be safe)
        luaL_error(L, "_gfx module already initialised");
        return 0;
    }

    // --- Initialise subsystems ---

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        luaL_error(L, "Failed to initialise SDL3: %s", SDL_GetError());
        return 0;
    }

    if (!gpu_init()) {
        SDL_Quit();
        luaL_error(L, "Failed to initialise GPU (WGPU)");
        return 0;
    }

    if (!gfx_init()) {
        gpu_destroy();
        SDL_Quit();
        luaL_error(L, "Failed to initialise FreeType");
        return 0;
    }

    s_initialised = true;
    atexit(gfx_atexit);

    // --- Register metatables ---
    // These store metatables in the Lua registry (shared across all threads)
    // so userdata created later will have the correct methods.
    // The globals they set on this thread are harmless side-effects.
    window_lib_register(L);
    gfx_lib_register(L);  // also registers Texture + Font metatables
    shader_lib_register(L);
    sound_lib_register(L);
    mouse_lib_register(L);
    particles_lib_register(L);

    // --- Build the return table ---
    lua_newtable(L);

    // Window
    lua_pushcfunction(L, window_create, "window_create");
    lua_setfield(L, -2, "window_create");

    // GFX (image / font loading)
    lua_pushcfunction(L, gfx_loadImage, "loadImage");
    lua_setfield(L, -2, "loadImage");

    lua_pushcfunction(L, gfx_loadFont, "loadFont");
    lua_setfield(L, -2, "loadFont");

    // Shader
    lua_pushcfunction(L, shader_load, "loadShader");
    lua_setfield(L, -2, "loadShader");

    // Sound
    lua_pushcfunction(L, sound_init, "sound_init");
    lua_setfield(L, -2, "sound_init");

    lua_pushcfunction(L, sound_load, "sound_load");
    lua_setfield(L, -2, "sound_load");

    // Mouse
    lua_pushcfunction(L, mouse_available, "mouse_available");
    lua_setfield(L, -2, "mouse_available");

    lua_pushcfunction(L, mouse_getPosition, "mouse_getPosition");
    lua_setfield(L, -2, "mouse_getPosition");

    lua_pushcfunction(L, mouse_getButtons, "mouse_getButtons");
    lua_setfield(L, -2, "mouse_getButtons");

    // Particles
    lua_pushcfunction(L, particles_createSystem, "particles_createSystem");
    lua_setfield(L, -2, "particles_createSystem");

    // Lifecycle
    lua_pushcfunction(L, gfx_shutdown, "shutdown");
    lua_setfield(L, -2, "shutdown");

    return 1;
}
