#pragma once
#include "pch.hpp"

// Simple bitmap structure for storing glyph images
struct GlyphBitmap {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int pitch = 0;
    int bearingX = 0;  // Horizontal bearing
    int bearingY = 0;  // Vertical bearing (offset from baseline)
    int advance = 0;   // Advance width to next character
};

// Glyph atlas entry - describes location of a glyph in the atlas texture
struct GlyphAtlasEntry {
    float uv_x, uv_y;  // Top-left UV coordinates
    float uv_w, uv_h;  // Width and height in UV space
    float advance;     // Advance width for next glyph
    float bearing_x;   // X bearing
    float bearing_y;   // Y bearing
};

// Glyph atlas - texture containing all rendered glyphs
struct GlyphAtlas {
    WGPUTexture gpu_texture = nullptr;
    WGPUTextureView gpu_view = nullptr;
    std::vector<uint32_t> cpu_pixels;
    int texture_width = 0;
    int texture_height = 0;
    std::map<int, struct GlyphAtlasEntry> glyphs;  // Keyed by glyph code
};

GlyphBitmap getGlyphBitmap(FT_Face face, char c);

struct LuaWindow;
bool buildGlyphAtlas(GlyphAtlas& atlas, FT_Face face, int atlas_width = 1024,
                     int atlas_height = 1024);
