#pragma once
#include "Texture.hpp"
#include "Window.hpp"


// Render queued text using glyph atlas
void renderQueuedText(LuaWindow* lua_window, GlyphAtlas& atlas, FT_Face face, const char* text,
                      float x, float y, uint32_t color, float* width, float* height);
// Queue a textured quad for rendering
void queueTexturedQuad(LuaWindow* lua_window, WGPUTextureView texture_view, LuaTexture* texture,
                       float x, float y, float w, float h, float uv_x, float uv_y, float uv_w,
                       float uv_h, uint32_t color);

// Queue a filled rectangle for GPU rendering
void queueFilledRectangle(LuaWindow* lua_window, float x, float y, float w, float h,
                          uint32_t color);

// Queue a rectangle border for |PU rendering
void queueRectangleBorder(LuaWindow* lua_window, float x, float y, float w, float h, uint32_t color,
                          float thickness);
// Queue a filled circle for GPU rendering (approximate with many triangles)
void queueFilledCircle(LuaWindow* lua_window, float cx, float cy, float r, uint32_t color,
                       int segments = 32);

// Queue a circle border for GPU rendering
void queueCircleBorder(LuaWindow* lua_window, float cx, float cy, float r, uint32_t color,
                       int thickness, int segments = 32);
// Queue a filled polygon for GPU rendering
void queueFilledPolygon(LuaWindow* lua_window, const std::vector<float>& points, uint32_t color);
