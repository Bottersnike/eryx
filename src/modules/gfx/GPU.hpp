#pragma once
#include "LL_Texture.hpp"  // IWYU pragma: export
#include "LL_Font.hpp"  // IWYU pragma: export
#include "pch.hpp"         // IWYU pragma: export


struct LuaShader;

// GPU vertex structure for rendering
struct GPUVertex {
    float x, y;      // Position
    float u, v;      // Texture coordinates
    uint32_t color;  // Color (RGBA)
};

// GPU rendering context for a window
struct GPURenderContext {
    WGPUDevice device = nullptr;
    WGPUQueue queue = nullptr;
    WGPUTextureFormat surface_format = WGPUTextureFormat_BGRA8Unorm;

    WGPUBuffer vertex_buffer = nullptr;
    WGPUBuffer index_buffer = nullptr;
    WGPUShaderModule shader_module = nullptr;
    WGPURenderPipeline pipeline = nullptr;
    WGPUBindGroupLayout bind_group_layout = nullptr;
    WGPUSampler sampler = nullptr;
    WGPUTexture default_texture = nullptr;
    WGPUTextureView default_texture_view = nullptr;
    WGPUTexture glyph_atlas_texture = nullptr;
    WGPUTextureView glyph_atlas_texture_view = nullptr;
    WGPUTexture msaa_texture = nullptr;
    WGPUTextureView msaa_view = nullptr;
    WGPUBuffer screen_uniform_buffer = nullptr;

    // Track current bind group and texture for batching
    WGPUBindGroup current_bind_group = nullptr;
    WGPUTextureView current_texture_view = nullptr;

    // Draw batches - track which texture each section of vertices uses
    struct DrawBatch {
        size_t index_start;
        size_t index_count;
        size_t vertex_start;
        size_t vertex_count;
        size_t item_count = 0;
        WGPUTextureView texture_view;
        LuaShader* shader = nullptr;
    };
    std::vector<DrawBatch> draw_batches;

    size_t max_vertices = 10000;
    size_t max_indices = 30000;

    std::vector<GPUVertex> vertex_queue;
    std::vector<uint32_t> index_queue;
};

// Cached GPU texture resources
struct GPUTexture {
    WGPUTexture texture = nullptr;
    WGPUTextureView view = nullptr;
    WGPUBindGroup bind_group = nullptr; // Cache bind group to avoid recreation
};

struct LuaWindow;

WGPUTextureView createTextureView(WGPUTexture texture);
bool initGPURenderContext(LuaWindow* lua_window);
WGPUTexture createGPUTexture(WGPUDevice device, WGPUQueue queue, const Image& image);
void clearGPUQueues(LuaWindow* lua_window);
bool gpu_init(void);
void gpu_destroy(void);
bool createWindowSurface(LuaWindow* lua_window);
bool uploadGlyphAtlas(LuaWindow* lua_window, GlyphAtlas& atlas);
// Returns error message if failed, empty string if success
std::string renderGPUQueue(LuaWindow* lua_window);


