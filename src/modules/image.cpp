#include "lualib.h"
#include "module_api.h"

// Must be here to ensure it's only in a single unit
#define STB_IMAGE_IMPLEMENTATION
#define STBI_FAILURE_USERMSG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

// See lbuffer.h in luau/VM/src/
#define MAX_BUFFER_SIZE (1 << 30)

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_image",
};
LUAU_MODULE_INFO()

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t channels;  // Always 4
    void* pixelBuffer;
    lua_State* L;
    int bufferRef;
} LuaImage;
static const char* IMAGE_METATABLE = "Image";

static void image_dtor(void* ud) {
    LuaImage* i = (LuaImage*)ud;

    if (i->pixelBuffer) {
        lua_unref(i->L, i->bufferRef);
        i->pixelBuffer = nullptr;
    }
}
static int image_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    int forceChannels = 4;  // RGBA

    int w, h, channels;
    stbi_uc* data = stbi_load(path, &w, &h, &channels, forceChannels);
    if (!data) {
        luaL_errorL(L, "Failed to load %s: %s", path, stbi_failure_reason());
        return 0;
    }
    if (w * h * forceChannels > MAX_BUFFER_SIZE) {
        stbi_image_free(data);
        luaL_error(L, "Failed to load: %s: %dx%d is too large for a Luau buffer!", path, w, h);
        return 0;
    }

    LuaImage* i = (LuaImage*)lua_newuserdatadtor(L, sizeof(LuaImage), image_dtor);
    i->width = w;
    i->height = h;
    i->channels = forceChannels;

    void* bufferData = lua_newbuffer(L, w * h * forceChannels);
    memcpy(bufferData, data, w * h * forceChannels);
    stbi_image_free(data);
    i->pixelBuffer = bufferData;
    // Keep a ref to the buffer
    i->L = L;
    i->bufferRef = lua_ref(L, -1);
    lua_pop(L, 1);  // Then discard it from our stack

    luaL_getmetatable(L, IMAGE_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int image_fromRGBABuffer(lua_State* L) {
    size_t bufLen;
    void* buffer = luaL_checkbuffer(L, 1, &bufLen);
    int width = luaL_checkinteger(L, 2);
    if (width <= 0) {
        luaL_error(L, "Cannot have 0 or negative width");
        return 0;
    }
    int height = luaL_checkinteger(L, 3);
    if (height <= 0) {
        luaL_error(L, "Cannot have 0 or negative height");
        return 0;
    }
    int channels = luaL_checkinteger(L, 4);
    if (channels != 4) {
        luaL_error(L, "Only RGBA channel format supported");
        return 0;
    }

    if (bufLen != width * height * channels) {
        luaL_error(L, "Provided buffer does not exactly match %dx%dx%d", width, height, channels);
        return 0;
    }

    LuaImage* i = (LuaImage*)lua_newuserdatadtor(L, sizeof(LuaImage), image_dtor);
    i->width = width;
    i->height = height;
    i->channels = channels;

    i->pixelBuffer = buffer;
    // Keep a ref to the buffer
    i->L = L;
    i->bufferRef = lua_ref(L, 1);

    luaL_getmetatable(L, IMAGE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}
static int image_tostring(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);

    lua_pushfstring(L, "Image(%d, %d)", i->width, i->height);
    return 1;
}
static int image_index(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    const char* key = luaL_checkstring(L, 2);

    // Resolve property fields
    if (strcmp(key, "width") == 0) {
        lua_pushnumber(L, i->width);
        return 1;
    }
    if (strcmp(key, "height") == 0) {
        lua_pushnumber(L, i->height);
        return 1;
    }
    if (strcmp(key, "channels") == 0) {
        lua_pushnumber(L, i->channels);
        return 1;
    }
    if (strcmp(key, "pixelBuffer") == 0) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, i->bufferRef);
        return 1;
    }

    // Fall back to methods table (upvalue 1)
    lua_pushvalue(L, 2);                 // push key
    lua_rawget(L, lua_upvalueindex(1));  // methods[key]
    return 1;
}
static int image_GetPixel(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);

    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    if (x < 0 || x >= i->width) {
        luaL_errorL(L, "X coordinate out of bounds");
        return 0;
    }
    if (y < 0 || y >= i->height) {
        luaL_errorL(L, "Y coordinate out of bounds");
        return 0;
    }

    uint8_t* data = &((uint8_t*)i->pixelBuffer)[(y * i->width + x) * i->channels];

    lua_createtable(L, 4, 0);
    for (int j = 0; j < i->channels; j++) {
        lua_pushnumber(L, data[j]);
        lua_rawseti(L, -2, j + 1);
    }

    return 1;
}
static int image_SetPixel(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);

    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    if (x < 0 || x >= i->width) {
        luaL_errorL(L, "X coordinate out of bounds");
        return 0;
    }
    if (y < 0 || y >= i->height) {
        luaL_errorL(L, "Y coordinate out of bounds");
        return 0;
    }

    if (lua_objlen(L, 4) != i->channels) {
        luaL_error(L, "Expected %d channels of colour. Received %d.", i->channels,
                   lua_objlen(L, 4));
        return 0;
    }
    for (int j = 0; j < i->channels; j++) {
        lua_rawgeti(L, 4, j + 1);
        int isNum = 0;
        int num = lua_tointegerx(L, -1, &isNum);
        if (!isNum) {
            lua_pop(L, 1);
            luaL_error(L, "#%d in colour data is not a number", j + 1);
        }
        if (num < 0 || num > 255) {
            lua_pop(L, 1);
            luaL_error(L, "Expected pixel channel data in range 0-255. Got %d for channel %d", num,
                       j + 1);
            return 0;
        }
        lua_pop(L, 1);
    }

    uint8_t* data = &((uint8_t*)i->pixelBuffer)[(y * i->width + x) * i->channels];

    for (int j = 0; j < i->channels; j++) {
        lua_rawgeti(L, 4, j + 1);
        int isNum = 0;
        data[j] = (uint8_t)lua_tointegerx(L, -1, &isNum);
        lua_pop(L, 1);
    }

    return 0;
}
static int image_Save(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    std::string path = luaL_checkstring(L, 2);

    int success = 0;
    int stride = i->width * i->channels;

    if (path.ends_with(".png")) {
        success =
            stbi_write_png(path.c_str(), i->width, i->height, i->channels, i->pixelBuffer, stride);
    } else if (path.ends_with(".jpg") || path.ends_with(".jpeg")) {
        int quality = luaL_optinteger(L, 3, 90);
        if (quality < 0 || quality > 100) {
            luaL_error(L, "Quality must be in range 0-100");
        }

        success =
            stbi_write_jpg(path.c_str(), i->width, i->height, i->channels, i->pixelBuffer, quality);
    } else if (path.ends_with(".bmp")) {
        success = stbi_write_bmp(path.c_str(), i->width, i->height, i->channels, i->pixelBuffer);
    } else if (path.ends_with(".tga")) {
        success = stbi_write_tga(path.c_str(), i->width, i->height, i->channels, i->pixelBuffer);
    } else {
        luaL_error(L, "Unsupported image format");
        return 0;
    }

    if (!success) {
        luaL_errorL(L, "Failed to save %s", path.c_str());
        return 0;
    }

    return 0;
}
static int image_Resize(lua_State* L) {
    LuaImage* i = (LuaImage*)luaL_checkudata(L, 1, IMAGE_METATABLE);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);

    if (width <= 0) {
        luaL_error(L, "Width cannot be 0 or negative");
        return 0;
    }
    if (height <= 0) {
        luaL_error(L, "Width cannot be 0 or negative");
        return 0;
    }
    if (width * height * i->channels > MAX_BUFFER_SIZE) {
        luaL_error(L, "Image would be too large to fit in a single buffer!");
        return 0;
    }

    LuaImage* newI = (LuaImage*)lua_newuserdatadtor(L, sizeof(LuaImage), image_dtor);
    newI->width = width;
    newI->height = height;
    newI->channels = i->channels;

    void* bufferData = lua_newbuffer(L, width * height * i->channels);
    newI->pixelBuffer = bufferData;
    // Keep a ref to the buffer
    newI->L = L;
    newI->bufferRef = lua_ref(L, -1);
    lua_pop(L, 1);  // Then discard it from our stack

    luaL_getmetatable(L, IMAGE_METATABLE);
    lua_setmetatable(L, -2);

    if (!stbir_resize_uint8_srgb((unsigned char*)i->pixelBuffer, i->width, i->height,
                                 i->width * i->channels, (unsigned char*)newI->pixelBuffer, width,
                                 height, width * newI->channels, STBIR_RGBA)) {
        lua_unref(L, newI->bufferRef);
        lua_pop(L, 1);  // Pop our now-unneeded userdata
        luaL_error(L, "Failed to resize image");
    }

    return 1;
}

LUAU_MODULE_EXPORT int luauopen_image(lua_State* L) {
    // -- Image metatable --
    luaL_newmetatable(L, IMAGE_METATABLE);

    lua_pushcfunction(L, image_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    // Build methods table (used as upvalue for __index)
    lua_newtable(L);  // methods table

    lua_pushcfunction(L, image_GetPixel, "getPixel");
    lua_setfield(L, -2, "getPixel");
    lua_pushcfunction(L, image_SetPixel, "setPixel");
    lua_setfield(L, -2, "setPixel");
    lua_pushcfunction(L, image_Save, "save");
    lua_setfield(L, -2, "save");
    lua_pushcfunction(L, image_Resize, "resize");
    lua_setfield(L, -2, "resize");

    // __index = image_index with methods table as upvalue
    lua_pushcclosure(L, image_index, "__index", 1);  // pops methods table
    lua_setfield(L, -2, "__index");
    lua_setreadonly(L, -1, true);  // Freeze metatable
    lua_pop(L, 1);                 // pop Image metatable

    lua_newtable(L);  // main return table

    lua_pushcfunction(L, image_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, image_fromRGBABuffer, "fromRGBABuffer");
    lua_setfield(L, -2, "fromRGBABuffer");

    lua_setreadonly(L, -1, true);
    return 1;
}
