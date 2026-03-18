#pragma once

#include <filesystem>
#include <span>
#include <vector>

bool vfs_build_bundle(const std::filesystem::path& sourceExePath,
                      const std::filesystem::path& destExePath, const std::filesystem::path& root,
                      const std::string& entrypoint,
                      const std::vector<std::filesystem::path>& files);

bool vfs_open(void);
void vfs_close(void);

bool vfs_is_isolated();
void vfs_set_isolated(bool isolated);

std::string_view vfs_get_entrypoint();
std::span<const uint8_t> vfs_read_file(const std::string& path);
uint64_t vfs_get_mtime(const std::string& path);
std::vector<std::string> vfs_list_dir(const std::string& dir);
bool vfs_is_file(const std::string& path);
bool vfs_is_dir(const std::string& path);
