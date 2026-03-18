#include "GPU.hpp"

#include "Window.hpp"

// Global device request state for initialization
static WGPUDevice g_created_device = nullptr;
static bool g_device_created = false;

static WGPUInstance wgpu_instance = nullptr;

static void uncapturedErrorCallback(WGPUDevice const* device, WGPUErrorType type,
                                    WGPUStringView message, void* userdata1, void* userdata2) {
    const char* errorTypeStr = "Unknown";
    switch (type) {
        case WGPUErrorType_Validation:
            errorTypeStr = "Validation";
            break;
        case WGPUErrorType_OutOfMemory:
            errorTypeStr = "OutOfMemory";
            break;
        case WGPUErrorType_Internal:
            errorTypeStr = "Internal";
            break;
        case WGPUErrorType_Unknown:
            errorTypeStr = "Unknown";
            break;
        default:
            break;
    }
    std::cerr << "WGPU Uncaptured Error (" << errorTypeStr
              << "): " << (message.data ? message.data : "Unknown") << std::endl;
}

static void deviceCreationCallback(WGPURequestDeviceStatus status, WGPUDevice device,
                                   WGPUStringView message, void* userdata1, void* userdata2) {
    if (status == WGPURequestDeviceStatus_Success) {
        g_created_device = device;
        g_device_created = true;
    } else {
        std::cerr << "Device creation failed" << std::endl;
        g_device_created = true;
    }
}

// Create WGPU surface for a window
bool createWindowSurface(LuaWindow* lua_window) {
    if (!lua_window || !lua_window->window || !wgpu_instance) {
        std::cerr << "Invalid window or WGPU instance" << std::endl;
        return false;
    }

    SDL_PropertiesID props = SDL_GetWindowProperties(lua_window->window);
    WGPUSurfaceDescriptor surface_desc = {};

#if defined(_WIN32)
    WGPUSurfaceSourceWindowsHWND hwnd_src = {};
    hwnd_src.chain.next = nullptr;
    hwnd_src.chain.sType = WGPUSType_SurfaceSourceWindowsHWND;
    hwnd_src.hinstance = GetModuleHandle(nullptr);
    hwnd_src.hwnd = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, nullptr);
    surface_desc.nextInChain = (const WGPUChainedStruct*)&hwnd_src;

#elif defined(__APPLE__)
    // SDL3 creates a CAMetalLayer-backed view; SDL_Metal_GetLayer returns it as void*
    SDL_MetalView metal_view = SDL_Metal_CreateView(lua_window->window);
    if (!metal_view) {
        std::cerr << "Failed to create SDL Metal view" << std::endl;
        return false;
    }
    WGPUSurfaceSourceMetalLayer metal_src = {};
    metal_src.chain.next = nullptr;
    metal_src.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
    metal_src.layer = SDL_Metal_GetLayer(metal_view);
    surface_desc.nextInChain = (const WGPUChainedStruct*)&metal_src;

#else
    // Linux: prefer Wayland, fall back to X11
    void* wayland_display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nullptr);
    void* wayland_surface = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, nullptr);

    WGPUSurfaceSourceWaylandSurface wayland_src = {};
    WGPUSurfaceSourceXlibWindow xlib_src = {};

    if (wayland_display && wayland_surface) {
        wayland_src.chain.next = nullptr;
        wayland_src.chain.sType = WGPUSType_SurfaceSourceWaylandSurface;
        wayland_src.display = wayland_display;
        wayland_src.surface = wayland_surface;
        surface_desc.nextInChain = (const WGPUChainedStruct*)&wayland_src;
    } else {
        void* x11_display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, nullptr);
        uint64_t x11_window = (uint64_t)SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (!x11_display || !x11_window) {
            std::cerr << "No suitable Linux window system found (tried Wayland and X11)" << std::endl;
            return false;
        }
        xlib_src.chain.next = nullptr;
        xlib_src.chain.sType = WGPUSType_SurfaceSourceXlibWindow;
        xlib_src.display = x11_display;
        xlib_src.window = x11_window;
        surface_desc.nextInChain = (const WGPUChainedStruct*)&xlib_src;
    }
#endif

    lua_window->surface = wgpuInstanceCreateSurface(wgpu_instance, &surface_desc);
    if (!lua_window->surface) {
        std::cerr << "Failed to create WGPU surface" << std::endl;
        return false;
    }

    return true;
}

// Initialize GPU rendering for a window
bool initGPURenderContext(LuaWindow* lua_window) {
    if (!lua_window || !lua_window->window || !wgpu_instance) return false;

    GPURenderContext& ctx = lua_window->gpu_context;

    // Create surface first if not already done
    if (!lua_window->surface) {
        if (!createWindowSurface(lua_window)) {
            std::cerr << "Failed to create window surface" << std::endl;
            return false;
        }
    }

    // Enumerate adapters
    WGPUInstanceEnumerateAdapterOptions adapter_opts = {};
    size_t adapter_count = wgpuInstanceEnumerateAdapters(wgpu_instance, &adapter_opts, nullptr);

    if (adapter_count == 0) {
        std::cerr << "No WGPU adapters found" << std::endl;
        return false;
    }

    std::vector<WGPUAdapter> adapters(adapter_count);
    wgpuInstanceEnumerateAdapters(wgpu_instance, &adapter_opts, adapters.data());

    if (adapters.empty()) {
        std::cerr << "Failed to get WGPU adapters" << std::endl;
        return false;
    }

    WGPUAdapter adapter = adapters[0];

    // Release other adapters we aren't using
    for (size_t i = 1; i < adapters.size(); i++) {
        wgpuAdapterRelease(adapters[i]);
    }

    // Request device with callback
    WGPUDeviceDescriptor device_desc = {};

    WGPUUncapturedErrorCallbackInfo error_callback_info = {};
    error_callback_info.callback = uncapturedErrorCallback;
    error_callback_info.userdata1 = nullptr;
    error_callback_info.userdata2 = nullptr;
    device_desc.uncapturedErrorCallbackInfo = error_callback_info;

    WGPURequestDeviceCallbackInfo callback_info = {};
    callback_info.callback = deviceCreationCallback;
    callback_info.userdata1 = nullptr;
    callback_info.userdata2 = nullptr;

    g_created_device = nullptr;
    g_device_created = false;
    wgpuAdapterRequestDevice(adapter, &device_desc, callback_info);

    // Wait for device creation with timeout
    int attempts = 0;
    while (!g_device_created && attempts < 500) {
        SDL_Delay(10);
        attempts++;
    }

    if (!g_created_device) {
        std::cerr << "Failed to create WGPU device" << std::endl;
        wgpuAdapterRelease(adapter);
        return false;
    }

    ctx.device = g_created_device;
    ctx.queue = wgpuDeviceGetQueue(ctx.device);

    // Release adapter now that we have the device
    wgpuAdapterRelease(adapter);

    // Poll device to process any pending callbacks
    wgpuDevicePoll(ctx.device, false, nullptr);

    // Configure surface for presentation
    int window_width = 0, window_height = 0;
    SDL_GetWindowSize(lua_window->window, &window_width, &window_height);

    WGPUSurfaceConfiguration surface_config = {};
    surface_config.device = ctx.device;
    surface_config.format = ctx.surface_format;
    surface_config.width = window_width;
    surface_config.height = window_height;
    surface_config.presentMode = WGPUPresentMode_Fifo;
    surface_config.usage = WGPUTextureUsage_RenderAttachment;
    surface_config.alphaMode = WGPUCompositeAlphaMode_Auto;

    wgpuSurfaceConfigure(lua_window->surface, &surface_config);

    // Create buffers for vertex and index data
    WGPUBufferDescriptor vertex_buffer_desc = {};
    vertex_buffer_desc.size = std::max(size_t(256), sizeof(GPUVertex) * ctx.max_vertices);
    vertex_buffer_desc.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
    vertex_buffer_desc.mappedAtCreation = false;
    ctx.vertex_buffer = wgpuDeviceCreateBuffer(ctx.device, &vertex_buffer_desc);

    WGPUBufferDescriptor index_buffer_desc = {};
    index_buffer_desc.size = std::max(size_t(256), sizeof(uint32_t) * ctx.max_indices);
    index_buffer_desc.usage = WGPUBufferUsage_Index | WGPUBufferUsage_CopyDst;
    index_buffer_desc.mappedAtCreation = false;
    ctx.index_buffer = wgpuDeviceCreateBuffer(ctx.device, &index_buffer_desc);

    // Create system uniform buffer
    WGPUBufferDescriptor uniform_buffer_desc = {};
    uniform_buffer_desc.size = 16;  // vec2<f32> aligned to 16 bytes
    uniform_buffer_desc.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
    uniform_buffer_desc.mappedAtCreation = false;
    ctx.screen_uniform_buffer = wgpuDeviceCreateBuffer(ctx.device, &uniform_buffer_desc);

    // Create shader module with WGSL code
    const char* shader_code =
#include "shader.wgsl"
        ;

    WGPUShaderSourceWGSL wgsl_src = {};
    wgsl_src.chain.sType = WGPUSType_ShaderSourceWGSL;
    wgsl_src.code = WGPUStringView{ shader_code, WGPU_STRLEN };

    WGPUShaderModuleDescriptor shader_desc = {};
    shader_desc.nextInChain = (const WGPUChainedStruct*)&wgsl_src;
    ctx.shader_module = wgpuDeviceCreateShaderModule(ctx.device, &shader_desc);

    if (!ctx.shader_module) {
        std::cerr << "Failed to create shader module" << std::endl;
        return false;
    }

    // Create render pipeline
    // Vertex buffer layout
    WGPUVertexAttribute vertex_attrs[3] = {};
    vertex_attrs[0].format = WGPUVertexFormat_Float32x2;
    vertex_attrs[0].offset = offsetof(GPUVertex, x);
    vertex_attrs[0].shaderLocation = 0;

    vertex_attrs[1].format = WGPUVertexFormat_Float32x2;
    vertex_attrs[1].offset = offsetof(GPUVertex, u);
    vertex_attrs[1].shaderLocation = 1;

    vertex_attrs[2].format = WGPUVertexFormat_Uint32;
    vertex_attrs[2].offset = offsetof(GPUVertex, color);
    vertex_attrs[2].shaderLocation = 2;

    WGPUVertexBufferLayout vertex_layout = {};
    vertex_layout.arrayStride = sizeof(GPUVertex);
    vertex_layout.stepMode = WGPUVertexStepMode_Vertex;
    vertex_layout.attributeCount = 3;
    vertex_layout.attributes = vertex_attrs;

    WGPUVertexState vertex_state = {};
    vertex_state.module = ctx.shader_module;
    vertex_state.entryPoint = WGPUStringView{ "vertex_main", WGPU_STRLEN };
    vertex_state.bufferCount = 1;
    vertex_state.buffers = &vertex_layout;

    // Fragment state
    WGPUColorTargetState color_target = {};
    color_target.format = ctx.surface_format;
    color_target.writeMask = WGPUColorWriteMask_All;

    // Enable Alpha Blending for text rendering
    WGPUBlendState blend = {};
    blend.color.srcFactor = WGPUBlendFactor_SrcAlpha;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;

    color_target.blend = &blend;

    WGPUFragmentState fragment_state = {};
    fragment_state.module = ctx.shader_module;
    fragment_state.entryPoint = WGPUStringView{ "fragment_main", WGPU_STRLEN };
    fragment_state.targetCount = 1;
    fragment_state.targets = &color_target;

    // Primitive state
    WGPUPrimitiveState primitive_state = {};
    primitive_state.topology = WGPUPrimitiveTopology_TriangleList;
    primitive_state.stripIndexFormat = WGPUIndexFormat_Undefined;
    primitive_state.frontFace = WGPUFrontFace_CCW;
    primitive_state.cullMode = WGPUCullMode_None;

    // Create bind group layout for texture and sampler
    WGPUBindGroupLayoutEntry layout_entries[3] = {};

    // Sampler binding
    layout_entries[0].binding = 0;
    layout_entries[0].visibility = WGPUShaderStage_Fragment;
    layout_entries[0].sampler.type = WGPUSamplerBindingType_Filtering;

    // Texture binding
    layout_entries[1].binding = 1;
    layout_entries[1].visibility = WGPUShaderStage_Fragment;
    layout_entries[1].texture.sampleType = WGPUTextureSampleType_Float;
    layout_entries[1].texture.viewDimension = WGPUTextureViewDimension_2D;
    layout_entries[1].texture.multisampled = false;

    // System Uniforms binding
    layout_entries[2].binding = 2;
    layout_entries[2].visibility = WGPUShaderStage_Vertex;
    layout_entries[2].buffer.type = WGPUBufferBindingType_Uniform;
    layout_entries[2].buffer.minBindingSize = 16;  // vec2<f32> + padding

    WGPUBindGroupLayoutDescriptor bgl_desc = {};
    bgl_desc.entryCount = 3;
    bgl_desc.entries = layout_entries;
    WGPUBindGroupLayout bind_group_layout = wgpuDeviceCreateBindGroupLayout(ctx.device, &bgl_desc);
    ctx.bind_group_layout = bind_group_layout;  // Store layout for later use

    // Pipeline layout with bind group
    WGPUPipelineLayoutDescriptor layout_desc = {};
    layout_desc.bindGroupLayoutCount = 1;
    layout_desc.bindGroupLayouts = &bind_group_layout;
    WGPUPipelineLayout layout = wgpuDeviceCreatePipelineLayout(ctx.device, &layout_desc);

    // Render pipeline
    WGPURenderPipelineDescriptor pipeline_desc = {};
    pipeline_desc.layout = layout;
    pipeline_desc.vertex = vertex_state;
    pipeline_desc.primitive = primitive_state;
    pipeline_desc.fragment = &fragment_state;
    pipeline_desc.multisample.count = 4;
    pipeline_desc.multisample.mask = 0xFFFFFFFF;
    pipeline_desc.multisample.alphaToCoverageEnabled = false;

    ctx.pipeline = wgpuDeviceCreateRenderPipeline(ctx.device, &pipeline_desc);
    wgpuPipelineLayoutRelease(layout);

    if (!ctx.pipeline) {
        std::cerr << "Failed to create render pipeline" << std::endl;
        return false;
    }

    // Create sampler
    WGPUSamplerDescriptor sampler_desc = {};
    sampler_desc.addressModeU = WGPUAddressMode_ClampToEdge;
    sampler_desc.addressModeV = WGPUAddressMode_ClampToEdge;
    sampler_desc.addressModeW = WGPUAddressMode_ClampToEdge;
    sampler_desc.magFilter = WGPUFilterMode_Linear;
    sampler_desc.minFilter = WGPUFilterMode_Linear;
    sampler_desc.mipmapFilter = WGPUMipmapFilterMode_Nearest;
    sampler_desc.lodMinClamp = 0.0f;
    sampler_desc.lodMaxClamp = 1.0f;
    sampler_desc.compare = WGPUCompareFunction_Undefined;
    sampler_desc.maxAnisotropy = 1;

    ctx.sampler = wgpuDeviceCreateSampler(ctx.device, &sampler_desc);

    // Create white default texture (1x1 white pixel) for solid color rendering
    WGPUTextureDescriptor white_texture_desc = {};
    white_texture_desc.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst;
    white_texture_desc.dimension = WGPUTextureDimension_2D;
    white_texture_desc.size.width = 1;
    white_texture_desc.size.height = 1;
    white_texture_desc.size.depthOrArrayLayers = 1;
    white_texture_desc.format = WGPUTextureFormat_RGBA8Unorm;
    white_texture_desc.mipLevelCount = 1;
    white_texture_desc.sampleCount = 1;

    ctx.default_texture = wgpuDeviceCreateTexture(ctx.device, &white_texture_desc);

    // Upload white pixel data
    uint32_t white_pixel = 0xFFFFFFFF;  // RGBA: white with full alpha

    WGPUTexelCopyTextureInfo copy_dest = {};
    copy_dest.texture = ctx.default_texture;
    copy_dest.mipLevel = 0;
    copy_dest.origin = { 0, 0, 0 };
    copy_dest.aspect = WGPUTextureAspect_All;

    WGPUTexelCopyBufferLayout data_layout = {};
    data_layout.offset = 0;
    data_layout.bytesPerRow = 4;
    data_layout.rowsPerImage = 1;

    WGPUExtent3D write_size = { 1, 1, 1 };
    wgpuQueueWriteTexture(ctx.queue, &copy_dest, &white_pixel, 4, &data_layout, &write_size);

    // Create texture view for default texture
    WGPUTextureViewDescriptor view_desc = {};
    view_desc.format = WGPUTextureFormat_RGBA8Unorm;
    view_desc.dimension = WGPUTextureViewDimension_2D;
    view_desc.baseMipLevel = 0;
    view_desc.mipLevelCount = 1;
    view_desc.baseArrayLayer = 0;
    view_desc.arrayLayerCount = 1;
    view_desc.aspect = WGPUTextureAspect_All;

    ctx.default_texture_view = wgpuTextureCreateView(ctx.default_texture, &view_desc);

    // Create initial bind group with sampler and default texture
    WGPUBindGroupEntry entries[3] = {};

    entries[0].binding = 0;
    entries[0].sampler = ctx.sampler;

    entries[1].binding = 1;
    entries[1].textureView = ctx.default_texture_view;

    entries[2].binding = 2;
    entries[2].buffer = ctx.screen_uniform_buffer;
    entries[2].size = 16;

    WGPUBindGroupDescriptor bind_group_desc = {};
    bind_group_desc.layout = bind_group_layout;
    bind_group_desc.entryCount = 3;
    bind_group_desc.entries = entries;

    ctx.current_bind_group = wgpuDeviceCreateBindGroup(ctx.device, &bind_group_desc);
    ctx.current_texture_view = ctx.default_texture_view;

    return true;
}

// Helper: Create GPU texture from image pixel data
WGPUTexture createGPUTexture(WGPUDevice device, WGPUQueue queue, const Image& image) {
    if (image.pixels.empty() || image.width <= 0 || image.height <= 0) {
        return nullptr;
    }

    // Create texture descriptor
    WGPUTextureDescriptor texture_desc = {};
    texture_desc.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst;
    texture_desc.dimension = WGPUTextureDimension_2D;
    texture_desc.size.width = image.width;
    texture_desc.size.height = image.height;
    texture_desc.size.depthOrArrayLayers = 1;
    texture_desc.format = WGPUTextureFormat_RGBA8Unorm;
    texture_desc.mipLevelCount = 1;
    texture_desc.sampleCount = 1;

    WGPUTexture texture = wgpuDeviceCreateTexture(device, &texture_desc);
    if (!texture) return nullptr;

    // Upload pixel data
    WGPUTexelCopyTextureInfo copy_dest = {};
    copy_dest.texture = texture;
    copy_dest.mipLevel = 0;
    copy_dest.origin = { 0, 0, 0 };
    copy_dest.aspect = WGPUTextureAspect_All;

    WGPUTexelCopyBufferLayout data_layout = {};
    data_layout.offset = 0;
    data_layout.bytesPerRow = image.width * 4;
    data_layout.rowsPerImage = image.height;

    WGPUExtent3D write_size = { (uint32_t)image.width, (uint32_t)image.height, 1 };
    wgpuQueueWriteTexture(queue, &copy_dest, image.pixels.data(), image.pixels.size() * 4,
                          &data_layout, &write_size);

    return texture;
}

// Helper: Create texture view from texture
WGPUTextureView createTextureView(WGPUTexture texture) {
    if (!texture) return nullptr;

    WGPUTextureViewDescriptor view_desc = {};
    view_desc.format = WGPUTextureFormat_Undefined;  // Determine from texture
    view_desc.dimension = WGPUTextureViewDimension_2D;
    view_desc.baseMipLevel = 0;
    view_desc.mipLevelCount = 1;
    view_desc.baseArrayLayer = 0;
    view_desc.arrayLayerCount = 1;
    view_desc.aspect = WGPUTextureAspect_All;

    return wgpuTextureCreateView(texture, &view_desc);
}

// Upload GPU atlas texture
bool uploadGlyphAtlas(LuaWindow* lua_window, GlyphAtlas& atlas) {
    if (!lua_window) return false;

    GPURenderContext& ctx = lua_window->gpu_context;

    if (atlas.cpu_pixels.empty()) return false;

    // Create GPU texture from CPU pixel data
    Image atlas_image;
    atlas_image.pixels = atlas.cpu_pixels;
    atlas_image.width = atlas.texture_width;
    atlas_image.height = atlas.texture_height;
    atlas_image.name = "glyph_atlas";

    atlas.gpu_texture = createGPUTexture(ctx.device, ctx.queue, atlas_image);
    if (!atlas.gpu_texture) {
        std::cerr << "Failed to create glyph atlas GPU texture" << std::endl;
        return false;
    }

    atlas.gpu_view = createTextureView(atlas.gpu_texture);
    if (!atlas.gpu_view) {
        std::cerr << "Failed to create glyph atlas texture view" << std::endl;
        wgpuTextureRelease(atlas.gpu_texture);
        atlas.gpu_texture = nullptr;
        return false;
    }

    // Update bind group to use glyph atlas texture using stored layout
    WGPUBindGroupEntry entries[3] = {};
    entries[0].binding = 0;
    entries[0].sampler = ctx.sampler;
    entries[1].binding = 1;
    entries[1].textureView = atlas.gpu_view;
    entries[2].binding = 2;
    entries[2].buffer = ctx.screen_uniform_buffer;
    entries[2].size = 16;

    WGPUBindGroupDescriptor bind_group_desc = {};
    bind_group_desc.layout = ctx.bind_group_layout;
    bind_group_desc.entryCount = 3;
    bind_group_desc.entries = entries;

    if (ctx.current_bind_group) {
        wgpuBindGroupRelease(ctx.current_bind_group);
    }
    // We don't cache atlas bind group in context for now, but we could in GlyphAtlas struct
    ctx.current_bind_group = wgpuDeviceCreateBindGroup(ctx.device, &bind_group_desc);
    ctx.current_texture_view = atlas.gpu_view;

    // Clear CPU pixels to save memory
    atlas.cpu_pixels.clear();
    atlas.cpu_pixels.shrink_to_fit();

    return true;
}

// Helper: Update bind group to use a specific texture view
void setBindGroupTexture(GPURenderContext& ctx, WGPUTextureView texture_view) {
    if (ctx.current_texture_view == texture_view) {
        return;  // Already bound
    }

    // TODO: Implement BindGroup caching to avoid creation churn
    // For now we create fresh, but we should look it up from a cache

    // Create new bind group with the specified texture
    WGPUBindGroupEntry entries[3] = {};
    entries[0].binding = 0;
    entries[0].sampler = ctx.sampler;
    entries[1].binding = 1;
    entries[1].textureView = texture_view;
    entries[2].binding = 2;
    entries[2].buffer = ctx.screen_uniform_buffer;
    entries[2].size = 16;

    WGPUBindGroupDescriptor bind_group_desc = {};
    bind_group_desc.layout = ctx.bind_group_layout;
    bind_group_desc.entryCount = 3;
    bind_group_desc.entries = entries;

    WGPUBindGroup new_bind_group = wgpuDeviceCreateBindGroup(ctx.device, &bind_group_desc);
    if (!new_bind_group) {
        std::cerr << "Failed to create bind group for texture" << std::endl;
        return;
    }

    if (ctx.current_bind_group) {
        wgpuBindGroupRelease(ctx.current_bind_group);
    }
    ctx.current_bind_group = new_bind_group;
    ctx.current_texture_view = texture_view;
}

struct ErrorScopeResult {
    bool completed;
    WGPUErrorType type;
    std::string message;
};

static void popErrorScopeCallback(WGPUPopErrorScopeStatus status, WGPUErrorType type,
                                  WGPUStringView message, void* userdata1, void* userdata2) {
    ErrorScopeResult* result = (ErrorScopeResult*)userdata1;
    result->completed = true;
    result->type = type;
    if (message.data) {
        result->message = std::string(message.data, message.length);
    }
}

bool compileShader(GPURenderContext& ctx, LuaShader* shader) {
    if (shader->pipeline) return true;             // Already compiled
    if (shader->compilation_failed) return false;  // Don't retry failed shaders
    if (shader->source.empty()) {
        shader->error_message = "Empty shader source";
        shader->compilation_failed = true;
        return false;
    }

    // Clean up potential mid-initialization garbage
    if (shader->bind_group_layout) {
        wgpuBindGroupLayoutRelease(shader->bind_group_layout);
        shader->bind_group_layout = nullptr;
    }
    if (shader->uniform_buffer) {
        wgpuBufferRelease(shader->uniform_buffer);
        shader->uniform_buffer = nullptr;
    }
    if (shader->bind_group) {
        wgpuBindGroupRelease(shader->bind_group);
        shader->bind_group = nullptr;
    }
    // Clean up user uniforms garbage
    if (shader->user_bind_group_layout) {
        wgpuBindGroupLayoutRelease(shader->user_bind_group_layout);
        shader->user_bind_group_layout = nullptr;
    }
    if (shader->user_uniform_buffer) {
        wgpuBufferRelease(shader->user_uniform_buffer);
        shader->user_uniform_buffer = nullptr;
    }
    if (shader->user_bind_group) {
        wgpuBindGroupRelease(shader->user_bind_group);
        shader->user_bind_group = nullptr;
    }

    // Create shader module
    WGPUShaderSourceWGSL wgsl_desc = {};
    wgsl_desc.chain.sType = WGPUSType_ShaderSourceWGSL;
    wgsl_desc.chain.next = nullptr;
    wgsl_desc.code = WGPUStringView{ shader->source.c_str(), shader->source.length() };

    WGPUShaderModuleDescriptor shader_desc = {};
    shader_desc.nextInChain = (const WGPUChainedStruct*)&wgsl_desc.chain;

    wgpuDevicePushErrorScope(ctx.device, WGPUErrorFilter_Validation);

    WGPUShaderModule shader_module = wgpuDeviceCreateShaderModule(ctx.device, &shader_desc);

    ErrorScopeResult error_result = { false, WGPUErrorType_NoError, "" };

    WGPUPopErrorScopeCallbackInfo callbackInfo = {};
    callbackInfo.callback = popErrorScopeCallback;
    callbackInfo.userdata1 = &error_result;

    wgpuDevicePopErrorScope(ctx.device, callbackInfo);

    while (!error_result.completed) {
        wgpuDevicePoll(ctx.device, true, nullptr);
    }

    if (error_result.type != WGPUErrorType_NoError) {
        shader->compilation_failed = true;
        shader->error_message = "Shader Compile Error: " + error_result.message;
        if (shader_module) wgpuShaderModuleRelease(shader_module);
        return false;
    }

    if (!shader_module) {
        shader->error_message = "Failed to create shader module (Unknown error)";
        shader->compilation_failed = true;
        return false;
    }

    // Layout for Group 1 (Uniforms)
    WGPUBindGroupLayoutEntry uniform_entry = {};
    uniform_entry.binding = 0;
    uniform_entry.visibility = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment;
    uniform_entry.buffer.type = WGPUBufferBindingType_Uniform;
    uniform_entry.buffer.minBindingSize = sizeof(Uniforms);

    WGPUBindGroupLayoutDescriptor bgl_desc = {};
    bgl_desc.entryCount = 1;
    bgl_desc.entries = &uniform_entry;

    shader->bind_group_layout = wgpuDeviceCreateBindGroupLayout(ctx.device, &bgl_desc);

    // Layout for Group 2 (User Uniforms)
    if (!shader->user_uniform_defs.empty()) {
        WGPUBindGroupLayoutEntry user_entry = {};
        user_entry.binding = 0;
        user_entry.visibility = WGPUShaderStage_Fragment | WGPUShaderStage_Vertex;
        user_entry.buffer.type = WGPUBufferBindingType_Uniform;
        user_entry.buffer.minBindingSize = shader->user_uniform_data.size();

        WGPUBindGroupLayoutDescriptor user_bgl_desc = {};
        user_bgl_desc.entryCount = 1;
        user_bgl_desc.entries = &user_entry;

        shader->user_bind_group_layout =
            wgpuDeviceCreateBindGroupLayout(ctx.device, &user_bgl_desc);
    }

    // Pipeline Layout: Group 0 (Texture), Group 1 (Uniforms), Group 2 (User)
    WGPUBindGroupLayout layouts[3];
    layouts[0] = ctx.bind_group_layout;
    layouts[1] = shader->bind_group_layout;
    int layout_count = 2;
    if (shader->user_bind_group_layout) {
        layouts[2] = shader->user_bind_group_layout;
        layout_count = 3;
    }

    WGPUPipelineLayoutDescriptor pipeline_layout_desc = {};
    pipeline_layout_desc.bindGroupLayoutCount = layout_count;
    pipeline_layout_desc.bindGroupLayouts = layouts;

    WGPUPipelineLayout pipeline_layout =
        wgpuDeviceCreatePipelineLayout(ctx.device, &pipeline_layout_desc);

    // Vertex Attributes (Must match default pipeline)
    WGPUVertexAttribute vert_attrs[3] = {};
    vert_attrs[0].format = WGPUVertexFormat_Float32x2;  // Pos
    vert_attrs[0].offset = 0;
    vert_attrs[0].shaderLocation = 0;

    vert_attrs[1].format = WGPUVertexFormat_Float32x2;  // UV
    vert_attrs[1].offset = 8;
    vert_attrs[1].shaderLocation = 1;

    vert_attrs[2].format = WGPUVertexFormat_Uint32;  // Color
    vert_attrs[2].offset = 16;
    vert_attrs[2].shaderLocation = 2;

    WGPUVertexBufferLayout vert_layout = {};
    vert_layout.arrayStride = sizeof(GPUVertex);
    vert_layout.stepMode = WGPUVertexStepMode_Vertex;
    vert_layout.attributeCount = 3;
    vert_layout.attributes = vert_attrs;

    // Blend State
    WGPUBlendState blend = {};
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_SrcAlpha;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState color_target = {};
    color_target.format = ctx.surface_format;
    color_target.blend = &blend;
    color_target.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fragment = {};
    fragment.module = shader_module;
    fragment.entryPoint = WGPUStringView{ "fs_main", WGPU_STRLEN };
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    WGPURenderPipelineDescriptor pipeline_desc = {};
    pipeline_desc.layout = pipeline_layout;
    pipeline_desc.vertex.module = shader_module;
    pipeline_desc.vertex.entryPoint = WGPUStringView{ "vs_main", WGPU_STRLEN };
    pipeline_desc.vertex.bufferCount = 1;
    pipeline_desc.vertex.buffers = &vert_layout;
    pipeline_desc.fragment = &fragment;
    pipeline_desc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    pipeline_desc.primitive.frontFace = WGPUFrontFace_CCW;
    pipeline_desc.primitive.cullMode = WGPUCullMode_None;
    pipeline_desc.multisample.count = 4;
    pipeline_desc.multisample.mask = ~0u;

    shader->pipeline = wgpuDeviceCreateRenderPipeline(ctx.device, &pipeline_desc);

    if (!shader->pipeline) {
        std::cerr << "Failed to create render pipeline for " << shader->name << std::endl;
        shader->compilation_failed = true;
        wgpuPipelineLayoutRelease(pipeline_layout);
        wgpuShaderModuleRelease(shader_module);
        return false;
    }

    // Create System Uniform Buffer
    WGPUBufferDescriptor buf_desc = {};
    buf_desc.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
    buf_desc.size = sizeof(Uniforms);
    shader->uniform_buffer = wgpuDeviceCreateBuffer(ctx.device, &buf_desc);

    // Create System Bind Group
    WGPUBindGroupEntry bg_entry = {};
    bg_entry.binding = 0;
    bg_entry.buffer = shader->uniform_buffer;
    bg_entry.size = sizeof(Uniforms);

    WGPUBindGroupDescriptor bg_desc = {};
    bg_desc.layout = shader->bind_group_layout;
    bg_desc.entryCount = 1;
    bg_desc.entries = &bg_entry;

    shader->bind_group = wgpuDeviceCreateBindGroup(ctx.device, &bg_desc);

    // Create User Uniform Buffer
    if (shader->user_bind_group_layout) {
        WGPUBufferDescriptor user_buf_desc = {};
        user_buf_desc.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
        user_buf_desc.size = shader->user_uniform_data.size();
        shader->user_uniform_buffer = wgpuDeviceCreateBuffer(ctx.device, &user_buf_desc);

        WGPUBindGroupEntry user_bg_entry = {};
        user_bg_entry.binding = 0;
        user_bg_entry.buffer = shader->user_uniform_buffer;
        user_bg_entry.size = shader->user_uniform_data.size();

        WGPUBindGroupDescriptor user_bg_desc = {};
        user_bg_desc.layout = shader->user_bind_group_layout;
        user_bg_desc.entryCount = 1;
        user_bg_desc.entries = &user_bg_entry;

        shader->user_bind_group = wgpuDeviceCreateBindGroup(ctx.device, &user_bg_desc);
    }

    wgpuPipelineLayoutRelease(pipeline_layout);
    wgpuShaderModuleRelease(shader_module);

    return shader->pipeline != nullptr;
}

// Render queued GPU vertices (geometry queued, ready for GPU submission)
std::string renderGPUQueue(LuaWindow* lua_window) {
    if (!lua_window) return "";

    GPURenderContext& ctx = lua_window->gpu_context;

    if (!ctx.device || !ctx.queue || !lua_window->surface || !ctx.pipeline) {
        return "";
    }

    // Pre-compile shaders to catch errors before rendering
    for (auto& batch : ctx.draw_batches) {
        if (batch.shader && !batch.shader->pipeline) {
            if (!compileShader(ctx, batch.shader)) {
                return "Shader compilation failed: " + batch.shader->error_message;
            }
        }
    }
    bool use_post = (lua_window->post_effect != nullptr);
    if (use_post && lua_window->post_effect && !lua_window->post_effect->pipeline) {
        if (!compileShader(ctx, lua_window->post_effect)) {
            return "Post-process shader compilation failed: " +
                   lua_window->post_effect->error_message;
        }
    }

    // Post-processing setup
    int width, height;
    SDL_GetWindowSize(lua_window->window, &width, &height);

    if (use_post) {
        // Ensure offscreen texture matches window size
        if (!lua_window->offscreen_texture ||
            (width > 0 && height > 0 &&
             ((int)wgpuTextureGetWidth(lua_window->offscreen_texture) != width ||
              (int)wgpuTextureGetHeight(lua_window->offscreen_texture) != height))) {
            if (lua_window->offscreen_view) wgpuTextureViewRelease(lua_window->offscreen_view);
            if (lua_window->offscreen_texture) wgpuTextureRelease(lua_window->offscreen_texture);

            WGPUTextureDescriptor desc = {};
            desc.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding;
            desc.dimension = WGPUTextureDimension_2D;
            desc.size = { (uint32_t)width, (uint32_t)height, 1 };
            desc.format = ctx.surface_format;
            desc.mipLevelCount = 1;
            desc.sampleCount = 1;

            lua_window->offscreen_texture = wgpuDeviceCreateTexture(ctx.device, &desc);
            lua_window->offscreen_view = createTextureView(lua_window->offscreen_texture);
        }
    }

    // Ensure MSAA texture matches window size
    if (!ctx.msaa_texture ||
        (width > 0 && height > 0 &&
         ((int)wgpuTextureGetWidth(ctx.msaa_texture) != width ||
          (int)wgpuTextureGetHeight(ctx.msaa_texture) != height))) {

        if (ctx.msaa_view) wgpuTextureViewRelease(ctx.msaa_view);
        if (ctx.msaa_texture) wgpuTextureRelease(ctx.msaa_texture);

        WGPUTextureDescriptor desc = {};
        desc.usage = WGPUTextureUsage_RenderAttachment;
        desc.dimension = WGPUTextureDimension_2D;
        desc.size = { (uint32_t)width, (uint32_t)height, 1 };
        desc.format = ctx.surface_format;
        desc.mipLevelCount = 1;
        desc.sampleCount = 4; // MSAA x4

        ctx.msaa_texture = wgpuDeviceCreateTexture(ctx.device, &desc);
        ctx.msaa_view = createTextureView(ctx.msaa_texture);
    }

    // Get surface texture (Final Target)
    WGPUSurfaceTexture surface_texture = {};
    wgpuSurfaceGetCurrentTexture(lua_window->surface, &surface_texture);

    if (surface_texture.texture == nullptr) {
        std::cerr << "Failed to get surface texture" << std::endl;
        return "Failed to get surface texture";
    }

    WGPUTextureViewDescriptor view_desc = {};
    view_desc.format = ctx.surface_format;
    view_desc.dimension = WGPUTextureViewDimension_2D;
    view_desc.baseMipLevel = 0;
    view_desc.mipLevelCount = 1;
    view_desc.baseArrayLayer = 0;
    view_desc.arrayLayerCount = 1;
    WGPUTextureView surface_view = wgpuTextureCreateView(surface_texture.texture, &view_desc);

    // Close the last batch's vertex count
    if (!ctx.draw_batches.empty()) {
        ctx.draw_batches.back().vertex_count = ctx.vertex_queue.size() - ctx.draw_batches.back().vertex_start;
    }

    // Chunking structure
    struct RenderChunk {
        WGPUBuffer vBuf = nullptr;
        WGPUBuffer iBuf = nullptr;
        size_t start_batch;
        size_t end_batch_exclusive;
        size_t vertex_start;
        size_t index_start;
    };
    std::vector<RenderChunk> chunks;

    const size_t MAX_VERTS_PER_CHUNK = 50000;

    if (!ctx.draw_batches.empty()) {
        chunks.push_back({nullptr, nullptr, 0, 0, ctx.draw_batches[0].vertex_start, ctx.draw_batches[0].index_start});
        size_t current_verts = 0;

        for (size_t i = 0; i < ctx.draw_batches.size(); ++i) {
            const auto& batch = ctx.draw_batches[i];
            if (current_verts + batch.vertex_count > MAX_VERTS_PER_CHUNK && chunks.back().end_batch_exclusive > chunks.back().start_batch) {
                chunks.push_back({nullptr, nullptr, i, i, batch.vertex_start, batch.index_start});
                current_verts = 0;
            }
            chunks.back().end_batch_exclusive++;
            current_verts += batch.vertex_count;
        }
    }

    // Create and Upload Buffers
    for (auto& chunk : chunks) {
        size_t last_batch_idx = chunk.end_batch_exclusive - 1;
        size_t chunk_vertex_end = ctx.draw_batches[last_batch_idx].vertex_start + ctx.draw_batches[last_batch_idx].vertex_count;
        size_t chunk_index_end = ctx.draw_batches[last_batch_idx].index_start + ctx.draw_batches[last_batch_idx].index_count;

        size_t v_count = chunk_vertex_end - chunk.vertex_start;
        size_t i_count = chunk_index_end - chunk.index_start;

        if (v_count > 0) {
            WGPUBufferDescriptor v_desc = {};
            v_desc.size = (v_count * sizeof(GPUVertex) + 3) & ~3;
            v_desc.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
            v_desc.mappedAtCreation = false;
            chunk.vBuf = wgpuDeviceCreateBuffer(ctx.device, &v_desc);
            wgpuQueueWriteBuffer(ctx.queue, chunk.vBuf, 0, &ctx.vertex_queue[chunk.vertex_start], v_count * sizeof(GPUVertex));
        }
        if (i_count > 0) {
            WGPUBufferDescriptor i_desc = {};
            i_desc.size = (i_count * sizeof(uint32_t) + 3) & ~3;
            i_desc.usage = WGPUBufferUsage_Index | WGPUBufferUsage_CopyDst;
            i_desc.mappedAtCreation = false;
            chunk.iBuf = wgpuDeviceCreateBuffer(ctx.device, &i_desc);
            wgpuQueueWriteBuffer(ctx.queue, chunk.iBuf, 0, &ctx.index_queue[chunk.index_start], i_count * sizeof(uint32_t));
        }
    }

    // Update system uniforms
    struct {
        float width;
        float height;
        float padding[2];
    } sys_uniforms = { (float)width, (float)height, { 0.0f, 0.0f } };
    wgpuQueueWriteBuffer(ctx.queue, ctx.screen_uniform_buffer, 0, &sys_uniforms,
                         sizeof(sys_uniforms));

    WGPUCommandEncoderDescriptor encoder_desc = {};
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(ctx.device, &encoder_desc);

    // --- Pass 1: Render Scene ---
    {
        WGPURenderPassColorAttachment color_attachment = {};
        // Draw to MSAA texture, resolve to Screen (or Offscreen)
        color_attachment.view = ctx.msaa_view;
        color_attachment.resolveTarget =
            (use_post && lua_window->offscreen_view) ? lua_window->offscreen_view : surface_view;

        if (!ctx.msaa_view) {
             // Skip rendering if MSAA view is missing (e.g. invalid size)
             // This avoids pipeline mismatch crashes
             wgpuCommandEncoderRelease(encoder);
             wgpuTextureViewRelease(surface_view);
             wgpuTextureRelease(surface_texture.texture);
             return "";
        }

        color_attachment.loadOp = WGPULoadOp_Clear;
        color_attachment.storeOp = WGPUStoreOp_Discard; // Don't keep MSAA data
        color_attachment.clearValue = WGPUColor{ 0.1f, 0.1f, 0.1f, 1.0f };
        color_attachment.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor render_pass_desc = {};
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;

        WGPURenderPassEncoder render_pass =
            wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

        for (const auto& chunk : chunks) {
            if (!chunk.vBuf || !chunk.iBuf) continue;

            size_t last_batch_idx = chunk.end_batch_exclusive - 1;
            size_t chunk_vertex_end = ctx.draw_batches[last_batch_idx].vertex_start + ctx.draw_batches[last_batch_idx].vertex_count;
            size_t v_count = chunk_vertex_end - chunk.vertex_start;
            size_t chunk_index_end = ctx.draw_batches[last_batch_idx].index_start + ctx.draw_batches[last_batch_idx].index_count;
            size_t i_count = chunk_index_end - chunk.index_start;

            wgpuRenderPassEncoderSetVertexBuffer(render_pass, 0, chunk.vBuf, 0, v_count * sizeof(GPUVertex));
            wgpuRenderPassEncoderSetIndexBuffer(render_pass, chunk.iBuf, WGPUIndexFormat_Uint32, 0, i_count * sizeof(uint32_t));

            for (size_t i = chunk.start_batch; i < chunk.end_batch_exclusive; ++i) {
                const auto& batch = ctx.draw_batches[i];
                if (batch.index_count == 0) continue;

                if (batch.shader) {
                    if (batch.shader->pipeline) {
                        // Update system uniforms
                        float t = (float)SDL_GetTicks() / 1000.0f;
                        batch.shader->uniform_data.time = t;

                        float x, y;
                        SDL_GetMouseState(&x, &y);
                        batch.shader->uniform_data.mouse[0] = x;
                        batch.shader->uniform_data.mouse[1] = y;

                        batch.shader->uniform_data.resolution[0] = (float)width;
                        batch.shader->uniform_data.resolution[1] = (float)height;

                        // Ortho Projection
                        std::fill(std::begin(batch.shader->uniform_data.projection),
                                  std::end(batch.shader->uniform_data.projection), 0.0f);
                        if (width > 0 && height > 0) {
                            batch.shader->uniform_data.projection[0] = 2.0f / width;
                            batch.shader->uniform_data.projection[5] = -2.0f / height;
                            batch.shader->uniform_data.projection[10] = 1.0f;
                            batch.shader->uniform_data.projection[15] = 1.0f;
                            batch.shader->uniform_data.projection[12] = -1.0f;
                            batch.shader->uniform_data.projection[13] = 1.0f;
                        }

                        // Force dirty
                        batch.shader->uniforms_dirty = true;

                        wgpuRenderPassEncoderSetPipeline(render_pass, batch.shader->pipeline);
                        if (batch.shader->uniforms_dirty) {
                            wgpuQueueWriteBuffer(ctx.queue, batch.shader->uniform_buffer, 0,
                                                 &batch.shader->uniform_data, sizeof(Uniforms));
                            batch.shader->uniforms_dirty = false;
                        }
                        wgpuRenderPassEncoderSetBindGroup(render_pass, 1, batch.shader->bind_group,
                                                          0, nullptr);

                        if (batch.shader->user_bind_group) {
                            if (batch.shader->user_uniforms_dirty) {
                                wgpuQueueWriteBuffer(ctx.queue, batch.shader->user_uniform_buffer,
                                                     0, batch.shader->user_uniform_data.data(),
                                                     batch.shader->user_uniform_data.size());
                                batch.shader->user_uniforms_dirty = false;
                            }
                            wgpuRenderPassEncoderSetBindGroup(
                                render_pass, 2, batch.shader->user_bind_group, 0, nullptr);
                        }
                    } else {
                        wgpuRenderPassEncoderSetPipeline(render_pass, ctx.pipeline);
                    }
                } else {
                    wgpuRenderPassEncoderSetPipeline(render_pass, ctx.pipeline);
                }

                // Bind texture group
                setBindGroupTexture(ctx, batch.texture_view);
                wgpuRenderPassEncoderSetBindGroup(render_pass, 0, ctx.current_bind_group, 0, nullptr);

                wgpuRenderPassEncoderDrawIndexed(render_pass, batch.index_count, 1,
                                                 batch.index_start - chunk.index_start,
                                                 -(int32_t)chunk.vertex_start, 0);
            }
        }
        wgpuRenderPassEncoderEnd(render_pass);
        wgpuRenderPassEncoderRelease(render_pass);

        // Release chunk buffers
        for (auto& c : chunks) {
            if (c.vBuf) wgpuBufferRelease(c.vBuf);
            if (c.iBuf) wgpuBufferRelease(c.iBuf);
        }
    }

    // --- Pass 2: Post Processing ---
    if (use_post && lua_window->offscreen_view) {
        // Create full screen quad buffers
        GPUVertex quad_verts[] = {
             { -1.0f, -1.0f, 0.0f, 1.0f, 0xFFFFFFFF },
             { 1.0f, -1.0f, 1.0f, 1.0f, 0xFFFFFFFF },
             { 1.0f, 1.0f, 1.0f, 0.0f, 0xFFFFFFFF },
             { -1.0f, 1.0f, 0.0f, 0.0f, 0xFFFFFFFF }
        };
        uint32_t quad_inds[] = { 0, 1, 2, 0, 2, 3 };

        WGPUBufferDescriptor v_desc = {};
        v_desc.size = sizeof(quad_verts);
        v_desc.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
        v_desc.mappedAtCreation = true;
        WGPUBuffer vBuf = wgpuDeviceCreateBuffer(ctx.device, &v_desc);
        void* ptr = wgpuBufferGetMappedRange(vBuf, 0, sizeof(quad_verts));
        memcpy(ptr, quad_verts, sizeof(quad_verts));
        wgpuBufferUnmap(vBuf);

        WGPUBufferDescriptor i_desc = {};
        i_desc.size = sizeof(quad_inds);
        i_desc.usage = WGPUBufferUsage_Index | WGPUBufferUsage_CopyDst;
        i_desc.mappedAtCreation = true;
        WGPUBuffer iBuf = wgpuDeviceCreateBuffer(ctx.device, &i_desc);
        ptr = wgpuBufferGetMappedRange(iBuf, 0, sizeof(quad_inds));
        memcpy(ptr, quad_inds, sizeof(quad_inds));
        wgpuBufferUnmap(iBuf);

        WGPURenderPassColorAttachment color_attachment = {};
        color_attachment.view = surface_view;
        color_attachment.loadOp = WGPULoadOp_Clear;
        color_attachment.storeOp = WGPUStoreOp_Store;
        color_attachment.clearValue = WGPUColor{ 0.0f, 0.0f, 0.0f, 1.0f };
        color_attachment.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor render_pass_desc = {};
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;

        WGPURenderPassEncoder render_pass =
            wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

        LuaShader* post = lua_window->post_effect;

        if (post->pipeline) {
            // System Uniforms for Post
            float t = (float)SDL_GetTicks() / 1000.0f;
            post->uniform_data.time = t;
            float x, y;
            SDL_GetMouseState(&x, &y);
            post->uniform_data.mouse[0] = x;
            post->uniform_data.mouse[1] = y;
            post->uniform_data.resolution[0] = (float)width;
            post->uniform_data.resolution[1] = (float)height;

            // Identity Projection
            std::fill(std::begin(post->uniform_data.projection),
                      std::end(post->uniform_data.projection), 0.0f);
            post->uniform_data.projection[0] = 1.0f;
            post->uniform_data.projection[5] = 1.0f;
            post->uniform_data.projection[10] = 1.0f;
            post->uniform_data.projection[15] = 1.0f;

            post->uniforms_dirty = true;

            wgpuRenderPassEncoderSetPipeline(render_pass, post->pipeline);

            if (post->uniforms_dirty) {
                wgpuQueueWriteBuffer(ctx.queue, post->uniform_buffer, 0, &post->uniform_data,
                                     sizeof(Uniforms));
                post->uniforms_dirty = false;
            }
            wgpuRenderPassEncoderSetBindGroup(render_pass, 1, post->bind_group, 0, nullptr);

            if (post->user_bind_group) {
                if (post->user_uniforms_dirty) {
                    wgpuQueueWriteBuffer(ctx.queue, post->user_uniform_buffer, 0,
                                         post->user_uniform_data.data(),
                                         post->user_uniform_data.size());
                    post->user_uniforms_dirty = false;
                }
                wgpuRenderPassEncoderSetBindGroup(render_pass, 2, post->user_bind_group, 0,
                                                  nullptr);
            }

            // Bind Offscreen Texture as Group 0
            setBindGroupTexture(ctx, lua_window->offscreen_view);
            wgpuRenderPassEncoderSetBindGroup(render_pass, 0, ctx.current_bind_group, 0, nullptr);

            wgpuRenderPassEncoderSetVertexBuffer(render_pass, 0, vBuf, 0, sizeof(quad_verts));
            wgpuRenderPassEncoderSetIndexBuffer(render_pass, iBuf, WGPUIndexFormat_Uint32, 0, sizeof(quad_inds));

            wgpuRenderPassEncoderDrawIndexed(render_pass, 6, 1, 0, 0, 0);
        }

        wgpuRenderPassEncoderEnd(render_pass);
        wgpuRenderPassEncoderRelease(render_pass);

        wgpuBufferRelease(vBuf);
        wgpuBufferRelease(iBuf);
    }

    // Finish and submit command buffer
    WGPUCommandBufferDescriptor cmd_buffer_desc = {};
    WGPUCommandBuffer cmd_buffer = wgpuCommandEncoderFinish(encoder, &cmd_buffer_desc);
    wgpuQueueSubmit(ctx.queue, 1, &cmd_buffer);
    wgpuCommandBufferRelease(cmd_buffer);
    wgpuCommandEncoderRelease(encoder);

    // Present to screen
    wgpuSurfacePresent(lua_window->surface);

    // Clean up
    wgpuTextureViewRelease(surface_view);
    wgpuTextureRelease(surface_texture.texture);

    return "";
}

// Clear the GPU rendering queues
void clearGPUQueues(LuaWindow* lua_window) {
    if (lua_window) {
        lua_window->gpu_context.vertex_queue.clear();
        lua_window->gpu_context.index_queue.clear();
        lua_window->gpu_context.draw_batches.clear();
    }
}

bool gpu_init() {
    wgpu_instance = wgpuCreateInstance(nullptr);
    if (!wgpu_instance) {
        std::cerr << "Failed to create WGPU instance" << std::endl;
        return false;
    }
    return true;
}
void gpu_destroy() {
    if (wgpu_instance) {
        wgpuInstanceRelease(wgpu_instance);
    }
}
