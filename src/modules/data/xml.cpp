// xml.cpp – XML module for Luau (element tree + XPath)
// Wraps pugixml to provide DOM parsing, manipulation, serialisation and XPath queries.

#include <sstream>
#include <string>
#include <vector>

#include "../../LuaUtil.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "module_helpers.hpp"
#include "pugixml.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_xml",
};
LUAU_MODULE_INFO()

// ── Metatable names ───────────────────────────────────────────────────────────

static const char* MT_DOCUMENT = "XmlDocument";
static const char* MT_NODE = "XmlNode";

// ── Helpers ───────────────────────────────────────────────────────────────────

// The xml_document owns all memory. We store it as a shared_ptr so that
// XmlNode handles can prevent premature collection while they still
// reference the tree.  A raw pugixml xml_node is just a lightweight
// handle (a pointer into the document's internal storage).

struct DocRef {
    pugi::xml_document* doc;
    int refcount;
};

struct LuaXmlDocument {
    DocRef* ref;
};

struct LuaXmlNode {
    pugi::xml_node node;
    DocRef* ref;  // prevent document GC while node is alive
};

static DocRef* docref_new() {
    DocRef* r = new DocRef();
    r->doc = new pugi::xml_document();
    r->refcount = 1;
    return r;
}

static void docref_retain(DocRef* r) {
    if (r) r->refcount++;
}

static void docref_release(DocRef* r) {
    if (r && --r->refcount == 0) {
        delete r->doc;
        delete r;
    }
}

// Push a pugixml node handle as a LuaXmlNode userdata.  The caller must
// ensure the DocRef stays alive (by retaining it before calling this).
static void push_xml_node(lua_State* L, pugi::xml_node node, DocRef* ref) {
    if (node.empty()) {
        lua_pushnil(L);
        return;
    }
    LuaXmlNode* ud = (LuaXmlNode*)lua_newuserdata(L, sizeof(LuaXmlNode));
    ud->node = node;
    ud->ref = ref;
    docref_retain(ref);
    luaL_getmetatable(L, MT_NODE);
    lua_setmetatable(L, -2);
}

// Check that argument is an XmlNode and return the handle.
static LuaXmlNode* check_node(lua_State* L, int idx) {
    return (LuaXmlNode*)luaL_checkudata(L, idx, MT_NODE);
}

// Check that argument is an XmlDocument and return the handle.
static LuaXmlDocument* check_doc(lua_State* L, int idx) {
    return (LuaXmlDocument*)luaL_checkudata(L, idx, MT_DOCUMENT);
}

// ── Node type name helper ─────────────────────────────────────────────────────

static const char* node_type_name(pugi::xml_node_type t) {
    switch (t) {
        case pugi::node_null:
            return "null";
        case pugi::node_document:
            return "document";
        case pugi::node_element:
            return "element";
        case pugi::node_pcdata:
            return "pcdata";
        case pugi::node_cdata:
            return "cdata";
        case pugi::node_comment:
            return "comment";
        case pugi::node_pi:
            return "pi";
        case pugi::node_declaration:
            return "declaration";
        case pugi::node_doctype:
            return "doctype";
        default:
            return "unknown";
    }
}

// ── xml.parse(str) -> XmlDocument ─────────────────────────────────────────────

static int xml_parse(lua_State* L) {
    size_t len;
    const char* str = luaL_checklstring(L, 1, &len);

    LuaXmlDocument* ud = (LuaXmlDocument*)lua_newuserdata(L, sizeof(LuaXmlDocument));
    ud->ref = docref_new();

    pugi::xml_parse_result result = ud->ref->doc->load_buffer(str, len);
    if (!result) {
        std::string err = std::string("XML parse error: ") + result.description() + " at offset " +
                          std::to_string(result.offset);
        docref_release(ud->ref);
        ud->ref = nullptr;
        luaL_error(L, "%s", err.c_str());
    }

    luaL_getmetatable(L, MT_DOCUMENT);
    lua_setmetatable(L, -2);
    return 1;
}

// ── xml.load(path) -> XmlDocument ─────────────────────────────────────────────

static int xml_load(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);

    LuaXmlDocument* ud = (LuaXmlDocument*)lua_newuserdata(L, sizeof(LuaXmlDocument));
    ud->ref = docref_new();

    pugi::xml_parse_result result = ud->ref->doc->load_file(path.c_str());
    if (!result) {
        std::string err = std::string("XML load error: ") + result.description() + " at offset " +
                          std::to_string(result.offset);
        docref_release(ud->ref);
        ud->ref = nullptr;
        luaL_error(L, "%s", err.c_str());
    }

    luaL_getmetatable(L, MT_DOCUMENT);
    lua_setmetatable(L, -2);
    return 1;
}

// ── xml.document() -> new empty XmlDocument ───────────────────────────────────

static int xml_document(lua_State* L) {
    LuaXmlDocument* ud = (LuaXmlDocument*)lua_newuserdata(L, sizeof(LuaXmlDocument));
    ud->ref = docref_new();
    luaL_getmetatable(L, MT_DOCUMENT);
    lua_setmetatable(L, -2);
    return 1;
}

// ── Document methods ──────────────────────────────────────────────────────────

static int doc_gc(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    docref_release(ud->ref);
    ud->ref = nullptr;
    return 0;
}

static int doc_tostring(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    std::ostringstream ss;
    ud->ref->doc->save(ss, "\t", pugi::format_default);
    std::string s = ss.str();
    lua_pushlstring(L, s.c_str(), s.size());
    return 1;
}

// doc:root() -> XmlNode (the document_element)
static int doc_root(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    push_xml_node(L, ud->ref->doc->document_element(), ud->ref);
    return 1;
}

// doc:save(indent?, flags?) -> string
static int doc_save(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    const char* indent = luaL_optstring(L, 2, "\t");
    // flags: "raw" | "indent" (default) | "no_declaration"
    unsigned int flags = pugi::format_default;
    if (lua_isstring(L, 3)) {
        const char* f = lua_tostring(L, 3);
        if (strcmp(f, "raw") == 0)
            flags = pugi::format_raw;
        else if (strcmp(f, "no_declaration") == 0)
            flags = pugi::format_no_declaration;
    }
    std::ostringstream ss;
    ud->ref->doc->save(ss, indent, flags);
    std::string s = ss.str();
    lua_pushlstring(L, s.c_str(), s.size());
    return 1;
}

// doc:savefile(path, indent?, flags?)
static int doc_savefile(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    std::string path = luaL_checkpathlike(L, 2);
    const char* indent = luaL_optstring(L, 3, "\t");
    unsigned int flags = pugi::format_default;
    if (lua_isstring(L, 4)) {
        const char* f = lua_tostring(L, 4);
        if (strcmp(f, "raw") == 0)
            flags = pugi::format_raw;
        else if (strcmp(f, "no_declaration") == 0)
            flags = pugi::format_no_declaration;
    }
    bool ok = ud->ref->doc->save_file(path.c_str(), indent, flags);
    if (!ok) luaL_error(L, "Failed to save XML file: %s", path.c_str());
    return 0;
}

// doc:xpath(query) -> {XmlNode...}
static int doc_xpath(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    const char* query = luaL_checkstring(L, 2);

    try {
        pugi::xpath_node_set nodes = ud->ref->doc->select_nodes(query);
        lua_newtable(L);
        int i = 1;
        for (auto& xn : nodes) {
            pugi::xml_node n = xn.node();
            if (!n) {
                // Attribute result - push as node's parent so the user can get at it
                n = xn.parent();
            }
            push_xml_node(L, n, ud->ref);
            lua_rawseti(L, -2, i++);
        }
    } catch (const pugi::xpath_exception& e) {
        luaL_error(L, "XPath error: %s", e.what());
    }

    return 1;
}

// doc:xpathone(query) -> XmlNode | nil
static int doc_xpathone(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    const char* query = luaL_checkstring(L, 2);

    try {
        pugi::xpath_node xn = ud->ref->doc->select_node(query);
        if (!xn) {
            lua_pushnil(L);
        } else {
            pugi::xml_node n = xn.node();
            if (!n) n = xn.parent();
            push_xml_node(L, n, ud->ref);
        }
    } catch (const pugi::xpath_exception& e) {
        luaL_error(L, "XPath error: %s", e.what());
    }

    return 1;
}

// doc:appendchild(name) -> XmlNode
static int doc_appendchild(lua_State* L) {
    LuaXmlDocument* ud = check_doc(L, 1);
    const char* name = luaL_checkstring(L, 2);
    pugi::xml_node child = ud->ref->doc->append_child(name);
    if (child.empty()) luaL_error(L, "Failed to append child");
    push_xml_node(L, child, ud->ref);
    return 1;
}

// ── Node GC ───────────────────────────────────────────────────────────────────

static int node_gc(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    docref_release(ud->ref);
    ud->ref = nullptr;
    return 0;
}

// ── Node methods ──────────────────────────────────────────────────────────────

static int node_tostring(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    std::ostringstream ss;
    ud->node.print(ss, "\t", pugi::format_default);
    std::string s = ss.str();
    lua_pushlstring(L, s.c_str(), s.size());
    return 1;
}

// node:children() -> {XmlNode...}
static int node_children(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* filter = luaL_optstring(L, 2, nullptr);
    lua_newtable(L);
    int i = 1;
    for (auto& child : ud->node.children()) {
        if (child.type() != pugi::node_element) continue;
        if (filter && strcmp(child.name(), filter) != 0) continue;
        push_xml_node(L, child, ud->ref);
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

// node:child(name) -> XmlNode | nil
static int node_child(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    push_xml_node(L, ud->node.child(name), ud->ref);
    return 1;
}

// node:appendchild(name) -> XmlNode
static int node_appendchild(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    pugi::xml_node child = ud->node.append_child(name);
    if (child.empty()) luaL_error(L, "Failed to append child element");
    push_xml_node(L, child, ud->ref);
    return 1;
}

// node:prependchild(name) -> XmlNode
static int node_prependchild(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    pugi::xml_node child = ud->node.prepend_child(name);
    if (child.empty()) luaL_error(L, "Failed to prepend child element");
    push_xml_node(L, child, ud->ref);
    return 1;
}

// node:removechild(name_or_node)
static int node_removechild(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    if (lua_isstring(L, 2)) {
        const char* name = lua_tostring(L, 2);
        if (!ud->node.remove_child(name)) luaL_error(L, "Failed to remove child '%s'", name);
    } else {
        LuaXmlNode* child = check_node(L, 2);
        if (!ud->node.remove_child(child->node)) luaL_error(L, "Failed to remove child node");
    }
    return 0;
}

// node:parent() -> XmlNode | nil
static int node_parent(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    push_xml_node(L, ud->node.parent(), ud->ref);
    return 1;
}

// node:nextsibling(name?) -> XmlNode | nil
static int node_nextsibling(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_optstring(L, 2, nullptr);
    push_xml_node(L, name ? ud->node.next_sibling(name) : ud->node.next_sibling(), ud->ref);
    return 1;
}

// node:prevsibling(name?) -> XmlNode | nil
static int node_prevsibling(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_optstring(L, 2, nullptr);
    push_xml_node(L, name ? ud->node.previous_sibling(name) : ud->node.previous_sibling(), ud->ref);
    return 1;
}

// node:attr(name) -> string | nil
static int node_attr(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    pugi::xml_attribute attr = ud->node.attribute(name);
    if (attr.empty()) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, attr.value());
    }
    return 1;
}

// node:setattr(name, value)
static int node_setattr(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    const char* val = luaL_checkstring(L, 3);
    pugi::xml_attribute attr = ud->node.attribute(name);
    if (attr.empty()) {
        attr = ud->node.append_attribute(name);
    }
    if (!attr.set_value(val)) luaL_error(L, "Failed to set attribute '%s'", name);
    return 0;
}

// node:removeattr(name)
static int node_removeattr(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    if (!ud->node.remove_attribute(name)) luaL_error(L, "Failed to remove attribute '%s'", name);
    return 0;
}

// node:attrs() -> {[name] = value, ...}
static int node_attrs(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    lua_newtable(L);
    for (auto& attr : ud->node.attributes()) {
        lua_pushstring(L, attr.value());
        lua_setfield(L, -2, attr.name());
    }
    return 1;
}

// node:text() -> string
static int node_text(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    lua_pushstring(L, ud->node.text().get());
    return 1;
}

// node:settext(value)
static int node_settext(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* val = luaL_checkstring(L, 2);
    if (!ud->node.text().set(val)) luaL_error(L, "Failed to set text");
    return 0;
}

// node:xpath(query) -> {XmlNode...}
static int node_xpath(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* query = luaL_checkstring(L, 2);

    try {
        pugi::xpath_node_set nodes = ud->node.select_nodes(query);
        lua_newtable(L);
        int i = 1;
        for (auto& xn : nodes) {
            pugi::xml_node n = xn.node();
            if (!n) n = xn.parent();
            push_xml_node(L, n, ud->ref);
            lua_rawseti(L, -2, i++);
        }
    } catch (const pugi::xpath_exception& e) {
        luaL_error(L, "XPath error: %s", e.what());
    }

    return 1;
}

// node:xpathone(query) -> XmlNode | nil
static int node_xpathone(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* query = luaL_checkstring(L, 2);

    try {
        pugi::xpath_node xn = ud->node.select_node(query);
        if (!xn) {
            lua_pushnil(L);
        } else {
            pugi::xml_node n = xn.node();
            if (!n) n = xn.parent();
            push_xml_node(L, n, ud->ref);
        }
    } catch (const pugi::xpath_exception& e) {
        luaL_error(L, "XPath error: %s", e.what());
    }

    return 1;
}

// node:xpathvalue(query) -> string | number | boolean | nil
static int node_xpathvalue(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* query = luaL_checkstring(L, 2);

    try {
        pugi::xpath_query q(query);
        switch (q.return_type()) {
            case pugi::xpath_type_boolean:
                lua_pushboolean(L, q.evaluate_boolean(ud->node));
                break;
            case pugi::xpath_type_number:
                lua_pushnumber(L, q.evaluate_number(ud->node));
                break;
            case pugi::xpath_type_string: {
                std::string s = q.evaluate_string(ud->node);
                lua_pushlstring(L, s.c_str(), s.size());
                break;
            }
            default:
                lua_pushnil(L);
                break;
        }
    } catch (const pugi::xpath_exception& e) {
        luaL_error(L, "XPath error: %s", e.what());
    }

    return 1;
}

// node:path(delimiter?) -> string
static int node_path(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* delim = luaL_optstring(L, 2, "/");
    std::string p = ud->node.path(delim[0]);
    lua_pushlstring(L, p.c_str(), p.size());
    return 1;
}

// ── Node __index ──────────────────────────────────────────────────────────────

static int node_index(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "name") == 0) {
        lua_pushstring(L, ud->node.name());
        return 1;
    }
    if (strcmp(key, "type") == 0) {
        lua_pushstring(L, node_type_name(ud->node.type()));
        return 1;
    }
    if (strcmp(key, "value") == 0) {
        lua_pushstring(L, ud->node.child_value());
        return 1;
    }

    // Fall through to metatable for methods
    return eryx_metatable_index(L);
}

// node:setname(name)
static int node_setname(lua_State* L) {
    LuaXmlNode* ud = check_node(L, 1);
    const char* name = luaL_checkstring(L, 2);
    if (!ud->node.set_name(name)) luaL_error(L, "Failed to set node name");
    return 0;
}

// ── Document __index ──────────────────────────────────────────────────────────

static int doc_index(lua_State* L) {
    // Fall through to metatable for methods
    return eryx_metatable_index(L);
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_xml(lua_State* L) {
    // -- XmlDocument metatable --
    luaL_newmetatable(L, MT_DOCUMENT);
    lua_pushcfunction(L, doc_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, doc_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, doc_gc, "gc");
    lua_setfield(L, -2, "__gc");

    // Methods
    lua_pushcfunction(L, doc_root, "root");
    lua_setfield(L, -2, "root");
    lua_pushcfunction(L, doc_save, "save");
    lua_setfield(L, -2, "save");
    lua_pushcfunction(L, doc_savefile, "saveFile");
    lua_setfield(L, -2, "saveFile");
    lua_pushcfunction(L, doc_xpath, "xpath");
    lua_setfield(L, -2, "xpath");
    lua_pushcfunction(L, doc_xpathone, "xpathOne");
    lua_setfield(L, -2, "xpathOne");
    lua_pushcfunction(L, doc_appendchild, "appendChild");
    lua_setfield(L, -2, "appendChild");
    lua_pop(L, 1);

    // -- XmlNode metatable --
    luaL_newmetatable(L, MT_NODE);
    lua_pushcfunction(L, node_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, node_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, node_gc, "gc");
    lua_setfield(L, -2, "__gc");

    // Methods
    lua_pushcfunction(L, node_children, "children");
    lua_setfield(L, -2, "children");
    lua_pushcfunction(L, node_child, "child");
    lua_setfield(L, -2, "child");
    lua_pushcfunction(L, node_appendchild, "appendChild");
    lua_setfield(L, -2, "appendChild");
    lua_pushcfunction(L, node_prependchild, "prependChild");
    lua_setfield(L, -2, "prependChild");
    lua_pushcfunction(L, node_removechild, "removeChild");
    lua_setfield(L, -2, "removeChild");
    lua_pushcfunction(L, node_parent, "parent");
    lua_setfield(L, -2, "parent");
    lua_pushcfunction(L, node_nextsibling, "nextSibling");
    lua_setfield(L, -2, "nextSibling");
    lua_pushcfunction(L, node_prevsibling, "prevSibling");
    lua_setfield(L, -2, "prevSibling");
    lua_pushcfunction(L, node_attr, "attr");
    lua_setfield(L, -2, "attr");
    lua_pushcfunction(L, node_setattr, "setAttr");
    lua_setfield(L, -2, "setAttr");
    lua_pushcfunction(L, node_removeattr, "removeAttr");
    lua_setfield(L, -2, "removeAttr");
    lua_pushcfunction(L, node_attrs, "attrs");
    lua_setfield(L, -2, "attrs");
    lua_pushcfunction(L, node_text, "text");
    lua_setfield(L, -2, "text");
    lua_pushcfunction(L, node_settext, "setText");
    lua_setfield(L, -2, "setText");
    lua_pushcfunction(L, node_xpath, "xpath");
    lua_setfield(L, -2, "xpath");
    lua_pushcfunction(L, node_xpathone, "xpathOne");
    lua_setfield(L, -2, "xpathOne");
    lua_pushcfunction(L, node_xpathvalue, "xpathValue");
    lua_setfield(L, -2, "xpathValue");
    lua_pushcfunction(L, node_path, "path");
    lua_setfield(L, -2, "path");
    lua_pushcfunction(L, node_setname, "setName");
    lua_setfield(L, -2, "setName");
    lua_pop(L, 1);

    // -- Module table --
    lua_newtable(L);
    lua_pushcfunction(L, xml_parse, "parse");
    lua_setfield(L, -2, "parse");
    lua_pushcfunction(L, xml_load, "load");
    lua_setfield(L, -2, "load");
    lua_pushcfunction(L, xml_document, "document");
    lua_setfield(L, -2, "document");
    return 1;
}
