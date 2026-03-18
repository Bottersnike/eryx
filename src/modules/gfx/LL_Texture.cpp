#include "LL_Texture.hpp"

// Must be here to ensure it's only in a single unit
#define STB_IMAGE_IMPLEMENTATION
#define STBI_FAILURE_USERMSG
#include "stb_image.h"

bool loadImageFile(const char* filename, Image& image) {
    // Try using stb_image first
    int w, h, channels;
    stbi_uc* data = stbi_load(filename, &w, &h, &channels, 4);  // Force RGBA

    if (data) {
        image.width = w;
        image.height = h;
        image.name = filename;
        image.pixels.resize(w * h);

        // Convert from RGBA to ARGB (our internal format)
        for (int i = 0; i < w * h; i++) {
            uint8_t r = data[i * 4 + 0];
            uint8_t g = data[i * 4 + 1];
            uint8_t b = data[i * 4 + 2];
            uint8_t a = data[i * 4 + 3];
            // Store as R, G, B, A in little-endian uint32
            // Byte 0: R, Byte 1: G, Byte 2: B, Byte 3: A
            image.pixels[i] = (a << 24) | (b << 16) | (g << 8) | r;
        }

        stbi_image_free(data);
        return true;
    } else {
        std::cout << stbi_failure_reason() << std::endl;
    }

    return false;
}
