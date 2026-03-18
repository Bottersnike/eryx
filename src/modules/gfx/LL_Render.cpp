#include "LL_Render.hpp"

#include "GPU.hpp"
#include "LL_Font.hpp"

// Helper to ensure correct texture batch
static void ensureBatch(GPURenderContext& ctx, WGPUTextureView texture_view,
                        LuaShader* shader = nullptr) {
    if (ctx.draw_batches.empty() ||
        ctx.draw_batches.back().texture_view !=
            (texture_view ? texture_view : ctx.default_texture_view) ||
        ctx.draw_batches.back().shader != shader) {
        if (!ctx.draw_batches.empty()) {
            ctx.draw_batches.back().vertex_count =
                ctx.vertex_queue.size() - ctx.draw_batches.back().vertex_start;
        }

        GPURenderContext::DrawBatch batch;
        batch.index_start = ctx.index_queue.size();
        batch.index_count = 0;
        batch.vertex_start = ctx.vertex_queue.size();
        batch.vertex_count = 0;
        batch.texture_view = texture_view ? texture_view : ctx.default_texture_view;
        batch.shader = shader;
        ctx.draw_batches.push_back(batch);
    }
}

// Queue a textured quad for rendering
void queueTexturedQuad(LuaWindow* lua_window, WGPUTextureView texture_view,  LuaTexture* texture, float x, float y,
                       float w, float h, float uv_x, float uv_y, float uv_w, float uv_h,
                       uint32_t color) {
    // Check if texture is in cache
    if (texture_view == nullptr) {
        GPURenderContext& ctx = lua_window->gpu_context;

        auto it = lua_window->texture_cache.find(&texture->image);
        if (it != lua_window->texture_cache.end()) {
            texture_view = it->second.view;
        } else {
            // Create GPU texture
            WGPUTexture gpu_tex = createGPUTexture(ctx.device, ctx.queue, texture->image);
            if (gpu_tex) {
                WGPUTextureView gpu_view = createTextureView(gpu_tex);
                if (gpu_view) {
                    GPUTexture gpu_res = { gpu_tex, gpu_view, nullptr };
                    lua_window->texture_cache[&texture->image] = gpu_res;
                    texture_view = gpu_view;
                } else {
                    wgpuTextureRelease(gpu_tex);
                }
            }
        }

        if (!texture_view) {
            texture_view = ctx.default_texture_view;
        }
    } else {
        texture_view = texture_view;
    }

    if (!lua_window) return;

    GPURenderContext& ctx = lua_window->gpu_context;

    // Ensure we have a batch for this texture and shader
    ensureBatch(ctx, texture_view, lua_window->current_shader);
    ctx.draw_batches.back().index_count += 6;  // 6 indices per quad
    ctx.draw_batches.back().item_count++;

    uint32_t base_idx = ctx.vertex_queue.size();

    // Add vertices for quad (CCW winding)
    ctx.vertex_queue.push_back({ x, y, uv_x, uv_y, color });
    ctx.vertex_queue.push_back({ x + w, y, uv_x + uv_w, uv_y, color });
    ctx.vertex_queue.push_back({ x + w, y + h, uv_x + uv_w, uv_y + uv_h, color });
    ctx.vertex_queue.push_back({ x, y + h, uv_x, uv_y + uv_h, color });

    // Add indices for two triangles
    ctx.index_queue.push_back(base_idx + 0);
    ctx.index_queue.push_back(base_idx + 1);
    ctx.index_queue.push_back(base_idx + 2);

    ctx.index_queue.push_back(base_idx + 0);
    ctx.index_queue.push_back(base_idx + 2);
    ctx.index_queue.push_back(base_idx + 3);
}

// Render queued text using glyph atlas
void renderQueuedText(LuaWindow* lua_window, GlyphAtlas& atlas, FT_Face face, const char* text,
                      float x, float y, uint32_t color, float* width, float* height) {
    if (!lua_window || !face) return;

    // Check if view exists. If not, try to upload.
    if (!atlas.gpu_view) {
        if (!atlas.cpu_pixels.empty()) {
            uploadGlyphAtlas(lua_window, atlas);
        }
        if (!atlas.gpu_view) return;
    }

    float current_x = x;
    float baseline_y = y;

    float total_width = 0;
    float max_height = 0;

    for (int i = 0; text[i] != '\0'; i++) {
        int c = (unsigned char)text[i];

        if (c == '\n') {
            current_x = x;
            baseline_y += face->size->metrics.height / 64.0f + 2;
            continue;
        }

        // Find glyph in atlas
        auto it = atlas.glyphs.find(c);
        if (it == atlas.glyphs.end()) continue;

        const GlyphAtlasEntry& glyph = it->second;

        // Position glyph using bearing
        float glyph_x = current_x + glyph.bearing_x;
        float glyph_y = baseline_y - glyph.bearing_y;
        float glyph_w = glyph.uv_w * atlas.texture_width;
        float glyph_h = glyph.uv_h * atlas.texture_height;

        total_width += glyph_w;
        max_height = std::max(glyph_h, max_height);

        // Queue textured quad using atlas texture
        queueTexturedQuad(lua_window, atlas.gpu_view, nullptr, glyph_x, glyph_y, glyph_w, glyph_h,
                          glyph.uv_x, glyph.uv_y, glyph.uv_w, glyph.uv_h, color);

        current_x += glyph.advance + 1;
    }

    if (width) *width = total_width;
    if (height) *height = max_height;
}

// Queue a filled rectangle for GPU rendering
void queueFilledRectangle(LuaWindow* lua_window, float x, float y, float w, float h,
                          uint32_t color) {
    if (!lua_window) return;

    GPURenderContext& ctx = lua_window->gpu_context;

    ensureBatch(ctx, ctx.default_texture_view, lua_window->current_shader);
    ctx.draw_batches.back().index_count += 6;
    ctx.draw_batches.back().item_count++;

    uint32_t base_idx = ctx.vertex_queue.size();

    // Add vertices for quad
    ctx.vertex_queue.push_back({ x, y, 0.0f, 0.0f, color });
    ctx.vertex_queue.push_back({ x + w, y, 0.0f, 0.0f, color });
    ctx.vertex_queue.push_back({ x + w, y + h, 0.0f, 0.0f, color });
    ctx.vertex_queue.push_back({ x, y + h, 0.0f, 0.0f, color });

    // Add indices for two triangles
    ctx.index_queue.push_back(base_idx + 0);
    ctx.index_queue.push_back(base_idx + 1);
    ctx.index_queue.push_back(base_idx + 2);

    ctx.index_queue.push_back(base_idx + 0);
    ctx.index_queue.push_back(base_idx + 2);
    ctx.index_queue.push_back(base_idx + 3);
}

// Queue a rectangle border for |PU rendering
void queueRectangleBorder(LuaWindow* lua_window, float x, float y, float w, float h, uint32_t color,
                          float thickness) {
    if (!lua_window) return;

    float t = (float)thickness;

    // Top
    queueFilledRectangle(lua_window, x, y, w, t, color);
    // Bottom
    queueFilledRectangle(lua_window, x, y + h - t, w, t, color);
    // Left
    queueFilledRectangle(lua_window, x, y, t, h, color);
    // Right
    queueFilledRectangle(lua_window, x + w - t, y, t, h, color);
}

static std::vector<std::pair<float, float>> unit_circle_cache;

// Queue a filled circle for GPU rendering (approximate with many triangles)
void queueFilledCircle(LuaWindow* lua_window, float cx, float cy, float r, uint32_t color,
                       int segments) {
    if (!lua_window) return;

    // Adaptive segments if default (32) is requested but radius is small
    if (segments == 32) {
        if (r < 5.0f)
            segments = 12;
        else if (r < 10.0f)
            segments = 16;
        else if (r < 20.0f)
            segments = 24;
    }

    // Initialize cache if needed (standard 32 segments)
    // Note: If dynamic segments are used, we might need multiple caches or just compute on fly for
    // weird counts. For now, let's optimize the loop directly without complex caching if we change
    // segments often. Actually, std::sin/cos are fast enough if we don't allocate. The bottleneck
    // is mostly resize/push_back allocations.

    GPURenderContext& ctx = lua_window->gpu_context;

    ensureBatch(ctx, ctx.default_texture_view, lua_window->current_shader);
    ctx.draw_batches.back().index_count += segments * 3;
    ctx.draw_batches.back().item_count++;

    uint32_t base_idx = ctx.vertex_queue.size();

    // Reserve space to avoid multiple reallocations
    size_t v_count = 1 + segments;
    size_t i_count = segments * 3;

    // Direct access to vector storage
    // We assume reserve is enough or resize is smart?
    // Manual resize + data() access is fastest.

    size_t current_v_size = ctx.vertex_queue.size();
    ctx.vertex_queue.resize(current_v_size + v_count);
    GPUVertex* v_ptr = &ctx.vertex_queue[current_v_size];

    size_t current_i_size = ctx.index_queue.size();
    ctx.index_queue.resize(current_i_size + i_count);
    uint32_t* i_ptr = &ctx.index_queue[current_i_size];

    // Center vertex
    v_ptr[0] = { cx, cy, 0.0f, 0.0f, color };

    // Circle vertices
    float angle_step = 6.283185307f / segments;
    for (int i = 0; i < segments; i++) {
        float angle = angle_step * i;
        // Fast approx sin/cos could be used here, but let's stick to std for accuracy
        float c = std::cos(angle);
        float s = std::sin(angle);
        v_ptr[1 + i] = { cx + r * c, cy + r * s, 0.0f, 0.0f, color };
    }

    // Indices
    for (int i = 0; i < segments; i++) {
        int next = (i + 1) % segments;
        i_ptr[i * 3 + 0] = base_idx;
        i_ptr[i * 3 + 1] = base_idx + 1 + i;
        i_ptr[i * 3 + 2] = base_idx + 1 + next;
    }
}

// Queue a circle border for GPU rendering
void queueCircleBorder(LuaWindow* lua_window, float cx, float cy, float r, uint32_t color,
                       int thickness, int segments) {
    if (!lua_window) return;

    GPURenderContext& ctx = lua_window->gpu_context;

    ensureBatch(ctx, ctx.default_texture_view, lua_window->current_shader);
    ctx.draw_batches.back().index_count += segments * 6;
    ctx.draw_batches.back().item_count++;

    uint32_t base_idx = ctx.vertex_queue.size();

    float inner_r = r - thickness / 2.0f;
    float outer_r = r + thickness / 2.0f;

    // Add outer circle vertices
    for (int i = 0; i < segments; i++) {
        float angle = 2.0f * 3.14159265f * i / segments;
        float x = cx + outer_r * std::cos(angle);
        float y = cy + outer_r * std::sin(angle);
        ctx.vertex_queue.push_back({ x, y, 0.0f, 0.0f, color });
    }

    // Add inner circle vertices
    for (int i = 0; i < segments; i++) {
        float angle = 2.0f * 3.14159265f * i / segments;
        float x = cx + inner_r * std::cos(angle);
        float y = cy + inner_r * std::sin(angle);
        ctx.vertex_queue.push_back({ x, y, 0.0f, 0.0f, color });
    }

    // Add indices for quads
    for (int i = 0; i < segments; i++) {
        int next = (i + 1) % segments;
        uint32_t outer_cur = base_idx + i;
        uint32_t outer_next = base_idx + next;
        uint32_t inner_cur = base_idx + segments + i;
        uint32_t inner_next = base_idx + segments + next;

        // First triangle
        ctx.index_queue.push_back(outer_cur);
        ctx.index_queue.push_back(outer_next);
        ctx.index_queue.push_back(inner_cur);

        // Second triangle
        ctx.index_queue.push_back(outer_next);
        ctx.index_queue.push_back(inner_next);
        ctx.index_queue.push_back(inner_cur);
    }
}

// Queue a filled polygon for GPU rendering
void queueFilledPolygon(LuaWindow* lua_window, const std::vector<float>& points, uint32_t color) {
    if (!lua_window || points.size() < 6) return;  // Need at least 3 points (2 floats each)

    GPURenderContext& ctx = lua_window->gpu_context;

    ensureBatch(ctx, ctx.default_texture_view, lua_window->current_shader);

    size_t num_points = points.size() / 2;
    ctx.draw_batches.back().index_count += (num_points - 2) * 3;
    ctx.draw_batches.back().item_count++;

    uint32_t base_idx = ctx.vertex_queue.size();

    // Add polygon vertices
    for (size_t i = 0; i < points.size(); i += 2) {
        ctx.vertex_queue.push_back({ points[i], points[i + 1], 0.0f, 0.0f, color });
    }

    // Add indices for triangles (fan triangulation)
    for (size_t i = 1; i < num_points - 1; i++) {
        ctx.index_queue.push_back(base_idx + 0);
        ctx.index_queue.push_back(base_idx + i);
        ctx.index_queue.push_back(base_idx + i + 1);
    }
}
