#pragma once
#include "LL_Font.hpp"
#include "LL_Texture.hpp"
#include "Shader.hpp"
#include "pch.hpp"

extern const char* WINDOW_METATABLE;

// Window userdata type
struct LuaWindow {
    SDL_Window* window = nullptr;
    std::string title;
    WGPUSurface surface = nullptr;
    bool should_close = false;

    // GPU rendering
    GPURenderContext gpu_context;
    std::map<const Image*, GPUTexture> texture_cache;  // Cached GPU textures

    LuaShader* current_shader = nullptr;
    LuaShader* post_effect = nullptr;
    WGPUTexture offscreen_texture = nullptr;
    WGPUTextureView offscreen_view = nullptr;

    int width = 0;
    int height = 0;

    LuaWindow() : window(nullptr), surface(nullptr), should_close(false), width(0), height(0) {}
    ~LuaWindow() {
        if (offscreen_view) wgpuTextureViewRelease(offscreen_view);
        if (offscreen_texture) wgpuTextureRelease(offscreen_texture);
    }
};

void window_lib_register(lua_State* L);
