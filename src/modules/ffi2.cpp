
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// This magic comment forces import order
#include "module_api.h"
// As does this one
#include <dyncall.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_ffi",
};
LUAU_MODULE_INFO()

#define FFI_TYPE_MT "eryx.ffi.Type"
#define FFI_DATA_MT "eryx.ffi.Data"
#define FFI_LIBRARY_MT "eryx.ffi.Library"

enum class TypeKind {
    Void,
    Primitive,
    Pointer,
    Array,
    Struct,
    Union,
    Function,
};

enum class PrimKind {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    F32,
    F64,
    Char,
};

struct Root {
    virtual ~Root() = default;
    std::vector<std::shared_ptr<Root>> deps;
};

struct MemoryRoot final : Root {
    std::unique_ptr<std::byte[]> bytes;
    size_t size;

    explicit MemoryRoot(size_t n) : bytes(std::make_unique<std::byte[]>(n)), size(n) {
        std::memset(bytes.get(), 0, n);
    }
};

struct StructField {
    std::string name;
    std::shared_ptr<struct FFIType> type;
    size_t offset = 0;

    size_t naturalAlign = 1;
    size_t effectiveAlign = 1;
};

static bool isPowerOfTwo(size_t n) { return n != 0 && (n & (n - 1)) == 0; }
static size_t alignUp(size_t value, size_t align) { return (value + align - 1) & ~(align - 1); }

struct FFIType {
    TypeKind kind;
    size_t size;
    size_t align;
    std::string name;

    PrimKind prim{};

    std::shared_ptr<FFIType> pointee;
    std::shared_ptr<FFIType> element;
    size_t arrayLength = 0;

    std::vector<StructField> fields;
    std::shared_ptr<DCaggr> aggrDesc;

    std::shared_ptr<FFIType> result;
    std::vector<std::shared_ptr<FFIType>> params;
    int callMode = DC_CALL_C_DEFAULT;
    bool variadic = false;

    static std::shared_ptr<FFIType> primitive(PrimKind prim, std::string name, size_t size,
                                              size_t align) {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Primitive;
        t->prim = prim;
        t->name = std::move(name);
        t->size = size;
        t->align = align;
        return t;
    }

    static std::shared_ptr<FFIType> pointer(std::shared_ptr<FFIType> to) {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Pointer;
        t->name = to->name + "*";
        t->size = sizeof(void*);
        t->align = alignof(void*);
        t->pointee = std::move(to);
        return t;
    }

    static std::shared_ptr<FFIType> array(std::shared_ptr<FFIType> elem, size_t n) {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Array;
        t->name = elem->name + "[" + std::to_string(n) + "]";
        t->size = elem->size * n;
        t->align = elem->align;
        t->element = std::move(elem);
        t->arrayLength = n;
        return t;
    }

    static std::shared_ptr<FFIType> voidType() {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Void;
        t->name = "void";
        t->size = 0;
        t->align = 1;
        return t;
    }

    static std::shared_ptr<FFIType> function(std::shared_ptr<FFIType> result,
                                             std::vector<std::shared_ptr<FFIType>> params,
                                             int callMode = DC_CALL_C_DEFAULT,
                                             bool variadic = false) {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Function;
        t->name = "function";
        t->size = sizeof(void*);
        t->align = alignof(void*);
        t->result = std::move(result);
        t->params = std::move(params);
        t->callMode = callMode;
        t->variadic = variadic;
        return t;
    }

    static std::shared_ptr<FFIType> structure(std::vector<StructField> fields,
                                              std::string name = "struct", size_t pack = 0) {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Struct;
        t->name = std::move(name);

        size_t offset = 0;
        size_t maxAlign = 1;

        for (auto& field : fields) {
            size_t natural = field.type->align;
            size_t effective = field.effectiveAlign;

            if (effective == 0) effective = natural;

            if (pack != 0) effective = std::min(effective, pack);

            if (!isPowerOfTwo(effective))
                throw std::runtime_error("struct field alignment must be a power of two");

            offset = alignUp(offset, effective);

            field.offset = offset;
            field.naturalAlign = natural;
            field.effectiveAlign = effective;

            offset += field.type->size;
            maxAlign = std::max(maxAlign, effective);
        }

        t->size = alignUp(offset, maxAlign);
        t->align = maxAlign;
        t->fields = std::move(fields);
        return t;
    }

    static std::shared_ptr<FFIType> unite(std::vector<StructField> fields,
                                          std::string name = "union") {
        auto t = std::make_shared<FFIType>();
        t->kind = TypeKind::Union;
        t->name = std::move(name);

        size_t maxSize = 0;
        size_t maxAlign = 1;

        for (auto& field : fields) {
            field.offset = 0;
            field.naturalAlign = field.type->align;
            field.effectiveAlign = field.type->align;
            maxSize = std::max(maxSize, field.type->size);
            maxAlign = std::max(maxAlign, field.type->align);
        }

        t->size = alignUp(maxSize, maxAlign);
        t->align = maxAlign;
        t->fields = std::move(fields);
        return t;
    }
};

static void freeAggrDesc(DCaggr* aggr) {
    if (aggr) dcFreeAggr(aggr);
}

static DCsigchar primitiveSigChar(PrimKind prim) {
    switch (prim) {
        case PrimKind::I8:
            return DC_SIGCHAR_CHAR;
        case PrimKind::U8:
            return DC_SIGCHAR_UCHAR;
        case PrimKind::I16:
            return DC_SIGCHAR_SHORT;
        case PrimKind::U16:
            return DC_SIGCHAR_USHORT;
        case PrimKind::I32:
            return DC_SIGCHAR_INT;
        case PrimKind::U32:
            return DC_SIGCHAR_UINT;
        case PrimKind::I64:
            return DC_SIGCHAR_LONGLONG;
        case PrimKind::U64:
            return DC_SIGCHAR_ULONGLONG;
        case PrimKind::F32:
            return DC_SIGCHAR_FLOAT;
        case PrimKind::F64:
            return DC_SIGCHAR_DOUBLE;
        case PrimKind::Char:
            return DC_SIGCHAR_CHAR;
    }

    throw std::runtime_error("unsupported primitive kind");
}

static std::shared_ptr<DCaggr> ensureStructAggr(const std::shared_ptr<FFIType>& type);

static void describeAggrField(const std::shared_ptr<FFIType>& type, DCsigchar& sig, DCsize& count,
                              const DCaggr*& nestedAggr) {
    count = 1;
    nestedAggr = nullptr;

    auto current = type;
    while (current->kind == TypeKind::Array) {
        count *= current->arrayLength;
        current = current->element;
    }

    switch (current->kind) {
        case TypeKind::Primitive:
            sig = primitiveSigChar(current->prim);
            return;
        case TypeKind::Pointer:
            sig = DC_SIGCHAR_POINTER;
            return;
        case TypeKind::Struct:
        case TypeKind::Union:
            sig = DC_SIGCHAR_AGGREGATE;
            nestedAggr = ensureStructAggr(current).get();
            return;
        case TypeKind::Array:
        case TypeKind::Void:
        case TypeKind::Function:
            break;
    }

    throw std::runtime_error("unsupported aggregate field type for by-value calls");
}

static std::shared_ptr<DCaggr> ensureStructAggr(const std::shared_ptr<FFIType>& type) {
#ifndef DC__Feature_AggrByVal
    throw std::runtime_error("dyncall aggregate-by-value support is unavailable on this platform");
#else
    if (type->kind != TypeKind::Struct && type->kind != TypeKind::Union)
        throw std::runtime_error("aggregate metadata requires struct or union type");
    if (type->aggrDesc) return type->aggrDesc;

    auto aggr = std::shared_ptr<DCaggr>(dcNewAggr(type->fields.size(), type->size), freeAggrDesc);
    if (!aggr) throw std::runtime_error("failed to allocate dyncall aggregate metadata");

    for (const StructField& field : type->fields) {
        DCsigchar sig;
        DCsize count;
        const DCaggr* nestedAggr;
        describeAggrField(field.type, sig, count, nestedAggr);

        if (sig == DC_SIGCHAR_AGGREGATE)
            dcAggrField(aggr.get(), sig, static_cast<DCint>(field.offset), count, nestedAggr);
        else
            dcAggrField(aggr.get(), sig, static_cast<DCint>(field.offset), count);
    }

    dcCloseAggr(aggr.get());
    type->aggrDesc = aggr;
    return aggr;
#endif
}

struct Bounds {
    void* base = nullptr;
    size_t elementSize = 0;
    size_t length = 0;
    ptrdiff_t index = 0;
};

struct FFIData {
    std::shared_ptr<FFIType> type;

    // Address of this value's storage, or a view into somebody else's storage.
    void* address = nullptr;

    // Keeps address valid.
    std::shared_ptr<Root> root;

    bool writable = true;
    bool ownsMemory = false;

    bool hasBounds = false;
    Bounds bounds;
};

struct LibraryRoot final : Root {
    void* handle = nullptr;
    bool closeable = true;
    bool closed = false;

    ~LibraryRoot() override {
        if (!closeable || !handle || closed) return;

#ifdef _WIN32
        FreeLibrary((HMODULE)handle);
#else
        dlclose(handle);
#endif
    }
};

struct FFILibrary {
    std::shared_ptr<LibraryRoot> root;
    std::string path;
};

static bool isAggregateType(const std::shared_ptr<FFIType>& type) {
    return type->kind == TypeKind::Array || type->kind == TypeKind::Struct ||
           type->kind == TypeKind::Union;
}

static bool isIntegralPrimitive(PrimKind prim) {
    switch (prim) {
        case PrimKind::I8:
        case PrimKind::U8:
        case PrimKind::I16:
        case PrimKind::U16:
        case PrimKind::Char:
        case PrimKind::I32:
        case PrimKind::U32:
        case PrimKind::I64:
        case PrimKind::U64:
            return true;
        case PrimKind::F32:
        case PrimKind::F64:
            return false;
    }

    return false;
}

static bool rootHasClosedLibrary(const std::shared_ptr<Root>& root) {
    if (!root) return false;

    if (auto lib = std::dynamic_pointer_cast<LibraryRoot>(root))
        return lib->closed || !lib->handle;

    for (const auto& dep : root->deps) {
        if (rootHasClosedLibrary(dep)) return true;
    }

    return false;
}

static void ensureRootAccessible(lua_State* L, const std::shared_ptr<Root>& root) {
    if (rootHasClosedLibrary(root)) luaL_error(L, "value depends on a closed library");
}

static void ensureDataAccessible(lua_State* L, const std::shared_ptr<FFIData>& d) {
    ensureRootAccessible(L, d->root);
}

static int64_t luaL_checkwholeinteger64(lua_State* L, int idx) {
    if (lua_isinteger64(L, idx)) return lua_tointeger64(L, idx, nullptr);

    int isnum = 0;
    lua_Number n = lua_tonumberx(L, idx, &isnum);
    if (!isnum) luaL_typeerror(L, idx, "number");

    if (!std::isfinite(n) || std::trunc(n) != n)
        luaL_argerror(L, idx, "integer or whole number expected");

    constexpr lua_Number kMin = static_cast<lua_Number>(std::numeric_limits<int64_t>::min());
    constexpr lua_Number kMax = static_cast<lua_Number>(std::numeric_limits<int64_t>::max());
    if (n < kMin || n > kMax) luaL_argerror(L, idx, "integer out of 64-bit range");

    return static_cast<int64_t>(n);
}

static uint64_t luaL_checkwholeunsigned64(lua_State* L, int idx) {
    int64_t value = luaL_checkwholeinteger64(L, idx);
    if (value < 0) luaL_argerror(L, idx, "non-negative integer expected");
    return static_cast<uint64_t>(value);
}

static size_t luaL_checkwholesize(lua_State* L, int idx) {
    uint64_t value = luaL_checkwholeunsigned64(L, idx);
    if (value > std::numeric_limits<size_t>::max())
        luaL_argerror(L, idx, "value out of range for size_t");
    return static_cast<size_t>(value);
}

static ptrdiff_t luaL_checkwholeptrdiff(lua_State* L, int idx) {
    int64_t value = luaL_checkwholeinteger64(L, idx);
    if (value < std::numeric_limits<ptrdiff_t>::min() ||
        value > std::numeric_limits<ptrdiff_t>::max())
        luaL_argerror(L, idx, "value out of range for ptrdiff_t");
    return static_cast<ptrdiff_t>(value);
}

static FFIType** checkTypeBox(lua_State* L, int idx) {
    return static_cast<FFIType**>(luaL_checkudata(L, idx, FFI_TYPE_MT));
}

static FFIData** checkDataBox(lua_State* L, int idx) {
    return static_cast<FFIData**>(luaL_checkudata(L, idx, FFI_DATA_MT));
}

static std::shared_ptr<FFIType> checkType(lua_State* L, int idx) {
    auto box = static_cast<std::shared_ptr<FFIType>*>(luaL_checkudata(L, idx, FFI_TYPE_MT));
    return *box;
}

static std::shared_ptr<FFIData> checkData(lua_State* L, int idx) {
    auto box = static_cast<std::shared_ptr<FFIData>*>(luaL_checkudata(L, idx, FFI_DATA_MT));
    return *box;
}

static void type_dtor(void* ud) {
    auto box = static_cast<std::shared_ptr<FFIType>*>(ud);
    box->~shared_ptr<FFIType>();
}

static void data_dtor(void* ud) {
    auto box = static_cast<std::shared_ptr<FFIData>*>(ud);
    box->~shared_ptr<FFIData>();
}

static void pushType(lua_State* L, std::shared_ptr<FFIType> t) {
    void* ud = lua_newuserdatadtor(L, sizeof(std::shared_ptr<FFIType>), type_dtor);
    new (ud) std::shared_ptr<FFIType>(std::move(t));

    luaL_getmetatable(L, FFI_TYPE_MT);
    lua_setmetatable(L, -2);
}

static void pushData(lua_State* L, std::shared_ptr<FFIData> d) {
    void* ud = lua_newuserdatadtor(L, sizeof(std::shared_ptr<FFIData>), data_dtor);
    new (ud) std::shared_ptr<FFIData>(std::move(d));

    luaL_getmetatable(L, FFI_DATA_MT);
    lua_setmetatable(L, -2);
}

static std::shared_ptr<MemoryRoot> makeMemory(size_t size) {
    return std::make_shared<MemoryRoot>(size);
}

static std::shared_ptr<FFIData> makeOwned(std::shared_ptr<FFIType> type) {
    if (type->kind == TypeKind::Void) throw std::runtime_error("cannot allocate void");

    auto root = makeMemory(type->size);

    auto d = std::make_shared<FFIData>();
    d->type = std::move(type);
    d->address = root->bytes.get();
    d->root = root;
    d->ownsMemory = true;
    return d;
}

static std::shared_ptr<FFIData> makeView(std::shared_ptr<FFIType> type, void* address,
                                         std::shared_ptr<Root> root, bool writable = true) {
    auto d = std::make_shared<FFIData>();
    d->type = std::move(type);
    d->address = address;
    d->root = std::move(root);
    d->writable = writable;
    d->ownsMemory = false;
    return d;
}

static std::shared_ptr<FFIData> makePointerTo(std::shared_ptr<FFIData> target) {
    std::shared_ptr<FFIType> pointeeType;

    if (target->type->kind == TypeKind::Array)
        pointeeType = target->type->element;
    else
        pointeeType = target->type;

    auto ptrType = FFIType::pointer(pointeeType);
    auto root = makeMemory(sizeof(void*));

    // Store actual pointer value.
    *reinterpret_cast<void**>(root->bytes.get()) = target->address;

    // Pointer storage keeps pointee/root alive.
    if (target->root) root->deps.push_back(target->root);

    auto d = std::make_shared<FFIData>();
    d->type = ptrType;
    d->address = root->bytes.get();
    d->root = root;
    d->ownsMemory = true;

    if (target->type->kind == TypeKind::Array) {
        d->hasBounds = true;
        d->bounds.base = target->address;
        d->bounds.elementSize = target->type->element->size;
        d->bounds.length = target->type->arrayLength;
        d->bounds.index = 0;
    } else {
        d->hasBounds = true;
        d->bounds.base = target->address;
        d->bounds.elementSize = target->type->size;
        d->bounds.length = 1;
        d->bounds.index = 0;
    }

    return d;
}

static void initValueFromLua(lua_State* L, std::shared_ptr<FFIData> d, int idx);
static void writeDataFromLua(lua_State* L, const std::shared_ptr<FFIData>& d, int valueIndex);

static void assignValueFromLua(lua_State* L, std::shared_ptr<FFIData> d, int idx) {
    if (isAggregateType(d->type))
        initValueFromLua(L, std::move(d), idx);
    else
        writeDataFromLua(L, d, idx);
}

static int pushDataAsLuaValue(lua_State* L, const std::shared_ptr<FFIData>& d) {
    ensureDataAccessible(L, d);

    if (d->type->kind == TypeKind::Pointer) {
        void* p = *reinterpret_cast<void**>(d->address);
        lua_pushinteger64(L, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(p)));
        return 1;
    }

    if (d->type->kind == TypeKind::Primitive) {
        switch (d->type->prim) {
            case PrimKind::I8:
                lua_pushinteger(L, *reinterpret_cast<int8_t*>(d->address));
                return 1;
            case PrimKind::U8:
                lua_pushinteger(L, *reinterpret_cast<uint8_t*>(d->address));
                return 1;
            case PrimKind::I16:
                lua_pushinteger(L, *reinterpret_cast<int16_t*>(d->address));
                return 1;
            case PrimKind::U16:
                lua_pushinteger(L, *reinterpret_cast<uint16_t*>(d->address));
                return 1;
            case PrimKind::I32:
                lua_pushinteger(L, *reinterpret_cast<int32_t*>(d->address));
                return 1;
            case PrimKind::U32:
                lua_pushinteger(L, *reinterpret_cast<uint32_t*>(d->address));
                return 1;
            case PrimKind::I64:
                lua_pushinteger64(L, *reinterpret_cast<int64_t*>(d->address));
                return 1;
            case PrimKind::U64:
                lua_pushinteger64(L, *reinterpret_cast<uint64_t*>(d->address));
                return 1;
            case PrimKind::F32:
                lua_pushnumber(L, *reinterpret_cast<float*>(d->address));
                return 1;
            case PrimKind::F64:
                lua_pushnumber(L, *reinterpret_cast<double*>(d->address));
                return 1;
            case PrimKind::Char:
                lua_pushinteger(L, *reinterpret_cast<char*>(d->address));
                return 1;
        }
    }

    if (d->type->kind == TypeKind::Array) {
        lua_createtable(L, static_cast<int>(d->type->arrayLength), 0);

        for (size_t i = 0; i < d->type->arrayLength; ++i) {
            void* addr = static_cast<std::byte*>(d->address) + i * d->type->element->size;
            auto elem = makeView(d->type->element, addr, d->root, d->writable);
            pushDataAsLuaValue(L, elem);
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }

        return 1;
    }

    if (d->type->kind == TypeKind::Struct || d->type->kind == TypeKind::Union) {
        lua_createtable(L, 0, static_cast<int>(d->type->fields.size()));

        for (const StructField& field : d->type->fields) {
            void* addr = static_cast<std::byte*>(d->address) + field.offset;
            auto view = makeView(field.type, addr, d->root, d->writable);
            pushDataAsLuaValue(L, view);
            lua_setfield(L, -2, field.name.c_str());
        }

        return 1;
    }

    luaL_error(L, "cannot convert value of type '%s' to Lua", d->type->name.c_str());
    return -1;
}

static int dataRead(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);

    if (d->type->kind == TypeKind::Pointer) {
        void* p = *reinterpret_cast<void**>(d->address);
        lua_pushinteger64(L, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(p)));
        return 1;
    }

    if (d->type->kind != TypeKind::Primitive) {
        luaL_error(L, "read() is only implemented for primitives and pointers");
        return -1;
    }

    switch (d->type->prim) {
        case PrimKind::I8:
            lua_pushinteger(L, *reinterpret_cast<int8_t*>(d->address));
            return 1;
        case PrimKind::U8:
            lua_pushinteger(L, *reinterpret_cast<uint8_t*>(d->address));
            return 1;
        case PrimKind::I16:
            lua_pushinteger(L, *reinterpret_cast<int16_t*>(d->address));
            return 1;
        case PrimKind::U16:
            lua_pushinteger(L, *reinterpret_cast<uint16_t*>(d->address));
            return 1;
        case PrimKind::I32:
            lua_pushinteger(L, *reinterpret_cast<int32_t*>(d->address));
            return 1;
        case PrimKind::U32:
            lua_pushinteger(L, *reinterpret_cast<uint32_t*>(d->address));
            return 1;
        case PrimKind::I64:
            lua_pushinteger64(L, *reinterpret_cast<int64_t*>(d->address));
            return 1;
        case PrimKind::U64:
            lua_pushinteger64(L, *reinterpret_cast<uint64_t*>(d->address));
            return 1;
        case PrimKind::F32:
            lua_pushnumber(L, *reinterpret_cast<float*>(d->address));
            return 1;
        case PrimKind::F64:
            lua_pushnumber(L, *reinterpret_cast<double*>(d->address));
            return 1;
        case PrimKind::Char:
            lua_pushinteger(L, *reinterpret_cast<char*>(d->address));
            return 1;
    }

    luaL_error(L, "unsupported primitive");
    return -1;
}

static void* luaL_testudata(lua_State* L, int ud, const char* tname) {
    if (!lua_isuserdata(L, ud)) return NULL;

    void* p = lua_touserdata(L, ud);
    if (p == NULL) return NULL;

    if (!lua_getmetatable(L, ud)) return NULL;

    lua_getfield(L, LUA_REGISTRYINDEX, tname);
    int ok = lua_rawequal(L, -1, -2);
    lua_pop(L, 2);

    return ok ? p : NULL;
}

static void writeDataFromLua(lua_State* L, const std::shared_ptr<FFIData>& d, int valueIndex) {
    if (!d->writable) luaL_error(L, "value is not writable");
    ensureDataAccessible(L, d);

    valueIndex = lua_absindex(L, valueIndex);

    if (d->type->kind == TypeKind::Pointer) {
        if (lua_isnil(L, valueIndex)) {
            *reinterpret_cast<void**>(d->address) = nullptr;
            return;
        }

        if (luaL_testudata(L, valueIndex, FFI_DATA_MT)) {
            auto src = checkData(L, valueIndex);

            if (src->type->kind != TypeKind::Pointer) luaL_error(L, "expected pointer value");

            *reinterpret_cast<void**>(d->address) = *reinterpret_cast<void**>(src->address);

            return;
        }

        auto addr = static_cast<uintptr_t>(luaL_checkwholeunsigned64(L, valueIndex));
        *reinterpret_cast<void**>(d->address) = reinterpret_cast<void*>(addr);
        return;
    }

    if (d->type->kind != TypeKind::Primitive)
        luaL_error(L, "write() is only implemented for primitives and pointers");

    switch (d->type->prim) {
        case PrimKind::I8:
            *reinterpret_cast<int8_t*>(d->address) =
                static_cast<int8_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::U8:
            *reinterpret_cast<uint8_t*>(d->address) =
                static_cast<uint8_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::I16:
            *reinterpret_cast<int16_t*>(d->address) =
                static_cast<int16_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::U16:
            *reinterpret_cast<uint16_t*>(d->address) =
                static_cast<uint16_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::I32:
            *reinterpret_cast<int32_t*>(d->address) =
                static_cast<int32_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::U32:
            *reinterpret_cast<uint32_t*>(d->address) =
                static_cast<uint32_t>(luaL_checkinteger(L, valueIndex));
            return;

        case PrimKind::I64:
            *reinterpret_cast<int64_t*>(d->address) =
                luaL_checkwholeinteger64(L, valueIndex);
            return;

        case PrimKind::U64:
            *reinterpret_cast<uint64_t*>(d->address) =
                luaL_checkwholeunsigned64(L, valueIndex);
            return;

        case PrimKind::F32:
            *reinterpret_cast<float*>(d->address) =
                static_cast<float>(luaL_checknumber(L, valueIndex));
            return;

        case PrimKind::F64:
            *reinterpret_cast<double*>(d->address) = luaL_checknumber(L, valueIndex);
            return;

        case PrimKind::Char:
            *reinterpret_cast<char*>(d->address) =
                static_cast<char>(luaL_checkinteger(L, valueIndex));
            return;
    }

    luaL_error(L, "unsupported primitive");
}

static int dataWrite(lua_State* L) {
    auto d = checkData(L, 1);
    writeDataFromLua(L, d, 2);
    return 0;
}

static int dataType(lua_State* L) {
    auto d = checkData(L, 1);
    pushType(L, d->type);
    return 1;
}

static int dataBytes(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    lua_pushlstring(L, static_cast<const char*>(d->address), d->type->size);
    return 1;
}

static int dataBuffer(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    void* out = lua_newbuffer(L, d->type->size);
    if (d->type->size != 0) std::memcpy(out, d->address, d->type->size);
    return 1;
}

static int dataAsArray(lua_State* L) {
    auto d = checkData(L, 1);

    if (d->type->kind != TypeKind::Array) {
        luaL_error(L, "asarray() requires array");
        return -1;
    }

    return pushDataAsLuaValue(L, d);
}

static int dataAsDict(lua_State* L) {
    auto d = checkData(L, 1);

    if (d->type->kind != TypeKind::Struct && d->type->kind != TypeKind::Union) {
        luaL_error(L, "asdict() requires struct or union");
        return -1;
    }

    return pushDataAsLuaValue(L, d);
}

static int dataPtr(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    pushData(L, makePointerTo(d));
    return 1;
}

static int dataIsNull(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);

    if (d->type->kind != TypeKind::Pointer) {
        luaL_error(L, "isNull() requires pointer");
        return -1;
    }

    void* p = *reinterpret_cast<void**>(d->address);
    lua_pushboolean(L, p == nullptr);
    return 1;
}

static int dataDeref(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);

    if (d->type->kind != TypeKind::Pointer) {
        luaL_error(L, "deref() requires pointer");
        return -1;
    }

    void* p = *reinterpret_cast<void**>(d->address);

    if (!p) {
        luaL_error(L, "null pointer dereference");
        return -1;
    }

    auto pointee = d->type->pointee;

    if (d->hasBounds) {
        if (d->bounds.index < 0 || static_cast<size_t>(d->bounds.index) >= d->bounds.length) {
            luaL_error(L, "pointer dereference out of bounds");
            return -1;
        }
    }

    // View inherits root from pointer storage.
    // This means pointer-to-pointer chains stay alive.
    auto view = makeView(pointee, p, d->root, true);
    pushData(L, view);
    return 1;
}

static int dataOffset(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    auto offset = luaL_checkwholeptrdiff(L, 2);

    if (d->type->kind != TypeKind::Pointer) {
        luaL_error(L, "offset() requires pointer");
        return -1;
    }

    auto pointee = d->type->pointee;
    if (pointee->kind == TypeKind::Void) {
        luaL_error(L, "cannot offset void pointer");
        return -1;
    }

    void* current = *reinterpret_cast<void**>(d->address);
    auto next = static_cast<std::byte*>(current) + offset * pointee->size;

    if (d->hasBounds) {
        ptrdiff_t newIndex = d->bounds.index + offset;
        if (newIndex < 0 || static_cast<size_t>(newIndex) >= d->bounds.length) {
            luaL_error(L, "pointer offset out of bounds");
            return -1;
        }
    }

    auto root = makeMemory(sizeof(void*));
    *reinterpret_cast<void**>(root->bytes.get()) = next;

    // Offset pointer keeps previous pointer root alive.
    if (d->root) root->deps.push_back(d->root);

    auto out = std::make_shared<FFIData>();
    out->type = d->type;
    out->address = root->bytes.get();
    out->root = root;
    out->ownsMemory = true;

    if (d->hasBounds) {
        out->hasBounds = true;
        out->bounds = d->bounds;
        out->bounds.index += offset;
    }

    pushData(L, out);
    return 1;
}

static int dataLength(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);

    if (d->type->kind != TypeKind::Array) {
        luaL_error(L, "length() requires array");
        return -1;
    }

    lua_pushinteger64(L, static_cast<uint64_t>(d->type->arrayLength));
    return 1;
}

static int dataGet(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    auto index = luaL_checkwholesize(L, 2);

    if (d->type->kind != TypeKind::Array) {
        luaL_error(L, "get() requires array");
        return -1;
    }

    if (index >= d->type->arrayLength) {
        luaL_error(L, "array index out of bounds");
        return -1;
    }

    auto elem = d->type->element;
    void* addr = static_cast<std::byte*>(d->address) + index * elem->size;

    auto view = makeView(elem, addr, d->root, d->writable);
    pushData(L, view);
    return 1;
}

static int dataSet(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    auto index = luaL_checkwholesize(L, 2);

    if (d->type->kind != TypeKind::Array) {
        luaL_error(L, "set() requires array");
        return -1;
    }

    if (index >= d->type->arrayLength) {
        luaL_error(L, "array index out of bounds");
        return -1;
    }

    auto elem = d->type->element;
    void* addr = static_cast<std::byte*>(d->address) + index * elem->size;

    auto view = makeView(elem, addr, d->root, d->writable);
    assignValueFromLua(L, view, 3);
    return 0;
}

static void initValueFromLua(lua_State* L, std::shared_ptr<FFIData> d, int idx) {
    if (lua_isnoneornil(L, idx)) return;

    idx = lua_absindex(L, idx);

    if (d->type->kind == TypeKind::Primitive || d->type->kind == TypeKind::Pointer) {
        writeDataFromLua(L, d, idx);
        return;
    }

    if (d->type->kind == TypeKind::Array) {
        luaL_checktype(L, idx, LUA_TTABLE);

        for (size_t i = 0; i < d->type->arrayLength; i++) {
            lua_rawgeti(L, idx, static_cast<int>(i + 1));

            if (!lua_isnil(L, -1)) {
                void* addr = static_cast<std::byte*>(d->address) + i * d->type->element->size;

                auto elem = makeView(d->type->element, addr, d->root, true);
                assignValueFromLua(L, elem, -1);
            }

            lua_pop(L, 1);
        }

        return;
    }

    if (d->type->kind == TypeKind::Struct || d->type->kind == TypeKind::Union) {
        luaL_checktype(L, idx, LUA_TTABLE);

        for (const StructField& field : d->type->fields) {
            lua_getfield(L, idx, field.name.c_str());

            if (!lua_isnil(L, -1)) {
                void* addr = static_cast<std::byte*>(d->address) + field.offset;
                auto view = makeView(field.type, addr, d->root, true);
                assignValueFromLua(L, view, -1);
            }

            lua_pop(L, 1);
        }

        return;
    }

    luaL_error(L, "initializer not implemented for this type");
}

static int cNew(lua_State* L) {
    auto type = checkType(L, 1);

    try {
        auto d = makeOwned(type);

        if (type->kind == TypeKind::Array) {
            d->hasBounds = true;
            d->bounds.base = d->address;
            d->bounds.elementSize = type->element->size;
            d->bounds.length = type->arrayLength;
            d->bounds.index = 0;
        }

        initValueFromLua(L, d, 2);
        pushData(L, d);
        return 1;
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
        return -1;
    }
}

static int cPtrType(lua_State* L) {
    auto t = checkType(L, 1);
    pushType(L, FFIType::pointer(t));
    return 1;
}

static int cArrayType(lua_State* L) {
    auto elem = checkType(L, 1);
    auto n = luaL_checkwholesize(L, 2);

    if (n == 0) {
        luaL_error(L, "array length must be greater than zero");
        return -1;
    }

    pushType(L, FFIType::array(elem, n));
    return 1;
}

static int cString(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);

    auto charType = FFIType::primitive(PrimKind::Char, "char", sizeof(char), alignof(char));
    auto arrType = FFIType::array(charType, len + 1);
    auto d = makeOwned(arrType);

    std::memcpy(d->address, s, len);
    static_cast<char*>(d->address)[len] = '\0';

    d->hasBounds = true;
    d->bounds.base = d->address;
    d->bounds.elementSize = sizeof(char);
    d->bounds.length = len + 1;
    d->bounds.index = 0;

    pushData(L, d);
    return 1;
}

static void setFieldType(lua_State* L, const char* name, std::shared_ptr<FFIType> t) {
    pushType(L, std::move(t));
    lua_setfield(L, -2, name);
}

static void library_dtor(void* ud) {
    auto box = static_cast<std::shared_ptr<FFILibrary>*>(ud);
    box->~shared_ptr<FFILibrary>();
}

static std::shared_ptr<FFILibrary> checkLibrary(lua_State* L, int idx) {
    auto box = static_cast<std::shared_ptr<FFILibrary>*>(luaL_checkudata(L, idx, FFI_LIBRARY_MT));
    return *box;
}

static void pushLibrary(lua_State* L, std::shared_ptr<FFILibrary> lib) {
    void* ud = lua_newuserdatadtor(L, sizeof(std::shared_ptr<FFILibrary>), library_dtor);
    new (ud) std::shared_ptr<FFILibrary>(std::move(lib));

    luaL_getmetatable(L, FFI_LIBRARY_MT);
    lua_setmetatable(L, -2);
}

static bool stringEndsWith(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.substr(s.size() - suffix.size()) == suffix;
}

static bool hasPathSeparator(std::string_view s) {
    return s.find('/') != std::string_view::npos || s.find('\\') != std::string_view::npos;
}

static std::vector<std::string> libraryCandidates(std::string_view name) {
    std::vector<std::string> out;
    out.emplace_back(name);

    if (hasPathSeparator(name)) return out;

    bool hasLibPrefix = name.size() >= 3 && name.substr(0, 3) == "lib";

#ifdef _WIN32
    if (!stringEndsWith(name, ".dll")) out.push_back(std::string(name) + ".dll");
    if (!stringEndsWith(name, ".dll") && !stringEndsWith(name, ".DLL") && !hasLibPrefix)
        out.push_back("lib" + std::string(name) + ".dll");
#elif __APPLE__
    if (!stringEndsWith(name, ".dylib"))
        out.push_back((hasLibPrefix ? std::string(name) : "lib" + std::string(name)) + ".dylib");
    if (!stringEndsWith(name, ".so"))
        out.push_back((hasLibPrefix ? std::string(name) : "lib" + std::string(name)) + ".so");
#else
    if (!stringEndsWith(name, ".so"))
        out.push_back((hasLibPrefix ? std::string(name) : "lib" + std::string(name)) + ".so");
#endif

    return out;
}

static void* openLibraryHandle(const char* path) {
#ifdef _WIN32
    return (void*)LoadLibraryA(path);
#else
    return dlopen(path, RTLD_LAZY | RTLD_LOCAL);
#endif
}

static void* processHandle() {
#ifdef _WIN32
    return (void*)GetModuleHandleA(nullptr);
#else
    return dlopen(nullptr, RTLD_LAZY);
#endif
}

static void* resolveSymbol(void* handle, const char* name) {
#ifdef _WIN32
    return (void*)GetProcAddress((HMODULE)handle, name);
#else
    dlerror();
    return dlsym(handle, name);
#endif
}

static std::string lastDlError() {
#ifdef _WIN32
    DWORD code = GetLastError();
    if (code == 0) return "dynamic library error";

    LPSTR message = nullptr;
    DWORD size = FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                    FORMAT_MESSAGE_IGNORE_INSERTS,
                                nullptr, code,
                                MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&message, 0,
                                nullptr);

    std::string text = (size != 0 && message) ? std::string(message, size) : "dynamic library error";
    if (message) LocalFree(message);

    while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) text.pop_back();

    return text;
#else
    const char* e = dlerror();
    return e ? e : "dynamic library error";
#endif
}

static int ffiOpen(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    std::string loadedPath = path;
    void* handle = nullptr;

    for (const std::string& candidate : libraryCandidates(path)) {
        handle = openLibraryHandle(candidate.c_str());
        if (handle) {
            loadedPath = candidate;
            break;
        }
    }

    if (!handle) {
        std::string err = lastDlError();
        luaL_error(L, "failed to open library '%s': %s", path, err.c_str());
        return -1;
    }

    auto root = std::make_shared<LibraryRoot>();
    root->handle = handle;
    root->closeable = true;

    auto lib = std::make_shared<FFILibrary>();
    lib->root = root;
    lib->path = std::move(loadedPath);

    pushLibrary(L, lib);
    return 1;
}

static int libraryGet(lua_State* L) {
    auto lib = checkLibrary(L, 1);
    const char* name = luaL_checkstring(L, 2);
    auto type = checkType(L, 3);

    if (!lib->root || !lib->root->handle || lib->root->closed) {
        luaL_error(L, "library is closed");
        return -1;
    }

    void* sym = resolveSymbol(lib->root->handle, name);
    if (!sym) {
        std::string err = lastDlError();
        luaL_error(L, "failed to resolve symbol '%s': %s", name, err.c_str());
        return -1;
    }

    auto d = makeView(type, sym, lib->root, type->kind != TypeKind::Function);

    pushData(L, d);
    return 1;
}

static int libraryClose(lua_State* L) {
    auto lib = checkLibrary(L, 1);

    if (!lib->root->closeable) {
        luaL_error(L, "cannot close process library");
        return -1;
    }

    if (!lib->root->closed && lib->root->handle) {
#ifdef _WIN32
        FreeLibrary((HMODULE)lib->root->handle);
#else
        dlclose(lib->root->handle);
#endif
        lib->root->closed = true;
        lib->root->handle = nullptr;
    }

    return 0;
}

static int libraryIsOpen(lua_State* L) {
    auto lib = checkLibrary(L, 1);
    lua_pushboolean(L, lib->root && lib->root->handle && !lib->root->closed);
    return 1;
}

static int library_tostring(lua_State* L) {
    auto lib = checkLibrary(L, 1);
    const char* state = (lib->root && lib->root->handle && !lib->root->closed) ? "open" : "closed";
    lua_pushfstring(L, "Library(%s, %s)", lib->path.c_str(), state);
    return 1;
}

static void createLibraryMt(lua_State* L) {
    luaL_newmetatable(L, FFI_LIBRARY_MT);

    lua_pushcfunction(L, library_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    lua_newtable(L);

    lua_pushcfunction(L, libraryGet, "get");
    lua_setfield(L, -2, "get");

    lua_pushcfunction(L, libraryClose, "close");
    lua_setfield(L, -2, "close");

    lua_pushcfunction(L, libraryIsOpen, "isOpen");
    lua_setfield(L, -2, "isOpen");

    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);
}

static int cFuncType(lua_State* L) {
    auto result = checkType(L, 1);

    luaL_checktype(L, 2, LUA_TTABLE);

    std::vector<std::shared_ptr<FFIType>> params;
    int callMode = DC_CALL_C_DEFAULT;
    bool variadic = false;

    auto parseMode = [&](const char* mode) -> bool {
        if (strcmp(mode, "default") == 0)
            callMode = DC_CALL_C_DEFAULT;
        else if (strcmp(mode, "cdecl") == 0)
            callMode = DC_CALL_C_X86_CDECL;
        else if (strcmp(mode, "stdcall") == 0)
            callMode = DC_CALL_C_X86_WIN32_STD;
        else if (strcmp(mode, "fastcall_ms") == 0)
            callMode = DC_CALL_C_X86_WIN32_FAST_MS;
        else if (strcmp(mode, "fastcall_gnu") == 0)
            callMode = DC_CALL_C_X86_WIN32_FAST_GNU;
        else
            return false;

        return true;
    };

    auto parseOptions = [&](int idx) -> bool {
        if (lua_isnoneornil(L, idx)) return true;

        if (lua_isstring(L, idx)) {
            const char* mode = lua_tostring(L, idx);
            if (!parseMode(mode)) {
                luaL_error(L, "unknown calling convention '%s'", mode);
                return false;
            }
            return true;
        }

        if (!lua_istable(L, idx)) return true;

        lua_getfield(L, idx, "convention");
        if (lua_isstring(L, -1)) {
            const char* mode = lua_tostring(L, -1);
            if (!parseMode(mode)) {
                luaL_error(L, "unknown calling convention '%s'", mode);
                return false;
            }
        } else if (!lua_isnil(L, -1)) {
            luaL_error(L, "function convention must be a string");
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, idx, "varargs");
        if (lua_isboolean(L, -1))
            variadic = lua_toboolean(L, -1);
        else if (!lua_isnil(L, -1)) {
            luaL_error(L, "function varargs flag must be a boolean");
            return false;
        }
        lua_pop(L, 1);

        return true;
    };

    if (!parseOptions(3) || !parseOptions(4)) return -1;

    int n = (int)lua_objlen(L, 2);
    params.reserve(n);

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        params.push_back(checkType(L, -1));
        lua_pop(L, 1);
    }

    if (variadic && callMode != DC_CALL_C_DEFAULT && callMode != DC_CALL_C_X86_CDECL) {
        luaL_error(L, "varargs currently only support default/cdecl calling conventions");
        return -1;
    }

    pushType(L, FFIType::function(result, std::move(params), callMode, variadic));
    return 1;
}

static int cStructType(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    std::string name = "struct";
    size_t pack = 0;  // 0 = natural machine layout

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "name");
        if (lua_isstring(L, -1)) name = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "pack");
        if (!lua_isnil(L, -1)) {
            pack = luaL_checkwholesize(L, -1);
            if (!isPowerOfTwo(pack)) {
                luaL_error(L, "struct pack must be a power of two");
                return -1;
            }
        }
        lua_pop(L, 1);
    } else if (lua_isstring(L, 2)) {
        name = lua_tostring(L, 2);
    }

    std::vector<StructField> fields;

    int n = (int)lua_objlen(L, 1);
    fields.reserve(n);

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_rawgeti(L, -1, 1);
        const char* fieldName = luaL_checkstring(L, -1);
        lua_pop(L, 1);

        lua_rawgeti(L, -1, 2);
        auto fieldType = checkType(L, -1);
        lua_pop(L, 1);

        size_t fieldAlign = 0;  // 0 = natural

        lua_getfield(L, -1, "align");
        if (!lua_isnil(L, -1)) {
            fieldAlign = luaL_checkwholesize(L, -1);
            if (!isPowerOfTwo(fieldAlign)) {
                luaL_error(L, "field align must be a power of two");
                return -1;
            }
        }
        lua_pop(L, 1);

        fields.push_back(StructField{
            fieldName,
            fieldType,
            0,
            fieldType->align,
            fieldAlign,
        });

        lua_pop(L, 1);
    }

    try {
        pushType(L, FFIType::structure(std::move(fields), std::move(name), pack));
        return 1;
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
        return -1;
    }
}

static const StructField* findField(const FFIType& type, const std::string& name) {
    for (const auto& field : type.fields) {
        if (field.name == name) return &field;
    }
    return nullptr;
}

static int dataStructGet(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    const char* name = luaL_checkstring(L, 2);

    if (d->type->kind != TypeKind::Struct && d->type->kind != TypeKind::Union) {
        luaL_error(L, "getField() requires struct or union");
        return -1;
    }

    const StructField* field = findField(*d->type, name);
    if (!field) {
        luaL_error(L, "unknown struct field '%s'", name);
        return -1;
    }

    void* addr = static_cast<std::byte*>(d->address) + field->offset;
    auto view = makeView(field->type, addr, d->root, d->writable);

    pushData(L, view);
    return 1;
}

static int dataStructSet(lua_State* L) {
    auto d = checkData(L, 1);
    ensureDataAccessible(L, d);
    const char* name = luaL_checkstring(L, 2);

    if (d->type->kind != TypeKind::Struct && d->type->kind != TypeKind::Union) {
        luaL_error(L, "setField() requires struct or union");
        return -1;
    }

    const StructField* field = findField(*d->type, name);
    if (!field) {
        luaL_error(L, "unknown struct field '%s'", name);
        return -1;
    }

    void* addr = static_cast<std::byte*>(d->address) + field->offset;
    auto view = makeView(field->type, addr, d->root, d->writable);

    assignValueFromLua(L, view, 3);
    return 0;
}

static int cUnionType(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    std::string name = "union";

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "name");
        if (lua_isstring(L, -1)) name = lua_tostring(L, -1);
        lua_pop(L, 1);
    } else if (lua_isstring(L, 2)) {
        name = lua_tostring(L, 2);
    }

    std::vector<StructField> fields;

    int n = (int)lua_objlen(L, 1);
    fields.reserve(n);

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_rawgeti(L, -1, 1);
        const char* fieldName = luaL_checkstring(L, -1);
        lua_pop(L, 1);

        lua_rawgeti(L, -1, 2);
        auto fieldType = checkType(L, -1);
        lua_pop(L, 1);

        fields.push_back(StructField{
            fieldName,
            fieldType,
            0,
            fieldType->align,
            fieldType->align,
        });

        lua_pop(L, 1);
    }

    try {
        pushType(L, FFIType::unite(std::move(fields), std::move(name)));
        return 1;
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
        return -1;
    }
}

static int cNull(lua_State* L) {
    auto type = checkType(L, 1);

    if (type->kind != TypeKind::Pointer) {
        luaL_error(L, "c.null() requires pointer type");
        return -1;
    }

    auto d = makeOwned(type);
    *reinterpret_cast<void**>(d->address) = nullptr;

    pushData(L, d);
    return 1;
}

struct ArgTemp {
    std::shared_ptr<Root> keepAlive;
    std::vector<std::byte> bytes;
};

static void dcPushPrimitive(DCCallVM* vm, const std::shared_ptr<FFIType>& type, void* addr) {
    switch (type->prim) {
        case PrimKind::I8:
            dcArgChar(vm, *reinterpret_cast<int8_t*>(addr));
            return;
        case PrimKind::U8:
            dcArgChar(vm, static_cast<DCchar>(*reinterpret_cast<uint8_t*>(addr)));
            return;
        case PrimKind::I16:
            dcArgShort(vm, *reinterpret_cast<int16_t*>(addr));
            return;
        case PrimKind::U16:
            dcArgShort(vm, static_cast<DCshort>(*reinterpret_cast<uint16_t*>(addr)));
            return;
        case PrimKind::Char:
            dcArgChar(vm, *reinterpret_cast<char*>(addr));
            return;
        case PrimKind::I32:
            dcArgInt(vm, *reinterpret_cast<int32_t*>(addr));
            return;
        case PrimKind::U32:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<uint32_t*>(addr)));
            return;
        case PrimKind::I64:
            dcArgLongLong(vm, static_cast<DClonglong>(*reinterpret_cast<int64_t*>(addr)));
            return;
        case PrimKind::U64:
            dcArgLongLong(vm, static_cast<DClonglong>(*reinterpret_cast<uint64_t*>(addr)));
            return;
        case PrimKind::F32:
            dcArgFloat(vm, *reinterpret_cast<float*>(addr));
            return;
        case PrimKind::F64:
            dcArgDouble(vm, *reinterpret_cast<double*>(addr));
            return;
    }

    throw std::runtime_error("unsupported primitive argument");
}

static void dcPushPromotedPrimitive(DCCallVM* vm, PrimKind prim, void* addr) {
    switch (prim) {
        case PrimKind::I8:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<int8_t*>(addr)));
            return;
        case PrimKind::U8:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<uint8_t*>(addr)));
            return;
        case PrimKind::I16:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<int16_t*>(addr)));
            return;
        case PrimKind::U16:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<uint16_t*>(addr)));
            return;
        case PrimKind::Char:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<char*>(addr)));
            return;
        case PrimKind::I32:
            dcArgInt(vm, *reinterpret_cast<int32_t*>(addr));
            return;
        case PrimKind::U32:
            dcArgInt(vm, static_cast<DCint>(*reinterpret_cast<uint32_t*>(addr)));
            return;
        case PrimKind::I64:
            dcArgLongLong(vm, static_cast<DClonglong>(*reinterpret_cast<int64_t*>(addr)));
            return;
        case PrimKind::U64:
            dcArgLongLong(vm, static_cast<DClonglong>(*reinterpret_cast<uint64_t*>(addr)));
            return;
        case PrimKind::F32:
            dcArgDouble(vm, static_cast<DCdouble>(*reinterpret_cast<float*>(addr)));
            return;
        case PrimKind::F64:
            dcArgDouble(vm, *reinterpret_cast<double*>(addr));
            return;
    }

    throw std::runtime_error("unsupported primitive vararg");
}

static void pushVarArg(lua_State* L, DCCallVM* vm, int idx, std::vector<ArgTemp>& temps) {
    idx = lua_absindex(L, idx);

    if (lua_isnil(L, idx)) {
        dcArgPointer(vm, nullptr);
        return;
    }

    if (lua_isboolean(L, idx)) {
        dcArgInt(vm, lua_toboolean(L, idx) ? 1 : 0);
        return;
    }

    if (luaL_testudata(L, idx, FFI_DATA_MT)) {
        auto d = checkData(L, idx);
        ensureDataAccessible(L, d);

        if (d->type->kind == TypeKind::Primitive) {
            dcPushPromotedPrimitive(vm, d->type->prim, d->address);

            ArgTemp temp;
            temp.keepAlive = d->root;
            temps.push_back(std::move(temp));
            return;
        }

        if (d->type->kind == TypeKind::Pointer) {
            dcArgPointer(vm, *reinterpret_cast<void**>(d->address));

            ArgTemp temp;
            temp.keepAlive = d->root;
            temps.push_back(std::move(temp));
            return;
        }

        if (d->type->kind == TypeKind::Array) {
            dcArgPointer(vm, d->address);

            ArgTemp temp;
            temp.keepAlive = d->root;
            temps.push_back(std::move(temp));
            return;
        }

        if (d->type->kind == TypeKind::Function) {
            dcArgPointer(vm, d->address);

            ArgTemp temp;
            temp.keepAlive = d->root;
            temps.push_back(std::move(temp));
            return;
        }

        luaL_error(L, "unsupported vararg userdata type");
        return;
    }

    if (lua_isstring(L, idx)) {
        size_t len = 0;
        const char* s = luaL_checklstring(L, idx, &len);

        ArgTemp temp;
        temp.bytes.resize(len + 1);
        std::memcpy(temp.bytes.data(), s, len);
        temp.bytes[len] = std::byte{ 0 };

        dcArgPointer(vm, temp.bytes.data());
        temps.push_back(std::move(temp));
        return;
    }

    if (lua_isnumber(L, idx)) {
        if (lua_isinteger64(L, idx)) {
            int64_t value = lua_tointeger64(L, idx, nullptr);
            if (value >= std::numeric_limits<int32_t>::min() &&
                value <= std::numeric_limits<int32_t>::max())
                dcArgInt(vm, static_cast<DCint>(value));
            else
                dcArgLongLong(vm, static_cast<DClonglong>(value));
            return;
        }

        int isnum = 0;
        lua_Number n = lua_tonumberx(L, idx, &isnum);
        if (!isnum) luaL_typeerror(L, idx, "number");

        if (std::isfinite(n) && std::trunc(n) == n && n >= std::numeric_limits<int32_t>::min() &&
            n <= std::numeric_limits<int32_t>::max()) {
            dcArgInt(vm, static_cast<DCint>(n));
            return;
        }

        dcArgDouble(vm, static_cast<DCdouble>(n));
        return;
    }

    luaL_error(L, "unsupported vararg type");
}

static void pushArg(lua_State* L, DCCallVM* vm, const std::shared_ptr<FFIType>& type, int idx,
                    std::vector<ArgTemp>& temps) {
    idx = lua_absindex(L, idx);

    if (type->kind == TypeKind::Primitive) {
        if (luaL_testudata(L, idx, FFI_DATA_MT)) {
            auto d = checkData(L, idx);
            ensureDataAccessible(L, d);
            if (d->type->kind != TypeKind::Primitive || d->type->prim != type->prim)
                luaL_error(L, "primitive argument type mismatch");

            dcPushPrimitive(vm, type, d->address);
            return;
        }

        ArgTemp temp;
        temp.bytes.resize(type->size);

        auto fake = std::make_shared<FFIData>();
        fake->type = type;
        fake->address = temp.bytes.data();
        fake->writable = true;

        writeDataFromLua(L, fake, idx);
        dcPushPrimitive(vm, type, temp.bytes.data());

        temps.push_back(std::move(temp));
        return;
    }

    if (type->kind == TypeKind::Pointer) {
        void* ptr = nullptr;

        if (lua_isnil(L, idx)) {
            ptr = nullptr;
        } else if (luaL_testudata(L, idx, FFI_DATA_MT)) {
            auto d = checkData(L, idx);
            ensureDataAccessible(L, d);

            if (d->type->kind == TypeKind::Pointer) {
                ptr = *reinterpret_cast<void**>(d->address);

                ArgTemp temp;
                temp.keepAlive = d->root;
                temps.push_back(std::move(temp));
            } else if (d->type->kind == TypeKind::Array) {
                ptr = d->address;

                ArgTemp temp;
                temp.keepAlive = d->root;
                temps.push_back(std::move(temp));
            } else {
                luaL_error(L, "expected pointer or array argument");
            }
        } else if (type->pointee->kind == TypeKind::Primitive &&
                   type->pointee->prim == PrimKind::Char && lua_isstring(L, idx)) {
            size_t len = 0;
            const char* s = luaL_checklstring(L, idx, &len);

            ArgTemp temp;
            temp.bytes.resize(len + 1);
            std::memcpy(temp.bytes.data(), s, len);
            temp.bytes[len] = std::byte{ 0 };

            ptr = temp.bytes.data();
            temps.push_back(std::move(temp));
        } else {
            luaL_error(L, "expected pointer argument");
        }

        dcArgPointer(vm, ptr);
        return;
    }

    if (type->kind == TypeKind::Array) {
        void* ptr = nullptr;

        if (lua_isnil(L, idx)) {
            ptr = nullptr;
        } else if (luaL_testudata(L, idx, FFI_DATA_MT)) {
            auto d = checkData(L, idx);
            ensureDataAccessible(L, d);

            if (d->type->kind == TypeKind::Array) {
                ptr = d->address;

                ArgTemp temp;
                temp.keepAlive = d->root;
                temps.push_back(std::move(temp));
            } else if (d->type->kind == TypeKind::Pointer) {
                ptr = *reinterpret_cast<void**>(d->address);

                ArgTemp temp;
                temp.keepAlive = d->root;
                temps.push_back(std::move(temp));
            } else {
                luaL_error(L, "expected array or pointer argument");
            }
        } else if (type->element->kind == TypeKind::Primitive &&
                   type->element->prim == PrimKind::Char && lua_isstring(L, idx)) {
            size_t len = 0;
            const char* s = luaL_checklstring(L, idx, &len);

            ArgTemp temp;
            temp.bytes.resize(len + 1);
            std::memcpy(temp.bytes.data(), s, len);
            temp.bytes[len] = std::byte{ 0 };

            ptr = temp.bytes.data();
            temps.push_back(std::move(temp));
        } else {
            luaL_error(L, "expected array or pointer argument");
        }

        dcArgPointer(vm, ptr);
        return;
    }

    if (type->kind == TypeKind::Struct || type->kind == TypeKind::Union) {
        std::shared_ptr<DCaggr> aggr;
        try {
            aggr = ensureStructAggr(type);
        } catch (const std::exception& e) {
            luaL_error(L, "%s", e.what());
            return;
        }

        if (luaL_testudata(L, idx, FFI_DATA_MT)) {
            auto d = checkData(L, idx);
            ensureDataAccessible(L, d);
            if (d->type != type) luaL_error(L, "struct argument type mismatch");

            dcArgAggr(vm, aggr.get(), d->address);

            ArgTemp temp;
            temp.keepAlive = d->root;
            temps.push_back(std::move(temp));
            return;
        }

        ArgTemp temp;
        temp.bytes.resize(type->size);

        auto fake = std::make_shared<FFIData>();
        fake->type = type;
        fake->address = temp.bytes.data();
        fake->writable = true;

        assignValueFromLua(L, fake, idx);
        dcArgAggr(vm, aggr.get(), temp.bytes.data());

        temps.push_back(std::move(temp));
        return;
    }

    if (type->kind == TypeKind::Void) {
        luaL_error(L, "cannot pass void argument");
    }

    luaL_error(L, "unsupported argument type");
}

static std::shared_ptr<FFIData> makeRawPointerReturn(std::shared_ptr<FFIType> type, void* ptr) {
    auto d = makeOwned(type);
    *reinterpret_cast<void**>(d->address) = ptr;
    d->hasBounds = false;
    return d;
}

static int pushCallResult(lua_State* L, DCCallVM* vm, void* fn,
                          const std::shared_ptr<FFIType>& result) {
    if (result->kind == TypeKind::Void) {
        dcCallVoid(vm, fn);
        return 0;
    }

    if (result->kind == TypeKind::Pointer) {
        void* p = dcCallPointer(vm, fn);
        pushData(L, makeRawPointerReturn(result, p));
        return 1;
    }

    if (result->kind == TypeKind::Struct || result->kind == TypeKind::Union) {
        std::shared_ptr<DCaggr> aggr;
        try {
            aggr = ensureStructAggr(result);
        } catch (const std::exception& e) {
            luaL_error(L, "%s", e.what());
            return -1;
        }

        auto out = makeOwned(result);
        dcCallAggr(vm, fn, aggr.get(), out->address);
        pushData(L, out);
        return 1;
    }

    if (result->kind != TypeKind::Primitive) {
        luaL_error(L, "only primitive, pointer, struct, and union returns are implemented");
        return -1;
    }

    auto out = makeOwned(result);

    switch (result->prim) {
        case PrimKind::I8:
            *reinterpret_cast<int8_t*>(out->address) = dcCallChar(vm, fn);
            break;
        case PrimKind::U8:
            *reinterpret_cast<uint8_t*>(out->address) =
                static_cast<uint8_t>(dcCallChar(vm, fn));
            break;
        case PrimKind::I16:
            *reinterpret_cast<int16_t*>(out->address) = dcCallShort(vm, fn);
            break;
        case PrimKind::U16:
            *reinterpret_cast<uint16_t*>(out->address) =
                static_cast<uint16_t>(dcCallShort(vm, fn));
            break;
        case PrimKind::Char:
            *reinterpret_cast<char*>(out->address) = dcCallChar(vm, fn);
            break;
        case PrimKind::I32:
            *reinterpret_cast<int32_t*>(out->address) = dcCallInt(vm, fn);
            break;
        case PrimKind::U32:
            *reinterpret_cast<uint32_t*>(out->address) = static_cast<uint32_t>(dcCallInt(vm, fn));
            break;
        case PrimKind::I64:
            *reinterpret_cast<int64_t*>(out->address) = dcCallLongLong(vm, fn);
            break;
        case PrimKind::U64:
            *reinterpret_cast<uint64_t*>(out->address) =
                static_cast<uint64_t>(dcCallLongLong(vm, fn));
            break;
        case PrimKind::F32:
            *reinterpret_cast<float*>(out->address) = dcCallFloat(vm, fn);
            break;
        case PrimKind::F64:
            *reinterpret_cast<double*>(out->address) = dcCallDouble(vm, fn);
            break;
    }

    pushData(L, out);
    return 1;
}

static int dataCall(lua_State* L) {
    auto fnData = checkData(L, 1);
    ensureDataAccessible(L, fnData);

    if (fnData->type->kind != TypeKind::Function) {
        luaL_error(L, "attempt to call non-function FFI value");
        return -1;
    }

    auto ft = fnData->type;

    int nargs = lua_gettop(L) - 1;
    if (ft->variadic) {
        if (nargs < (int)ft->params.size()) {
            luaL_error(L, "expected at least %d arguments, got %d", (int)ft->params.size(), nargs);
            return -1;
        }
    } else if (nargs != (int)ft->params.size()) {
        luaL_error(L, "expected %d arguments, got %d", (int)ft->params.size(), nargs);
        return -1;
    }

    static thread_local DCCallVM* vm = nullptr;
    if (!vm) vm = dcNewCallVM(4096);

    dcReset(vm);
    dcMode(vm, ft->variadic ? DC_CALL_C_ELLIPSIS : ft->callMode);

    if (ft->result->kind == TypeKind::Struct || ft->result->kind == TypeKind::Union) {
        try {
            dcBeginCallAggr(vm, ensureStructAggr(ft->result).get());
        } catch (const std::exception& e) {
            luaL_error(L, "%s", e.what());
            return -1;
        }
    }

    std::vector<ArgTemp> temps;
    temps.reserve(ft->params.size());

    for (size_t i = 0; i < ft->params.size(); i++) {
        pushArg(L, vm, ft->params[i], (int)i + 2, temps);
    }

    if (ft->variadic) {
        dcMode(vm, DC_CALL_C_ELLIPSIS_VARARGS);
        for (int i = (int)ft->params.size() + 2; i <= nargs + 1; ++i)
            pushVarArg(L, vm, i, temps);
    }

    void* fn = fnData->address;
    return pushCallResult(L, vm, fn, ft->result);
}

static int cCast(lua_State* L) {
    auto src = checkData(L, 1);
    auto to = checkType(L, 2);
    ensureDataAccessible(L, src);

    if (to->kind == TypeKind::Pointer) {
        auto out = makeOwned(to);

        if (src->type->kind == TypeKind::Pointer) {
            *reinterpret_cast<void**>(out->address) = *reinterpret_cast<void**>(src->address);

            if (src->root) out->root->deps.push_back(src->root);

            pushData(L, out);
            return 1;
        }

        if (src->type->kind == TypeKind::Array) {
            *reinterpret_cast<void**>(out->address) = src->address;

            if (src->root) out->root->deps.push_back(src->root);

            out->hasBounds = true;
            out->bounds.base = src->address;
            out->bounds.elementSize = src->type->element->size;
            out->bounds.length = src->type->arrayLength;
            out->bounds.index = 0;

            pushData(L, out);
            return 1;
        }

        if (src->type->kind == TypeKind::Primitive) {
            uintptr_t addr = 0;

            switch (src->type->prim) {
                case PrimKind::I8:
                    addr = (uintptr_t)*reinterpret_cast<int8_t*>(src->address);
                    break;
                case PrimKind::U8:
                    addr = (uintptr_t)*reinterpret_cast<uint8_t*>(src->address);
                    break;
                case PrimKind::I16:
                    addr = (uintptr_t)*reinterpret_cast<int16_t*>(src->address);
                    break;
                case PrimKind::U16:
                    addr = (uintptr_t)*reinterpret_cast<uint16_t*>(src->address);
                    break;
                case PrimKind::I32:
                    addr = (uintptr_t) * reinterpret_cast<int32_t*>(src->address);
                    break;
                case PrimKind::U32:
                    addr = (uintptr_t) * reinterpret_cast<uint32_t*>(src->address);
                    break;
                case PrimKind::I64:
                    addr = (uintptr_t) * reinterpret_cast<int64_t*>(src->address);
                    break;
                case PrimKind::U64:
                    addr = (uintptr_t) * reinterpret_cast<uint64_t*>(src->address);
                    break;
                default:
                    luaL_error(L, "cannot cast this primitive to pointer");
                    return -1;
            }

            *reinterpret_cast<void**>(out->address) = reinterpret_cast<void*>(addr);
            pushData(L, out);
            return 1;
        }
    }

    if (to->kind == TypeKind::Primitive && src->type->kind == TypeKind::Primitive) {
        auto out = makeOwned(to);

        if (isIntegralPrimitive(src->type->prim) && isIntegralPrimitive(to->prim)) {
            uint64_t bits = 0;

            switch (src->type->prim) {
                case PrimKind::I8:
                    bits = static_cast<uint64_t>(*reinterpret_cast<int8_t*>(src->address));
                    break;
                case PrimKind::U8:
                    bits = *reinterpret_cast<uint8_t*>(src->address);
                    break;
                case PrimKind::I16:
                    bits = static_cast<uint64_t>(*reinterpret_cast<int16_t*>(src->address));
                    break;
                case PrimKind::U16:
                    bits = *reinterpret_cast<uint16_t*>(src->address);
                    break;
                case PrimKind::Char:
                    bits = static_cast<uint64_t>(*reinterpret_cast<char*>(src->address));
                    break;
                case PrimKind::I32:
                    bits = static_cast<uint64_t>(*reinterpret_cast<int32_t*>(src->address));
                    break;
                case PrimKind::U32:
                    bits = *reinterpret_cast<uint32_t*>(src->address);
                    break;
                case PrimKind::I64:
                    bits = static_cast<uint64_t>(*reinterpret_cast<int64_t*>(src->address));
                    break;
                case PrimKind::U64:
                    bits = *reinterpret_cast<uint64_t*>(src->address);
                    break;
                case PrimKind::F32:
                case PrimKind::F64:
                    break;
            }

            switch (to->prim) {
                case PrimKind::I8:
                    *reinterpret_cast<int8_t*>(out->address) = static_cast<int8_t>(bits);
                    break;
                case PrimKind::U8:
                    *reinterpret_cast<uint8_t*>(out->address) = static_cast<uint8_t>(bits);
                    break;
                case PrimKind::I16:
                    *reinterpret_cast<int16_t*>(out->address) = static_cast<int16_t>(bits);
                    break;
                case PrimKind::U16:
                    *reinterpret_cast<uint16_t*>(out->address) = static_cast<uint16_t>(bits);
                    break;
                case PrimKind::Char:
                    *reinterpret_cast<char*>(out->address) = static_cast<char>(bits);
                    break;
                case PrimKind::I32:
                    *reinterpret_cast<int32_t*>(out->address) = static_cast<int32_t>(bits);
                    break;
                case PrimKind::U32:
                    *reinterpret_cast<uint32_t*>(out->address) = static_cast<uint32_t>(bits);
                    break;
                case PrimKind::I64:
                    *reinterpret_cast<int64_t*>(out->address) = static_cast<int64_t>(bits);
                    break;
                case PrimKind::U64:
                    *reinterpret_cast<uint64_t*>(out->address) = bits;
                    break;
                case PrimKind::F32:
                case PrimKind::F64:
                    break;
            }
        } else {
            lua_Number n = 0;

            switch (src->type->prim) {
                case PrimKind::I8:
                    n = *reinterpret_cast<int8_t*>(src->address);
                    break;
                case PrimKind::U8:
                    n = *reinterpret_cast<uint8_t*>(src->address);
                    break;
                case PrimKind::I16:
                    n = *reinterpret_cast<int16_t*>(src->address);
                    break;
                case PrimKind::U16:
                    n = *reinterpret_cast<uint16_t*>(src->address);
                    break;
                case PrimKind::Char:
                    n = *reinterpret_cast<char*>(src->address);
                    break;
                case PrimKind::I32:
                    n = *reinterpret_cast<int32_t*>(src->address);
                    break;
                case PrimKind::U32:
                    n = *reinterpret_cast<uint32_t*>(src->address);
                    break;
                case PrimKind::I64:
                    n = static_cast<lua_Number>(*reinterpret_cast<int64_t*>(src->address));
                    break;
                case PrimKind::U64:
                    n = static_cast<lua_Number>(*reinterpret_cast<uint64_t*>(src->address));
                    break;
                case PrimKind::F32:
                    n = *reinterpret_cast<float*>(src->address);
                    break;
                case PrimKind::F64:
                    n = *reinterpret_cast<double*>(src->address);
                    break;
            }

            switch (to->prim) {
                case PrimKind::I8:
                    *reinterpret_cast<int8_t*>(out->address) = static_cast<int8_t>(n);
                    break;
                case PrimKind::U8:
                    *reinterpret_cast<uint8_t*>(out->address) = static_cast<uint8_t>(n);
                    break;
                case PrimKind::I16:
                    *reinterpret_cast<int16_t*>(out->address) = static_cast<int16_t>(n);
                    break;
                case PrimKind::U16:
                    *reinterpret_cast<uint16_t*>(out->address) = static_cast<uint16_t>(n);
                    break;
                case PrimKind::Char:
                    *reinterpret_cast<char*>(out->address) = static_cast<char>(n);
                    break;
                case PrimKind::I32:
                    *reinterpret_cast<int32_t*>(out->address) = static_cast<int32_t>(n);
                    break;
                case PrimKind::U32:
                    *reinterpret_cast<uint32_t*>(out->address) = static_cast<uint32_t>(n);
                    break;
                case PrimKind::I64:
                    *reinterpret_cast<int64_t*>(out->address) = static_cast<int64_t>(n);
                    break;
                case PrimKind::U64:
                    *reinterpret_cast<uint64_t*>(out->address) = static_cast<uint64_t>(n);
                    break;
                case PrimKind::F32:
                    *reinterpret_cast<float*>(out->address) = static_cast<float>(n);
                    break;
                case PrimKind::F64:
                    *reinterpret_cast<double*>(out->address) = static_cast<double>(n);
                    break;
            }
        }

        pushData(L, out);
        return 1;
    }

    luaL_error(L, "unsupported cast");
    return -1;
}

static std::string callModeName(int callMode) {
    switch (callMode) {
        case DC_CALL_C_DEFAULT:
            return "default";
        case DC_CALL_C_X86_CDECL:
            return "cdecl";
        case DC_CALL_C_X86_WIN32_STD:
            return "stdcall";
        case DC_CALL_C_X86_WIN32_FAST_MS:
            return "fastcall_ms";
        case DC_CALL_C_X86_WIN32_FAST_GNU:
            return "fastcall_gnu";
        default:
            return std::to_string(callMode);
    }
}

static std::string describeType(const std::shared_ptr<FFIType>& type) {
    if (!type) return "<null-type>";

    if (type->kind != TypeKind::Function) return type->name;

    std::string out = "func(" + describeType(type->result) + ", {";
    for (size_t i = 0; i < type->params.size(); ++i) {
        if (i != 0) out += ", ";
        out += describeType(type->params[i]);
    }
    if (type->variadic) {
        if (!type->params.empty()) out += ", ";
        out += "...";
    }
    out += "}";

    if (type->callMode != DC_CALL_C_DEFAULT || type->variadic) {
        out += ", {";
        bool needComma = false;

        if (type->callMode != DC_CALL_C_DEFAULT) {
            out += " convention = \"";
            out += callModeName(type->callMode);
            out += "\"";
            needComma = true;
        }

        if (type->variadic) {
            if (needComma) out += ",";
            out += " varargs = true";
        }

        out += " }";
    }

    out += ")";
    return out;
}

static int typeSize(lua_State* L) {
    auto type = checkType(L, 1);
    lua_pushinteger64(L, static_cast<uint64_t>(type->size));
    return 1;
}

static int typeAlign(lua_State* L) {
    auto type = checkType(L, 1);
    lua_pushinteger64(L, static_cast<uint64_t>(type->align));
    return 1;
}

static int typeName(lua_State* L) {
    auto type = checkType(L, 1);
    std::string text = describeType(type);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int typeOffsetOf(lua_State* L) {
    auto type = checkType(L, 1);
    const char* name = luaL_checkstring(L, 2);

    if (type->kind != TypeKind::Struct && type->kind != TypeKind::Union) {
        luaL_error(L, "offsetOf() requires struct or union type");
        return -1;
    }

    const StructField* field = findField(*type, name);
    if (!field) {
        luaL_error(L, "unknown struct field '%s'", name);
        return -1;
    }

    lua_pushinteger64(L, static_cast<uint64_t>(field->offset));
    return 1;
}

static int type_tostring(lua_State* L) {
    auto type = checkType(L, 1);
    std::string text = "Type<" + describeType(type) + ">";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static void createTypeMt(lua_State* L) {
    luaL_newmetatable(L, FFI_TYPE_MT);

    lua_pushcfunction(L, type_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    lua_newtable(L);

    lua_pushcfunction(L, typeSize, "size");
    lua_setfield(L, -2, "size");

    lua_pushcfunction(L, typeAlign, "align");
    lua_setfield(L, -2, "align");

    lua_pushcfunction(L, typeName, "name");
    lua_setfield(L, -2, "name");

    lua_pushcfunction(L, typeOffsetOf, "offsetOf");
    lua_setfield(L, -2, "offsetOf");

    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);
}

static int data_tostring(lua_State* L) {
    auto d = checkData(L, 1);
    std::string text = "Data<" + describeType(d->type) + ">(";

    if (d->type->kind == TypeKind::Pointer) {
        void* p = d->address ? *reinterpret_cast<void**>(d->address) : nullptr;
        text += p ? "ptr" : "null";
    } else {
        text += d->address ? "addr" : "null";
    }

    if (d->ownsMemory) text += ", owned";
    if (rootHasClosedLibrary(d->root)) text += ", closed";

    text += ")";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static void createDataMt(lua_State* L) {
    luaL_newmetatable(L, FFI_DATA_MT);

    lua_pushcfunction(L, data_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, dataCall, "__call");
    lua_setfield(L, -2, "__call");

    lua_newtable(L);

    lua_pushcfunction(L, dataRead, "read");
    lua_setfield(L, -2, "read");

    lua_pushcfunction(L, dataWrite, "write");
    lua_setfield(L, -2, "write");

    lua_pushcfunction(L, dataType, "type");
    lua_setfield(L, -2, "type");

    lua_pushcfunction(L, dataBytes, "bytes");
    lua_setfield(L, -2, "bytes");

    lua_pushcfunction(L, dataBuffer, "buffer");
    lua_setfield(L, -2, "buffer");

    lua_pushcfunction(L, dataPtr, "ptr");
    lua_setfield(L, -2, "ptr");

    lua_pushcfunction(L, dataDeref, "deref");
    lua_setfield(L, -2, "deref");

    lua_pushcfunction(L, dataOffset, "offset");
    lua_setfield(L, -2, "offset");

    lua_pushcfunction(L, dataIsNull, "isNull");
    lua_setfield(L, -2, "isNull");

    lua_pushcfunction(L, dataLength, "length");
    lua_setfield(L, -2, "length");

    lua_pushcfunction(L, dataGet, "get");
    lua_setfield(L, -2, "get");

    lua_pushcfunction(L, dataSet, "set");
    lua_setfield(L, -2, "set");

    lua_pushcfunction(L, dataAsArray, "asarray");
    lua_setfield(L, -2, "asarray");

    lua_pushcfunction(L, dataAsDict, "asdict");
    lua_setfield(L, -2, "asdict");

    lua_pushcfunction(L, dataStructGet, "getField");
    lua_setfield(L, -2, "getField");

    lua_pushcfunction(L, dataStructSet, "setField");
    lua_setfield(L, -2, "setField");

    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);
}

extern "C" int luaopen_eryx_ffi(lua_State* L) { return 1; }

LUAU_MODULE_EXPORT int luauopen_ffi(lua_State* L) {
    createTypeMt(L);
    createDataMt(L);
    createLibraryMt(L);

    lua_newtable(L);  // ffi

    lua_pushcfunction(L, ffiOpen, "open");
    lua_setfield(L, -2, "open");

    // ffi.process
    {
        auto root = std::make_shared<LibraryRoot>();
        root->handle = processHandle();
        root->closeable = false;

        auto lib = std::make_shared<FFILibrary>();
        lib->root = root;
        lib->path = "<process>";

        pushLibrary(L, lib);
        lua_setfield(L, -2, "process");
    }

    lua_newtable(L);  // c

    lua_pushcfunction(L, cNew, "new");
    lua_setfield(L, -2, "new");

    lua_pushcfunction(L, cPtrType, "ptr");
    lua_setfield(L, -2, "ptr");

    lua_pushcfunction(L, cArrayType, "array");
    lua_setfield(L, -2, "array");

    lua_pushcfunction(L, cString, "string");
    lua_setfield(L, -2, "string");

    lua_pushcfunction(L, cFuncType, "func");
    lua_setfield(L, -2, "func");

    lua_pushcfunction(L, cStructType, "struct");
    lua_setfield(L, -2, "struct");

    lua_pushcfunction(L, cUnionType, "union");
    lua_setfield(L, -2, "union");

    lua_pushcfunction(L, cNull, "null");
    lua_setfield(L, -2, "null");

    lua_pushcfunction(L, cCast, "cast");
    lua_setfield(L, -2, "cast");

    setFieldType(L, "void", FFIType::voidType());

    setFieldType(L, "int8", FFIType::primitive(PrimKind::I8, "int8", sizeof(int8_t), alignof(int8_t)));
    setFieldType(L, "uint8",
                 FFIType::primitive(PrimKind::U8, "uint8", sizeof(uint8_t), alignof(uint8_t)));
    setFieldType(L, "short",
                 FFIType::primitive(PrimKind::I16, "short", sizeof(short), alignof(short)));
    setFieldType(L, "ushort",
                 FFIType::primitive(PrimKind::U16, "ushort", sizeof(unsigned short),
                                    alignof(unsigned short)));
    setFieldType(L, "int16",
                 FFIType::primitive(PrimKind::I16, "int16", sizeof(int16_t), alignof(int16_t)));
    setFieldType(L, "uint16",
                 FFIType::primitive(PrimKind::U16, "uint16", sizeof(uint16_t), alignof(uint16_t)));
    setFieldType(L, "schar",
                 FFIType::primitive(PrimKind::I8, "schar", sizeof(signed char), alignof(signed char)));
    setFieldType(L, "uchar",
                 FFIType::primitive(PrimKind::U8, "uchar", sizeof(unsigned char),
                                    alignof(unsigned char)));
    setFieldType(L, "byte",
                 FFIType::primitive(PrimKind::U8, "byte", sizeof(uint8_t), alignof(uint8_t)));

    setFieldType(L, "int",
                 FFIType::primitive(sizeof(int) == 8 ? PrimKind::I64 : PrimKind::I32, "int",
                                    sizeof(int), alignof(int)));
    setFieldType(L, "uint",
                 FFIType::primitive(sizeof(unsigned int) == 8 ? PrimKind::U64 : PrimKind::U32,
                                    "uint", sizeof(unsigned int), alignof(unsigned int)));
    setFieldType(L, "long",
                 FFIType::primitive(sizeof(long) == 8 ? PrimKind::I64 : PrimKind::I32, "long",
                                    sizeof(long), alignof(long)));
    setFieldType(L, "ulong",
                 FFIType::primitive(sizeof(unsigned long) == 8 ? PrimKind::U64 : PrimKind::U32,
                                    "ulong", sizeof(unsigned long), alignof(unsigned long)));
    setFieldType(L, "intptr_t",
                 FFIType::primitive(sizeof(intptr_t) == 8 ? PrimKind::I64 : PrimKind::I32,
                                    "intptr_t", sizeof(intptr_t), alignof(intptr_t)));
    setFieldType(L, "uintptr_t",
                 FFIType::primitive(sizeof(uintptr_t) == 8 ? PrimKind::U64 : PrimKind::U32,
                                    "uintptr_t", sizeof(uintptr_t), alignof(uintptr_t)));
    setFieldType(L, "size_t",
                 FFIType::primitive(sizeof(size_t) == 8 ? PrimKind::U64 : PrimKind::U32, "size_t",
                                    sizeof(size_t), alignof(size_t)));

    setFieldType(L, "int32",
                 FFIType::primitive(PrimKind::I32, "int32", sizeof(int32_t), alignof(int32_t)));
    setFieldType(L, "uint32",
                 FFIType::primitive(PrimKind::U32, "uint32", sizeof(uint32_t), alignof(uint32_t)));
    setFieldType(L, "int64",
                 FFIType::primitive(PrimKind::I64, "int64", sizeof(int64_t), alignof(int64_t)));
    setFieldType(L, "uint64",
                 FFIType::primitive(PrimKind::U64, "uint64", sizeof(uint64_t), alignof(uint64_t)));
    setFieldType(L, "float",
                 FFIType::primitive(PrimKind::F32, "float", sizeof(float), alignof(float)));
    setFieldType(L, "double",
                 FFIType::primitive(PrimKind::F64, "double", sizeof(double), alignof(double)));
    setFieldType(L, "char",
                 FFIType::primitive(PrimKind::Char, "char", sizeof(char), alignof(char)));

    lua_setfield(L, -2, "c");

    lua_setreadonly(L, -1, true);
    return 1;
}
