#include "userdata.hpp"

#include <array>
#include <cassert>
#include <memory>

#include "Luau/DenseHash.h"
#include "lstring.h"
#include "lua.h"
#include "lualib.h"

// The smallest possible atom we can use, to allow the largest range we can
#define MIN_ATOM (ATOM_UNDEF + 1)
#define MAX_ATOM (32767)

static Luau::DenseHashMap<lua_State*, uint8_t> currentTag{ nullptr };
static Luau::DenseHashMap<lua_State*, int16_t> currentAtom{ nullptr };

using AtomKey = std::pair<lua_State*, std::string_view>;

struct udataNamecall {
    int16_t atom;
    lua_CFunction callback;
};
struct udataRef {
    udataDef* def;
    uint8_t tag;
    udataNamecall* namecalls;
};

struct udataRegistry {
    std::array<udataDef*, LUA_UTAG_LIMIT> defs{};
    std::array<udataRef*, LUA_UTAG_LIMIT> refs{};
};

struct AtomKeyHash {
    size_t operator()(const AtomKey& k) const {
        size_t h1 = std::hash<lua_State*>{}(k.first);
        size_t h2 = std::hash<std::string_view>{}(k.second);

        return h1 ^ (h2 + 0x9e3779b97f4a7c15ull + (h1 << 6) + (h1 >> 2));
    }
};

static Luau::DenseHashMap<AtomKey, int16_t, AtomKeyHash> atomMap{ { nullptr, std::string_view{} } };
static Luau::DenseHashMap<lua_State*, udataRegistry> registries{ nullptr };

template <typename Key, typename Value, typename Hash, typename Keep>
static void denseHashMapRemoveIf(Luau::DenseHashMap<Key, Value, Hash>& map, const Key& emptyKey,
                                 Keep&& keep) {
    Luau::DenseHashMap<Key, Value, Hash> filtered{ emptyKey };
    for (const auto& entry : map) {
        if (keep(entry.first, entry.second)) {
            filtered[entry.first] = entry.second;
        }
    }

    map = std::move(filtered);
}

static udataRegistry* eryxUdata_getregistry(lua_State* L) {
    return registries.find(lua_mainthread(L));
}

static udataDef* eryxUdata_getdefinition(lua_State* L, int tag) {
    udataRegistry* registry = eryxUdata_getregistry(L);
    if (!registry) {
        return nullptr;
    }

    return registry->defs[tag];
}

static udataRef* eryxUdata_getref(lua_State* L, int tag) {
    udataRegistry* registry = eryxUdata_getregistry(L);
    if (!registry) {
        return nullptr;
    }

    return registry->refs[tag];
}

static int16_t eryxUdata_useratom(lua_State* L, const char* s, size_t l) {
    std::string_view name{ s, l };

    int16_t* atom = atomMap.find({ lua_mainthread(L), name });
    if (atom) return *atom;

    return ATOM_UNDEF;
}

static int eryxUdata_index(lua_State* L) {
    int tag = lua_userdatatag(L, 1);
    if (tag == -1) {
        luaL_typeerrorL(L, 1, "userdata");
    }

    udataDef* definition = eryxUdata_getdefinition(L, tag);
    if (definition == nullptr) {
        luaL_error(L, "invalid argument #1 to '__index' (eryx-tagged userdata expected)");
    }

    const char* name = luaL_optstring(L, 2, NULL);
    if (name) {
        if (udataField* field = definition->fields) {
            while (field->name) {
                if (field->getter && strcmp(field->name, name) == 0) {
                    return (*field->getter)(L);
                }

                field++;
            }
        }

        if (luaL_Reg* method = definition->dotcallMethods) {
            while (method->name) {
                if (strcmp(method->name, name) == 0) {
                    lua_pushcclosure(L, method->func, method->name, 0);
                    return 1;
                }

                method++;
            }
        }

        if (luaL_Reg* method = definition->bothcallMethods) {
            while (method->name) {
                if (strcmp(method->name, name) == 0) {
                    lua_pushcclosure(L, method->func, method->name, 0);
                    return 1;
                }

                method++;
            }
        }
    }

    if (definition->indexFallback) {
        return (*definition->indexFallback)(L);
    }

    return 0;
}

int eryxUdata_newindex(lua_State* L) {
    int tag = lua_userdatatag(L, 1);
    if (tag == -1) {
        luaL_typeerrorL(L, 1, "userdata");
    }

    udataDef* definition = eryxUdata_getdefinition(L, tag);
    if (definition == nullptr) {
        luaL_error(L, "invalid argument #1 to '__newindex' (eryx-tagged userdata expected)");
    }

    const char* name = luaL_optstring(L, 2, NULL);
    if (name) {
        if (udataField* field = definition->fields) {
            while (field->name) {
                if (field->setter && strcmp(field->name, name) == 0) {
                    return (*field->setter)(L);
                }

                field++;
            }
        }
    }

    if (definition->newindexFallback) {
        return (*definition->newindexFallback)(L);
    }

    luaL_errorL(L, "cannot assign field '%s' of %s", name, definition->name);
}

int eryxUdata_namecall(lua_State* L) {
    int tag = lua_userdatatag(L, 1);
    if (tag == -1) {
        luaL_typeerrorL(L, 1, "userdata");
    }

    udataDef* definition = eryxUdata_getdefinition(L, tag);
    if (definition == nullptr) {
        luaL_error(L, "invalid argument #1 to '__namecall' (eryx-tagged userdata expected)");
    }

    int atom;
    const char* name = lua_namecallatom(L, &atom);

    // Fast path for atoms
    udataRef* ref = eryxUdata_getref(L, tag);
    if (atom != ATOM_UNDEF && ref && ref->namecalls) {
        udataNamecall* nc = ref->namecalls;
        while (nc->callback) {
            if (nc->atom == atom) {
                return nc->callback(L);
            }

            nc++;
        }
    }

    // Slow path for strcmp lookup
    if (name) {
        if (luaL_Reg* method = definition->namecallMethods) {
            while (method->name) {
                if (strcmp(method->name, name) == 0) {
                    return method->func(L);
                }

                method++;
            }
        }
        if (luaL_Reg* method = definition->bothcallMethods) {
            while (method->name) {
                if (strcmp(method->name, name) == 0) {
                    return method->func(L);
                }

                method++;
            }
        }
    }

    luaL_errorL(L, "cannot namecall static member '%s' of %s", name, definition->name);
}

udataRef* eryxUdata_registerudata(lua_State* L, udataDef* definition) {
    lua_State* GL = lua_mainthread(L);
    udataRegistry& registry = registries[GL];

    if (!currentTag.find(GL)) {
        currentTag[GL] = 0;
    }

    uint8_t tag = currentTag[GL]++;
    // TODO: Technically we can fall back on untagged userdata in this instance
    // That's a lot of machinery I don't want to put in place right now though
    if (tag >= LUA_UTAG_LIMIT) {
        luaL_error(L, "Tag limit hit when registering %s", definition->name);
    }

    luaL_newmetatable(L, definition->name);

    if (definition->metamethods) {
        luaL_register(L, nullptr, definition->metamethods);
    }

    lua_pushstring(L, definition->name);
    lua_rawsetfield(L, -2, "__type");

    lua_pushcclosure(L, eryxUdata_index, "__index", 0);
    lua_rawsetfield(L, -2, "__index");
    lua_pushcclosure(L, eryxUdata_newindex, "__newindex", 0);
    lua_rawsetfield(L, -2, "__newindex");
    lua_pushcclosure(L, eryxUdata_namecall, "__namecall", 0);
    lua_rawsetfield(L, -2, "__namecall");

    lua_setuserdatametatable(L, tag);

    // Register the destructor
    if (definition->destructor) {
        lua_setuserdatadtor(L, tag, definition->destructor);
    }

    // Register atoms for namecalls
    int numNamecalls = 0;
    if (!currentAtom.find(GL)) {
        currentAtom[GL] = MIN_ATOM;
    }

    if (luaL_Reg* method = definition->namecallMethods) {
        while (method->name) {
            if (!atomMap.find({ GL, method->name })) {
                int16_t newAtom = currentAtom[GL]++;
                // TODO: We can safely fall back to non-atom matching in this instance
                if (newAtom == MAX_ATOM) {
                    luaL_error(L, "Atom limit hit when registering %s.%s", definition->name,
                               method->name);
                }
                atomMap[{ GL, std::string_view{ method->name } }] = newAtom;
            }
            numNamecalls += 1;
            method++;
        }
    }
    if (luaL_Reg* method = definition->bothcallMethods) {
        while (method->name) {
            if (!atomMap.find({ GL, method->name })) {
                int16_t newAtom = currentAtom[GL]++;
                // TODO: We can safely fall back to non-atom matching in this instance
                if (newAtom == MAX_ATOM) {
                    luaL_error(L, "Atom limit hit when registering %s.%s", definition->name,
                               method->name);
                }
                atomMap[{ GL, std::string_view{ method->name } }] = newAtom;
            }
            numNamecalls += 1;
            method++;
        }
    }
    udataNamecall* nc = nullptr;
    if (numNamecalls) {
        nc = (udataNamecall*)malloc(sizeof(udataNamecall) * (numNamecalls + 1));

        int i = 0;
        if (luaL_Reg* method = definition->namecallMethods) {
            while (method->name) {
                // We just assigned these all to the map so we can be a bit unsafe here
                nc[i].atom = *atomMap.find({ GL, method->name });
                nc[i++].callback = method->func;
                method++;
            }
        }
        if (luaL_Reg* method = definition->bothcallMethods) {
            while (method->name) {
                // We just assigned these all to the map so we can be a bit unsafe here
                nc[i].atom = *atomMap.find({ GL, method->name });
                nc[i++].callback = method->func;
                method++;
            }
        }
        // Sentinel
        nc[i].atom = ATOM_UNDEF;
        nc[i].callback = nullptr;
    }

    udataRef* ref = (udataRef*)malloc(sizeof(udataRef));
    ref->tag = tag;
    ref->def = definition;
    ref->namecalls = nc;

    registry.defs[tag] = definition;
    registry.refs[tag] = ref;
    return ref;
}

void eryxUdata_addmethodstotable(lua_State* L, udataDef* definition, int tableIndex) {
    tableIndex = lua_absindex(L, tableIndex);
    if (luaL_Reg* method = definition->dotcallMethods) {
        while (method->name) {
            lua_pushcclosure(L, method->func, method->name, 0);
            lua_rawsetfield(L, tableIndex, method->name);

            method++;
        }
    }
    if (luaL_Reg* method = definition->bothcallMethods) {
        while (method->name) {
            lua_pushcclosure(L, method->func, method->name, 0);
            lua_rawsetfield(L, tableIndex, method->name);

            method++;
        }
    }
}

void* eryxUdata_pushudata(lua_State* L, udataRef* ref) {
    assert(ref);
    return lua_newuserdatataggedwithmetatable(L, ref->def->size, ref->tag);
}

void* eryxUdata_testudata(lua_State* L, udataRef* ref, int index) {
    assert(ref);
    return lua_touserdatatagged(L, index, ref->tag);
}

void* eryxUdata_checkudata(lua_State* L, udataRef* ref, int index) {
    assert(ref);
    void* ud = lua_touserdatatagged(L, index, ref->tag);
    if (ud == nullptr) {
        luaL_typeerrorL(L, index, ref->def->name);
    }
    return ud;
}

void eryxUdata_initialiseEnvironment(lua_State* L) {
    lua_callbacks(L)->useratom = eryxUdata_useratom;
}

void eryxUdata_destroyEnvironment(lua_State* L) {
    lua_State* GL = lua_mainthread(L);
    lua_State* emptyStateKey = nullptr;

    if (udataRegistry* registry = registries.find(GL)) {
        for (udataRef* ref : registry->refs) {
            if (!ref) {
                continue;
            }

            free(ref->namecalls);
            free(ref);
        }
    }

    denseHashMapRemoveIf(registries, emptyStateKey,
                         [GL](lua_State* key, const udataRegistry&) { return key != GL; });
    denseHashMapRemoveIf(currentTag, emptyStateKey,
                         [GL](lua_State* key, uint8_t) { return key != GL; });
    denseHashMapRemoveIf(currentAtom, emptyStateKey,
                         [GL](lua_State* key, int16_t) { return key != GL; });
    denseHashMapRemoveIf(atomMap, AtomKey{ nullptr, std::string_view{} },
                         [GL](const AtomKey& key, int16_t) { return key.first != GL; });
}
