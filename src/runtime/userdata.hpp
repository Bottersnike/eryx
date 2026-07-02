#pragma once

#include "lua.h"
#include "lualib.h"

typedef void(udataDtor)(lua_State* L, void* ptr);

typedef struct udataField {
    // Field name used for `foo.name`
    const char* name;
    // Optional getter
    lua_CFunction getter;
    // Optional setter
    lua_CFunction setter;
} udataField;

typedef struct udataDef {
    // Name of the userdata. Will be assigned to __type and used in error messages
    const char* name;
    // Size of the GC-allocated data required for this userdata
    size_t size;
    // Optional fields accessible on an instance of this userdata
    udataField* fields;
    // Optional fallback for __index
    lua_CFunction indexFallback;
    // Optional fallback for __newindex
    lua_CFunction newindexFallback;

    // Optional list of metamethods, such as __tostring
    // Must not include:
    // - "__type"
    // - "__index"
    // - "__newindex"
    // - "__namecall"
    // They will be ignored
    luaL_Reg* metamethods;

    // Optional list of dotcall (static) methods.
    // ie `foo.bar()`
    luaL_Reg* dotcallMethods;
    // Optional list of namecall (member) methods.
    // ie `foo:bar()`
    luaL_Reg* namecallMethods;
    // Optional list of methods that can be called in both ways.
    // ie both `foo.bar()` and `foo:bar()`
    luaL_Reg* bothcallMethods;

    // Optional destructor called when GC cleans up instances of this userdata
    udataDtor* destructor;
} udataDef;

// Intentional opaque reference to a registered userdata
typedef struct udataRef udataRef;

/**
 * @brief Register a new userdata
 *
 * @param L Lua state
 * @param definition Pointer to userdata definition
 * @return udataRef* Reference to new userdata
 */
udataRef* eryxUdata_registerudata(lua_State* L, udataDef* definition);

/**
 * @brief Add all members of this userdata (dotcall and bothcall) to a table
 *
 * This can be useful when you want to allow both `foo:bar()` and `Foo.bar(foo)`
 *
 * @param L Lua state
 * @param definition Pointer to userdata definition
 * @param tableIndex Stack index for the table to add these items to
 */
void eryxUdata_addmethodstotable(lua_State* L, udataDef* definition, int tableIndex);

/**
 * @brief Create a new userdata and push it to the stack
 *
 * @param L Lua state
 * @param ref Userdata reference
 * @return void* Allocated memory for the userdata
 */
void* eryxUdata_pushudata(lua_State* L, udataRef* ref);

/**
 * @brief Test if an item on the stack is a particular userdata
 *
 * @param L Lua state
 * @param ref Userdata reference
 * @param index Stack index
 * @return void* Located userdata memory, or nullptr if the type does not match
 */
void* eryxUdata_testudata(lua_State* L, udataRef* ref, int index);

/**
 * @brief Check if an item on the stack is a particular userdata
 *
 * This function will throw a Lua error if this is not the case
 *
 * @param L Lua state
 * @param ref Userdata reference
 * @param index Stack index
 * @return void* Located userdata memory
 */
void* eryxUdata_checkudata(lua_State* L, udataRef* ref, int index);

/**
 * @brief Runtime handler called during environment initialisation
 *
 * Registers the "useratom" callback on the Lua state
 *
 * @param L Lua state
 */
void eryxUdata_initialiseEnvironment(lua_State* L);

/**
 * @brief Runtime handler called before environment teardown
 *
 * Releases userdata bookkeeping associated with the Lua main state.
 *
 * @param L Lua state
 */
void eryxUdata_destroyEnvironment(lua_State* L);
