#pragma once
#include "pch.hpp"

// Simple image structure
struct Image {
    std::vector<uint32_t> pixels;
    int width = 0;
    int height = 0;
    std::string name;
};

bool loadImageFile(const char* filename, Image& image);
