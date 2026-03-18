#include "Shader.hpp"
#include <vector>
#include <string>
#include <iostream>

const char* SHADER_METATABLE = "Shader";

// Helper for layout (std140)
static size_t get_align(const std::string& type) {
    if (type == "f32" || type == "i32" || type == "u32") return 4;
    if (type == "vec2") return 8;
    if (type == "vec3") return 16;
    if (type == "vec4") return 16;
    return 16;
}

static size_t get_size(const std::string& type) {
    if (type == "f32" || type == "i32" || type == "u32") return 4;
    if (type == "vec2") return 8;
    if (type == "vec3") return 12;
    if (type == "vec4") return 16;
    return 0;
}

int shader_load(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    const char* source = luaL_checkstring(L, 2);

    LuaShader* shader = (LuaShader*)lua_newuserdata(L, sizeof(LuaShader));
    new (shader) LuaShader();
    shader->name = name;

    const char* constant_prefix = R"(
struct VertexInput {
    @location(0) pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: u32,
};
struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};
struct Uniforms {
    projection: mat4x4<f32>,
    time: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
    resolution: vec2<f32>,
    mouse: vec2<f32>,
};
@group(1) @binding(0) var<uniform> sys: Uniforms;
@group(0) @binding(0) var s_diffuse: sampler;
@group(0) @binding(1) var t_diffuse: texture_2d<f32>;
)";

    // Parse uniforms from optional 3rd argument
    std::string uniforms_wgsl;

    if (lua_istable(L, 3)) {
        uniforms_wgsl += "struct UserUniforms {\n";

        size_t current_offset = 0;
        int len = (int)lua_objlen(L, 3);

        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, 3, i); // Push item
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "name");
                std::string u_name = luaL_checkstring(L, -1);
                lua_pop(L, 1);

                lua_getfield(L, -1, "type");
                std::string u_type = luaL_checkstring(L, -1);
                lua_pop(L, 1);

                size_t align = get_align(u_type);
                size_t size = get_size(u_type);
                if (size == 0) {
                    luaL_error(L, "Unknown WGSL datatype: %s", u_type.c_str());
                    return 0;
                }

                // Align current offset
                size_t padding = (current_offset % align == 0) ? 0 : (align - (current_offset % align));
                current_offset += padding;

                UserUniform u;
                u.name = u_name;
                u.offset = (uint32_t)current_offset;
                u.size = (uint32_t)size;
                shader->user_uniform_defs.push_back(u);

                // WGSL supports vec3<f32> but let's stick to standard names
                uniforms_wgsl += "    " + u_name + ": " + u_type + ",\n";

                current_offset += size;
            }
            lua_pop(L, 1); // Pop item
        }

        // Final padding to 16 bytes (uniform buffer requirement)
        if (current_offset > 0) {
            if (current_offset % 16 != 0) {
                current_offset += 16 - (current_offset % 16);
            }

            uniforms_wgsl += "};\n";
            uniforms_wgsl += "@group(2) @binding(0) var<uniform> uni: UserUniforms;\n\n";

            shader->user_uniform_data.resize(current_offset, 0);
        } else {
             uniforms_wgsl = ""; // No fields found
        }
    }

    shader->source = constant_prefix + uniforms_wgsl + std::string(source);

    luaL_getmetatable(L, SHADER_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

int shader_tostring(lua_State* L) {
    LuaShader* shader = (LuaShader*)luaL_checkudata(L, 1, SHADER_METATABLE);
    lua_pushfstring(L, "Shader(%s)", shader->name.c_str());
    return 1;
}

int share_gc(lua_State* L) {
    LuaShader* shader = (LuaShader*)luaL_checkudata(L, 1, SHADER_METATABLE);
    if (shader) {
        shader->~LuaShader();  // Explicitly call destructor
    }
    return 0;
}

// Shader::Set(name: string, values...) -> ()
int shader_Set(lua_State* L) {
    LuaShader* shader = (LuaShader*)luaL_checkudata(L, 1, SHADER_METATABLE);
    const char* uniform_name = luaL_checkstring(L, 2);

    if (!shader) {
        luaL_error(L, "Invalid shader object");
        return 0;
    }

    // Search user uniforms first
    for (const auto& u : shader->user_uniform_defs) {
        if (u.name == uniform_name) {
            int num_args = lua_gettop(L) - 2;
            int float_count = u.size / 4;
            int count = (num_args < float_count) ? num_args : float_count;

            float* ptr = (float*)(shader->user_uniform_data.data() + u.offset);
            for (int i = 0; i < count; i++) {
                ptr[i] = (float)luaL_checknumber(L, 3 + i);
            }
            shader->user_uniforms_dirty = true;
            return 0;
        }
    }

    luaL_error(L, "Unknown shader uniform '%s'", uniform_name);
    return 0;
}

// Shader:error() -> string?
int shader_error(lua_State* L) {
    LuaShader* shader = (LuaShader*)luaL_checkudata(L, 1, SHADER_METATABLE);
    if (shader && !shader->error_message.empty()) {
        lua_pushstring(L, shader->error_message.c_str());
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

void shader_lib_register(lua_State* L) {
    // Shader methods
    luaL_newmetatable(L, SHADER_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, shader_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, share_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, shader_error, "error");
    lua_setfield(L, -2, "error");

    lua_pushcfunction(L, shader_Set, "Set");
    lua_setfield(L, -2, "Set");

    lua_pop(L, 1);


    // Create gfx library extensions for shaders
    lua_getglobal(L, "gfx");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, shader_load, "loadShader");
        lua_setfield(L, -2, "loadShader");
    }
    lua_pop(L, 1);
}