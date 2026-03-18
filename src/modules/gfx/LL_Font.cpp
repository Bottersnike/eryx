#include "LL_Font.hpp"
#include "Window.hpp"

// Get a glyph bitmap from a font
GlyphBitmap getGlyphBitmap(FT_Face face, char c) {
    GlyphBitmap result;

    FT_UInt glyph_index = FT_Get_Char_Index(face, (unsigned char)c);
    // Use FT_LOAD_NO_BITMAP to force rendering from outline (avoids embedded bitmaps)
    if (FT_Load_Glyph(face, glyph_index, FT_LOAD_RENDER | FT_LOAD_NO_BITMAP)) {
        return result;  // Failed to load glyph
    }

    FT_Bitmap& bitmap = face->glyph->bitmap;
    result.width = bitmap.width;
    result.height = bitmap.rows;
    result.pitch = bitmap.pitch;
    result.bearingX = face->glyph->bitmap_left;
    result.bearingY = face->glyph->bitmap_top;     // Top bearing for baseline calculation
    result.advance = face->glyph->advance.x >> 6;  // Convert from 26.6 fixed point

    if (bitmap.buffer && bitmap.width > 0 && bitmap.rows > 0) {
        result.pixels.resize(bitmap.width * bitmap.rows);
        std::memcpy(result.pixels.data(), bitmap.buffer, bitmap.width * bitmap.rows);
    }

    return result;
}

// Build glyph atlas from a FreeType font
bool buildGlyphAtlas(GlyphAtlas& atlas, FT_Face face, int atlas_width,
                     int atlas_height) {
    if (!face) return false;

    // Clear old atlas
    if (atlas.gpu_texture) {
        wgpuTextureRelease(atlas.gpu_texture);
        atlas.gpu_texture = nullptr;
    }
    if (atlas.gpu_view) {
        wgpuTextureViewRelease(atlas.gpu_view);
        atlas.gpu_view = nullptr;
    }
    atlas.glyphs.clear();

    atlas.texture_width = atlas_width;
    atlas.texture_height = atlas_height;
    // Resize and clear to transparent black
    atlas.cpu_pixels.assign(atlas_width * atlas_height, 0x00000000);

    // Render common glyphs to atlas
    int current_x = 2, current_y = 2;
    int max_y_in_row = 0;

    // Build atlas for printable ASCII characters
    for (int c = 32; c < 127; c++) {
        FT_UInt glyph_index = FT_Get_Char_Index(face, c);
        // Force outline rendering to ensure we get an 8-bit bitmap, avoiding embedded bitmaps
        if (FT_Load_Glyph(face, glyph_index, FT_LOAD_RENDER | FT_LOAD_NO_BITMAP)) continue;

        FT_Bitmap& bitmap = face->glyph->bitmap;
        int glyph_width = bitmap.width + 2;  // Add padding
        int glyph_height = bitmap.rows + 2;

        // Check if we need to start a new row
        if (current_x + glyph_width > atlas_width) {
            current_x = 2;
            current_y += max_y_in_row + 2;
            max_y_in_row = 0;

            if (current_y + glyph_height > atlas_height) {
                std::cerr << "Glyph atlas too small for font" << std::endl;
                break;
            }
        }

        // Copy glyph bitmap to atlas with padding
        for (int row = 0; row < bitmap.rows; row++) {
            for (int col = 0; col < bitmap.width; col++) {
                uint8_t alpha = bitmap.buffer[row * bitmap.pitch + col];
                // Store as grayscale (same in RGB) with alpha in A channel
                uint32_t pixel = (alpha << 24) | 0xFFFFFF;  // White glyph
                atlas.cpu_pixels[(current_y + 1 + row) * atlas_width + (current_x + 1 + col)] =
                    pixel;
            }
        }

        // Store glyph entry
        GlyphAtlasEntry entry;
        entry.uv_x = (float)(current_x + 1) / atlas_width;
        entry.uv_y = (float)(current_y + 1) / atlas_height;
        entry.uv_w = (float)bitmap.width / atlas_width;
        entry.uv_h = (float)bitmap.rows / atlas_height;
        entry.advance = face->glyph->advance.x >> 6;
        entry.bearing_x = face->glyph->bitmap_left;
        entry.bearing_y = face->glyph->bitmap_top;
        atlas.glyphs[c] = entry;

        max_y_in_row = std::max(max_y_in_row, glyph_height);
        current_x += glyph_width;
    }

    // For now, keep CPU atlas pixels for future GPU upload when WGPU API is fully available
    return true;
}
