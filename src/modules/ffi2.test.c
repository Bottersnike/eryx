// ffi_test.c
// Build with MSVC:
//   cl /LD ffi_test.c /Fe:ffi_test.dll
//
// Build with clang-cl:
//   clang-cl /LD ffi_test.c /Fe:ffi_test.dll

#define WIN32_LEAN_AND_MEAN
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <windows.h>


#ifdef _MSC_VER
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((dllexport))
#endif

// ------------------------------------------------------------
// Exported data symbols / constants
// ------------------------------------------------------------

EXPORT int32_t ffi_i32_constant = 123456;
EXPORT uint64_t ffi_u64_constant = 0x1122334455667788ULL;
EXPORT double ffi_double_constant = 3.141592653589793;
EXPORT const char* ffi_string_constant = "hello from exported data";
EXPORT int32_t ffi_debug_vararg_count = -1;
EXPORT int32_t ffi_debug_vararg_i0 = -1;
EXPORT int32_t ffi_debug_vararg_i1 = -1;
EXPORT int32_t ffi_debug_vararg_i2 = -1;
EXPORT int32_t ffi_debug_vararg_i3 = -1;

typedef struct Point {
    int32_t x;
    int32_t y;
} Point;

EXPORT Point ffi_point_constant = { 10, 20 };

// ------------------------------------------------------------
// Plain primitive functions
// ------------------------------------------------------------

EXPORT int32_t ffi_add_i32(int32_t a, int32_t b) { return a + b; }

EXPORT uint64_t ffi_add_u64(uint64_t a, uint64_t b) { return a + b; }

EXPORT double ffi_add_double(double a, double b) { return a + b; }

EXPORT int ffi_bool_not(int v) { return !v; }

EXPORT void ffi_noop(void) {}

// ------------------------------------------------------------
// Pointers / out params
// ------------------------------------------------------------

EXPORT void ffi_write_i32(int32_t* out, int32_t value) {
    if (out) {
        *out = value;
    }
}

EXPORT int32_t ffi_read_i32(const int32_t* ptr) { return ptr ? *ptr : -1; }

EXPORT void ffi_swap_i32(int32_t* a, int32_t* b) {
    if (!a || !b) return;

    int32_t tmp = *a;
    *a = *b;
    *b = tmp;
}

EXPORT size_t ffi_sum_i32_array(const int32_t* values, size_t count) {
    size_t total = 0;

    if (!values) return 0;

    for (size_t i = 0; i < count; i++) {
        total += (size_t)values[i];
    }

    return total;
}

// ------------------------------------------------------------
// Strings
// ------------------------------------------------------------

EXPORT size_t ffi_strlen_ascii(const char* s) {
    if (!s) return 0;

    const char* p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

EXPORT const char* ffi_get_static_string(void) { return "static string from function"; }

EXPORT int ffi_streq(const char* a, const char* b) {
    if (!a || !b) return 0;

    while (*a && *b) {
        if (*a != *b) return 0;
        a++;
        b++;
    }

    return *a == *b;
}

// ------------------------------------------------------------
// Structs by value
// ------------------------------------------------------------

typedef struct Pair {
    int32_t a;
    int32_t b;
} Pair;

typedef struct Mixed {
    uint8_t tag;
    // likely padding here
    int32_t count;
    double value;
} Mixed;

typedef struct Vec3 {
    float x;
    float y;
    float z;
} Vec3;

typedef union IntOrFloat {
    int32_t i;
    float f;
} IntOrFloat;

EXPORT Pair ffi_make_pair(int32_t a, int32_t b) {
    Pair p = { a, b };
    return p;
}

EXPORT int32_t ffi_sum_pair_by_value(Pair p) { return p.a + p.b; }

EXPORT Pair ffi_add_pairs_by_value(Pair a, Pair b) {
    Pair r = { a.a + b.a, a.b + b.b };
    return r;
}

EXPORT Mixed ffi_make_mixed(uint8_t tag, int32_t count, double value) {
    Mixed m;
    m.tag = tag;
    m.count = count;
    m.value = value;
    return m;
}

EXPORT double ffi_mixed_score_by_value(Mixed m) {
    return (double)m.tag + (double)m.count + m.value;
}

EXPORT Vec3 ffi_make_vec3(float x, float y, float z) {
    Vec3 v = { x, y, z };
    return v;
}

EXPORT float ffi_dot_vec3_by_value(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

// ------------------------------------------------------------
// Unions
// ------------------------------------------------------------

EXPORT IntOrFloat ffi_make_union_i32(int32_t value) {
    IntOrFloat u;
    u.i = value;
    return u;
}

EXPORT IntOrFloat ffi_make_union_float(float value) {
    IntOrFloat u;
    u.f = value;
    return u;
}

EXPORT int32_t ffi_union_read_i32(IntOrFloat value) { return value.i; }

EXPORT float ffi_union_read_float(IntOrFloat value) { return value.f; }

EXPORT size_t ffi_sizeof_union_int_or_float(void) { return sizeof(IntOrFloat); }

// ------------------------------------------------------------
// Varargs
// ------------------------------------------------------------

EXPORT int32_t ffi_sum_varargs_i32(int count, ...) {
    va_list args;
    int32_t total = 0;

    va_start(args, count);
    for (int i = 0; i < count; ++i)
        total += va_arg(args, int);
    va_end(args);

    return total;
}

EXPORT int64_t ffi_sum_varargs_i64(int count, ...) {
    va_list args;
    int64_t total = 0;

    va_start(args, count);
    for (int i = 0; i < count; ++i)
        total += va_arg(args, long long);
    va_end(args);

    return total;
}

EXPORT double ffi_sum_varargs_double(int count, ...) {
    va_list args;
    double total = 0.0;

    va_start(args, count);
    for (int i = 0; i < count; ++i)
        total += va_arg(args, double);
    va_end(args);

    return total;
}

EXPORT size_t ffi_sum_varargs_strlen(int count, ...) {
    va_list args;
    size_t total = 0;

    va_start(args, count);
    for (int i = 0; i < count; ++i) {
        const char* s = va_arg(args, const char*);
        if (!s) continue;

        const char* p = s;
        while (*p) p++;
        total += (size_t)(p - s);
    }
    va_end(args);

    return total;
}

EXPORT void ffi_capture_varargs_i32_4(int count, ...) {
    va_list args;

    ffi_debug_vararg_count = count;
    ffi_debug_vararg_i0 = -1;
    ffi_debug_vararg_i1 = -1;
    ffi_debug_vararg_i2 = -1;
    ffi_debug_vararg_i3 = -1;

    va_start(args, count);
    if (count > 0) ffi_debug_vararg_i0 = va_arg(args, int);
    if (count > 1) ffi_debug_vararg_i1 = va_arg(args, int);
    if (count > 2) ffi_debug_vararg_i2 = va_arg(args, int);
    if (count > 3) ffi_debug_vararg_i3 = va_arg(args, int);
    va_end(args);
}

// ------------------------------------------------------------
// Packed structs
// ------------------------------------------------------------

#pragma pack(push, 1)
typedef struct Packed {
    uint8_t a;
    uint32_t b;
    uint16_t c;
} Packed;
#pragma pack(pop)

EXPORT Packed ffi_make_packed(uint8_t a, uint32_t b, uint16_t c) {
    Packed p;
    p.a = a;
    p.b = b;
    p.c = c;
    return p;
}

EXPORT uint32_t ffi_sum_packed_by_value(Packed p) { return (uint32_t)p.a + p.b + (uint32_t)p.c; }

EXPORT size_t ffi_sizeof_packed(void) { return sizeof(Packed); }

EXPORT size_t ffi_offsetof_packed_b(void) { return offsetof(Packed, b); }

// ------------------------------------------------------------
// Normal struct layout inspection
// ------------------------------------------------------------

EXPORT size_t ffi_sizeof_pair(void) { return sizeof(Pair); }

EXPORT size_t ffi_sizeof_mixed(void) { return sizeof(Mixed); }

EXPORT size_t ffi_offsetof_mixed_tag(void) { return offsetof(Mixed, tag); }

EXPORT size_t ffi_offsetof_mixed_count(void) { return offsetof(Mixed, count); }

EXPORT size_t ffi_offsetof_mixed_value(void) { return offsetof(Mixed, value); }

// ------------------------------------------------------------
// Callbacks
// ------------------------------------------------------------

typedef int32_t (*BinaryCallback)(int32_t a, int32_t b);

EXPORT int32_t ffi_call_callback(BinaryCallback cb, int32_t a, int32_t b) {
    if (!cb) return -1;
    return cb(a, b);
}

EXPORT int32_t ffi_call_callback_twice(BinaryCallback cb, int32_t a, int32_t b) {
    if (!cb) return -1;
    return cb(a, b) + cb(b, a);
}

// ------------------------------------------------------------
// Win32-ish tests
// ------------------------------------------------------------

EXPORT DWORD ffi_get_current_process_id(void) { return GetCurrentProcessId(); }

EXPORT DWORD ffi_set_last_error_and_return(DWORD code) {
    SetLastError(code);
    return 0;
}

EXPORT DWORD ffi_get_last_error_value(void) { return GetLastError(); }

// ------------------------------------------------------------
// Memory allocation tests
// ------------------------------------------------------------

EXPORT void* ffi_alloc_bytes(size_t size) {
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
}

EXPORT void ffi_free_bytes(void* ptr) {
    if (ptr) {
        HeapFree(GetProcessHeap(), 0, ptr);
    }
}

EXPORT int32_t* ffi_alloc_i32(int32_t value) {
    int32_t* ptr = (int32_t*)HeapAlloc(GetProcessHeap(), 0, sizeof(int32_t));
    if (!ptr) return NULL;

    *ptr = value;
    return ptr;
}

EXPORT void ffi_free_i32(int32_t* ptr) {
    if (ptr) {
        HeapFree(GetProcessHeap(), 0, ptr);
    }
}

// ------------------------------------------------------------
// DLL entry point
// ------------------------------------------------------------

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance;
    (void)reason;
    (void)reserved;
    return TRUE;
}
