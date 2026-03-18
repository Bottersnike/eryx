#include "vfs.hpp"

#ifdef _WIN32
#include <Windows.h>
#else
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#include <cinttypes>
#include <cstring>
#include <fstream>

static const uint64_t VFS_MARKER = 0x5346564558595245U;
static const uint32_t VFS_VERSION = 1;

typedef struct {
    uint64_t fileTableOffset;
    uint64_t stringTableOffset;
    uint64_t dataOffset;
    uint32_t fileCount;

    uint32_t entrypointOffset;  // into string table
    uint32_t entrypointLength;
} VFSHeader;
typedef struct {
    uint64_t marker;
    uint32_t version;
    uint64_t vfsOffset;
} VFSFooter;

typedef struct {
    std::string path;
    std::vector<char> data;
    uint64_t mtime;
} PackFile;

typedef struct {
    uint32_t pathOffset;  // offset into string table
    uint32_t pathLength;

    uint64_t dataOffset;  // relative to data section
    uint64_t size;

    uint64_t mtime;
} VFSFileEntry;

typedef enum {
    kVFS_ERROR_OK = 0,
    kVFS_ERROR_FILE = -1,
    kVFS_ERROR_SIZE = -2,
    kVFS_ERROR_MARKER = -3,
    kVFS_ERROR_VERSION = -4,
} VFS_ERROR;

typedef struct VFS {
#ifdef _WIN32
    HANDLE file;
    HANDLE mapping;
#else
    int file;
#endif
    size_t base;

    const VFSFileEntry* entries;
    const char* strings;
    const void* data;
    uint32_t fileCount;

    const char* entrypoint;
    uint32_t entrypointLength;
} VFS;

static VFS g_vfs;
static bool g_vfsOpen = false;
static bool g_vfsIsolated = true;

bool vfs_is_isolated() { return g_vfsIsolated; }
void vfs_set_isolated(bool isolated) { g_vfsIsolated = isolated; }

struct PackMeta {
    std::filesystem::path diskPath;  // real file
    std::string vfsPath;             // path inside VFS
    uint64_t size;
    uint64_t mtime;
};

static bool vfs_build_payload(const std::filesystem::path& root,
                              const std::vector<std::filesystem::path>& files,
                              const std::string& entrypoint, std::ostream& out) {
    std::vector<PackMeta> meta;
    meta.reserve(files.size());

    for (auto& f : files) {
        PackMeta m;

        m.diskPath = f;
        m.vfsPath = std::filesystem::relative(f, root).generic_string();
        std::replace(m.vfsPath.begin(), m.vfsPath.end(), '\\', '/');

        // TODO: If any files don't exist, give up!
        m.size = std::filesystem::file_size(f);
        m.mtime = std::filesystem::last_write_time(f).time_since_epoch().count();

        meta.push_back(std::move(m));
    }
    std::string entrypointNormalised = entrypoint;
    std::replace(entrypointNormalised.begin(), entrypointNormalised.end(), '\\', '/');

    // sort by VFS path (required for binary search)
    std::sort(meta.begin(), meta.end(),
              [](const PackMeta& a, const PackMeta& b) { return a.vfsPath < b.vfsPath; });

    VFSHeader header{};
    header.fileCount = (uint32_t)meta.size();
    header.fileTableOffset = sizeof(VFSHeader);

    std::vector<VFSFileEntry> entries(meta.size());

    // build string table
    std::string strings;

    for (size_t i = 0; i < meta.size(); i++) {
        entries[i].pathOffset = strings.size();
        entries[i].pathLength = meta[i].vfsPath.size();

        strings += meta[i].vfsPath;
    }

    uint32_t entryOffset = -1;
    uint32_t entryLength = entrypointNormalised.size();
    for (size_t i = 0; i < meta.size(); i++) {
        if (meta[i].vfsPath == entrypointNormalised) {
            entryOffset = entries[i].pathOffset;
            break;
        }
    }
    if (entryOffset == -1) {
        return false;
    }
    header.entrypointOffset = entryOffset;
    header.entrypointLength = entryLength;

    header.stringTableOffset = header.fileTableOffset + sizeof(VFSFileEntry) * meta.size();

    header.dataOffset = header.stringTableOffset + strings.size();

    uint64_t dataCursor = 0;

    for (size_t i = 0; i < meta.size(); i++) {
        entries[i].dataOffset = dataCursor;
        entries[i].size = meta[i].size;
        entries[i].mtime = meta[i].mtime;

        dataCursor += meta[i].size;
    }

    // write metadata
    printf("Writing header %I64x\n", (uint64_t)out.tellp());
    out.write((char*)&header, sizeof(header));
    printf("Writing entries %I64x\n", (uint64_t)out.tellp());
    out.write((char*)entries.data(), entries.size() * sizeof(VFSFileEntry));
    printf("Writing string %I64x\n", (uint64_t)out.tellp());
    out.write(strings.data(), strings.size());

    // stream file contents
    std::vector<char> buffer(64 * 1024);

    for (auto& m : meta) {
        std::ifstream file(m.diskPath, std::ios::binary);

        while (file) {
            file.read(buffer.data(), buffer.size());
            out.write(buffer.data(), file.gcount());
        }
    }

    return true;
}

bool vfs_build_bundle(const std::filesystem::path& sourceExePath,
                      const std::filesystem::path& destExePath, const std::filesystem::path& root,
                      const std::string& entrypoint,
                      const std::vector<std::filesystem::path>& files) {
    std::ifstream sourceExe(sourceExePath, std::ios::binary);
    // std::ifstream payload(payloadPath, std::ios::binary);
    std::ofstream destExe(destExePath, std::ios::binary);

    if (!sourceExe || !destExe) return false;

    // Clone base exe
    destExe << sourceExe.rdbuf();

    // Current position is the start of the VFS
    uint64_t payloadOffset = destExe.tellp();
    printf("Payload offset: %" PRIx64 "\n", payloadOffset);

    // Pack payload
    if (!vfs_build_payload(root, files, entrypoint, destExe)) {
        return false;
    }

    // Append a final footer
    VFSFooter footer;
    footer.marker = VFS_MARKER;
    footer.version = VFS_VERSION;
    footer.vfsOffset = payloadOffset;

    destExe.write((const char*)&footer, sizeof(footer));

    return true;
}

static bool get_own_executable(std::string& path) {
#ifdef _WIN32
    char buf[MAX_PATH];
    GetModuleFileNameA(NULL, buf, MAX_PATH);
    path = buf;
    return true;
#else
    Dl_info info;
    if (!dladdr((void*)&get_own_executable, &info)) return false;

    path = info.dli_fname;
    return true;
#endif
}

static VFS_ERROR vfs_locate_payload() {
    std::string path;
    if (!get_own_executable(path)) return kVFS_ERROR_FILE;

#ifdef _WIN32
    g_vfs.file = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                             FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_vfs.file == INVALID_HANDLE_VALUE) return kVFS_ERROR_FILE;

    g_vfs.mapping = CreateFileMappingA(g_vfs.file, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!g_vfs.mapping) return kVFS_ERROR_FILE;

    g_vfs.base = (size_t)MapViewOfFile(g_vfs.mapping, FILE_MAP_READ, 0, 0, 0);
    if (!g_vfs.base) return kVFS_ERROR_FILE;

    LARGE_INTEGER size;
    GetFileSizeEx(g_vfs.file, &size);
    uint64_t fileSize = size.QuadPart;
#else
    g_vfs.file = open(path.c_str(), O_RDONLY);
    if (g_vfs.file < 0) return kVFS_ERROR_FILE;

    struct stat st;
    if (fstat(g_vfs.file, &st) != 0) return kVFS_ERROR_FILE;

    uint64_t fileSize = st.st_size;

    g_vfs.base = (size_t)mmap(NULL, fileSize, PROT_READ, MAP_PRIVATE, g_vfs.file, 0);
    if (g_vfs.base == (size_t)MAP_FAILED) return kVFS_ERROR_FILE;
#endif

    if (fileSize < sizeof(VFSFooter)) return kVFS_ERROR_SIZE;

    uint8_t* fileEnd = (uint8_t*)(g_vfs.base + fileSize);

    VFSFooter* footer = (VFSFooter*)(fileEnd - sizeof(VFSFooter));

    if (footer->marker != VFS_MARKER) return kVFS_ERROR_MARKER;

    if (footer->version != VFS_VERSION) return kVFS_ERROR_VERSION;

    size_t payloadBase = g_vfs.base + footer->vfsOffset;

    VFSHeader* header = (VFSHeader*)payloadBase;

    g_vfs.entries = (VFSFileEntry*)(payloadBase + header->fileTableOffset);
    g_vfs.strings = (char*)(payloadBase + header->stringTableOffset);
    g_vfs.data = (void*)(payloadBase + header->dataOffset);
    g_vfs.fileCount = header->fileCount;

    g_vfs.entrypoint = (char*)(g_vfs.strings + header->entrypointOffset);
    g_vfs.entrypointLength = header->entrypointLength;

    return kVFS_ERROR_OK;
}

void vfs_close() {
#ifdef _WIN32
    if (g_vfs.base) UnmapViewOfFile((void*)(g_vfs.base));
    if (g_vfs.mapping) CloseHandle(g_vfs.mapping);
    if (g_vfs.file) CloseHandle(g_vfs.file);
#else
    if (g_vfs.base) munmap((void*)g_vfs.base, 0);
    if (g_vfs.file >= 0) close(g_vfs.file);
#endif

    g_vfsOpen = false;
}
bool vfs_open() {
    if (g_vfsOpen) return true;

    if (vfs_locate_payload() != kVFS_ERROR_OK) {
        vfs_close();
        return false;
    }
    g_vfsOpen = true;
    return true;
}

const VFSFileEntry* vfs_find_file(const std::string& path) {
    uint32_t left = 0;
    uint32_t right = g_vfs.fileCount;

    while (left < right) {
        uint32_t mid = (left + right) / 2;
        const auto& e = g_vfs.entries[mid];

        std::string_view p(g_vfs.strings + e.pathOffset, e.pathLength);

        int cmp = path.compare(p);

        if (cmp == 0) return &e;

        if (cmp < 0)
            right = mid;
        else
            left = mid + 1;
    }

    return nullptr;
}
std::string_view vfs_get_entrypoint() { return { g_vfs.entrypoint, g_vfs.entrypointLength }; }
std::span<const uint8_t> vfs_read_file(const std::string& path) {
    auto e = vfs_find_file(path);
    if (!e) return {};
    return { (uint8_t*)g_vfs.data + e->dataOffset, (size_t)e->size };
}
uint64_t vfs_get_mtime(const std::string& path) {
    auto e = vfs_find_file(path);
    if (!e) return 0;
    return e->mtime;
}
std::vector<std::string> vfs_list_dir(const std::string& dir) {
    std::vector<std::string> out;

    std::string prefix = dir;
    if (!prefix.empty() && prefix.back() != '/') prefix += '/';

    for (uint32_t i = 0; i < g_vfs.fileCount; i++) {
        const auto& e = g_vfs.entries[i];

        std::string_view p(g_vfs.strings + e.pathOffset, e.pathLength);

        if (p.starts_with(prefix)) out.emplace_back(p);
    }

    return out;
}

bool vfs_is_file(const std::string& path) { return vfs_find_file(path) != nullptr; }

bool vfs_is_dir(const std::string& path) {
    std::string prefix = path;
    if (!prefix.empty() && prefix.back() != '/') prefix += '/';

    for (uint32_t i = 0; i < g_vfs.fileCount; i++) {
        const auto& e = g_vfs.entries[i];
        std::string_view p(g_vfs.strings + e.pathOffset, e.pathLength);
        if (p.starts_with(prefix)) return true;
    }
    return false;
}
