#include "Font.hpp"
#include "LL_Render.hpp"
#include "Texture.hpp"
#include "Window.hpp"


FT_Library ft_library = nullptr;

// Texture methods
int textureSize(lua_State* L) {
    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 1, TEXTURE_METATABLE);
    if (!texture) {
        luaL_error(L, "Invalid texture object");
        return 0;
    }

    lua_pushnumber(L, texture->image.width);
    lua_pushnumber(L, texture->image.height);
    return 2;
}

int textureDestroy(lua_State* L) {
    LuaTexture* texture = (LuaTexture*)luaL_checkudata(L, 1, TEXTURE_METATABLE);
    if (texture) {
        texture->image.pixels.clear();
    }
    return 0;
}
// Lua Texture library functions
int gfx_loadImage(lua_State* L) {
    const char* filename = luaL_checkstring(L, 1);

    Image img;
    if (!loadImageFile(filename, img)) {
        luaL_error(L, "Failed to load image: %s", filename);
        return 0;
    }

    // Create userdata for texture
    LuaTexture* texture = (LuaTexture*)lua_newuserdata(L, sizeof(LuaTexture));
    new (texture) LuaTexture();
    texture->image = img;
    texture->name = filename;

    // Set metatable
    luaL_getmetatable(L, TEXTURE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

// Lua Font library functions
int gfx_loadFont(lua_State* L) {
    const char* filename = luaL_checkstring(L, 1);
    int size = (int)luaL_checknumber(L, 2);

    // Load the font face
    FT_Face face;
    if (FT_New_Face(ft_library, filename, 0, &face)) {
        luaL_error(L, "Failed to load font: %s", filename);
        return 0;
    }

    FT_Set_Pixel_Sizes(face, 0, size);

    // Create userdata for font
    LuaFont* font = (LuaFont*)lua_newuserdata(L, sizeof(LuaFont));
    new (font) LuaFont();  // Call constructor to initialize
    font->face = face;
    font->name = filename;

    // Set metatable
    luaL_getmetatable(L, FONT_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

static const luaL_Reg gfx_lib[] = {
    { "loadImage", gfx_loadImage },
    { "loadFont", gfx_loadFont },
    { NULL, NULL },
};

void gfx_lib_register(lua_State* L) {
    texture_lib_register(L);
    font_lib_register(L);

    luaL_register(L, "gfx", gfx_lib);
}

bool gfx_init() {
    if (FT_Init_FreeType(&ft_library)) {
        std::cerr << "Failed to initialize FreeType" << std::endl;
        return false;
    }
    return true;
}
void gfx_destroy() {
    if (ft_library) FT_Done_FreeType(ft_library);
}
