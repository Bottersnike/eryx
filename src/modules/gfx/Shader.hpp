#pragma once
#include "GPU.hpp"
#include "pch.hpp"


extern const char* SHADER_METATABLE;

struct alignas(16) Uniforms {
    float projection[16];  // 64 bytes
    float time;            // 4 bytes
    float padding[3];      // 12 bytes (align to 16)
    float resolution[2];   // 8 bytes
    float mouse[2];        // 8 bytes
};

struct UserUniform {
    std::string name;
    uint32_t offset;
    uint32_t size;
    // We only support f32, vec2, vec3, vec4 for now
};

struct LuaShader {
    std::string name;
    std::string source;

    WGPURenderPipeline pipeline = nullptr;
    WGPUBindGroupLayout bind_group_layout = nullptr;  // Group 1 (System)
    WGPUBindGroup bind_group = nullptr;               // Group 1 (System)
    WGPUBuffer uniform_buffer = nullptr;

    WGPUBindGroupLayout user_bind_group_layout = nullptr; // Group 2 (User)
    WGPUBindGroup user_bind_group = nullptr;              // Group 2 (User)
    WGPUBuffer user_uniform_buffer = nullptr;

    Uniforms uniform_data = {};
    bool uniforms_dirty = true;

    std::vector<uint8_t> user_uniform_data;
    std::vector<UserUniform> user_uniform_defs;
    bool user_uniforms_dirty = false;

    bool compilation_failed = false;
    std::string error_message;

    LuaShader() = default;
    ~LuaShader() {
        if (bind_group) wgpuBindGroupRelease(bind_group);
        if (bind_group_layout) wgpuBindGroupLayoutRelease(bind_group_layout);
        if (user_bind_group) wgpuBindGroupRelease(user_bind_group);
        if (user_bind_group_layout) wgpuBindGroupLayoutRelease(user_bind_group_layout);
        if (pipeline) wgpuRenderPipelineRelease(pipeline);
        if (uniform_buffer) wgpuBufferRelease(uniform_buffer);
        if (user_uniform_buffer) wgpuBufferRelease(user_uniform_buffer);
    }
};

void shader_lib_register(lua_State* L);
