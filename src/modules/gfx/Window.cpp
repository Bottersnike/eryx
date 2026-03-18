#include "Window.hpp"

#include "Font.hpp"
#include "GPU.hpp"
#include "LL_Render.hpp"
#include "LuaUtil.hpp"
#include "Texture.hpp"

const char* WINDOW_METATABLE = "Window";

// export type Vec2 = {number, number}
// export type UV = {number, number, number, number}

// window.create(width: number, height: number, title: string) -> Window
int window_create(lua_State* L) {
    int width = (int)luaL_checknumber(L, 1);
    int height = (int)luaL_checknumber(L, 2);
    const char* title = luaL_checkstring(L, 3);

    SDL_Window* window = SDL_CreateWindow(title, width, height, 0);
    if (!window) {
        luaL_error(L, "Failed to create SDL window: %s", SDL_GetError());
        return 0;
    }

    // Create userdata for window
    LuaWindow* lua_window = (LuaWindow*)lua_newuserdata(L, sizeof(LuaWindow));
    new (lua_window) LuaWindow();  // Call constructor to initialize
    lua_window->window = window;
    lua_window->title = title;
    lua_window->width = width;
    lua_window->height = height;
    lua_window->surface = nullptr;

    // Create WGPU surface for this window
    if (!createWindowSurface(lua_window)) {
        std::cerr << "    [C++] Failed to create WGPU surface" << std::endl;
        SDL_DestroyWindow(window);
        luaL_error(L, "Failed to create WGPU surface for window");
        return 0;
    }

    // Initialize GPU rendering context
    if (!initGPURenderContext(lua_window)) {
        std::cerr << "    [C++] Failed to initialize GPU rendering context" << std::endl;
        SDL_DestroyWindow(window);
        luaL_error(L, "Failed to initialize GPU rendering");
        return 0;
    }

    // Set metatable
    luaL_getmetatable(L, WINDOW_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

// __tostring(Window) -> string
int window_tostring(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    lua_pushfstring(L, "Window(%s)", lua_window->title.c_str());
    return 1;
}

// __gc(Window) -> ()
int window_gc(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window) return 0;

    // Release GPU resources
    if (lua_window->surface) {
        wgpuSurfaceRelease(lua_window->surface);
        lua_window->surface = nullptr;
    }

    GPURenderContext& ctx = lua_window->gpu_context;
    if (ctx.pipeline) wgpuRenderPipelineRelease(ctx.pipeline);
    if (ctx.shader_module) wgpuShaderModuleRelease(ctx.shader_module);
    if (ctx.sampler) wgpuSamplerRelease(ctx.sampler);
    if (ctx.bind_group_layout) wgpuBindGroupLayoutRelease(ctx.bind_group_layout);
    if (ctx.vertex_buffer) wgpuBufferRelease(ctx.vertex_buffer);
    if (ctx.index_buffer) wgpuBufferRelease(ctx.index_buffer);
    if (ctx.default_texture) wgpuTextureRelease(ctx.default_texture);
    if (ctx.default_texture_view) wgpuTextureViewRelease(ctx.default_texture_view);
    if (ctx.current_bind_group) wgpuBindGroupRelease(ctx.current_bind_group);

    // Release texture cache resources
    for (auto& pair : lua_window->texture_cache) {
        if (pair.second.texture) wgpuTextureRelease(pair.second.texture);
        if (pair.second.view) wgpuTextureViewRelease(pair.second.view);
        if (pair.second.bind_group) wgpuBindGroupRelease(pair.second.bind_group);
    }

    if (lua_window->window) {
        SDL_DestroyWindow(lua_window->window);
        lua_window->window = nullptr;
    }

    lua_window->~LuaWindow();  // Explicitly call destructor

    return 0;
}

// Window::PollEvents() -> number
// TODO: Return actual events

#define SET_STRING(key, val) \
    lua_pushstring(L, val);  \
    lua_setfield(L, -2, key)
#define SET_INT(key, val)                   \
    lua_pushinteger(L, (lua_Integer)(val)); \
    lua_setfield(L, -2, key)
#define SET_BOOL(key, val)     \
    lua_pushboolean(L, (val)); \
    lua_setfield(L, -2, key)
#define SET_NUMBER(key, val)              \
    lua_pushnumber(L, (lua_Number)(val)); \
    lua_setfield(L, -2, key)

int window_PollEvents(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    SDL_Event event;
    // int event_count = 0;

    lua_newtable(L);
    int event_index = 1;

    // while (SDL_PollEvent(&event)) {
    //     event_count++;

    //     if (event.type == SDL_EVENT_QUIT) {
    //         std::cout << "  [C++] Quit event received" << std::endl;
    //         lua_window->should_close = true;
    //     } else if (event.type == SDL_EVENT_KEY_DOWN) {
    //         std::cout << "  [C++] Key pressed: " << (int)event.key.key << std::endl;
    //     } else if (event.type == SDL_EVENT_KEY_UP) {
    //     }
    // }

    while (SDL_PollEvent(&event)) {
        lua_newtable(L);

        SET_INT("timestamp", event.common.timestamp);

        switch (event.type) {
            /* ---------------- Quit ---------------- */
            case SDL_EVENT_QUIT:
                SET_STRING("type", "quit");
                lua_window->should_close = true;
                break;

            /* ---------------- Window ---------------- */
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                SET_STRING("type", "window_close");
                break;

            case SDL_EVENT_WINDOW_RESIZED:
                SET_STRING("type", "window_resized");
                SET_INT("width", event.window.data1);
                SET_INT("height", event.window.data2);
                break;

            case SDL_EVENT_WINDOW_FOCUS_GAINED:
                SET_STRING("type", "window_focus_gained");
                break;

            case SDL_EVENT_WINDOW_FOCUS_LOST:
                SET_STRING("type", "window_focus_lost");
                break;

            /* ---------------- Keyboard ---------------- */
            case SDL_EVENT_KEY_DOWN:
                SET_STRING("type", "key_down");
                SET_STRING("key", SDL_GetKeyName(event.key.key));
                SET_INT("keycode", event.key.key);
                SET_INT("scancode", event.key.scancode);
                SET_BOOL("isRepeat", event.key.repeat);
                break;

            case SDL_EVENT_KEY_UP:
                SET_STRING("type", "key_up");
                SET_STRING("key", SDL_GetKeyName(event.key.key));
                SET_INT("keycode", event.key.key);
                SET_INT("scancode", event.key.scancode);
                break;

            /* ---------------- Text input ---------------- */
            case SDL_EVENT_TEXT_INPUT:
                SET_STRING("type", "text_input");
                SET_STRING("text", event.text.text);
                break;

            case SDL_EVENT_TEXT_EDITING:
                SET_STRING("type", "text_editing");
                SET_STRING("text", event.edit.text);
                SET_INT("start", event.edit.start);
                SET_INT("length", event.edit.length);
                break;

            /* ---------------- Mouse buttons ---------------- */
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
                SET_STRING("type", "mouse_button_down");
                SET_INT("button", event.button.button);
                SET_INT("x", event.button.x);
                SET_INT("y", event.button.y);
                SET_INT("clicks", event.button.clicks);
                break;

            case SDL_EVENT_MOUSE_BUTTON_UP:
                SET_STRING("type", "mouse_button_up");
                SET_INT("button", event.button.button);
                SET_INT("x", event.button.x);
                SET_INT("y", event.button.y);
                break;

            /* ---------------- Mouse motion ---------------- */
            case SDL_EVENT_MOUSE_MOTION:
                SET_STRING("type", "mouse_motion");
                SET_INT("x", event.motion.x);
                SET_INT("y", event.motion.y);
                SET_INT("dx", event.motion.xrel);
                SET_INT("dy", event.motion.yrel);
                break;

            /* ---------------- Mouse wheel ---------------- */
            case SDL_EVENT_MOUSE_WHEEL:
                SET_STRING("type", "mouse_wheel");
                SET_NUMBER("x", event.wheel.x);
                SET_NUMBER("y", event.wheel.y);
                SET_BOOL("flipped", event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED);
                break;

            /* ---------------- Gamepad (basic) ---------------- */
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                SET_STRING("type", "gamepad_button_down");
                SET_INT("button", event.gbutton.button);
                SET_INT("which", event.gbutton.which);
                break;

            case SDL_EVENT_GAMEPAD_BUTTON_UP:
                SET_STRING("type", "gamepad_button_up");
                SET_INT("button", event.gbutton.button);
                SET_INT("which", event.gbutton.which);
                break;

            case SDL_EVENT_GAMEPAD_AXIS_MOTION:
                SET_STRING("type", "gamepad_axis");
                SET_INT("axis", event.gaxis.axis);
                SET_INT("value", event.gaxis.value);
                SET_INT("which", event.gaxis.which);
                break;

            /* ---------------- Fallback ---------------- */
            default:
                SET_STRING("type", "unknown");
                SET_INT("raw_type", event.type);
                break;
        }

        lua_rawseti(L, -2, event_index++);
    }

    // lua_pushnumber(L, event_count);
    return 1;
}

// Window::StartFrame() -> ()
int window_StartFrame(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    // GPU rendering uses implicit clear on each frame, just signal start of new frame
    clearGPUQueues(lua_window);

    return 0;
}

// Window::EndFrame() -> ()
int window_EndFrame(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    GPURenderContext& ctx = lua_window->gpu_context;

    // Render all queued GPU vertices
    if (!ctx.vertex_queue.empty()) {
        std::string err = renderGPUQueue(lua_window);
        if (!err.empty()) {
            luaL_error(L, "%s", err.c_str());
        }
    }

    // Clear queues for next frame
    clearGPUQueues(lua_window);

    // Poll device to free resources
    wgpuDevicePoll(ctx.device, false, nullptr);

    return 0;
}

// Window.size: Vec2
int window_size(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    int w, h;
    SDL_GetWindowSize(lua_window->window, &w, &h);

    lua_pushvec2(L, w, h);
    return 1;
}

// Window::ShouldClose() -> boolean
int window_ShouldClose(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }
    lua_pushboolean(L, lua_window->should_close);
    return 1;
}

// Window::SetTitle(title: string) -> ()
int window_SetTitle(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    const char* title = luaL_checkstring(L, 2);

    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    SDL_SetWindowTitle(lua_window->window, title);
    lua_window->title = title;
    return 0;
}

// Window::SetFullscreen(fullscreen: boolean) -> ()
int window_SetFullscreen(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    bool fullscreen = lua_toboolean(L, 2);

    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    SDL_SetWindowFullscreen(lua_window->window, fullscreen);
    return 0;
}

// Window::Close() -> ()
int window_Close(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    lua_window->should_close = true;
    return 0;
}

// Window::DrawText(font: Font, text: string, pos: Vec2, colour?: number) -> (width:
// number, height: number)
int window_DrawText(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    LuaFont* font = (LuaFont*)luaL_checkudata(L, 2, FONT_METATABLE);
    const char* text = luaL_checkstring(L, 3);
    double pos[2];
    luaL_checkvec2(L, 4, pos);
    uint32_t color = 0xFFFFFFFF;
    if (luaL_hasarg(L, 5)) color = luaL_checkcolour(L, 5);

    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    if (!font || !font->face) {
        luaL_error(L, "Invalid font object");
        return 0;
    }

    // Build glyph atlas if needed (lazy init)
    if (font->atlas.glyphs.empty()) {
        if (buildGlyphAtlas(font->atlas, font->face)) {
            uploadGlyphAtlas(lua_window, font->atlas);
        }
    }

    // Queue text for GPU rendering
    float width, height;
    renderQueuedText(lua_window, font->atlas, font->face, text, pos[0], pos[1], color, &width,
                     &height);

    lua_pushnumber(L, width);
    lua_pushnumber(L, height);
    return 2;
}

// Window::DrawTexture(
//     texture: Texture,
//     pos: Vec2,
//     size?: Vec2
//     uv?: UV,
//     tint?: number
// ) -> ()
int window_DrawTexture(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 2, TEXTURE_METATABLE);
    double pos[2];
    luaL_checkvec2(L, 3, pos);

    // Optional width/height parameters
    double size[2] = { (double)texture->image.width, (double)texture->image.height };
    if (luaL_hasarg(L, 4)) {
        luaL_checkvec2(L, 4, size);
    }

    if (!texture) {
        luaL_error(L, "Invalid texture object");
        return 0;
    }

    double uv[4] = { 0.0, 0.0, 1.0, 1.0 };
    if (luaL_hasarg(L, 5)) {
        luaL_checkuv(L, 5, uv);
    }
    uint32_t tint = 0xFFFFFFFF;
    if (luaL_hasarg(L, 6)) {
        tint = luaL_checkcolour(L, 6);
    }

    // Queue textured quad for GPU rendering (whole texture, no scaling)
    queueTexturedQuad(lua_window, nullptr, texture, pos[0], pos[1], size[0], size[1], uv[0], uv[1], uv[2],
                      uv[3], tint);

    return 0;
}

// Window::DrawRectangle(pos: Vec2, size: Vec2, colour: number, border?: number) -> ()
int window_DrawRectangle(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    double pos[2];
    double size[2];
    luaL_checkvec2(L, 2, pos);
    luaL_checkvec2(L, 3, size);

    uint32_t color = luaL_checkcolour(L, 4);
    float border = 0;
    if (luaL_hasarg(L, 5)) border = luaL_checknumber(L, 5);

    if (border > 0) {
        queueRectangleBorder(lua_window, pos[0], pos[1], size[0], size[1], color, border);
    } else {
        queueFilledRectangle(lua_window, pos[0], pos[1], size[0], size[1], color);
    }

    return 0;
}

// Window::DrawCircle(pos: Vec2, radius: number, colour: number, border?: number) -> ()
int window_DrawCircle(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    double pos[2];
    luaL_checkvec2(L, 2, pos);
    double radius = luaL_checknumber(L, 3);
    uint32_t color = luaL_checkcolour(L, 4);
    float border = 0;
    if (luaL_hasarg(L, 5)) border = luaL_checknumber(L, 5);

    // If no border and radius is small, imply lower segments for perf
    // This is now handled in queueFilledCircle, but we pass default which triggers it.

    if (border > 0) {
        queueCircleBorder(lua_window, pos[0], pos[1], radius, color, border);
    } else {
        queueFilledCircle(lua_window, pos[0], pos[1], radius, color);
    }

    return 0;
}

// Window::DrawPolygon(points: {Vec2}, colour: number) -> ()
int window_DrawPolygon(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    luaL_checktype(L, 2, LUA_TTABLE);
    int count = (int)lua_objlen(L, 2);

    std::vector<float> points;
    points.reserve(count * 2);

    for (int i = 1; i <= count; i++) {
        // Push points[i]
        lua_rawgeti(L, 2, i);

        // Read Vec2
        double point[2];
        luaL_checkvec2(L, -1, point);

        // Pop points[i]
        lua_pop(L, 1);

        // Append to vector
        points.push_back(point[0]);
        points.push_back(point[1]);
    }
    uint32_t color = luaL_checkcolour(L, 3);

    if (points.size() < 6) {
        luaL_error(L, "Polygon requires at least 3 points");
        return 0;
    }

    queueFilledPolygon(lua_window, points, color);
    return 0;
}

// Window::SetShader(shader?: Shader) -> ()
int window_SetShader(lua_State* L) {
    LuaWindow* window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!window) return 0;

    if (lua_isnoneornil(L, 2)) {
        window->current_shader = nullptr;
    } else {
        LuaShader* shader = (LuaShader*)luaL_checkudata(L, 2, SHADER_METATABLE);
        if (shader) {
            window->current_shader = shader;
        } else {
            luaL_error(L, "Invalid shader object");
        }
    }
    return 0;
}

// Window::SetPostEffect(shader?: Shader) -> ()
int window_SetPostEffect(lua_State* L) {
    LuaWindow* window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!window) return 0;

    if (lua_isnoneornil(L, 2)) {
        window->post_effect = nullptr;
    } else {
        LuaShader* shader = (LuaShader*)luaL_checkudata(L, 2, SHADER_METATABLE);
        if (shader) {
            window->post_effect = shader;
        } else {
            luaL_error(L, "Invalid shader object");
        }
    }
    return 0;
}

// Window::GetRenderStats() -> {
//     vertices: number,
//     indices: number,
//     batches: number,
//     textures: number
// }
int window_GetRenderStats(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    if (!lua_window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    GPURenderContext& ctx = lua_window->gpu_context;

    lua_newtable(L);

    lua_pushstring(L, "vertices");
    lua_pushnumber(L, (double)ctx.vertex_queue.size());
    lua_settable(L, -3);

    lua_pushstring(L, "indices");
    lua_pushnumber(L, (double)ctx.index_queue.size());
    lua_settable(L, -3);

    lua_pushstring(L, "batches");
    lua_pushnumber(L, (double)ctx.draw_batches.size());
    lua_settable(L, -3);

    // Detailed batch info (array of strings) if requested
    if (lua_gettop(L) >= 2 && lua_toboolean(L, 2)) {
        lua_pushstring(L, "batch_details");
        lua_newtable(L);
        int i = 1;
        for (const auto& batch : ctx.draw_batches) {
            std::string desc = "Items:" + std::to_string(batch.item_count) +
                               " V:" + std::to_string(batch.vertex_count) +
                               " I:" + std::to_string(batch.index_count) +
                               (batch.shader ? " SHADER" : " NO-SHADER");
            lua_pushnumber(L, i++);
            lua_pushstring(L, desc.c_str());
            lua_settable(L, -3);
        }
        lua_settable(L, -3);
    }

    lua_pushstring(L, "textures");
    lua_pushnumber(L, (double)lua_window->texture_cache.size());
    lua_settable(L, -3);

    return 1;
}

// Window::DrawGlyphAtlas(font: Font, pos: Vec2, size?: Vec2) -> boolean
int window_DrawGlyphAtlas(lua_State* L) {
    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
    LuaFont* font = (LuaFont*)luaL_checkudata(L, 2, FONT_METATABLE);

    if (!lua_window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }
    if (!font) {
        luaL_error(L, "Invalid font object");
        return 0;
    }

    double pos[2];
    luaL_checkvec2(L, 3, pos);
    double size[2] = { 512, 512 };
    if (luaL_hasarg(L, 4)) {
        luaL_checkvec2(L, 4, size);
    }

    if (font->atlas.gpu_view) {
        queueTexturedQuad(lua_window, font->atlas.gpu_view, nullptr, pos[0], pos[1], size[0], size[1], 0.0f,
                          0.0f, 1.0f, 1.0f, 0xFFFFFFFF);

        lua_pushboolean(L, true);
    } else {
        lua_pushboolean(L, false);
    }

    return 1;
}

// int windowGetPressedKeys(lua_State* L) {
//     LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
//     if (!lua_window || !lua_window->window) {
//         luaL_error(L, "Invalid window object");
//         return 0;
//     }

//     lua_newtable(L);
//     for (int i = 0; i < (int)lua_window->pressed_keys.size(); i++) {
//         lua_pushstring(L, getKeyName(lua_window->pressed_keys[i]).c_str());
//         lua_rawseti(L, -2, i + 1);
//     }
//     return 1;
// }

// int windowGetHeldKeys(lua_State* L) {
//     LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 1, WINDOW_METATABLE);
//     if (!lua_window || !lua_window->window) {
//         luaL_error(L, "Invalid window object");
//         return 0;
//     }

//     lua_newtable(L);
//     int i = 1;
//     for (SDL_Keycode key : lua_window->held_keys) {
//         lua_pushstring(L, getKeyName(key).c_str());
//         lua_rawseti(L, -2, i++);
//     }
//     return 1;
// }

// Register the window library
void window_lib_register(lua_State* L) {
    // Create metatable for Window userdata
    luaL_newmetatable(L, WINDOW_METATABLE);

    // Set __index to point to the metatable itself for method calls with :
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, window_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, window_gc, "gc");
    lua_setfield(L, -2, "__gc");

    // Add methods to metatable
    lua_pushcfunction(L, window_PollEvents, "PollEvents");
    lua_setfield(L, -2, "PollEvents");

    // lua_pushcfunction(L, windowGetPressedKeys, "getPressedKeys");
    // lua_setfield(L, -2, "getPressedKeys");

    // lua_pushcfunction(L, windowGetHeldKeys, "getHeldKeys");
    // lua_setfield(L, -2, "getHeldKeys");

    lua_pushcfunction(L, window_StartFrame, "StartFrame");
    lua_setfield(L, -2, "StartFrame");

    lua_pushcfunction(L, window_EndFrame, "EndFrame");
    lua_setfield(L, -2, "EndFrame");

    // Window management
    lua_pushcfunction(L, window_size, "size");
    lua_setfield(L, -2, "size");

    lua_pushcfunction(L, window_ShouldClose, "ShouldClose");
    lua_setfield(L, -2, "ShouldClose");

    lua_pushcfunction(L, window_SetTitle, "SetTitle");
    lua_setfield(L, -2, "SetTitle");

    lua_pushcfunction(L, window_SetFullscreen, "SetFullscreen");
    lua_setfield(L, -2, "SetFullscreen");

    lua_pushcfunction(L, window_Close, "Close");
    lua_setfield(L, -2, "Close");

    // Drawing
    lua_pushcfunction(L, window_DrawText, "DrawText");
    lua_setfield(L, -2, "DrawText");

    lua_pushcfunction(L, window_DrawTexture, "DrawTexture");
    lua_setfield(L, -2, "DrawTexture");

    // Primatives
    lua_pushcfunction(L, window_DrawRectangle, "DrawRectangle");
    lua_setfield(L, -2, "DrawRectangle");

    lua_pushcfunction(L, window_DrawCircle, "DrawCircle");
    lua_setfield(L, -2, "DrawCircle");

    lua_pushcfunction(L, window_DrawPolygon, "DrawPolygon");
    lua_setfield(L, -2, "DrawPolygon");

    // Shaders
    lua_pushcfunction(L, window_SetShader, "SetShader");
    lua_setfield(L, -2, "SetShader");

    lua_pushcfunction(L, window_SetPostEffect, "SetPostEffect");
    lua_setfield(L, -2, "SetPostEffect");

    // Debugging
    lua_pushcfunction(L, window_GetRenderStats, "GetRenderStats");
    lua_setfield(L, -2, "GetRenderStats");

    lua_pushcfunction(L, window_DrawGlyphAtlas, "DrawGlyphAtlas");
    lua_setfield(L, -2, "DrawGlyphAtlas");

    lua_pop(L, 1);

    // Create window library table
    lua_newtable(L);

    lua_pushcfunction(L, window_create, "create");
    lua_setfield(L, -2, "create");

    lua_setglobal(L, "window");
}
