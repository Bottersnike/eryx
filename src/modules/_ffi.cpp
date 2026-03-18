// _ffi.cpp  –  Foreign Function Interface for Luau (Win32)
//
// Loads native shared libraries at runtime and calls their exported
// functions via dyncall.  Provides typed values for safe marshalling
// between Luau and C ABIs.
//
// API:
//
//   _ffi.loadLibrary(path)  -> ForeignLibrary
//   ForeignLibrary:getFunction(name|ordinal, retType, {argTypes...}) -> ForeignFunction
//   ForeignFunction(args...)  -> ForeignValue
//   ForeignType(initialValue?) -> ForeignValue
//   ForeignType:pointer()      -> ForeignType (pointer-to)
//   ForeignValue:get()          -> Luau value
//   ForeignValue:set(value)     -> ForeignValue
//   ForeignValue:pointer()      -> ForeignValue (pointer-to)
//
// Types: void, str, char, unsigned char, u8, u16, u32, u64, i8, i16, i32, i64
// ---------------------------------------------------------------------------

#include <string>
#include <vector>

#include "dyncall.h"
#include "module_api.h"
#include "lua.h"
#include "lualib.h"

// ---------------------------------------------------------------------------
// Module metadata
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__ffi",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Metatables
// ---------------------------------------------------------------------------
static const char* FOREIGN_LIBRARY_METATABLE = "ForeignLibrary";
static const char* FOREIGN_FUNCTION_METATABLE = "ForeignFunction";
static const char* FOREIGN_TYPE_METATABLE = "ForeignType";
static const char* FOREIGN_VALUE_METATABLE = "ForeignValue";

struct LuaForeignLibrary {
    std::string filename;
    HMODULE hModule;
};
typedef enum {
    FFI_T_VOID,
    FFI_T_STR,
    FFI_T_UCHAR,
    FFI_T_CHAR,
    FFI_T_U8,
    FFI_T_U16,
    FFI_T_U32,
    FFI_T_U64,
    FFI_T_I8,
    FFI_T_I16,
    FFI_T_I32,
    FFI_T_I64
    // FFI_T_CALLBACK  // TODO: This will be hard lol
} ffi_type_kind;
struct LuaForeignType {
    ffi_type_kind kind;
    uint8_t indirectionLevels;
    size_t size;
};
struct LuaForeignValue {
    void* pValue;
    uint8_t ownsValue;
    LuaForeignType type;
};
struct LuaForeignFunction {
    std::string name;
    LuaForeignType ret;
    std::vector<LuaForeignType> args;
    FARPROC pFunc;
};

static int push_lua_type_from_ffi(lua_State* L, LuaForeignType* type, void* value) {
    if (type->indirectionLevels > 0) {
        luaL_error(L, "Attempted to represent pointer as Luau value");
    }

    switch (type->kind) {
        case FFI_T_STR:
            lua_pushstring(L, (const char*)value);
            return 1;
        case FFI_T_VOID:
            lua_pushnil(L);
            return 1;
        case FFI_T_UCHAR:
            lua_pushnumber(L, *(unsigned char*)value);
            return 1;
        case FFI_T_CHAR:
            char str[2];
            str[0] = *(char*)value;
            str[1] = 0;
            lua_pushstring(L, str);
            return 1;
        case FFI_T_U8:
            lua_pushnumber(L, *(uint8_t*)value);
            return 1;
        case FFI_T_U16:
            lua_pushnumber(L, *(uint16_t*)value);
            return 1;
        case FFI_T_U32:
            lua_pushnumber(L, *(uint32_t*)value);
            return 1;
        case FFI_T_U64:
            lua_pushnumber(L, *(uint64_t*)value);
            return 1;
        case FFI_T_I8:
            lua_pushnumber(L, *(int8_t*)value);
            return 1;
        case FFI_T_I16:
            lua_pushnumber(L, *(int16_t*)value);
            return 1;
        case FFI_T_I32:
            lua_pushnumber(L, *(int32_t*)value);
            return 1;
        case FFI_T_I64:
            lua_pushnumber(L, *(int64_t*)value);
            return 1;
        default:
            luaL_error(L, "Unknown internal type %d", type->kind);
    }
}
static int set_lua_type_from_ffi(lua_State* L, LuaForeignType* type, void** value, int stackIndex) {
    if (type->indirectionLevels > 0) {
        if (lua_type(L, stackIndex) == LUA_TNIL) {
            *(void**)value = NULL;
            return 0;
        }

        // TODO: Support assigning a a ForeignValue pointer
        luaL_error(L, "Attempted to assign pointer from Luau value");
    }

    switch (type->kind) {
        case FFI_T_STR: {
            const char* str = luaL_checkstring(L, stackIndex);
            free(*value);
            // if (*(void**)value) {
            //     free(*(void**)value);
            // }

            *(char**)value = (char*)malloc(strlen(str) + 1);
            memcpy(*value, str, strlen(str) + 1);
            return 0;
        }
        case FFI_T_VOID:
            return 0;
        case FFI_T_UCHAR: {
            unsigned int num = luaL_checkunsigned(L, stackIndex);
            if (num > 255) {
                luaL_error(L, "%d out of range for uchar", num);
            }
            **(unsigned char**)value = num;
            return 0;
        }
        case FFI_T_CHAR: {
            if (lua_type(L, stackIndex) == LUA_TSTRING) {
                const char* str = luaL_checkstring(L, stackIndex);
                if (strlen(str) != 1) {
                    luaL_error(L,
                               "Assignment to char must be numeric or a single character string");
                }
                **(char**)value = str[0];
                return 0;
            }
            int num = luaL_checkinteger(L, stackIndex);
            if (num < -128 || num > 127) {
                luaL_error(L, "%d out of range for char", num);
            }
            **(char**)value = num;
            return 0;
        }
        case FFI_T_U8: {
            unsigned int num = luaL_checkunsigned(L, stackIndex);
            if (num > 0xFF) {
                luaL_error(L, "%d out of range for u8", num);
            }
            **(uint8_t**)value = num;
            return 0;
        }
        case FFI_T_U16: {
            unsigned int num = luaL_checkunsigned(L, stackIndex);
            if (num > 0xFFFF) {
                luaL_error(L, "%d out of range for u16", num);
            }
            **(uint16_t**)value = num;
            return 0;
        }
        case FFI_T_U32: {
            unsigned int num = luaL_checkunsigned(L, stackIndex);
            if (num > 0xFFFFFFFF) {
                luaL_error(L, "%d out of range for u32", num);
            }
            **(uint32_t**)value = num;
            return 0;
        }
        // TODO: check* always just returns a 32 bit number lmao
        case FFI_T_U64: {
            unsigned int num = luaL_checkunsigned(L, stackIndex);
            if (num > 0xFFFFFFFFFFFFFFFF) {
                luaL_error(L, "%d out of range for u64", num);
            }
            **(uint64_t**)value = num;
            return 0;
        }
        case FFI_T_I8: {
            int num = luaL_checkinteger(L, stackIndex);
            if (num < -128 || num > 127) {
                luaL_error(L, "%d out of range for i8", num);
            }
            **(int8_t**)value = num;
            return 0;
        }
        case FFI_T_I16: {
            int num = luaL_checkinteger(L, stackIndex);
            if (num < -32768 || num > 32767) {
                luaL_error(L, "%d out of range for i16", num);
            }
            **(int16_t**)value = num;
            return 0;
        }
        case FFI_T_I32: {
            int num = luaL_checkinteger(L, stackIndex);
            if (num < -2147483648 || num > 2147483647) {
                luaL_error(L, "%d out of range for i32", num);
            }
            **(int32_t**)value = num;
            return 0;
        }
        case FFI_T_I64: {
            // No need for bounds checks here
            int num = luaL_checkinteger(L, stackIndex);
            **(int64_t**)value = num;
            return 0;
        }
        default:
            luaL_error(L, "Unknown internal type %d", type->kind);
    }
}

static std::string get_win32_error(DWORD dwErrorCode) {
    LPCSTR pszErrorMessage = NULL;
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS |
                       FORMAT_MESSAGE_ARGUMENT_ARRAY | FORMAT_MESSAGE_ALLOCATE_BUFFER,
                   NULL, dwErrorCode, 0, (LPSTR)&pszErrorMessage, 0, NULL);

    std::string ret;
    if (pszErrorMessage == NULL) {
        ret += "Unknown error ";
        ret += dwErrorCode;
        return ret;
    }

    ret += pszErrorMessage;
    LocalFree((LPVOID)pszErrorMessage);
    return ret;
}

int ffi_lib_gc(lua_State* L) {
    LuaForeignLibrary* flib = (LuaForeignLibrary*)luaL_checkudata(L, 1, FOREIGN_LIBRARY_METATABLE);
    if (flib) {
        if (flib->hModule != NULL) {
            FreeLibrary(flib->hModule);
            flib->hModule = NULL;
        }

        flib->~LuaForeignLibrary();  // Explicitly call destructor
    }
    return 0;
}

int ffi_lib_tostring(lua_State* L) {
    LuaForeignLibrary* flib = (LuaForeignLibrary*)luaL_checkudata(L, 1, FOREIGN_LIBRARY_METATABLE);
    lua_pushfstring(L, "ForeignLibrary(%s @ 0x%016llx)", flib->filename.c_str(), flib->hModule);
    return 1;
}

int ffi_lib_getFunction(lua_State* L) {
    LuaForeignLibrary* flib = (LuaForeignLibrary*)luaL_checkudata(L, 1, FOREIGN_LIBRARY_METATABLE);

    // Function name
    WORD ordinal = -1;
    const char* name = NULL;

    if (lua_type(L, 2) == LUA_TNUMBER) {
        lua_Number ordFloat = luaL_checkinteger(L, 2);
        if (ordFloat > 0xFFFF || ordFloat < 0) {
            luaL_error(L, "Ordinal %d out of range", ordFloat);
        }
        ordinal = ordFloat;
    } else {
        name = luaL_checkstring(L, 2);
    }

    // Return type
    LuaForeignType* ftype_ret = (LuaForeignType*)luaL_checkudata(L, 3, FOREIGN_TYPE_METATABLE);

    // Arguments
    std::vector<LuaForeignType*> ftype_args;
    luaL_checktype(L, 4, LUA_TTABLE);
    lua_Integer expected = 1;
    lua_pushnil(L);
    while (lua_next(L, 4) != 0) {
        // key at -2, value at -1
        // Must be integer key
        if (!lua_isnumber(L, -2)) {
            luaL_error(L, "args must have only integer keys");
        }
        lua_Integer k = luaL_checkinteger(L, -2);
        // Must be exactly 1..n in order (no holes, no hash part)
        if (k != expected) {
            luaL_error(L, "args must be a dense sequence (1..n with no holes)");
        }
        // Must be correct userdata type
        LuaForeignType* item = (LuaForeignType*)luaL_checkudata(L, -1, FOREIGN_TYPE_METATABLE);
        ftype_args.push_back(item);
        expected++;
        lua_pop(L, 1);  // pop value, keep key
    }

    if (flib->hModule == NULL) {
        luaL_error(L, "Internal error: hModule NULL");
    }

    FARPROC addr;
    if (name != NULL) {
        addr = GetProcAddress(flib->hModule, name);
        if (addr == NULL) {
            luaL_error(L, "Unable to locate %s in %s", name, flib->filename.c_str());
        }
    } else {
        addr = GetProcAddress(flib->hModule, MAKEINTRESOURCEA(ordinal));
        if (addr == NULL) {
            luaL_error(L, "Unable to locate ordinal %d in %s", ordinal, flib->filename.c_str());
        }
    }

    LuaForeignFunction* ffunc = (LuaForeignFunction*)lua_newuserdata(L, sizeof(LuaForeignFunction));
    new (ffunc) LuaForeignFunction();

    ffunc->name = name;
    ffunc->pFunc = addr;
    ffunc->ret.indirectionLevels = ftype_ret->indirectionLevels;
    ffunc->ret.kind = ftype_ret->kind;
    ffunc->ret.size = ftype_ret->size;
    ffunc->args.clear();
    ffunc->args.resize(ftype_args.size());
    for (size_t i = 0; i < ftype_args.size(); i++) {
        ffunc->args[i].indirectionLevels = ftype_args[i]->indirectionLevels;
        ffunc->args[i].kind = ftype_args[i]->kind;
        ffunc->args[i].size = ftype_args[i]->size;
    }

    luaL_getmetatable(L, FOREIGN_FUNCTION_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

int ffi_func_tostring(lua_State* L) {
    LuaForeignFunction* ffunc =
        (LuaForeignFunction*)luaL_checkudata(L, 1, FOREIGN_FUNCTION_METATABLE);
    lua_pushfstring(L, "ForeignFunction(%s @ 0x%016llx)", ffunc->name.c_str(), ffunc->pFunc);
    return 1;
}

int ffi_func_gc(lua_State* L) {
    LuaForeignFunction* ffunc =
        (LuaForeignFunction*)luaL_checkudata(L, 1, FOREIGN_FUNCTION_METATABLE);
    if (ffunc) {
        ffunc->~LuaForeignFunction();  // Explicitly call destructor
    }
    return 0;
}

int ffi_func_call(lua_State* L) {
    //puts("Call time");
    LuaForeignFunction* ffunc =
        (LuaForeignFunction*)luaL_checkudata(L, 1, FOREIGN_FUNCTION_METATABLE);

    int num_args = lua_gettop(L) - 1;  // Everything after index 1

    if (num_args != ffunc->args.size()) {
        luaL_error(L, "Expected %d arguments", ffunc->args.size());
    }
    // printf("%p\n", ffunc);
    // printf("%d %d\n", num_args, ffunc->args.size());

    // Make a dyncall VM for this call
    //puts("New VM");
    static DCCallVM* vm = NULL;
    if (!vm) vm = dcNewCallVM(4096);
    //puts("Reset");
    dcReset(vm);

    //puts("Load arg");
    // Load in arguments
    void** needs_freed = (void**)malloc(sizeof(void*) * num_args);
    memset(needs_freed, 0, sizeof(void*) * num_args);
    // printf("Arg: %d\n", num_args);
    for (int i = 0; i < num_args; i++) {
        LuaForeignType* arg = &(ffunc->args[i]);

        void* value = NULL;

        // printf("Parsing arg %d\n", i);
        // TODO: Support automatic casting
        if (lua_type(L, i + 2) != LUA_TUSERDATA) {
            value = malloc(arg->size);
            memset(value, 0, arg->size);
            // printf("Got %p\n", value);
            set_lua_type_from_ffi(L, arg, &value, i + 2);
            // printf("And set %p\n", value);
            needs_freed[i] = value;
            // printf("Are we okay?\n");
        } else {
            LuaForeignValue* passed_arg =
                (LuaForeignValue*)luaL_checkudata(L, i + 2, FOREIGN_VALUE_METATABLE);

            if (passed_arg->type.indirectionLevels != arg->indirectionLevels) {
                luaL_error(L, "invalid argument #%d (indirection mismatch)", i + 2);
            }
            if (passed_arg->type.kind != arg->kind) {
                luaL_error(L, "invalid argument #%d (type mismatch)", i + 2);
            }

            value = passed_arg->pValue;
        }

        if (arg->indirectionLevels > 0) {
            //puts("Passing pointer");
            //printf("%p\n", value);
            // printf("%p\n", *(void**)value);
            // pValue points to a void*, so we dereference it to get the address
            dcArgPointer(vm, value);
            //puts("Done");
        } else {
            //puts("Passing value as-is");
            // Push by value based on kind
            switch (arg->kind) {
                case FFI_T_VOID:
                    dcFree(vm);
                    luaL_error(L, "Cannot pass void as function argument");
                case FFI_T_STR:
                    dcArgPointer(vm, value);
                    break;
                case FFI_T_UCHAR:
                    dcArgInt(vm, *(unsigned char*)value);
                    break;
                case FFI_T_CHAR:
                    dcArgInt(vm, *(char*)value);
                    break;
                case FFI_T_U8:
                    dcArgInt(vm, *(uint8_t*)value);
                    break;
                case FFI_T_U16:
                    dcArgInt(vm, *(uint16_t*)value);
                    break;
                case FFI_T_U32:
                    dcArgInt(vm, *(uint32_t*)value);
                    break;
                case FFI_T_U64:
                    dcArgInt(vm, *(uint64_t*)value);
                    break;
                case FFI_T_I8:
                    dcArgInt(vm, *(int8_t*)value);
                    break;
                case FFI_T_I16:
                    dcArgInt(vm, *(int16_t*)value);
                    break;
                case FFI_T_I32:
                    dcArgInt(vm, *(int32_t*)value);
                    break;
                case FFI_T_I64:
                    dcArgInt(vm, *(int64_t*)value);
                    break;
            }
        }
    }

    //puts("Ret alloc time");

    // Allocate size for return
    void* rc;
    if (ffunc->ret.indirectionLevels == 0) {
        rc = malloc(ffunc->ret.size);
        //printf("Allocated %d byte buffer\n", ffunc->ret.size);
    } else {
        rc = malloc(sizeof(void*));
        //printf("Allocated pointer (%d %p)\n", sizeof(void*), rc);
    }

    //puts("Making call");
    if (ffunc->ret.indirectionLevels > 0) {
        rc = dcCallPointer(vm, (void*)ffunc->pFunc);
    } else {
        switch (ffunc->ret.kind) {
            case FFI_T_VOID:
                dcCallVoid(vm, (void*)ffunc->pFunc);
                break;
            case FFI_T_STR:
                rc = dcCallPointer(vm, (void*)ffunc->pFunc);
                break;
            case FFI_T_UCHAR:
            case FFI_T_CHAR:
            case FFI_T_U8:
            case FFI_T_I8:
                *(uint8_t*)rc = dcCallChar(vm, (void*)ffunc->pFunc);
                break;
            case FFI_T_U16:
            case FFI_T_I16:
                *(uint16_t*)rc = dcCallShort(vm, (void*)ffunc->pFunc);
                break;
            case FFI_T_U32:
            case FFI_T_I32:
                *(uint32_t*)rc = dcCallLong(vm, (void*)ffunc->pFunc);
                break;
            case FFI_T_U64:
            case FFI_T_I64:
                *(uint64_t*)rc = dcCallLongLong(vm, (void*)ffunc->pFunc);
                break;
        }
    }
    //puts("Call done");
    // if (ffunc->ret.indirectionLevels == 0) {
    //     printf("<<<<< %d bytes returned: ", ffunc->ret.size);
    //     for (int i = 0; i < ffunc->ret.size; i++) {
    //         printf("%02x ", ((uint8_t*)&rc)[i]);
    //     }
    // } else {
    //     printf("<<<<< Pointer returned: ");
    //     for (int i = 0; i < sizeof(void*); i++) {
    //         printf("%02x ", ((uint8_t*)&rc)[i]);
    //     }
    // }
    //puts("");

    //puts("Free 1");

    for (int i = 0; i < num_args; i++) {
        if (needs_freed[i]) free(needs_freed[i]);
    }

    //puts("Free 2");

    // 5. Wrap the result in a LuaForeignValue
    LuaForeignValue* res = (LuaForeignValue*)lua_newuserdata(L, sizeof(LuaForeignValue));
    // if (ffunc->ret.indirectionLevels == 0) {
    res->pValue = rc;
    res->ownsValue = 1;
    res->type.indirectionLevels = ffunc->ret.indirectionLevels;
    // } else {
    //     for (int i = 0; i < ffunc->ret.indirectionLevels; i++) {
    //         void* newrc = malloc(sizeof(void*));
    //         newrc = &rc;
    //         rc = newrc;
    //     }
    //     res->pValue = rc;
    //     res->ownsValue = ffunc->ret.indirectionLevels + 1;
    //     res->type.indirectionLevels = ffunc->ret.indirectionLevels;
    // }
    res->type.kind = ffunc->ret.kind;
    res->type.size = ffunc->ret.size;
    luaL_getmetatable(L, FOREIGN_VALUE_METATABLE);
    lua_setmetatable(L, -2);

    //puts("Returning now");

    return 1;
}

static int ffi_loadLibrary(lua_State* L) {
    const char* szLibrary = luaL_checkstring(L, 1);

    HMODULE hLib = LoadLibraryA(szLibrary);
    if (hLib == NULL) {
        luaL_error(L, "Failed to load library %s: %s", szLibrary,
                   get_win32_error(GetLastError()).c_str());
    }

    LuaForeignLibrary* flib = (LuaForeignLibrary*)lua_newuserdata(L, sizeof(LuaForeignLibrary));
    new (flib) LuaForeignLibrary();

    flib->filename = szLibrary;
    flib->hModule = hLib;

    luaL_getmetatable(L, FOREIGN_LIBRARY_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

int ffi_type_gc(lua_State* L) {
    LuaForeignType* ftype = (LuaForeignType*)luaL_checkudata(L, 1, FOREIGN_TYPE_METATABLE);
    if (ftype) {
        ftype->~LuaForeignType();  // Explicitly call destructor
    }
    return 0;
}

int ffi_type_tostring(lua_State* L) {
    LuaForeignType* ftype = (LuaForeignType*)luaL_checkudata(L, 1, FOREIGN_TYPE_METATABLE);
    // TODO: Nicer stuff here!
    lua_pushfstring(L, "ForeignType(%s%d bytes)",
                    std::string(ftype->indirectionLevels, '*').c_str(), ftype->size);
    return 1;
}

int ffi_type_pointer(lua_State* L) {
    LuaForeignType* ftype = (LuaForeignType*)luaL_checkudata(L, 1, FOREIGN_TYPE_METATABLE);

    LuaForeignType* ftype_pointer = (LuaForeignType*)lua_newuserdata(L, sizeof(LuaForeignType));
    new (ftype_pointer) LuaForeignType();

    ftype_pointer->kind = ftype->kind;
    ftype_pointer->size = ftype->size;
    ftype_pointer->indirectionLevels = ftype->indirectionLevels + 1;

    luaL_getmetatable(L, FOREIGN_TYPE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

int ffi_value_gc(lua_State* L) {
    LuaForeignValue* fvalue = (LuaForeignValue*)luaL_checkudata(L, 1, FOREIGN_VALUE_METATABLE);
    if (fvalue) {
        if (fvalue->pValue) {
            // If we're the base value, we're the one that allocated memory
            if (fvalue->ownsValue) {
                void* toFree = fvalue->pValue;
                while (fvalue->ownsValue) {
                    fvalue->ownsValue--;

                    void* nextToFree = NULL;
                    if (fvalue->ownsValue) {
                        nextToFree = *(void**)toFree;
                    }
                    free(toFree);
                    toFree = nextToFree;
                }

                // if (fvalue->type.kind == FFI_T_STR) {
                //     if (*(const char*)fvalue->ownsValue != NULL) {
                //         free(*(void**)fvalue->pValue);
                //     }
                // }
                // free(fvalue->pValue);
            } else {
                fvalue->pValue = NULL;
            }
        }
        fvalue->~LuaForeignValue();  // Explicitly call destructor
    }
    return 0;
}

int ffi_value_tostring(lua_State* L) {
    LuaForeignValue* fvalue = (LuaForeignValue*)luaL_checkudata(L, 1, FOREIGN_VALUE_METATABLE);
    // TODO: Nicer stuff here!
    lua_pushfstring(L, "ForeignValue()");
    return 1;
}

int ffi_value_get(lua_State* L) {
    LuaForeignValue* fvalue = (LuaForeignValue*)luaL_checkudata(L, 1, FOREIGN_VALUE_METATABLE);
    // TODO: Nicer stuff here!

    // If we're a pointer, dereference the pointer
    if (fvalue->type.indirectionLevels > 0) {
        if (luaL_optboolean(L, 2, true)) {
            if (fvalue->pValue == NULL) {
                luaL_error(L, "Attempted to dereference null value");
            }
            if (fvalue->pValue == INVALID_HANDLE_VALUE) {
                luaL_error(L, "Attempted to dereference invalid pointer");
            }

            LuaForeignValue* new_fvalue =
                (LuaForeignValue*)lua_newuserdata(L, sizeof(LuaForeignValue));
            new (new_fvalue) LuaForeignValue();

            new_fvalue->type.indirectionLevels = fvalue->type.indirectionLevels - 1;
            new_fvalue->type.kind = fvalue->type.kind;
            new_fvalue->type.size = fvalue->type.size;

            // Dereference the pointer by one
            new_fvalue->ownsValue = 0;
            new_fvalue->pValue = *((void**)fvalue->pValue);

            luaL_getmetatable(L, FOREIGN_VALUE_METATABLE);
            lua_setmetatable(L, -2);
        } else {
            if (fvalue->pValue == NULL) {
                luaL_error(L, "Attempted to dereference null value");
            }
            // Don't dereference!
            lua_pushnumber(L, (uint64_t)fvalue->pValue);
        }

        return 1;
    }

    return push_lua_type_from_ffi(L, &fvalue->type, fvalue->pValue);
}
int ffi_value_set(lua_State* L) {
    LuaForeignValue* fvalue = (LuaForeignValue*)luaL_checkudata(L, 1, FOREIGN_VALUE_METATABLE);

    if (fvalue->type.indirectionLevels > 0) {
        luaL_error(L, "Cannot assign to pointer");
    }

    set_lua_type_from_ffi(L, &fvalue->type, &fvalue->pValue, 2);

    // Return ourself for chaining
    lua_pushvalue(L, 1);
    return 1;
}

int ffi_type_call(lua_State* L) {
    LuaForeignType* ftype = (LuaForeignType*)luaL_checkudata(L, 1, FOREIGN_TYPE_METATABLE);

    if (ftype->size == 0) {
        luaL_errorL(L, "Cannot make instances of void");
    }
    if (ftype->indirectionLevels != 0) {
        luaL_errorL(L,
                    "Cannot make instances of pointer type. Instead, create instance of base type "
                    "then generate a pointer to it.");
    }

    LuaForeignValue* fvalue = (LuaForeignValue*)lua_newuserdata(L, sizeof(LuaForeignValue));
    new (fvalue) LuaForeignValue();

    fvalue->type.indirectionLevels = ftype->indirectionLevels;
    fvalue->type.kind = ftype->kind;
    fvalue->type.size = ftype->size;

    // Create a placeholder to store whatever it is we're going to be storing
    fvalue->ownsValue = 1;
    fvalue->pValue = malloc(fvalue->type.size);
    memset(fvalue->pValue, 0, fvalue->type.size);

    if (lua_gettop(L) > 2) {
        if (fvalue->type.indirectionLevels > 0) {
            luaL_error(L, "Cannot assign to pointer");
        }
        set_lua_type_from_ffi(L, &fvalue->type, &fvalue->pValue, 2);
    }

    luaL_getmetatable(L, FOREIGN_VALUE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}
int ffi_value_pointer(lua_State* L) {
    LuaForeignValue* fvalue = (LuaForeignValue*)luaL_checkudata(L, 1, FOREIGN_VALUE_METATABLE);

    LuaForeignValue* new_fvalue = (LuaForeignValue*)lua_newuserdata(L, sizeof(LuaForeignValue));
    new (new_fvalue) LuaForeignValue();

    new_fvalue->type.indirectionLevels = fvalue->type.indirectionLevels + 1;
    new_fvalue->type.kind = fvalue->type.kind;
    new_fvalue->type.size = fvalue->type.size;
    new_fvalue->ownsValue = 0;
    new_fvalue->pValue = &fvalue->pValue;

    luaL_getmetatable(L, FOREIGN_VALUE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

static void push_ffi_type(lua_State* L, ffi_type_kind kind, size_t size) {
    LuaForeignType* ftype = (LuaForeignType*)lua_newuserdata(L, sizeof(LuaForeignType));
    new (ftype) LuaForeignType();

    ftype->kind = kind;
    ftype->size = size;

    luaL_getmetatable(L, FOREIGN_TYPE_METATABLE);
    lua_setmetatable(L, -2);
}

LUAU_MODULE_EXPORT int luauopen__ffi(lua_State* L) {
    // Library metatable
    luaL_newmetatable(L, FOREIGN_LIBRARY_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, ffi_lib_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, ffi_lib_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, ffi_lib_getFunction, "GetFunction");
    lua_setfield(L, -2, "GetFunction");

    lua_pop(L, 1);

    // Function metatable
    luaL_newmetatable(L, FOREIGN_FUNCTION_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, ffi_func_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, ffi_func_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, ffi_func_call, "call");
    lua_setfield(L, -2, "__call");

    lua_pop(L, 1);

    // C-type metatable
    luaL_newmetatable(L, FOREIGN_TYPE_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, ffi_type_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, ffi_type_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, ffi_type_call, "call");
    lua_setfield(L, -2, "__call");

    lua_pushcfunction(L, ffi_type_pointer, "Pointer");
    lua_setfield(L, -2, "Pointer");

    lua_pop(L, 1);

    // C-value metatable
    luaL_newmetatable(L, FOREIGN_VALUE_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, ffi_value_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, ffi_value_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, ffi_value_pointer, "Pointer");
    lua_setfield(L, -2, "Pointer");

    lua_pushcfunction(L, ffi_value_get, "Get");
    lua_setfield(L, -2, "Get");
    lua_pushcfunction(L, ffi_value_set, "Set");
    lua_setfield(L, -2, "Set");

    lua_pop(L, 1);

    // Build module table
    lua_newtable(L);

    // Functions
    lua_pushcfunction(L, ffi_loadLibrary, "loadLibrary");
    lua_setfield(L, -2, "loadLibrary");

    // Data types
    push_ffi_type(L, FFI_T_VOID, 0);
    lua_setfield(L, -2, "void");
    push_ffi_type(L, FFI_T_UCHAR, sizeof(unsigned char));
    lua_setfield(L, -2, "unsigned char");
    push_ffi_type(L, FFI_T_CHAR, sizeof(char));
    lua_setfield(L, -2, "char");
    push_ffi_type(L, FFI_T_STR, sizeof(char*));
    lua_setfield(L, -2, "str");
    push_ffi_type(L, FFI_T_U8, sizeof(uint8_t));
    lua_setfield(L, -2, "u8");
    push_ffi_type(L, FFI_T_U16, sizeof(uint16_t));
    lua_setfield(L, -2, "u16");
    push_ffi_type(L, FFI_T_U32, sizeof(uint32_t));
    lua_setfield(L, -2, "u32");
    push_ffi_type(L, FFI_T_U64, sizeof(uint64_t));
    lua_setfield(L, -2, "u64");
    push_ffi_type(L, FFI_T_I8, sizeof(int8_t));
    lua_setfield(L, -2, "i8");
    push_ffi_type(L, FFI_T_I16, sizeof(int16_t));
    lua_setfield(L, -2, "i16");
    push_ffi_type(L, FFI_T_I32, sizeof(int32_t));
    lua_setfield(L, -2, "i32");
    push_ffi_type(L, FFI_T_I64, sizeof(int64_t));
    lua_setfield(L, -2, "i64");

    return 1;
}
