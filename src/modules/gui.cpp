#include <algorithm>
#include <cctype>
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "../runtime/runtime_host.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "wx/aboutdlg.h"
#include "wx/app.h"
#include "wx/artprov.h"
#include "wx/bitmap.h"
#include "wx/button.h"
#include "wx/checkbox.h"
#include "wx/choicdlg.h"
#include "wx/choice.h"
#include "wx/clipbrd.h"
#include "wx/clrpicker.h"
#include "wx/colordlg.h"
#include "wx/combobox.h"
#include "wx/dataview.h"
#include "wx/datectrl.h"
#include "wx/dateevt.h"
#include "wx/dialog.h"
#include "wx/dirdlg.h"
#include "wx/evtloop.h"
#include "wx/filedlg.h"
#include "wx/fontdlg.h"
#include "wx/frame.h"
#include "wx/gauge.h"
#include "wx/hyperlink.h"
#include "wx/image.h"
#include "wx/infobar.h"
#include "wx/listbox.h"
#include "wx/listctrl.h"
#include "wx/menu.h"
#include "wx/msgdlg.h"
#include "wx/notebook.h"
#include "wx/numdlg.h"
#include "wx/panel.h"
#include "wx/progdlg.h"
#include "wx/radiobut.h"
#include "wx/scrolwin.h"
#include "wx/settings.h"
#include "wx/sizer.h"
#include "wx/slider.h"
#include "wx/spinctrl.h"
#include "wx/splitter.h"
#include "wx/srchctrl.h"
#include "wx/statbox.h"
#include "wx/statline.h"
#include "wx/stattext.h"
#include "wx/statusbr.h"
#include "wx/textctrl.h"
#include "wx/textdlg.h"
#include "wx/tglbtn.h"
#include "wx/toolbar.h"
#include "wx/treectrl.h"
#include "wx/utils.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_gui",
};
LUAU_MODULE_INFO()

namespace {

class EryxWxApp final : public wxApp {
   public:
    bool OnInit() override { return true; }
};

wxIMPLEMENT_APP_NO_MAIN(EryxWxApp);

enum class GuiKind {
    App,
    Window,
    Dialog,
    Layout,
    Spacer,
    Label,
    Button,
    ToggleButton,
    ToolBar,
    TextBox,
    TextArea,
    SearchBox,
    CheckBox,
    RadioButton,
    DatePicker,
    Hyperlink,
    Choice,
    ComboBox,
    ListBox,
    TreeView,
    Slider,
    SpinBox,
    ProgressBar,
    Tabs,
    TableView,
    ListView,
    Panel,
    ScrollArea,
    GroupBox,
    StaticLine,
    InfoBar,
    Splitter,
    StatusBar,
    MenuBar,
    Menu,
    Action,
    Bitmap,
};

struct GuiBase {
    GuiKind kind;
    EryxRuntime* rt = nullptr;
    int selfRef = LUA_NOREF;
    bool pinned = false;
};

struct LayoutChild {
    int ref = LUA_NOREF;
    bool expand = false;
};

struct TableColumn {
    std::string key;
    std::string title;
    int width = -1;
    bool expand = false;
};

struct TableRow {
    std::unordered_map<std::string, std::string> values;
};

struct TreeNode {
    std::string label;
    std::vector<TreeNode> children;
};

struct TabPage {
    std::string title;
    int childRef = LUA_NOREF;
};

struct GuiAppHandle {
    GuiBase base{ GuiKind::App };
};

enum class LayoutKind {
    Box,
    Grid,
    Form,
};

struct GuiLayout {
    GuiBase base{ GuiKind::Layout };
    wxSizer* sizer = nullptr;
    wxWindow* hostWindow = nullptr;
    wxWindow* sizerHost = nullptr;
    LayoutKind kind = LayoutKind::Box;
    int orient = wxVERTICAL;
    int columns = 1;
    int gap = 0;
    int padding = 0;
    std::vector<LayoutChild> children;
};

struct GuiSpacer {
    GuiBase base{ GuiKind::Spacer };
    int size = 0;
};

struct GuiBitmap {
    GuiBase base{ GuiKind::Bitmap };
    wxBitmap* bitmap = nullptr;
};

struct GuiWidget {
    GuiBase base{ GuiKind::Label };
    wxWindow* window = nullptr;
    wxWindow* parent = nullptr;
    wxWindow* contentHost = nullptr;
    wxStaticBox* staticBox = nullptr;
    std::string text;
    std::string placeholder;
    bool enabled = true;
    bool checked = false;
    bool readOnly = false;
    bool password = false;
    bool processEnter = false;
    int minValue = 0;
    int selectedIndex = -1;
    int range = 100;
    int gaugeValue = 0;
    int onClickRef = LUA_NOREF;
    int onChangeRef = LUA_NOREF;
    int onSelectRef = LUA_NOREF;
    int onSubmitRef = LUA_NOREF;
    int iconRef = LUA_NOREF;
    int childRef = LUA_NOREF;
    int secondChildRef = LUA_NOREF;
    int splitterPosition = 240;
    bool splitterVertical = true;
    std::vector<int> itemRefs;
    std::vector<std::string> items;
    std::vector<TableColumn> columns;
    std::vector<TableRow> rows;
    std::vector<TreeNode> treeNodes;
    std::vector<TabPage> tabs;
    std::string filter;
};

struct GuiStatusBar {
    GuiBase base{ GuiKind::StatusBar };
    wxStatusBar* bar = nullptr;
    wxFrame* owner = nullptr;
    std::vector<std::string> fields;
    std::vector<int> widths;
};

struct GuiAction {
    GuiBase base{ GuiKind::Action };
    wxMenuItem* item = nullptr;
    wxMenu* owner = nullptr;
    std::string label;
    int callbackRef = LUA_NOREF;
    int id = wxID_ANY;
};

struct GuiMenu {
    GuiBase base{ GuiKind::Menu };
    wxMenu* menu = nullptr;
    std::string title;
    std::vector<int> itemRefs;
};

struct GuiMenuBar {
    GuiBase base{ GuiKind::MenuBar };
    wxMenuBar* menuBar = nullptr;
    std::vector<int> menuRefs;
};

struct GuiWindow {
    GuiBase base{ GuiKind::Window };
    wxTopLevelWindow* topLevel = nullptr;
    wxFrame* frame = nullptr;
    wxDialog* dialog = nullptr;
    bool closing = false;
    bool modalLoopActive = false;
    int modalResult = wxID_CANCEL;
    int minWidth = -1;
    int minHeight = -1;
    int layoutRef = LUA_NOREF;
    int statusBarRef = LUA_NOREF;
    int menuBarRef = LUA_NOREF;
    int onCloseRef = LUA_NOREF;
};

constexpr const char* MT_APP = "eryx.gui.app";
constexpr const char* MT_WINDOW = "eryx.gui.window";
constexpr const char* MT_DIALOG = "eryx.gui.dialog";
constexpr const char* MT_LAYOUT = "eryx.gui.layout";
constexpr const char* MT_SPACER = "eryx.gui.spacer";
constexpr const char* MT_WIDGET = "eryx.gui.widget";
constexpr const char* MT_STATUS = "eryx.gui.statusbar";
constexpr const char* MT_MENU = "eryx.gui.menu";
constexpr const char* MT_MENUBAR = "eryx.gui.menubar";
constexpr const char* MT_ACTION = "eryx.gui.action";
constexpr const char* MT_BITMAP = "eryx.gui.bitmap";

bool g_wxInitialised = false;
bool g_appQuitRequested = false;
int g_liveWindows = 0;

static wxString to_wx(const std::string& value) { return wxString::FromUTF8(value.c_str()); }

static std::string to_utf8(const wxString& value) {
    wxScopedCharBuffer buffer = value.utf8_str();
    return std::string(buffer.data(), buffer.length());
}

static std::string to_iso_date(const wxDateTime& value) {
    if (!value.IsValid()) return "";
    return to_utf8(value.FormatISODate());
}

static wxDateTime from_iso_date(const std::string& value) {
    wxDateTime date;
    if (!value.empty()) {
        date.ParseISODate(to_wx(value));
    }
    return date;
}

static void release_ref(lua_State* L, int& ref) {
    if (ref != LUA_NOREF) {
        lua_unref(L, ref);
        ref = LUA_NOREF;
    }
}

static int store_value_ref(lua_State* L, int idx) {
    idx = lua_absindex(L, idx);
    lua_pushvalue(L, idx);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);
    return ref;
}

static void pin_self(lua_State* L, GuiBase& base, int idx) {
    if (base.pinned) return;
    base.selfRef = store_value_ref(L, idx);
    base.pinned = true;
}

static void unpin_self(lua_State* L, GuiBase& base) {
    if (!base.pinned) return;
    release_ref(L, base.selfRef);
    base.pinned = false;
}

static void ensure_wx(lua_State* L) {
    if (g_wxInitialised) return;

    int argc = 0;
    char** argv = nullptr;
    if (!wxEntryStart(argc, argv)) {
        luaL_error(L, "failed to initialise wxWidgets");
    }
    if (!wxTheApp || !wxTheApp->CallOnInit()) {
        luaL_error(L, "failed to start wxWidgets app");
    }

    wxTheApp->SetExitOnFrameDelete(false);
    g_wxInitialised = true;
}

template <typename T>
static T* check_udata(lua_State* L, int idx, const char* mt) {
    udataRef* ref = eryxUdata_getudata(L, mt);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", mt);
        return nullptr;
    }
    return static_cast<T*>(eryxUdata_checkudata(L, ref, idx));
}

template <typename T>
static T* test_udata(lua_State* L, int idx, const char* mt) {
    udataRef* ref = eryxUdata_getudata(L, mt);
    return ref ? static_cast<T*>(eryxUdata_testudata(L, ref, idx)) : nullptr;
}

static GuiBase* check_any(lua_State* L, int idx) {
    if (auto* p = test_udata<GuiBase>(L, idx, MT_LAYOUT)) return p;
    if (auto* p = test_udata<GuiBase>(L, idx, MT_SPACER)) return p;
    if (auto* p = test_udata<GuiBase>(L, idx, MT_WIDGET)) return p;
    if (auto* p = test_udata<GuiBase>(L, idx, MT_STATUS)) return p;
    luaL_error(L, "gui widget, spacer, or layout expected");
    return nullptr;
}

static GuiLayout* as_layout(GuiBase* base) {
    return base && base->kind == GuiKind::Layout ? reinterpret_cast<GuiLayout*>(base) : nullptr;
}

static GuiWidget* as_widget(GuiBase* base) {
    if (!base) return nullptr;
    switch (base->kind) {
        case GuiKind::Label:
        case GuiKind::Button:
        case GuiKind::ToggleButton:
        case GuiKind::ToolBar:
        case GuiKind::TextBox:
        case GuiKind::TextArea:
        case GuiKind::SearchBox:
        case GuiKind::CheckBox:
        case GuiKind::RadioButton:
        case GuiKind::DatePicker:
        case GuiKind::Hyperlink:
        case GuiKind::Choice:
        case GuiKind::ComboBox:
        case GuiKind::ListBox:
        case GuiKind::TreeView:
        case GuiKind::Slider:
        case GuiKind::SpinBox:
        case GuiKind::ProgressBar:
        case GuiKind::Tabs:
        case GuiKind::TableView:
        case GuiKind::ListView:
        case GuiKind::Panel:
        case GuiKind::ScrollArea:
        case GuiKind::GroupBox:
        case GuiKind::StaticLine:
        case GuiKind::InfoBar:
        case GuiKind::Splitter:
            return reinterpret_cast<GuiWidget*>(base);
        default:
            return nullptr;
    }
}

static GuiSpacer* as_spacer(GuiBase* base) {
    return base && base->kind == GuiKind::Spacer ? reinterpret_cast<GuiSpacer*>(base) : nullptr;
}

static void queue_callback_start(EryxRuntime* rt, int callbackRef, int nargs,
                                 const std::function<void(lua_State*)>& pushArgs) {
    if (callbackRef == LUA_NOREF) return;

    lua_State* GL = rt->GL;
    lua_State* TL = lua_newthread(GL);
    lua_getref(GL, callbackRef);
    lua_xmove(GL, TL, 1);
    pushArgs(TL);
    int ref = lua_ref(GL, -1);
    lua_pop(GL, 1);
    eryx_push_thread(rt, ref, nargs, false);
}

static void queue_callback0(EryxRuntime* rt, int callbackRef) {
    queue_callback_start(rt, callbackRef, 0, [](lua_State*) {});
}

static void queue_callback1_string(EryxRuntime* rt, int callbackRef, const std::string& value) {
    queue_callback_start(rt, callbackRef, 1,
                         [&](lua_State* TL) { lua_pushstring(TL, value.c_str()); });
}

static void queue_callback1_boolean(EryxRuntime* rt, int callbackRef, bool value) {
    queue_callback_start(rt, callbackRef, 1, [&](lua_State* TL) { lua_pushboolean(TL, value); });
}

static void queue_callback1_integer(EryxRuntime* rt, int callbackRef, int value) {
    queue_callback_start(rt, callbackRef, 1, [&](lua_State* TL) { lua_pushinteger(TL, value); });
}

static void queue_close_callback(EryxRuntime* rt, int callbackRef) {
    queue_callback_start(rt, callbackRef, 1, [](lua_State* TL) {
        lua_createtable(TL, 0, 2);
        lua_pushboolean(TL, false);
        lua_setfield(TL, -2, "canVeto");
        lua_pushboolean(TL, true);
        lua_setfield(TL, -2, "closed");
        lua_setreadonly(TL, -1, true);
    });
}

static EryxRuntimeRunResult pump_runtime_once(EryxRuntime* rt) {
    EryxRuntimeHost host;
    host.GL = rt->GL;
    host.rt = rt;

    lua_State* running = nullptr;
    return eryx_runtime_run_once(&host, &running, nullptr, UV_RUN_NOWAIT);
}

static bool process_wx_once(wxEventLoopBase* loop) {
    bool didWork = wxTheApp->HasPendingEvents();

    wxTheApp->ProcessPendingEvents();
    for (int i = 0; i < 64 && loop->Pending(); ++i) {
        didWork = true;
        if (!loop->Dispatch()) {
            g_appQuitRequested = true;
            break;
        }
    }
    loop->ProcessIdle();
    return didWork;
}

static std::string lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return value;
}

static std::string lua_value_to_string(lua_State* L, int idx) {
    size_t len = 0;
    const char* raw = lua_tolstring(L, idx, &len);
    if (raw) return std::string(raw, len);
    luaL_tolstring(L, idx, nullptr);
    std::string value = lua_tostring(L, -1);
    lua_pop(L, 1);
    return value;
}

static std::string opt_constructor_text(lua_State* L, int idx = 1) {
    const int top = lua_gettop(L);
    if (top < idx || lua_isnoneornil(L, idx)) {
        return "";
    }

    if (lua_type(L, idx) == LUA_TSTRING) {
        size_t len = 0;
        const char* value = lua_tolstring(L, idx, &len);
        return std::string(value, len);
    }

    if (top >= idx + 1 && !lua_isnoneornil(L, idx + 1)) {
        if (lua_type(L, idx + 1) == LUA_TSTRING) {
            size_t len = 0;
            const char* value = lua_tolstring(L, idx + 1, &len);
            return std::string(value, len);
        }
        luaL_checkstring(L, idx + 1);
    }

    if (lua_type(L, idx) == LUA_TUSERDATA || lua_type(L, idx) == LUA_TLIGHTUSERDATA ||
        lua_type(L, idx) == LUA_TTABLE) {
        return "";
    }

    luaL_checkstring(L, idx);
    return "";
}

static int opt_constructor_integer(lua_State* L, int defaultValue, int idx = 1) {
    const int top = lua_gettop(L);
    if (top < idx || lua_isnoneornil(L, idx)) {
        return defaultValue;
    }

    if (lua_isnumber(L, idx)) {
        return luaL_checkinteger(L, idx);
    }

    if (top >= idx + 1 && !lua_isnoneornil(L, idx + 1) && lua_isnumber(L, idx + 1)) {
        return luaL_checkinteger(L, idx + 1);
    }

    if (lua_type(L, idx) == LUA_TUSERDATA || lua_type(L, idx) == LUA_TLIGHTUSERDATA ||
        lua_type(L, idx) == LUA_TTABLE) {
        return defaultValue;
    }

    return luaL_checkinteger(L, idx);
}

static GuiBitmap* check_bitmap(lua_State* L, int idx) {
    return check_udata<GuiBitmap>(L, idx, MT_BITMAP);
}
static GuiLayout* check_layout(lua_State* L, int idx) {
    return check_udata<GuiLayout>(L, idx, MT_LAYOUT);
}
static GuiWidget* check_widget(lua_State* L, int idx) {
    return check_udata<GuiWidget>(L, idx, MT_WIDGET);
}
static GuiStatusBar* check_status(lua_State* L, int idx) {
    return check_udata<GuiStatusBar>(L, idx, MT_STATUS);
}
static GuiWindow* check_window(lua_State* L, int idx) {
    return check_udata<GuiWindow>(L, idx, MT_WINDOW);
}
static GuiWindow* check_dialog(lua_State* L, int idx) {
    return check_udata<GuiWindow>(L, idx, MT_DIALOG);
}
static GuiWindow* check_top_level(lua_State* L, int idx) {
    if (auto* window = test_udata<GuiWindow>(L, idx, MT_WINDOW)) return window;
    if (auto* dialog = test_udata<GuiWindow>(L, idx, MT_DIALOG)) return dialog;
    luaL_error(L, "gui.Window or gui.Dialog expected");
    return nullptr;
}
static GuiSpacer* check_spacer(lua_State* L, int idx) {
    return check_udata<GuiSpacer>(L, idx, MT_SPACER);
}
static GuiMenu* check_menu(lua_State* L, int idx) { return check_udata<GuiMenu>(L, idx, MT_MENU); }
static GuiMenuBar* check_menubar(lua_State* L, int idx) {
    return check_udata<GuiMenuBar>(L, idx, MT_MENUBAR);
}
static GuiAction* check_action(lua_State* L, int idx) {
    return check_udata<GuiAction>(L, idx, MT_ACTION);
}
static GuiAppHandle* check_app(lua_State* L, int idx) {
    return check_udata<GuiAppHandle>(L, idx, MT_APP);
}

static void rebuild_layout(lua_State* L, GuiLayout* layout);
static void ensure_widget_realised(lua_State* L, GuiWidget* widget, wxWindow* parent);
static void apply_table_view(lua_State* L, GuiWidget* widget);
static void apply_items_widget(GuiWidget* widget);
static void apply_tree_view(GuiWidget* widget);
static void apply_tabs(lua_State* L, GuiWidget* widget);
static void apply_list_view(GuiWidget* widget);
static void apply_panel(lua_State* L, GuiWidget* widget);
static void apply_splitter(lua_State* L, GuiWidget* widget);
static void apply_toolbar(lua_State* L, GuiWidget* widget);
static void attach_child_to_host(lua_State* L, GuiBase* base, wxWindow* host);

static void ensure_layout_realised(GuiLayout* layout) {
    if (layout->sizerHost != layout->hostWindow) {
        layout->sizer = nullptr;
        layout->sizerHost = layout->hostWindow;
    }

    if (!layout->sizer) {
        if (layout->kind == LayoutKind::Box) {
            layout->sizer = new wxBoxSizer(layout->orient);
        } else {
            auto* sizer =
                new wxFlexGridSizer(0, std::max(layout->columns, 1), layout->gap, layout->gap);
            if (layout->kind == LayoutKind::Form) {
                sizer->AddGrowableCol(1, 1);
            }
            layout->sizer = sizer;
        }
    }
}

static bool widget_matches_filter(const GuiWidget* widget, const TableRow& row) {
    if (widget->filter.empty()) return true;

    std::string needle = lower_copy(widget->filter);
    for (const TableColumn& column : widget->columns) {
        auto it = row.values.find(column.key);
        if (it == row.values.end()) continue;
        if (lower_copy(it->second).find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

static void apply_status_fields(GuiStatusBar* status) {
    if (!status->bar) return;

    int fieldCount =
        std::max<int>(1, status->widths.empty() ? status->fields.size() : status->widths.size());
    status->bar->SetFieldsCount(fieldCount);
    if (!status->widths.empty()) {
        status->bar->SetStatusWidths(fieldCount, status->widths.data());
    }

    if (status->fields.size() < static_cast<size_t>(fieldCount)) {
        status->fields.resize(fieldCount);
    }

    for (int i = 0; i < fieldCount; ++i) {
        status->bar->SetStatusText(to_wx(status->fields[static_cast<size_t>(i)]), i);
    }
}

static void apply_items_widget(GuiWidget* widget) {
    if (!widget->window) return;

    if (auto* choice = dynamic_cast<wxChoice*>(widget->window)) {
        choice->Clear();
        for (const std::string& item : widget->items) {
            choice->Append(to_wx(item));
        }
        if (widget->selectedIndex >= 0 &&
            widget->selectedIndex < static_cast<int>(widget->items.size())) {
            choice->SetSelection(widget->selectedIndex);
        }
        return;
    }

    if (auto* combo = dynamic_cast<wxComboBox*>(widget->window)) {
        combo->Clear();
        for (const std::string& item : widget->items) {
            combo->Append(to_wx(item));
        }
        if (widget->selectedIndex >= 0 &&
            widget->selectedIndex < static_cast<int>(widget->items.size())) {
            combo->SetSelection(widget->selectedIndex);
        }
        return;
    }

    if (auto* list = dynamic_cast<wxListBox*>(widget->window)) {
        list->Clear();
        for (const std::string& item : widget->items) {
            list->Append(to_wx(item));
        }
        if (widget->selectedIndex >= 0 &&
            widget->selectedIndex < static_cast<int>(widget->items.size())) {
            list->SetSelection(widget->selectedIndex);
        }
    }
}

static void append_tree_nodes(wxTreeCtrl* tree, const wxTreeItemId& parentId,
                              const std::vector<TreeNode>& nodes) {
    for (const TreeNode& node : nodes) {
        wxTreeItemId id;
        if (parentId.IsOk()) {
            id = tree->AppendItem(parentId, to_wx(node.label));
        } else {
            id = tree->AddRoot(to_wx(node.label));
        }

        if (!node.children.empty()) {
            append_tree_nodes(tree, id, node.children);
        }
    }
}

static void apply_tree_view(GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::TreeView) return;

    auto* tree = dynamic_cast<wxTreeCtrl*>(widget->window);
    if (!tree) return;

    tree->DeleteAllItems();
    if (!widget->treeNodes.empty()) {
        wxTreeItemId root = tree->AddRoot("root");
        append_tree_nodes(tree, root, widget->treeNodes);
        tree->ExpandAll();
    }
}

static void apply_table_view(lua_State*, GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::TableView) return;

    auto* table = dynamic_cast<wxDataViewListCtrl*>(widget->window);
    if (!table) return;

    table->DeleteAllItems();
    table->ClearColumns();

    for (const TableColumn& column : widget->columns) {
        int mode = wxDATAVIEW_CELL_INERT;
        int width = column.expand ? wxCOL_WIDTH_AUTOSIZE : column.width;
        table->AppendTextColumn(to_wx(column.title), wxDATAVIEW_CELL_INERT, width, wxALIGN_LEFT,
                                column.expand ? wxDATAVIEW_COL_RESIZABLE : 0);
    }

    for (const TableRow& row : widget->rows) {
        if (!widget_matches_filter(widget, row)) continue;

        wxVector<wxVariant> values;
        for (const TableColumn& column : widget->columns) {
            auto it = row.values.find(column.key);
            values.push_back(wxVariant(to_wx(it == row.values.end() ? "" : it->second)));
        }
        table->AppendItem(values);
    }
}

static void apply_list_view(GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::ListView) return;

    auto* list = dynamic_cast<wxListCtrl*>(widget->window);
    if (!list) return;

    list->Freeze();
    list->DeleteAllItems();
    while (list->DeleteColumn(0)) {
    }

    for (size_t i = 0; i < widget->columns.size(); ++i) {
        const TableColumn& column = widget->columns[i];
        int width = column.width > 0 ? column.width : 180;
        list->InsertColumn(static_cast<int>(i), to_wx(column.title), wxLIST_FORMAT_LEFT, width);
    }

    long rowIndex = 0;
    for (const TableRow& row : widget->rows) {
        if (!widget_matches_filter(widget, row)) continue;

        for (size_t i = 0; i < widget->columns.size(); ++i) {
            const TableColumn& column = widget->columns[i];
            auto it = row.values.find(column.key);
            std::string value = it == row.values.end() ? "" : it->second;
            if (i == 0) {
                list->InsertItem(rowIndex, to_wx(value));
            } else {
                list->SetItem(rowIndex, static_cast<int>(i), to_wx(value));
            }
        }
        ++rowIndex;
    }

    if (widget->selectedIndex >= 0 && widget->selectedIndex < rowIndex) {
        list->SetItemState(widget->selectedIndex, wxLIST_STATE_SELECTED | wxLIST_STATE_FOCUSED,
                           wxLIST_STATE_SELECTED | wxLIST_STATE_FOCUSED);
    }
    list->Thaw();
}

static int child_flags(const GuiLayout* layout, bool expand, int padding) {
    int flags = expand ? wxEXPAND : 0;
    if (padding > 0) {
        flags |= wxALL;
    }
    if (layout->kind == LayoutKind::Form && expand) {
        flags |= wxALIGN_CENTER_VERTICAL;
    }
    return flags;
}

static void detach_host_sizer(wxWindow* host) {
    if (!host) return;

    if (auto* existing = host->GetSizer()) {
        host->SetSizer(nullptr, false);
        existing->SetContainingWindow(nullptr);
    }
}

static void attach_child_to_host(lua_State* L, GuiBase* base, wxWindow* host) {
    if (auto* layout = as_layout(base)) {
        detach_host_sizer(host);
        if (layout->hostWindow != host && layout->sizer) {
            layout->sizer->SetContainingWindow(nullptr);
        }
        layout->hostWindow = host;
        rebuild_layout(L, layout);
        if (layout->padding > 0) {
            auto* outer = new wxBoxSizer(wxVERTICAL);
            outer->Add(layout->sizer, 1, wxEXPAND | wxALL, layout->padding);
            host->SetSizer(outer);
        } else {
            host->SetSizer(layout->sizer);
        }
        host->Layout();
        return;
    }

    if (auto* widget = as_widget(base)) {
        ensure_widget_realised(L, widget, host);
        detach_host_sizer(host);
        auto* sizer = new wxBoxSizer(wxVERTICAL);
        sizer->Add(widget->window, 1, wxEXPAND);
        host->SetSizer(sizer);
        host->Layout();
        return;
    }

    if (auto* spacer = as_spacer(base)) {
        detach_host_sizer(host);
        auto* sizer = new wxBoxSizer(wxVERTICAL);
        sizer->AddSpacer(std::max(spacer->size, 0));
        host->SetSizer(sizer);
        host->Layout();
    }
}

static void apply_tabs(lua_State* L, GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::Tabs) return;

    auto* notebook = dynamic_cast<wxNotebook*>(widget->window);
    if (!notebook) return;

    while (notebook->GetPageCount() > 0) {
        notebook->DeletePage(0);
    }

    for (const TabPage& page : widget->tabs) {
        lua_getref(L, page.childRef);
        GuiBase* child = check_any(L, -1);

        auto* panel = new wxPanel(notebook, wxID_ANY);
        attach_child_to_host(L, child, panel);
        notebook->AddPage(panel, to_wx(page.title), false);

        lua_pop(L, 1);
    }

    if (widget->selectedIndex >= 0 &&
        widget->selectedIndex < static_cast<int>(widget->tabs.size())) {
        notebook->SetSelection(widget->selectedIndex);
    }
}

static void apply_panel(lua_State* L, GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::Panel || widget->childRef == LUA_NOREF)
        return;

    lua_getref(L, widget->childRef);
    GuiBase* child = check_any(L, -1);
    attach_child_to_host(L, child, widget->window);
    lua_pop(L, 1);
}

static void apply_single_child_container(lua_State* L, GuiWidget* widget, wxWindow* host) {
    if (!host || widget->childRef == LUA_NOREF) return;

    lua_getref(L, widget->childRef);
    GuiBase* child = check_any(L, -1);
    attach_child_to_host(L, child, host);
    lua_pop(L, 1);
}

static void apply_toolbar(lua_State* L, GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::ToolBar) return;

    auto* toolbar = dynamic_cast<wxToolBar*>(widget->window);
    if (!toolbar) return;

    while (toolbar->GetToolsCount() > 0) {
        toolbar->DeleteToolByPos(0);
    }
    toolbar->SetToolBitmapSize(wxSize(16, 16));
    wxImage placeholderImage(16, 16, true);
    std::fill_n(placeholderImage.GetData(), 16 * 16 * 3, 0);
    placeholderImage.InitAlpha();
    std::fill_n(placeholderImage.GetAlpha(), 16 * 16, 0);
    wxBitmap placeholder(placeholderImage);

    for (int itemRef : widget->itemRefs) {
        if (itemRef == LUA_NOREF) {
            toolbar->AddSeparator();
            continue;
        }

        lua_getref(L, itemRef);
        auto* action = check_action(L, -1);
        toolbar->AddTool(action->id, to_wx(action->label), wxBitmapBundle::FromBitmap(placeholder),
                         to_wx(action->label));
        toolbar->Bind(
            wxEVT_TOOL,
            [rt = action->base.rt, ref = action->callbackRef](wxCommandEvent&) {
                queue_callback0(rt, ref);
            },
            action->id);
        lua_pop(L, 1);
    }

    toolbar->Realize();
}

static void apply_splitter(lua_State* L, GuiWidget* widget) {
    if (!widget->window || widget->base.kind != GuiKind::Splitter) return;
    if (widget->childRef == LUA_NOREF || widget->secondChildRef == LUA_NOREF) return;

    auto* splitter = dynamic_cast<wxSplitterWindow*>(widget->window);
    if (!splitter) return;

    wxWindow* first = splitter->GetWindow1();
    wxWindow* second = splitter->GetWindow2();
    if (!first) first = new wxPanel(splitter, wxID_ANY);
    if (!second) second = new wxPanel(splitter, wxID_ANY);

    lua_getref(L, widget->childRef);
    GuiBase* firstChild = check_any(L, -1);
    attach_child_to_host(L, firstChild, first);
    lua_pop(L, 1);

    lua_getref(L, widget->secondChildRef);
    GuiBase* secondChild = check_any(L, -1);
    attach_child_to_host(L, secondChild, second);
    lua_pop(L, 1);

    if (splitter->IsSplit()) {
        splitter->Unsplit();
    }

    if (widget->splitterVertical) {
        splitter->SplitVertically(first, second, widget->splitterPosition);
    } else {
        splitter->SplitHorizontally(first, second, widget->splitterPosition);
    }
}

static void apply_widget_common(GuiWidget* widget) {
    if (!widget->window) return;
    widget->window->Enable(widget->enabled);
}

static void prepare_widget_for_host(GuiWidget* widget, wxWindow* host) {
    if (!widget || !widget->window || !host) return;

    if (auto* containingSizer = widget->window->GetContainingSizer()) {
        containingSizer->Detach(widget->window);
    }

    if (widget->window->GetParent() != host) {
        widget->window->Reparent(host);
    }

    widget->parent = host;
}

static void ensure_widget_realised(lua_State* L, GuiWidget* widget, wxWindow* parent) {
    if (widget->window) {
        prepare_widget_for_host(widget, parent);
        return;
    }
    widget->parent = parent;

    switch (widget->base.kind) {
        case GuiKind::Label:
            widget->window = new wxStaticText(parent, wxID_ANY, to_wx(widget->text));
            break;
        case GuiKind::Button: {
            auto* button = new wxButton(parent, wxID_ANY, to_wx(widget->text));
            if (widget->iconRef != LUA_NOREF) {
                lua_getref(L, widget->iconRef);
                auto* bitmap = check_bitmap(L, -1);
                if (bitmap->bitmap) {
                    button->SetBitmap(*bitmap->bitmap);
                }
                lua_pop(L, 1);
            }
            if (widget->onClickRef != LUA_NOREF) {
                button->Bind(wxEVT_BUTTON, [rt = widget->base.rt, ref = widget->onClickRef](
                                               wxCommandEvent&) { queue_callback0(rt, ref); });
            }
            widget->window = button;
            break;
        }
        case GuiKind::ToggleButton: {
            auto* button = new wxToggleButton(parent, wxID_ANY, to_wx(widget->text));
            button->SetValue(widget->checked);
            if (widget->onClickRef != LUA_NOREF) {
                button->Bind(wxEVT_TOGGLEBUTTON,
                             [rt = widget->base.rt, ref = widget->onClickRef](wxCommandEvent&) {
                                 queue_callback0(rt, ref);
                             });
            }
            if (widget->onChangeRef != LUA_NOREF) {
                button->Bind(wxEVT_TOGGLEBUTTON, [rt = widget->base.rt, ref = widget->onChangeRef,
                                                  button](wxCommandEvent&) {
                    queue_callback1_boolean(rt, ref, button->GetValue());
                });
            }
            widget->window = button;
            break;
        }
        case GuiKind::ToolBar: {
            auto* toolbar = new wxToolBar(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize,
                                          wxTB_FLAT | wxTB_HORIZONTAL | wxTB_TEXT | wxTB_NOICONS);
            widget->window = toolbar;
            apply_toolbar(L, widget);
            break;
        }
        case GuiKind::TextBox: {
            long style = wxTE_PROCESS_ENTER;
            if (widget->password) style |= wxTE_PASSWORD;
            if (widget->readOnly) style |= wxTE_READONLY;
            auto* text = new wxTextCtrl(parent, wxID_ANY, to_wx(widget->text), wxDefaultPosition,
                                        wxDefaultSize, style);
            if (!widget->placeholder.empty()) {
                text->SetHint(to_wx(widget->placeholder));
            }
            text->Bind(wxEVT_CHAR_HOOK, [text](wxKeyEvent& event) {
                if (event.GetModifiers() == wxMOD_CONTROL && event.GetKeyCode() == 'A') {
                    text->SelectAll();
                    return;
                }
                event.Skip();
            });
            if (widget->onChangeRef != LUA_NOREF) {
                text->Bind(wxEVT_TEXT, [rt = widget->base.rt, ref = widget->onChangeRef,
                                        text](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(text->GetValue()));
                });
            }
            if (widget->onSubmitRef != LUA_NOREF) {
                text->Bind(wxEVT_TEXT_ENTER, [rt = widget->base.rt, ref = widget->onSubmitRef,
                                              text](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(text->GetValue()));
                });
            }
            widget->window = text;
            break;
        }
        case GuiKind::TextArea: {
            auto* text = new wxTextCtrl(parent, wxID_ANY, to_wx(widget->text), wxDefaultPosition,
                                        wxDefaultSize,
                                        wxTE_MULTILINE | (widget->readOnly ? wxTE_READONLY : 0));
            if (!widget->placeholder.empty()) {
                text->SetHint(to_wx(widget->placeholder));
            }
            text->Bind(wxEVT_CHAR_HOOK, [text](wxKeyEvent& event) {
                if (event.GetModifiers() == wxMOD_CONTROL && event.GetKeyCode() == 'A') {
                    text->SelectAll();
                    return;
                }
                event.Skip();
            });
            if (widget->onChangeRef != LUA_NOREF) {
                text->Bind(wxEVT_TEXT, [rt = widget->base.rt, ref = widget->onChangeRef,
                                        text](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(text->GetValue()));
                });
            }
            widget->window = text;
            break;
        }
        case GuiKind::SearchBox: {
            auto* search = new wxSearchCtrl(parent, wxID_ANY, to_wx(widget->text),
                                            wxDefaultPosition, wxDefaultSize, wxTE_PROCESS_ENTER);
            search->ShowSearchButton(true);
            search->ShowCancelButton(true);
            if (!widget->placeholder.empty()) {
                search->SetDescriptiveText(to_wx(widget->placeholder));
            }
            if (widget->onChangeRef != LUA_NOREF) {
                search->Bind(wxEVT_TEXT, [rt = widget->base.rt, ref = widget->onChangeRef,
                                          search](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                });
            }
            if (widget->onSubmitRef != LUA_NOREF) {
                search->Bind(wxEVT_TEXT_ENTER, [rt = widget->base.rt, ref = widget->onSubmitRef,
                                                search](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                });
                search->Bind(
                    wxEVT_SEARCHCTRL_SEARCH_BTN,
                    [rt = widget->base.rt, ref = widget->onSubmitRef, search](wxCommandEvent&) {
                        queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                    });
            }
            widget->window = search;
            break;
        }
        case GuiKind::CheckBox: {
            auto* box = new wxCheckBox(parent, wxID_ANY, to_wx(widget->text));
            box->SetValue(widget->checked);
            if (widget->onChangeRef != LUA_NOREF) {
                box->Bind(wxEVT_CHECKBOX,
                          [rt = widget->base.rt, ref = widget->onChangeRef, box](wxCommandEvent&) {
                              queue_callback1_boolean(rt, ref, box->GetValue());
                          });
            }
            widget->window = box;
            break;
        }
        case GuiKind::RadioButton: {
            auto* radio = new wxRadioButton(parent, wxID_ANY, to_wx(widget->text));
            radio->SetValue(widget->checked);
            if (widget->onChangeRef != LUA_NOREF) {
                radio->Bind(wxEVT_RADIOBUTTON, [rt = widget->base.rt, ref = widget->onChangeRef,
                                                radio](wxCommandEvent&) {
                    queue_callback1_boolean(rt, ref, radio->GetValue());
                });
            }
            widget->window = radio;
            break;
        }
        case GuiKind::DatePicker: {
            auto* picker = new wxDatePickerCtrl(parent, wxID_ANY);
            wxDateTime date = from_iso_date(widget->text);
            if (date.IsValid()) {
                picker->SetValue(date);
            }
            if (widget->onChangeRef != LUA_NOREF) {
                picker->Bind(wxEVT_DATE_CHANGED, [rt = widget->base.rt, ref = widget->onChangeRef,
                                                  picker](wxDateEvent&) {
                    queue_callback1_string(rt, ref, to_iso_date(picker->GetValue()));
                });
            }
            widget->window = picker;
            break;
        }
        case GuiKind::Hyperlink: {
            auto* link = new wxHyperlinkCtrl(parent, wxID_ANY, to_wx(widget->text),
                                             to_wx(widget->placeholder));
            widget->window = link;
            break;
        }
        case GuiKind::Choice: {
            auto* choice = new wxChoice(parent, wxID_ANY);
            widget->window = choice;
            apply_items_widget(widget);
            if (widget->onChangeRef != LUA_NOREF) {
                choice->Bind(wxEVT_CHOICE, [rt = widget->base.rt, ref = widget->onChangeRef,
                                            choice](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(choice->GetStringSelection()));
                });
            }
            break;
        }
        case GuiKind::ComboBox: {
            auto* combo = new wxComboBox(parent, wxID_ANY, to_wx(widget->text));
            widget->window = combo;
            apply_items_widget(widget);
            if (widget->onChangeRef != LUA_NOREF) {
                combo->Bind(wxEVT_COMBOBOX, [rt = widget->base.rt, ref = widget->onChangeRef,
                                             combo](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(combo->GetValue()));
                });
            }
            break;
        }
        case GuiKind::ListBox: {
            auto* list = new wxListBox(parent, wxID_ANY);
            widget->window = list;
            apply_items_widget(widget);
            if (widget->onChangeRef != LUA_NOREF) {
                list->Bind(wxEVT_LISTBOX, [rt = widget->base.rt, ref = widget->onChangeRef,
                                           list](wxCommandEvent&) {
                    queue_callback1_string(rt, ref, to_utf8(list->GetStringSelection()));
                });
            }
            break;
        }
        case GuiKind::TreeView: {
            auto* tree = new wxTreeCtrl(
                parent, wxID_ANY, wxDefaultPosition, wxDefaultSize,
                wxTR_HAS_BUTTONS | wxTR_LINES_AT_ROOT | wxTR_HIDE_ROOT | wxTR_DEFAULT_STYLE);
            widget->window = tree;
            apply_tree_view(widget);
            if (widget->onSelectRef != LUA_NOREF) {
                tree->Bind(wxEVT_TREE_SEL_CHANGED,
                           [rt = widget->base.rt, ref = widget->onSelectRef, tree](wxTreeEvent&) {
                               wxTreeItemId item = tree->GetSelection();
                               queue_callback1_string(
                                   rt, ref, item.IsOk() ? to_utf8(tree->GetItemText(item)) : "");
                           });
            }
            break;
        }
        case GuiKind::Slider: {
            auto* slider = new wxSlider(
                parent, wxID_ANY, std::clamp(widget->gaugeValue, widget->minValue, widget->range),
                widget->minValue, std::max(widget->range, widget->minValue));
            if (widget->onChangeRef != LUA_NOREF) {
                slider->Bind(wxEVT_SLIDER, [rt = widget->base.rt, ref = widget->onChangeRef,
                                            slider](wxCommandEvent&) {
                    queue_callback1_integer(rt, ref, slider->GetValue());
                });
            }
            widget->window = slider;
            break;
        }
        case GuiKind::SpinBox: {
            auto* spin = new wxSpinCtrl(
                parent, wxID_ANY, wxEmptyString, wxDefaultPosition, wxDefaultSize, wxSP_ARROW_KEYS,
                widget->minValue, std::max(widget->range, widget->minValue),
                std::clamp(widget->gaugeValue, widget->minValue, widget->range));
            if (widget->onChangeRef != LUA_NOREF) {
                spin->Bind(wxEVT_SPINCTRL,
                           [rt = widget->base.rt, ref = widget->onChangeRef, spin](wxSpinEvent&) {
                               queue_callback1_integer(rt, ref, spin->GetValue());
                           });
            }
            widget->window = spin;
            break;
        }
        case GuiKind::ProgressBar: {
            auto* gauge = new wxGauge(parent, wxID_ANY, std::max(widget->range, 1));
            gauge->SetValue(std::clamp(widget->gaugeValue, 0, std::max(widget->range, 1)));
            widget->window = gauge;
            break;
        }
        case GuiKind::Tabs: {
            auto* notebook = new wxNotebook(parent, wxID_ANY);
            widget->window = notebook;
            apply_tabs(L, widget);
            if (widget->onSelectRef != LUA_NOREF) {
                notebook->Bind(
                    wxEVT_NOTEBOOK_PAGE_CHANGED,
                    [rt = widget->base.rt, ref = widget->onSelectRef, notebook](wxBookCtrlEvent&) {
                        queue_callback1_integer(rt, ref, notebook->GetSelection() + 1);
                    });
            }
            break;
        }
        case GuiKind::TableView: {
            auto* table = new wxDataViewListCtrl(parent, wxID_ANY);
            widget->window = table;
            apply_table_view(L, widget);
            break;
        }
        case GuiKind::ListView: {
            auto* list = new wxListCtrl(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize,
                                        wxLC_REPORT | wxLC_SINGLE_SEL);
            widget->window = list;
            apply_list_view(widget);
            if (widget->onSelectRef != LUA_NOREF) {
                list->Bind(wxEVT_LIST_ITEM_SELECTED,
                           [rt = widget->base.rt, ref = widget->onSelectRef](wxListEvent& event) {
                               queue_callback1_integer(rt, ref,
                                                       static_cast<int>(event.GetIndex()) + 1);
                           });
            }
            break;
        }
        case GuiKind::Panel: {
            auto* panel = new wxPanel(parent, wxID_ANY);
            widget->window = panel;
            apply_single_child_container(L, widget, panel);
            break;
        }
        case GuiKind::ScrollArea: {
            auto* scroll = new wxScrolledWindow(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize,
                                                wxVSCROLL | wxHSCROLL | wxBORDER_THEME);
            scroll->SetScrollRate(8, 8);
            widget->window = scroll;
            apply_single_child_container(L, widget, scroll);
            break;
        }
        case GuiKind::GroupBox: {
            auto* panel = new wxPanel(parent, wxID_ANY);
            auto* group = new wxStaticBox(panel, wxID_ANY, to_wx(widget->text));
            auto* content = new wxPanel(panel, wxID_ANY);
            auto* sizer = new wxStaticBoxSizer(group, wxVERTICAL);
            sizer->Add(content, 1, wxEXPAND | wxALL, 8);
            panel->SetSizer(sizer);
            widget->window = panel;
            widget->contentHost = content;
            widget->staticBox = group;
            apply_single_child_container(L, widget, content);
            break;
        }
        case GuiKind::StaticLine: {
            widget->window = new wxStaticLine(parent, wxID_ANY);
            break;
        }
        case GuiKind::InfoBar: {
            auto* info = new wxInfoBar(parent);
            widget->window = info;
            break;
        }
        case GuiKind::Splitter: {
            auto* splitter = new wxSplitterWindow(parent, wxID_ANY);
            splitter->SetMinimumPaneSize(80);
            widget->window = splitter;
            apply_splitter(L, widget);
            break;
        }
        default:
            luaL_error(L, "widget kind cannot be realised");
    }

    apply_widget_common(widget);
}

static void rebuild_layout(lua_State* L, GuiLayout* layout) {
    if (!layout->hostWindow) return;
    layout->sizer = nullptr;
    layout->sizerHost = layout->hostWindow;
    ensure_layout_realised(layout);
    layout->sizer->Clear(false);
    if (auto* flex = dynamic_cast<wxFlexGridSizer*>(layout->sizer)) {
        flex->SetCols(std::max(layout->columns, 1));
        flex->SetHGap(layout->gap);
        flex->SetVGap(layout->gap);
    }

    bool first = true;
    for (const LayoutChild& child : layout->children) {
        lua_getref(L, child.ref);
        GuiBase* base = check_any(L, -1);

        if (layout->kind == LayoutKind::Box && !first && layout->gap > 0) {
            layout->sizer->AddSpacer(layout->gap);
        }

        if (auto* nested = as_layout(base)) {
            nested->hostWindow = layout->hostWindow;
            rebuild_layout(L, nested);
            layout->sizer->Add(nested->sizer, child.expand ? 1 : 0,
                               child_flags(layout, child.expand, nested->padding), nested->padding);
        } else if (auto* spacer = as_spacer(base)) {
            if (layout->kind == LayoutKind::Box) {
                layout->sizer->AddSpacer(std::max(spacer->size, 0));
            } else {
                layout->sizer->Add(std::max(spacer->size, 0), std::max(spacer->size, 0));
            }
        } else if (auto* widget = as_widget(base)) {
            ensure_widget_realised(L, widget, layout->hostWindow);
            if (widget->window) {
                if (auto* containingSizer = widget->window->GetContainingSizer()) {
                    containingSizer->Detach(widget->window);
                }
                if (widget->window->GetParent() != layout->hostWindow) {
                    widget->window->Reparent(layout->hostWindow);
                }
            }
            layout->sizer->Add(widget->window, child.expand ? 1 : 0,
                               child_flags(layout, child.expand, 0));
        }

        lua_pop(L, 1);
        first = false;
    }

    layout->sizer->Layout();
}

static void bind_menu_callbacks(lua_State* L, GuiWindow* window, GuiMenuBar* bar) {
    if (!window->frame || !bar->menuBar) return;

    for (int menuRef : bar->menuRefs) {
        lua_getref(L, menuRef);
        auto* menu = check_menu(L, -1);
        for (int itemRef : menu->itemRefs) {
            lua_getref(L, itemRef);
            if (auto* action = test_udata<GuiBase>(L, -1, MT_ACTION)) {
                auto* actual = reinterpret_cast<GuiAction*>(action);
                if (actual->callbackRef != LUA_NOREF && actual->item) {
                    window->frame->Bind(
                        wxEVT_MENU,
                        [rt = actual->base.rt, ref = actual->callbackRef](wxCommandEvent&) {
                            queue_callback0(rt, ref);
                        },
                        actual->item->GetId());
                }
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
}

static void invalidate_window_status_bar(lua_State* L, GuiWindow* window) {
    if (!window || window->statusBarRef == LUA_NOREF) return;

    lua_getref(L, window->statusBarRef);
    if (auto* status = test_udata<GuiStatusBar>(L, -1, MT_STATUS)) {
        if (!window->frame || status->owner == window->frame) {
            status->bar = nullptr;
            status->owner = nullptr;
        }
    }
    lua_pop(L, 1);
}

static void init_top_level_bindings(lua_State* L, GuiWindow* window) {
    pin_self(L, window->base, -1);
    ++g_liveWindows;

    window->topLevel->Bind(wxEVT_CLOSE_WINDOW, [window](wxCloseEvent& event) {
        if (window->dialog && window->modalLoopActive) {
            window->modalLoopActive = false;
            window->modalResult = wxID_CANCEL;
            window->dialog->Hide();
            event.Veto();
            return;
        }
        if (!window->closing) {
            window->closing = true;
            if (window->onCloseRef != LUA_NOREF) {
                queue_close_callback(window->base.rt, window->onCloseRef);
            }
        }
        if (window->dialog && !window->dialog->IsModal()) {
            window->dialog->Destroy();
            return;
        }
        event.Skip();
    });
    window->topLevel->Bind(wxEVT_DESTROY, [window](wxWindowDestroyEvent&) {
        window->closing = true;
        if (window->topLevel) {
            if (window->base.rt) {
                invalidate_window_status_bar(window->base.rt->GL, window);
            }
            window->topLevel = nullptr;
            window->frame = nullptr;
            window->dialog = nullptr;
        }
        if (g_liveWindows > 0) --g_liveWindows;
        g_appQuitRequested = g_liveWindows == 0;
    });
}

static void attach_menubar(lua_State* L, GuiWindow* window, GuiMenuBar* bar) {
    if (!window->frame) return;
    if (!bar->menuBar) bar->menuBar = new wxMenuBar();

    while (bar->menuBar->GetMenuCount() > 0) {
        wxMenu* menu = bar->menuBar->Remove(0);
        delete menu;
    }

    for (int menuRef : bar->menuRefs) {
        lua_getref(L, menuRef);
        auto* menu = check_menu(L, -1);
        if (!menu->menu) menu->menu = new wxMenu();

        for (int itemRef : menu->itemRefs) {
            lua_getref(L, itemRef);
            if (test_udata<GuiAction>(L, -1, MT_ACTION)) {
                auto* action = check_action(L, -1);
                if (!action->item) {
                    action->item = new wxMenuItem(menu->menu, action->id, to_wx(action->label));
                    action->id = action->item->GetId();
                    menu->menu->Append(action->item);
                    action->owner = menu->menu;
                }
            } else {
                menu->menu->AppendSeparator();
            }
            lua_pop(L, 1);
        }

        bar->menuBar->Append(menu->menu, to_wx(menu->title));
        lua_pop(L, 1);
    }

    window->frame->SetMenuBar(bar->menuBar);
    bind_menu_callbacks(L, window, bar);
}

static void destroy_window(lua_State* L, GuiWindow* window) {
    if (!window->topLevel) return;
    wxTopLevelWindow* topLevel = window->topLevel;
    window->closing = true;
    invalidate_window_status_bar(L, window);
    window->topLevel = nullptr;
    window->frame = nullptr;
    window->dialog = nullptr;
    topLevel->Destroy();
    unpin_self(L, window->base);
}

static void gui_base_dtor(lua_State* L, void* userdata) {
    auto* base = static_cast<GuiBase*>(userdata);
    if (!base) return;
    L = base->rt ? base->rt->GL : L;

    switch (base->kind) {
        case GuiKind::Window:
        case GuiKind::Dialog: {
            auto* window = reinterpret_cast<GuiWindow*>(base);
            if (window->topLevel) {
                destroy_window(L, window);
            }
            release_ref(L, window->layoutRef);
            release_ref(L, window->statusBarRef);
            release_ref(L, window->menuBarRef);
            release_ref(L, window->onCloseRef);
            break;
        }
        case GuiKind::Layout: {
            auto* layout = reinterpret_cast<GuiLayout*>(base);
            for (LayoutChild& child : layout->children) {
                release_ref(L, child.ref);
            }
            if (layout->sizer && !layout->hostWindow) {
                delete layout->sizer;
            }
            break;
        }
        case GuiKind::Spacer:
            break;
        case GuiKind::Label:
        case GuiKind::Button:
        case GuiKind::ToggleButton:
        case GuiKind::TextBox:
        case GuiKind::TextArea:
        case GuiKind::SearchBox:
        case GuiKind::CheckBox:
        case GuiKind::RadioButton:
        case GuiKind::Choice:
        case GuiKind::ComboBox:
        case GuiKind::ListBox:
        case GuiKind::TreeView:
        case GuiKind::Slider:
        case GuiKind::SpinBox:
        case GuiKind::ProgressBar:
        case GuiKind::Tabs:
        case GuiKind::TableView:
        case GuiKind::ListView:
        case GuiKind::Panel:
        case GuiKind::ToolBar:
        case GuiKind::DatePicker:
        case GuiKind::Hyperlink:
        case GuiKind::ScrollArea:
        case GuiKind::GroupBox:
        case GuiKind::StaticLine:
        case GuiKind::InfoBar:
        case GuiKind::Splitter: {
            auto* widget = reinterpret_cast<GuiWidget*>(base);
            release_ref(L, widget->onClickRef);
            release_ref(L, widget->onChangeRef);
            release_ref(L, widget->onSelectRef);
            release_ref(L, widget->onSubmitRef);
            release_ref(L, widget->iconRef);
            release_ref(L, widget->childRef);
            release_ref(L, widget->secondChildRef);
            for (int& ref : widget->itemRefs) {
                release_ref(L, ref);
            }
            for (TabPage& page : widget->tabs) {
                release_ref(L, page.childRef);
            }
            break;
        }
        case GuiKind::StatusBar: {
            auto* status = reinterpret_cast<GuiStatusBar*>(base);
            if (status->bar && !status->owner) {
                delete status->bar;
            }
            break;
        }
        case GuiKind::Menu: {
            auto* menu = reinterpret_cast<GuiMenu*>(base);
            for (int& ref : menu->itemRefs) release_ref(L, ref);
            break;
        }
        case GuiKind::MenuBar: {
            auto* bar = reinterpret_cast<GuiMenuBar*>(base);
            for (int& ref : bar->menuRefs) release_ref(L, ref);
            break;
        }
        case GuiKind::Action: {
            auto* action = reinterpret_cast<GuiAction*>(base);
            release_ref(L, action->callbackRef);
            break;
        }
        case GuiKind::Bitmap: {
            auto* bitmap = reinterpret_cast<GuiBitmap*>(base);
            delete bitmap->bitmap;
            break;
        }
        case GuiKind::App:
            break;
    }

    unpin_self(L, *base);
}

template <typename T>
static T* push_object(lua_State* L, const char* mt) {
    udataRef* ref = eryxUdata_getudata(L, mt);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", mt);
        return nullptr;
    }
    auto* object = static_cast<T*>(eryxUdata_pushudata(L, ref));
    new (object) T();
    object->base.rt = eryx_get_runtime(L);
    return object;
}

static int app_new(lua_State* L) {
    ensure_wx(L);
    push_object<GuiAppHandle>(L, MT_APP);
    return 1;
}

static int app_run(lua_State* L) {
    check_app(L, 1);
    ensure_wx(L);
    g_appQuitRequested = false;

    std::unique_ptr<wxEventLoopBase> ownedLoop;
    wxEventLoopBase* loop = wxTheApp ? wxTheApp->GetMainLoop() : nullptr;
    if (!loop) {
        ownedLoop = std::make_unique<wxEventLoop>();
        loop = ownedLoop.get();
    }
    if (!loop) {
        luaL_error(L, "failed to create wx event loop");
    }

    wxEventLoopActivator activate(loop);
    EryxRuntime* rt = eryx_get_runtime(L);

    bool finalDrainDone = false;
    while (g_liveWindows > 0 || !finalDrainDone) {
        bool wxDidWork = process_wx_once(loop);

        EryxRuntimeRunResult result = pump_runtime_once(rt);
        if (g_liveWindows == 0) {
            finalDrainDone = true;
        }
        if (result == EryxRuntimeRunResult::NoWork && !wxDidWork && !loop->Pending()) {
            wxMilliSleep(8);
        }
    }

    return 0;
}

static int app_quit(lua_State* L) {
    check_app(L, 1);
    g_appQuitRequested = true;

    wxWindowList::compatibility_iterator node = wxTopLevelWindows.GetFirst();
    while (node) {
        wxWindow* top = node->GetData();
        node = node->GetNext();
        if (top) {
            top->Close(true);
        }
    }

    return 0;
}

static GuiWindow* create_top_level(lua_State* L, const char* mt, GuiKind kind,
                                   wxTopLevelWindow* topLevel) {
    auto* window = push_object<GuiWindow>(L, mt);
    window->base.kind = kind;
    window->topLevel = topLevel;
    window->frame = dynamic_cast<wxFrame*>(topLevel);
    window->dialog = dynamic_cast<wxDialog*>(topLevel);
    window->topLevel->SetBackgroundColour(wxSystemSettings::GetColour(wxSYS_COLOUR_WINDOW));
    wxIcon icon = wxArtProvider::GetIcon(wxART_INFORMATION, wxART_FRAME_ICON);
    if (icon.IsOk()) {
        window->topLevel->SetIcon(icon);
    }
    init_top_level_bindings(L, window);
    return window;
}

static int window_new(lua_State* L) {
    ensure_wx(L);

    std::string title = luaL_checkstring(L, 1);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);

    create_top_level(
        L, MT_WINDOW, GuiKind::Window,
        new wxFrame(nullptr, wxID_ANY, to_wx(title), wxDefaultPosition, wxSize(width, height)));

    return 1;
}

static int dialog_new(lua_State* L) {
    ensure_wx(L);

    std::string title = luaL_checkstring(L, 1);
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);

    create_top_level(L, MT_DIALOG, GuiKind::Dialog,
                     new wxDialog(nullptr, wxID_ANY, to_wx(title), wxDefaultPosition,
                                  wxSize(width, height), wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER));

    return 1;
}

static int window_minimum_size(lua_State* L) {
    auto* window = check_top_level(L, 1);
    window->minWidth = luaL_checkinteger(L, 2);
    window->minHeight = luaL_checkinteger(L, 3);
    if (window->topLevel) {
        window->topLevel->SetMinSize(wxSize(window->minWidth, window->minHeight));
    }
    return 0;
}

static int window_set_title(lua_State* L) {
    auto* window = check_top_level(L, 1);
    std::string title = luaL_checkstring(L, 2);
    if (window->topLevel) {
        window->topLevel->SetTitle(to_wx(title));
    }
    return 0;
}

static int layout_vbox(lua_State* L) {
    auto* layout = push_object<GuiLayout>(L, MT_LAYOUT);
    layout->orient = wxVERTICAL;
    ensure_layout_realised(layout);
    return 1;
}

static int layout_hbox(lua_State* L) {
    auto* layout = push_object<GuiLayout>(L, MT_LAYOUT);
    layout->orient = wxHORIZONTAL;
    ensure_layout_realised(layout);
    return 1;
}

static int layout_grid(lua_State* L) {
    auto* layout = push_object<GuiLayout>(L, MT_LAYOUT);
    layout->kind = LayoutKind::Grid;
    layout->columns = std::max(opt_constructor_integer(L, 2), 1);
    ensure_layout_realised(layout);
    return 1;
}

static int layout_form(lua_State* L) {
    auto* layout = push_object<GuiLayout>(L, MT_LAYOUT);
    layout->kind = LayoutKind::Form;
    layout->columns = 2;
    ensure_layout_realised(layout);
    return 1;
}

static int spacer_new(lua_State* L) {
    auto* spacer = push_object<GuiSpacer>(L, MT_SPACER);
    spacer->size = std::max(opt_constructor_integer(L, 0), 0);
    return 1;
}

static int layout_add(lua_State* L) {
    auto* layout = check_layout(L, 1);
    GuiBase* child = check_any(L, 2);
    (void)child;

    LayoutChild spec;
    spec.ref = store_value_ref(L, 2);
    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "expand");
        spec.expand = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }
    layout->children.push_back(spec);

    if (layout->hostWindow) {
        rebuild_layout(L, layout);
        if (layout->hostWindow->GetSizer()) {
            layout->hostWindow->Layout();
        }
    }
    return 0;
}

static int layout_padding(lua_State* L) {
    auto* layout = check_layout(L, 1);
    layout->padding = luaL_checkinteger(L, 2);
    return 0;
}

static int layout_gap(lua_State* L) {
    auto* layout = check_layout(L, 1);
    layout->gap = luaL_checkinteger(L, 2);
    if (layout->hostWindow) {
        rebuild_layout(L, layout);
        layout->hostWindow->Layout();
    }
    return 0;
}

static int label_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Label;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int button_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Button;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int togglebutton_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ToggleButton;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int toolbar_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ToolBar;
    return 1;
}

static int textbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::TextBox;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int textarea_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::TextArea;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int searchbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::SearchBox;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int checkbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::CheckBox;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int radiobutton_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::RadioButton;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int datepicker_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::DatePicker;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int hyperlink_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Hyperlink;
    widget->text = opt_constructor_text(L);
    if (lua_gettop(L) >= 2 && lua_type(L, 2) == LUA_TSTRING) {
        widget->placeholder = lua_tostring(L, 2);
    }
    return 1;
}

static int choice_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Choice;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int combobox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ComboBox;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int listbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ListBox;
    return 1;
}

static int tree_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::TreeView;
    return 1;
}

static int slider_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Slider;
    widget->minValue = 0;
    widget->range = 100;
    widget->gaugeValue = opt_constructor_integer(L, 0);
    return 1;
}

static int spinbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::SpinBox;
    widget->minValue = 0;
    widget->range = 100;
    widget->gaugeValue = opt_constructor_integer(L, 0);
    return 1;
}

static int progress_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ProgressBar;
    widget->range = opt_constructor_integer(L, 100);
    return 1;
}

static int tabs_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Tabs;
    return 1;
}

static int table_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::TableView;
    return 1;
}

static int listview_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ListView;
    return 1;
}

static int panel_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Panel;
    return 1;
}

static int scrollarea_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::ScrollArea;
    return 1;
}

static int groupbox_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::GroupBox;
    widget->text = opt_constructor_text(L);
    return 1;
}

static int staticline_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::StaticLine;
    return 1;
}

static int infobar_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::InfoBar;
    return 1;
}

static int hsplitter_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Splitter;
    widget->splitterVertical = false;
    widget->splitterPosition = opt_constructor_integer(L, 220);
    return 1;
}

static int vsplitter_new(lua_State* L) {
    auto* widget = push_object<GuiWidget>(L, MT_WIDGET);
    widget->base.kind = GuiKind::Splitter;
    widget->splitterVertical = true;
    widget->splitterPosition = opt_constructor_integer(L, 320);
    return 1;
}

static int status_new(lua_State* L) {
    auto* status = push_object<GuiStatusBar>(L, MT_STATUS);
    status->fields.push_back(opt_constructor_text(L));
    return 1;
}

static int menu_new(lua_State* L) {
    auto* menu = push_object<GuiMenu>(L, MT_MENU);
    menu->title = luaL_checkstring(L, 1);
    menu->menu = new wxMenu();
    return 1;
}

static int menubar_new(lua_State* L) {
    auto* bar = push_object<GuiMenuBar>(L, MT_MENUBAR);
    bar->menuBar = new wxMenuBar();
    if (lua_istable(L, 1)) {
        int length = lua_objlen(L, 1);
        for (int i = 1; i <= length; ++i) {
            lua_rawgeti(L, 1, i);
            check_menu(L, -1);
            bar->menuRefs.push_back(store_value_ref(L, -1));
            lua_pop(L, 1);
        }
    }
    return 1;
}

static int action_new(lua_State* L) {
    auto* action = push_object<GuiAction>(L, MT_ACTION);
    action->label = luaL_checkstring(L, 1);
    action->id = wxWindow::NewControlId();
    if (lua_isfunction(L, 2)) {
        action->callbackRef = store_value_ref(L, 2);
    }
    return 1;
}

static int window_set_layout(lua_State* L) {
    auto* window = check_top_level(L, 1);
    auto* layout = check_layout(L, 2);

    release_ref(L, window->layoutRef);
    window->layoutRef = store_value_ref(L, 2);

    detach_host_sizer(window->topLevel);
    layout->hostWindow = window->topLevel;
    rebuild_layout(L, layout);

    if (layout->padding > 0) {
        auto* outer = new wxBoxSizer(wxVERTICAL);
        outer->Add(layout->sizer, 1, wxEXPAND | wxALL, layout->padding);
        window->topLevel->SetSizer(outer);
    } else {
        window->topLevel->SetSizer(layout->sizer);
    }
    if (window->minWidth > 0 && window->minHeight > 0) {
        window->topLevel->SetMinSize(wxSize(window->minWidth, window->minHeight));
    }
    window->topLevel->Layout();
    return 0;
}

static int window_set_status_bar(lua_State* L) {
    auto* window = check_window(L, 1);
    auto* status = check_status(L, 2);

    release_ref(L, window->statusBarRef);
    window->statusBarRef = store_value_ref(L, 2);

    if (!status->bar) {
        status->bar = window->frame->CreateStatusBar();
        status->owner = window->frame;
    }
    apply_status_fields(status);
    window->frame->SetStatusBar(status->bar);
    return 0;
}

static int window_set_menu_bar(lua_State* L) {
    auto* window = check_window(L, 1);
    auto* bar = check_menubar(L, 2);

    release_ref(L, window->menuBarRef);
    window->menuBarRef = store_value_ref(L, 2);
    attach_menubar(L, window, bar);
    return 0;
}

static int window_on_close(lua_State* L) {
    auto* window = check_top_level(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    release_ref(L, window->onCloseRef);
    window->onCloseRef = store_value_ref(L, 2);
    return 0;
}

static int window_show(lua_State* L) {
    auto* window = check_top_level(L, 1);
    if (window->topLevel) {
        window->topLevel->Show();
    }
    return 0;
}

static int dialog_show_modal(lua_State* L) {
    auto* dialog = check_dialog(L, 1);
    if (!dialog->dialog) {
        lua_pushnil(L);
        return 1;
    }

    ensure_wx(L);

    std::unique_ptr<wxEventLoopBase> ownedLoop;
    wxEventLoopBase* loop = wxTheApp ? wxTheApp->GetMainLoop() : nullptr;
    if (!loop) {
        ownedLoop = std::make_unique<wxEventLoop>();
        loop = ownedLoop.get();
    }
    if (!loop) {
        luaL_error(L, "failed to create wx event loop");
    }

    dialog->modalLoopActive = true;
    dialog->modalResult = wxID_CANCEL;
    dialog->dialog->Show();
    dialog->dialog->Raise();
    dialog->dialog->SetFocus();
    std::unique_ptr<wxWindowDisabler> modalDisabler =
        std::make_unique<wxWindowDisabler>(dialog->dialog);

    wxEventLoopActivator activate(loop);
    EryxRuntime* rt = eryx_get_runtime(L);

    while (dialog->modalLoopActive && dialog->dialog && dialog->dialog->IsShown()) {
        bool wxDidWork = process_wx_once(loop);

        EryxRuntimeRunResult result = pump_runtime_once(rt);
        if (result == EryxRuntimeRunResult::NoWork && !wxDidWork && !loop->Pending()) {
            wxMilliSleep(8);
        }
    }

    if (dialog->dialog) {
        dialog->dialog->Hide();
    }
    dialog->modalLoopActive = false;
    lua_pushinteger(L, dialog->modalResult);
    return 1;
}

static int window_close(lua_State* L) {
    auto* window = check_top_level(L, 1);
    if (window->dialog && window->modalLoopActive) {
        window->modalResult = wxID_CANCEL;
        window->modalLoopActive = false;
        window->dialog->Hide();
    } else if (window->dialog && window->dialog->IsModal()) {
        window->dialog->EndModal(wxID_CANCEL);
    } else if (window->topLevel) {
        window->topLevel->Close();
    }
    return 0;
}

static int status_set_text(lua_State* L) {
    auto* status = check_status(L, 1);
    std::string value = luaL_checkstring(L, 2);
    int field = luaL_optinteger(L, 3, 1);
    if (field < 1) {
        luaL_error(L, "status field index must be >= 1");
    }

    if (status->fields.size() < static_cast<size_t>(field)) {
        status->fields.resize(field);
    }
    status->fields[static_cast<size_t>(field - 1)] = value;

    if (status->bar) {
        apply_status_fields(status);
    }
    return 0;
}

static int status_set_fields(lua_State* L) {
    auto* status = check_status(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    status->widths.clear();

    int length = lua_objlen(L, 2);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, 2, i);
        status->widths.push_back(luaL_checkinteger(L, -1));
        lua_pop(L, 1);
    }

    if (status->fields.size() < status->widths.size()) {
        status->fields.resize(status->widths.size());
    }
    apply_status_fields(status);
    return 0;
}

static int widget_enabled(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        bool enabled = widget->window ? widget->window->IsEnabled() : widget->enabled;
        lua_pushboolean(L, enabled);
        return 1;
    }

    widget->enabled = lua_toboolean(L, 2);
    apply_widget_common(widget);
    return 0;
}

static int widget_text(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        std::string value = widget->text;
        switch (widget->base.kind) {
            case GuiKind::Label:
                if (auto* label = dynamic_cast<wxStaticText*>(widget->window))
                    value = to_utf8(label->GetLabel());
                break;
            case GuiKind::Button:
                if (auto* button = dynamic_cast<wxButton*>(widget->window))
                    value = to_utf8(button->GetLabel());
                break;
            case GuiKind::ToggleButton:
                if (auto* button = dynamic_cast<wxToggleButton*>(widget->window))
                    value = to_utf8(button->GetLabel());
                break;
            case GuiKind::ToolBar:
                value = widget->text;
                break;
            case GuiKind::TextBox:
            case GuiKind::TextArea:
                if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window))
                    value = to_utf8(text->GetValue());
                break;
            case GuiKind::SearchBox:
                if (auto* search = dynamic_cast<wxSearchCtrl*>(widget->window))
                    value = to_utf8(search->GetValue());
                break;
            case GuiKind::CheckBox:
                if (auto* box = dynamic_cast<wxCheckBox*>(widget->window))
                    value = to_utf8(box->GetLabel());
                break;
            case GuiKind::RadioButton:
                if (auto* radio = dynamic_cast<wxRadioButton*>(widget->window))
                    value = to_utf8(radio->GetLabel());
                break;
            case GuiKind::DatePicker:
                if (auto* picker = dynamic_cast<wxDatePickerCtrl*>(widget->window))
                    value = to_iso_date(picker->GetValue());
                break;
            case GuiKind::Hyperlink:
                if (auto* link = dynamic_cast<wxHyperlinkCtrl*>(widget->window))
                    value = to_utf8(link->GetLabel());
                break;
            case GuiKind::Choice:
                if (auto* choice = dynamic_cast<wxChoice*>(widget->window))
                    value = to_utf8(choice->GetStringSelection());
                break;
            case GuiKind::ComboBox:
                if (auto* combo = dynamic_cast<wxComboBox*>(widget->window))
                    value = to_utf8(combo->GetValue());
                break;
            case GuiKind::ListBox:
                if (auto* list = dynamic_cast<wxListBox*>(widget->window))
                    value = to_utf8(list->GetStringSelection());
                break;
            default:
                break;
        }
        lua_pushstring(L, value.c_str());
        return 1;
    }

    widget->text = luaL_checkstring(L, 2);

    switch (widget->base.kind) {
        case GuiKind::Label:
            if (auto* label = dynamic_cast<wxStaticText*>(widget->window))
                label->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::Button:
            if (auto* button = dynamic_cast<wxButton*>(widget->window))
                button->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::ToggleButton:
            if (auto* button = dynamic_cast<wxToggleButton*>(widget->window))
                button->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::ToolBar:
            apply_toolbar(L, widget);
            break;
        case GuiKind::TextBox:
        case GuiKind::TextArea:
            if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window))
                text->SetValue(to_wx(widget->text));
            break;
        case GuiKind::SearchBox:
            if (auto* search = dynamic_cast<wxSearchCtrl*>(widget->window))
                search->SetValue(to_wx(widget->text));
            break;
        case GuiKind::CheckBox:
            if (auto* box = dynamic_cast<wxCheckBox*>(widget->window))
                box->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::RadioButton:
            if (auto* radio = dynamic_cast<wxRadioButton*>(widget->window))
                radio->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::DatePicker:
            if (auto* picker = dynamic_cast<wxDatePickerCtrl*>(widget->window)) {
                wxDateTime date = from_iso_date(widget->text);
                if (date.IsValid()) picker->SetValue(date);
            }
            break;
        case GuiKind::Hyperlink:
            if (auto* link = dynamic_cast<wxHyperlinkCtrl*>(widget->window))
                link->SetLabel(to_wx(widget->text));
            break;
        case GuiKind::Choice:
            if (auto* choice = dynamic_cast<wxChoice*>(widget->window))
                choice->SetStringSelection(to_wx(widget->text));
            break;
        case GuiKind::ComboBox:
            if (auto* combo = dynamic_cast<wxComboBox*>(widget->window))
                combo->SetValue(to_wx(widget->text));
            break;
        case GuiKind::ListBox:
            if (auto* list = dynamic_cast<wxListBox*>(widget->window))
                list->SetStringSelection(to_wx(widget->text));
            break;
        case GuiKind::GroupBox:
            if (widget->staticBox) widget->staticBox->SetLabel(to_wx(widget->text));
            break;
        default:
            break;
    }

    return 0;
}

static int widget_checked(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        bool checked = widget->checked;
        if (auto* box = dynamic_cast<wxCheckBox*>(widget->window)) {
            checked = box->GetValue();
        } else if (auto* radio = dynamic_cast<wxRadioButton*>(widget->window)) {
            checked = radio->GetValue();
        } else if (auto* toggle = dynamic_cast<wxToggleButton*>(widget->window)) {
            checked = toggle->GetValue();
        }
        lua_pushboolean(L, checked);
        return 1;
    }

    widget->checked = lua_toboolean(L, 2);

    if (auto* box = dynamic_cast<wxCheckBox*>(widget->window)) {
        box->SetValue(widget->checked);
    } else if (auto* radio = dynamic_cast<wxRadioButton*>(widget->window)) {
        radio->SetValue(widget->checked);
    } else if (auto* toggle = dynamic_cast<wxToggleButton*>(widget->window)) {
        toggle->SetValue(widget->checked);
    }

    return 0;
}

static int button_on_click(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    release_ref(L, widget->onClickRef);
    widget->onClickRef = store_value_ref(L, 2);
    if (!widget->window) {
        return 0;
    }

    if (widget->base.kind == GuiKind::Button) {
        if (auto* button = dynamic_cast<wxButton*>(widget->window)) {
            button->Bind(wxEVT_BUTTON, [rt = widget->base.rt, ref = widget->onClickRef](
                                           wxCommandEvent&) { queue_callback0(rt, ref); });
        }
    } else if (widget->base.kind == GuiKind::ToggleButton) {
        if (auto* button = dynamic_cast<wxToggleButton*>(widget->window)) {
            button->Bind(wxEVT_TOGGLEBUTTON, [rt = widget->base.rt, ref = widget->onClickRef](
                                                 wxCommandEvent&) { queue_callback0(rt, ref); });
        }
    } else if (widget->base.kind == GuiKind::Hyperlink) {
        if (auto* link = dynamic_cast<wxHyperlinkCtrl*>(widget->window)) {
            link->Bind(wxEVT_HYPERLINK, [rt = widget->base.rt, ref = widget->onClickRef](
                                            wxHyperlinkEvent&) { queue_callback0(rt, ref); });
        }
    }
    return 0;
}

static int button_set_icon(lua_State* L) {
    auto* widget = check_widget(L, 1);
    auto* bitmap = check_bitmap(L, 2);
    release_ref(L, widget->iconRef);
    widget->iconRef = store_value_ref(L, 2);
    if (widget->window && widget->base.kind == GuiKind::Button && bitmap->bitmap) {
        dynamic_cast<wxButton*>(widget->window)->SetBitmap(*bitmap->bitmap);
    }
    return 0;
}

static int textbox_placeholder(lua_State* L) {
    auto* widget = check_widget(L, 1);
    widget->placeholder = luaL_checkstring(L, 2);
    if (auto* search = dynamic_cast<wxSearchCtrl*>(widget->window)) {
        search->SetDescriptiveText(to_wx(widget->placeholder));
    } else if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window)) {
        text->SetHint(to_wx(widget->placeholder));
    }
    return 0;
}

static int textbox_on_change(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    release_ref(L, widget->onChangeRef);
    widget->onChangeRef = store_value_ref(L, 2);
    if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window)) {
        text->Bind(wxEVT_TEXT,
                   [rt = widget->base.rt, ref = widget->onChangeRef, text](wxCommandEvent&) {
                       queue_callback1_string(rt, ref, to_utf8(text->GetValue()));
                   });
    } else if (auto* search = dynamic_cast<wxSearchCtrl*>(widget->window)) {
        search->Bind(wxEVT_TEXT,
                     [rt = widget->base.rt, ref = widget->onChangeRef, search](wxCommandEvent&) {
                         queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                     });
    } else if (auto* box = dynamic_cast<wxCheckBox*>(widget->window)) {
        box->Bind(wxEVT_CHECKBOX,
                  [rt = widget->base.rt, ref = widget->onChangeRef, box](wxCommandEvent&) {
                      queue_callback1_boolean(rt, ref, box->GetValue());
                  });
    } else if (auto* radio = dynamic_cast<wxRadioButton*>(widget->window)) {
        radio->Bind(wxEVT_RADIOBUTTON,
                    [rt = widget->base.rt, ref = widget->onChangeRef, radio](wxCommandEvent&) {
                        queue_callback1_boolean(rt, ref, radio->GetValue());
                    });
    } else if (auto* picker = dynamic_cast<wxDatePickerCtrl*>(widget->window)) {
        picker->Bind(wxEVT_DATE_CHANGED,
                     [rt = widget->base.rt, ref = widget->onChangeRef, picker](wxDateEvent&) {
                         queue_callback1_string(rt, ref, to_iso_date(picker->GetValue()));
                     });
    } else if (auto* toggle = dynamic_cast<wxToggleButton*>(widget->window)) {
        toggle->Bind(wxEVT_TOGGLEBUTTON,
                     [rt = widget->base.rt, ref = widget->onChangeRef, toggle](wxCommandEvent&) {
                         queue_callback1_boolean(rt, ref, toggle->GetValue());
                     });
    } else if (auto* choice = dynamic_cast<wxChoice*>(widget->window)) {
        choice->Bind(wxEVT_CHOICE,
                     [rt = widget->base.rt, ref = widget->onChangeRef, choice](wxCommandEvent&) {
                         queue_callback1_string(rt, ref, to_utf8(choice->GetStringSelection()));
                     });
    } else if (auto* combo = dynamic_cast<wxComboBox*>(widget->window)) {
        combo->Bind(wxEVT_COMBOBOX,
                    [rt = widget->base.rt, ref = widget->onChangeRef, combo](wxCommandEvent&) {
                        queue_callback1_string(rt, ref, to_utf8(combo->GetValue()));
                    });
    } else if (auto* list = dynamic_cast<wxListBox*>(widget->window)) {
        list->Bind(wxEVT_LISTBOX,
                   [rt = widget->base.rt, ref = widget->onChangeRef, list](wxCommandEvent&) {
                       queue_callback1_string(rt, ref, to_utf8(list->GetStringSelection()));
                   });
    } else if (auto* slider = dynamic_cast<wxSlider*>(widget->window)) {
        slider->Bind(wxEVT_SLIDER,
                     [rt = widget->base.rt, ref = widget->onChangeRef, slider](wxCommandEvent&) {
                         queue_callback1_integer(rt, ref, slider->GetValue());
                     });
    } else if (auto* spin = dynamic_cast<wxSpinCtrl*>(widget->window)) {
        spin->Bind(wxEVT_SPINCTRL,
                   [rt = widget->base.rt, ref = widget->onChangeRef, spin](wxSpinEvent&) {
                       queue_callback1_integer(rt, ref, spin->GetValue());
                   });
    }
    return 0;
}

static int widget_set_items(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    widget->items.clear();

    int length = lua_objlen(L, 2);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, 2, i);
        widget->items.push_back(luaL_checkstring(L, -1));
        lua_pop(L, 1);
    }

    apply_items_widget(widget);
    return 0;
}

static TreeNode parse_tree_node(lua_State* L, int idx) {
    idx = lua_absindex(L, idx);
    TreeNode node;

    lua_getfield(L, idx, "label");
    node.label = luaL_checkstring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "children");
    if (lua_istable(L, -1)) {
        int length = lua_objlen(L, -1);
        for (int i = 1; i <= length; ++i) {
            lua_rawgeti(L, -1, i);
            node.children.push_back(parse_tree_node(L, -1));
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    return node;
}

static int widget_set_nodes(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    widget->treeNodes.clear();

    int length = lua_objlen(L, 2);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, 2, i);
        widget->treeNodes.push_back(parse_tree_node(L, -1));
        lua_pop(L, 1);
    }

    apply_tree_view(widget);
    return 0;
}

static int widget_selected(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        int selectedIndex = widget->selectedIndex;
        if (auto* choice = dynamic_cast<wxChoice*>(widget->window)) {
            selectedIndex = choice->GetSelection();
        } else if (auto* combo = dynamic_cast<wxComboBox*>(widget->window)) {
            selectedIndex = combo->GetSelection();
        } else if (auto* list = dynamic_cast<wxListBox*>(widget->window)) {
            selectedIndex = list->GetSelection();
        } else if (auto* notebook = dynamic_cast<wxNotebook*>(widget->window)) {
            selectedIndex = notebook->GetSelection();
        } else if (auto* listView = dynamic_cast<wxListCtrl*>(widget->window)) {
            selectedIndex = listView->GetNextItem(-1, wxLIST_NEXT_ALL, wxLIST_STATE_SELECTED);
        }

        if (selectedIndex < 0) {
            lua_pushnil(L);
        } else {
            lua_pushinteger(L, selectedIndex + 1);
        }
        return 1;
    }

    widget->selectedIndex = luaL_checkinteger(L, 2) - 1;

    if (auto* choice = dynamic_cast<wxChoice*>(widget->window)) {
        choice->SetSelection(widget->selectedIndex);
    } else if (auto* combo = dynamic_cast<wxComboBox*>(widget->window)) {
        combo->SetSelection(widget->selectedIndex);
    } else if (auto* list = dynamic_cast<wxListBox*>(widget->window)) {
        list->SetSelection(widget->selectedIndex);
    } else if (auto* notebook = dynamic_cast<wxNotebook*>(widget->window)) {
        notebook->SetSelection(widget->selectedIndex);
    } else if (auto* listView = dynamic_cast<wxListCtrl*>(widget->window)) {
        listView->SetItemState(widget->selectedIndex, wxLIST_STATE_SELECTED | wxLIST_STATE_FOCUSED,
                               wxLIST_STATE_SELECTED | wxLIST_STATE_FOCUSED);
    }

    return 0;
}

static int widget_value(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        int value = widget->gaugeValue;
        if (auto* slider = dynamic_cast<wxSlider*>(widget->window)) {
            value = slider->GetValue();
        } else if (auto* spin = dynamic_cast<wxSpinCtrl*>(widget->window)) {
            value = spin->GetValue();
        } else if (auto* gauge = dynamic_cast<wxGauge*>(widget->window)) {
            value = gauge->GetValue();
        }
        lua_pushinteger(L, value);
        return 1;
    }

    widget->gaugeValue = luaL_checkinteger(L, 2);
    if (auto* slider = dynamic_cast<wxSlider*>(widget->window)) {
        slider->SetValue(std::clamp(widget->gaugeValue, widget->minValue, widget->range));
    } else if (auto* spin = dynamic_cast<wxSpinCtrl*>(widget->window)) {
        spin->SetValue(std::clamp(widget->gaugeValue, widget->minValue, widget->range));
    } else if (auto* gauge = dynamic_cast<wxGauge*>(widget->window)) {
        gauge->SetValue(std::clamp(widget->gaugeValue, 0, std::max(widget->range, 1)));
    }
    return 0;
}

static int widget_limits(lua_State* L) {
    auto* widget = check_widget(L, 1);
    widget->minValue = luaL_checkinteger(L, 2);
    widget->range = luaL_checkinteger(L, 3);
    if (widget->range < widget->minValue) {
        std::swap(widget->minValue, widget->range);
    }

    if (auto* slider = dynamic_cast<wxSlider*>(widget->window)) {
        slider->SetRange(widget->minValue, widget->range);
        slider->SetValue(std::clamp(widget->gaugeValue, widget->minValue, widget->range));
    } else if (auto* spin = dynamic_cast<wxSpinCtrl*>(widget->window)) {
        spin->SetRange(widget->minValue, widget->range);
        spin->SetValue(std::clamp(widget->gaugeValue, widget->minValue, widget->range));
    } else if (auto* gauge = dynamic_cast<wxGauge*>(widget->window)) {
        gauge->SetRange(std::max(widget->range, 1));
        gauge->SetValue(std::clamp(widget->gaugeValue, 0, std::max(widget->range, 1)));
    }

    return 0;
}

static int widget_on_select(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    release_ref(L, widget->onSelectRef);
    widget->onSelectRef = store_value_ref(L, 2);

    if (auto* tree = dynamic_cast<wxTreeCtrl*>(widget->window)) {
        tree->Bind(wxEVT_TREE_SEL_CHANGED, [rt = widget->base.rt, ref = widget->onSelectRef,
                                            tree](wxTreeEvent&) {
            wxTreeItemId item = tree->GetSelection();
            queue_callback1_string(rt, ref, item.IsOk() ? to_utf8(tree->GetItemText(item)) : "");
        });
    } else if (auto* listView = dynamic_cast<wxListCtrl*>(widget->window)) {
        listView->Bind(wxEVT_LIST_ITEM_SELECTED,
                       [rt = widget->base.rt, ref = widget->onSelectRef](wxListEvent& event) {
                           queue_callback1_integer(rt, ref, static_cast<int>(event.GetIndex()) + 1);
                       });
    } else if (auto* notebook = dynamic_cast<wxNotebook*>(widget->window)) {
        notebook->Bind(
            wxEVT_NOTEBOOK_PAGE_CHANGED,
            [rt = widget->base.rt, ref = widget->onSelectRef, notebook](wxBookCtrlEvent&) {
                queue_callback1_integer(rt, ref, notebook->GetSelection() + 1);
            });
    }

    return 0;
}

static int widget_add(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind == GuiKind::Tabs) {
        std::string title = luaL_checkstring(L, 2);
        check_any(L, 3);

        TabPage page;
        page.title = title;
        page.childRef = store_value_ref(L, 3);
        widget->tabs.push_back(std::move(page));

        if (widget->window) {
            apply_tabs(L, widget);
        }
        return 0;
    }

    if (widget->base.kind == GuiKind::Panel) {
        check_any(L, 2);
        release_ref(L, widget->childRef);
        widget->childRef = store_value_ref(L, 2);
        if (widget->window) {
            apply_panel(L, widget);
        }
        return 0;
    }

    if (widget->base.kind == GuiKind::ScrollArea || widget->base.kind == GuiKind::GroupBox) {
        check_any(L, 2);
        release_ref(L, widget->childRef);
        widget->childRef = store_value_ref(L, 2);
        if (widget->window) {
            apply_single_child_container(
                L, widget, widget->contentHost ? widget->contentHost : widget->window);
        }
        return 0;
    }

    if (widget->base.kind == GuiKind::ToolBar) {
        if (lua_isnil(L, 2)) {
            widget->itemRefs.push_back(LUA_NOREF);
        } else {
            check_action(L, 2);
            widget->itemRefs.push_back(store_value_ref(L, 2));
        }
        if (widget->window) {
            apply_toolbar(L, widget);
        }
        return 0;
    }

    luaL_error(L,
               "widget:add is only supported for gui.Tabs, gui.Panel, gui.ScrollArea, "
               "gui.GroupBox, and gui.ToolBar");
    return 0;
}

static int splitter_set_panes(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind != GuiKind::Splitter) {
        luaL_error(L, "setPanes is only supported for gui.HSplitter and gui.VSplitter");
    }

    check_any(L, 2);
    check_any(L, 3);
    release_ref(L, widget->childRef);
    release_ref(L, widget->secondChildRef);
    widget->childRef = store_value_ref(L, 2);
    widget->secondChildRef = store_value_ref(L, 3);

    if (widget->window) {
        apply_splitter(L, widget);
    }
    return 0;
}

static int splitter_position(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind != GuiKind::Splitter) {
        luaL_error(L, "position is only supported for gui.HSplitter and gui.VSplitter");
    }

    if (lua_gettop(L) < 2) {
        int position = widget->splitterPosition;
        if (auto* splitter = dynamic_cast<wxSplitterWindow*>(widget->window)) {
            position = splitter->GetSashPosition();
        }
        lua_pushinteger(L, position);
        return 1;
    }

    widget->splitterPosition = luaL_checkinteger(L, 2);
    if (auto* splitter = dynamic_cast<wxSplitterWindow*>(widget->window)) {
        splitter->SetSashPosition(widget->splitterPosition);
    }
    return 0;
}

static int widget_read_only(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        lua_pushboolean(L, widget->readOnly);
        return 1;
    }

    widget->readOnly = lua_toboolean(L, 2);
    if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window)) {
        text->SetEditable(!widget->readOnly);
    }
    return 0;
}

static int widget_password(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (lua_gettop(L) < 2) {
        lua_pushboolean(L, widget->password);
        return 1;
    }

    widget->password = lua_toboolean(L, 2);
    return 0;
}

static int widget_append(lua_State* L) {
    auto* widget = check_widget(L, 1);
    std::string value = luaL_checkstring(L, 2);

    if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window)) {
        text->AppendText(to_wx(value));
        widget->text = to_utf8(text->GetValue());
        return 0;
    }

    luaL_error(L, "widget:append is only supported for gui.TextBox and gui.TextArea");
    return 0;
}

static int widget_on_submit(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    release_ref(L, widget->onSubmitRef);
    widget->onSubmitRef = store_value_ref(L, 2);
    if (auto* search = dynamic_cast<wxSearchCtrl*>(widget->window)) {
        search->Bind(wxEVT_TEXT_ENTER,
                     [rt = widget->base.rt, ref = widget->onSubmitRef, search](wxCommandEvent&) {
                         queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                     });
        search->Bind(wxEVT_SEARCHCTRL_SEARCH_BTN,
                     [rt = widget->base.rt, ref = widget->onSubmitRef, search](wxCommandEvent&) {
                         queue_callback1_string(rt, ref, to_utf8(search->GetValue()));
                     });
    } else if (auto* text = dynamic_cast<wxTextCtrl*>(widget->window)) {
        text->Bind(wxEVT_TEXT_ENTER,
                   [rt = widget->base.rt, ref = widget->onSubmitRef, text](wxCommandEvent&) {
                       queue_callback1_string(rt, ref, to_utf8(text->GetValue()));
                   });
    }
    return 0;
}

static int widget_url(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind != GuiKind::Hyperlink) {
        luaL_error(L, "url is only supported for gui.Hyperlink");
    }

    if (lua_gettop(L) < 2) {
        std::string value = widget->placeholder;
        if (auto* link = dynamic_cast<wxHyperlinkCtrl*>(widget->window)) {
            value = to_utf8(link->GetURL());
        }
        lua_pushstring(L, value.c_str());
        return 1;
    }

    widget->placeholder = luaL_checkstring(L, 2);
    if (auto* link = dynamic_cast<wxHyperlinkCtrl*>(widget->window)) {
        link->SetURL(to_wx(widget->placeholder));
    }
    return 0;
}

static long info_style_from_kind(const std::string& kind) {
    if (kind == "warning") return wxICON_WARNING;
    if (kind == "error") return wxICON_ERROR;
    return wxICON_INFORMATION;
}

static int widget_show_message(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind != GuiKind::InfoBar) {
        luaL_error(L, "showMessage is only supported for gui.InfoBar");
    }

    std::string message = luaL_checkstring(L, 2);
    std::string kind = luaL_optstring(L, 3, "info");
    if (auto* info = dynamic_cast<wxInfoBar*>(widget->window)) {
        info->ShowMessage(to_wx(message), info_style_from_kind(kind));
    }
    return 0;
}

static int widget_dismiss(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (widget->base.kind != GuiKind::InfoBar) {
        luaL_error(L, "dismiss is only supported for gui.InfoBar");
    }

    if (auto* info = dynamic_cast<wxInfoBar*>(widget->window)) {
        info->Dismiss();
    }
    return 0;
}

static int progress_range(lua_State* L) {
    auto* widget = check_widget(L, 1);
    widget->range = std::max(luaL_checkinteger(L, 2), 1);
    if (auto* gauge = dynamic_cast<wxGauge*>(widget->window)) {
        gauge->SetRange(widget->range);
        gauge->SetValue(std::clamp(widget->gaugeValue, 0, widget->range));
    }
    return 0;
}

static int progress_value(lua_State* L) { return widget_value(L); }

static int progress_pulse(lua_State* L) {
    auto* widget = check_widget(L, 1);
    if (auto* gauge = dynamic_cast<wxGauge*>(widget->window)) {
        gauge->Pulse();
    }
    return 0;
}

static int table_set_columns(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    widget->columns.clear();

    int length = lua_objlen(L, 2);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, 2, i);
        lua_getfield(L, -1, "key");
        lua_getfield(L, -2, "title");
        lua_getfield(L, -3, "width");
        lua_getfield(L, -4, "expand");

        TableColumn column;
        column.key = luaL_checkstring(L, -4);
        column.title = luaL_checkstring(L, -3);
        column.width = lua_isnil(L, -2) ? -1 : luaL_checkinteger(L, -2);
        column.expand = lua_toboolean(L, -1);
        widget->columns.push_back(std::move(column));

        lua_pop(L, 5);
    }

    apply_table_view(L, widget);
    apply_list_view(widget);
    return 0;
}

static int table_set_rows(lua_State* L) {
    auto* widget = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    widget->rows.clear();

    int length = lua_objlen(L, 2);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, 2, i);
        TableRow row;
        for (const TableColumn& column : widget->columns) {
            lua_getfield(L, -1, column.key.c_str());
            row.values[column.key] = lua_value_to_string(L, -1);
            lua_pop(L, 1);
        }
        widget->rows.push_back(std::move(row));
        lua_pop(L, 1);
    }

    apply_table_view(L, widget);
    apply_list_view(widget);
    return 0;
}

static int table_set_filter(lua_State* L) {
    auto* widget = check_widget(L, 1);
    widget->filter = luaL_optstring(L, 2, "");
    apply_table_view(L, widget);
    apply_list_view(widget);
    return 0;
}

static int menu_add(lua_State* L) {
    auto* menu = check_menu(L, 1);
    if (lua_isnil(L, 2)) {
        menu->itemRefs.push_back(LUA_NOREF);
        return 0;
    }

    if (!test_udata<GuiAction>(L, 2, MT_ACTION)) {
        luaL_error(L, "menu:add expects gui.Action or nil");
    }
    menu->itemRefs.push_back(store_value_ref(L, 2));
    return 0;
}

static int menu_add_separator(lua_State* L) {
    auto* menu = check_menu(L, 1);
    (void)menu;
    menu->itemRefs.push_back(LUA_NOREF);
    return 0;
}

static int menubar_add(lua_State* L) {
    auto* bar = check_menubar(L, 1);
    check_menu(L, 2);
    bar->menuRefs.push_back(store_value_ref(L, 2));
    return 0;
}

static int bitmap_from_image(lua_State* L) {
    ensure_wx(L);
    int imageIndex = 1;

    lua_getfield(L, imageIndex, "width");
    lua_getfield(L, imageIndex, "height");
    lua_getfield(L, imageIndex, "format");
    lua_getfield(L, imageIndex, "buffer");

    int width = luaL_checkinteger(L, -4);
    int height = luaL_checkinteger(L, -3);
    std::string format = luaL_checkstring(L, -2);
    size_t bufferLength = 0;
    const auto* buffer = static_cast<const unsigned char*>(lua_tobuffer(L, -1, &bufferLength));
    if (!buffer) {
        luaL_error(L, "gui.bitmap expects an @eryx/image image");
    }

    std::vector<unsigned char> rgb(static_cast<size_t>(width) * height * 3);
    std::vector<unsigned char> alpha(static_cast<size_t>(width) * height);
    if (format == "rgba8") {
        for (int i = 0; i < width * height; ++i) {
            rgb[i * 3 + 0] = buffer[i * 4 + 0];
            rgb[i * 3 + 1] = buffer[i * 4 + 1];
            rgb[i * 3 + 2] = buffer[i * 4 + 2];
            alpha[i] = buffer[i * 4 + 3];
        }
    } else if (format == "rgb8") {
        for (int i = 0; i < width * height; ++i) {
            rgb[i * 3 + 0] = buffer[i * 3 + 0];
            rgb[i * 3 + 1] = buffer[i * 3 + 1];
            rgb[i * 3 + 2] = buffer[i * 3 + 2];
            alpha[i] = 255;
        }
    } else {
        luaL_error(L, "gui.bitmap currently supports rgba8 and rgb8 images");
    }
    lua_pop(L, 4);

    wxImage image(width, height);
    image.SetData(new unsigned char[rgb.size()], true);
    std::copy(rgb.begin(), rgb.end(), image.GetData());
    image.SetAlpha(new unsigned char[alpha.size()], true);
    std::copy(alpha.begin(), alpha.end(), image.GetAlpha());

    auto* bitmap = push_object<GuiBitmap>(L, MT_BITMAP);
    bitmap->bitmap = new wxBitmap(image);
    return 1;
}

static int open_file_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "filter");
    std::string title = lua_isnil(L, -2) ? "Open File" : lua_tostring(L, -2);
    std::string filter = lua_isnil(L, -1) ? "All files|*" : lua_tostring(L, -1);
    lua_pop(L, 2);

    wxFileDialog dialog(nullptr, to_wx(title), "", "", to_wx(filter),
                        wxFD_OPEN | wxFD_FILE_MUST_EXIST);
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, to_utf8(dialog.GetPath()).c_str());
    return 1;
}

static int save_file_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "filter");
    std::string title = lua_isnil(L, -2) ? "Save File" : lua_tostring(L, -2);
    std::string filter = lua_isnil(L, -1) ? "All files|*" : lua_tostring(L, -1);
    lua_pop(L, 2);

    wxFileDialog dialog(nullptr, to_wx(title), "", "", to_wx(filter),
                        wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, to_utf8(dialog.GetPath()).c_str());
    return 1;
}

static int open_directory_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    std::string title = lua_isnil(L, -1) ? "Choose Directory" : lua_tostring(L, -1);
    lua_pop(L, 1);

    wxDirDialog dialog(nullptr, to_wx(title));
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, to_utf8(dialog.GetPath()).c_str());
    return 1;
}

static int text_entry_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "message");
    lua_getfield(L, 1, "value");
    std::string title = lua_isnil(L, -3) ? "Enter Text" : lua_tostring(L, -3);
    std::string message = lua_isnil(L, -2) ? "" : lua_tostring(L, -2);
    std::string value = lua_isnil(L, -1) ? "" : lua_tostring(L, -1);
    lua_pop(L, 3);

    wxTextEntryDialog dialog(nullptr, to_wx(message), to_wx(title), to_wx(value));
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, to_utf8(dialog.GetValue()).c_str());
    return 1;
}

static int number_entry_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "message");
    lua_getfield(L, 1, "value");
    lua_getfield(L, 1, "min");
    lua_getfield(L, 1, "max");
    std::string title = lua_isnil(L, -5) ? "Enter Number" : lua_tostring(L, -5);
    std::string message = lua_isnil(L, -4) ? "" : lua_tostring(L, -4);
    long value = lua_isnil(L, -3) ? 0 : luaL_checkinteger(L, -3);
    long minValue = lua_isnil(L, -2) ? 0 : luaL_checkinteger(L, -2);
    long maxValue = lua_isnil(L, -1) ? 100 : luaL_checkinteger(L, -1);
    lua_pop(L, 5);

    long result = wxGetNumberFromUser(wxEmptyString, to_wx(message), to_wx(title), value, minValue,
                                      maxValue, nullptr);
    if (result == -1) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushinteger(L, result);
    return 1;
}

static int choice_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "message");
    lua_getfield(L, 1, "choices");
    std::string title = lua_isnil(L, -3) ? "Choose" : lua_tostring(L, -3);
    std::string message = lua_isnil(L, -2) ? "" : lua_tostring(L, -2);
    luaL_checktype(L, -1, LUA_TTABLE);

    wxArrayString choices;
    int length = lua_objlen(L, -1);
    for (int i = 1; i <= length; ++i) {
        lua_rawgeti(L, -1, i);
        choices.Add(to_wx(luaL_checkstring(L, -1)));
        lua_pop(L, 1);
    }
    lua_pop(L, 3);

    wxSingleChoiceDialog dialog(nullptr, to_wx(message), to_wx(title), choices);
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, to_utf8(dialog.GetStringSelection()).c_str());
    return 1;
}

static int colour_dialog(lua_State* L) {
    ensure_wx(L);
    (void)L;
    wxColourData data;
    wxColourDialog dialog(nullptr, &data);
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    wxColour colour = dialog.GetColourData().GetColour();
    char buffer[8];
    snprintf(buffer, sizeof(buffer), "#%02X%02X%02X", colour.Red(), colour.Green(), colour.Blue());
    lua_pushstring(L, buffer);
    return 1;
}

static int font_dialog(lua_State* L) {
    ensure_wx(L);
    (void)L;
    wxFontData data;
    wxFontDialog dialog(nullptr, data);
    if (dialog.ShowModal() != wxID_OK) {
        lua_pushnil(L);
        return 1;
    }

    wxFont font = dialog.GetFontData().GetChosenFont();
    lua_createtable(L, 0, 4);
    lua_pushstring(L, to_utf8(font.GetFaceName()).c_str());
    lua_setfield(L, -2, "face");
    lua_pushinteger(L, font.GetPointSize());
    lua_setfield(L, -2, "size");
    lua_pushboolean(L, font.GetWeight() >= wxFONTWEIGHT_BOLD);
    lua_setfield(L, -2, "bold");
    lua_pushboolean(L, font.GetStyle() == wxFONTSTYLE_ITALIC);
    lua_setfield(L, -2, "italic");
    return 1;
}

static int about_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    wxAboutDialogInfo info;
    lua_getfield(L, 1, "name");
    lua_getfield(L, 1, "version");
    lua_getfield(L, 1, "description");
    info.SetName(lua_isnil(L, -3) ? to_wx("Eryx App") : to_wx(lua_tostring(L, -3)));
    if (!lua_isnil(L, -2)) info.SetVersion(to_wx(lua_tostring(L, -2)));
    if (!lua_isnil(L, -1)) info.SetDescription(to_wx(lua_tostring(L, -1)));
    lua_pop(L, 3);

    wxAboutBox(info);
    return 0;
}

static int progress_dialog(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "message");
    lua_getfield(L, 1, "value");
    lua_getfield(L, 1, "max");
    std::string title = lua_isnil(L, -4) ? "Progress" : lua_tostring(L, -4);
    std::string message = lua_isnil(L, -3) ? "" : lua_tostring(L, -3);
    int value = lua_isnil(L, -2) ? 0 : luaL_checkinteger(L, -2);
    int maxValue = lua_isnil(L, -1) ? 100 : luaL_checkinteger(L, -1);
    lua_pop(L, 4);

    wxProgressDialog dialog(to_wx(title), to_wx(message), std::max(maxValue, 1), nullptr,
                            wxPD_APP_MODAL | wxPD_AUTO_HIDE);
    bool keepGoing = dialog.Update(std::clamp(value, 0, std::max(maxValue, 1)));
    lua_pushboolean(L, keepGoing);
    return 1;
}

static int message_box(lua_State* L) {
    ensure_wx(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "title");
    lua_getfield(L, 1, "message");
    lua_getfield(L, 1, "kind");
    std::string title = lua_isnil(L, -3) ? "Message" : lua_tostring(L, -3);
    std::string message = lua_isnil(L, -2) ? "" : lua_tostring(L, -2);
    std::string kind = lua_isnil(L, -1) ? "info" : lua_tostring(L, -1);
    lua_pop(L, 3);

    long style = wxOK;
    if (kind == "warning")
        style |= wxICON_WARNING;
    else if (kind == "error")
        style |= wxICON_ERROR;
    else
        style |= wxICON_INFORMATION;

    wxMessageBox(to_wx(message), to_wx(title), style);
    return 0;
}

static int set_clipboard_text(lua_State* L) {
    ensure_wx(L);
    std::string text = luaL_checkstring(L, 1);
    if (wxTheClipboard->Open()) {
        wxTheClipboard->SetData(new wxTextDataObject(to_wx(text)));
        wxTheClipboard->Close();
    }
    return 0;
}

static int get_clipboard_text(lua_State* L) {
    ensure_wx(L);
    wxString text;
    if (wxTheClipboard->Open()) {
        if (wxTheClipboard->IsSupported(wxDF_TEXT)) {
            wxTextDataObject data;
            wxTheClipboard->GetData(data);
            text = data.GetText();
        }
        wxTheClipboard->Close();
    }
    lua_pushstring(L, to_utf8(text).c_str());
    return 1;
}

}  // namespace

LUAU_MODULE_EXPORT int luauopen_gui(lua_State* L) {
    static luaL_Reg appMethods[] = {
        { "run", app_run },
        { "quit", app_quit },
        { nullptr, nullptr },
    };
    static luaL_Reg windowMethods[] = {
        { "minimumSize", window_minimum_size },
        { "setTitle", window_set_title },
        { "setLayout", window_set_layout },
        { "setStatusBar", window_set_status_bar },
        { "setMenuBar", window_set_menu_bar },
        { "onClose", window_on_close },
        { "show", window_show },
        { "close", window_close },
        { nullptr, nullptr },
    };
    static luaL_Reg dialogMethods[] = {
        { "minimumSize", window_minimum_size },
        { "setTitle", window_set_title },
        { "setLayout", window_set_layout },
        { "onClose", window_on_close },
        { "show", window_show },
        { "showModal", dialog_show_modal },
        { "close", window_close },
        { nullptr, nullptr },
    };
    static luaL_Reg layoutMethods[] = {
        { "add", layout_add },
        { "padding", layout_padding },
        { "gap", layout_gap },
        { nullptr, nullptr },
    };
    static luaL_Reg spacerMethods[] = { { nullptr, nullptr } };
    static luaL_Reg widgetMethods[] = {
        { "enabled", widget_enabled },
        { "text", widget_text },
        { "checked", widget_checked },
        { "onClick", button_on_click },
        { "setIcon", button_set_icon },
        { "placeholder", textbox_placeholder },
        { "readOnly", widget_read_only },
        { "password", widget_password },
        { "append", widget_append },
        { "url", widget_url },
        { "onChange", textbox_on_change },
        { "onSubmit", widget_on_submit },
        { "limits", widget_limits },
        { "setItems", widget_set_items },
        { "setNodes", widget_set_nodes },
        { "selected", widget_selected },
        { "onSelect", widget_on_select },
        { "add", widget_add },
        { "setPanes", splitter_set_panes },
        { "position", splitter_position },
        { "showMessage", widget_show_message },
        { "dismiss", widget_dismiss },
        { "range", progress_range },
        { "value", widget_value },
        { "pulse", progress_pulse },
        { "setColumns", table_set_columns },
        { "setRows", table_set_rows },
        { "setFilter", table_set_filter },
        { nullptr, nullptr },
    };
    static luaL_Reg statusMethods[] = {
        { "setText", status_set_text },
        { "setFields", status_set_fields },
        { nullptr, nullptr },
    };
    static luaL_Reg menuMethods[] = {
        { "add", menu_add },
        { "addSeparator", menu_add_separator },
        { nullptr, nullptr },
    };
    static luaL_Reg menubarMethods[] = {
        { "add", menubar_add },
        { nullptr, nullptr },
    };
    static luaL_Reg actionMethods[] = { { nullptr, nullptr } };
    static luaL_Reg bitmapMethods[] = { { nullptr, nullptr } };

    static udataDef appDef = {
        .name = MT_APP,
        .size = sizeof(GuiAppHandle),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = appMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef windowDef = {
        .name = MT_WINDOW,
        .size = sizeof(GuiWindow),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = windowMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef dialogDef = {
        .name = MT_DIALOG,
        .size = sizeof(GuiWindow),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = dialogMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef layoutDef = {
        .name = MT_LAYOUT,
        .size = sizeof(GuiLayout),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = layoutMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef spacerDef = {
        .name = MT_SPACER,
        .size = sizeof(GuiSpacer),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = spacerMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef widgetDef = {
        .name = MT_WIDGET,
        .size = sizeof(GuiWidget),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = widgetMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef statusDef = {
        .name = MT_STATUS,
        .size = sizeof(GuiStatusBar),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = statusMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef menuDef = {
        .name = MT_MENU,
        .size = sizeof(GuiMenu),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = menuMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef menubarDef = {
        .name = MT_MENUBAR,
        .size = sizeof(GuiMenuBar),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = menubarMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef actionDef = {
        .name = MT_ACTION,
        .size = sizeof(GuiAction),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = actionMethods,
        .destructor = gui_base_dtor,
    };
    static udataDef bitmapDef = {
        .name = MT_BITMAP,
        .size = sizeof(GuiBitmap),
        .fields = nullptr,
        .indexFallback = nullptr,
        .newindexFallback = nullptr,
        .metamethods = nullptr,
        .dotcallMethods = nullptr,
        .namecallMethods = nullptr,
        .bothcallMethods = bitmapMethods,
        .destructor = gui_base_dtor,
    };

    eryxUdata_registerudata(L, &appDef);
    eryxUdata_registerudata(L, &windowDef);
    eryxUdata_registerudata(L, &dialogDef);
    eryxUdata_registerudata(L, &layoutDef);
    eryxUdata_registerudata(L, &spacerDef);
    eryxUdata_registerudata(L, &widgetDef);
    eryxUdata_registerudata(L, &statusDef);
    eryxUdata_registerudata(L, &menuDef);
    eryxUdata_registerudata(L, &menubarDef);
    eryxUdata_registerudata(L, &actionDef);
    eryxUdata_registerudata(L, &bitmapDef);

    lua_newtable(L);

    lua_pushcfunction(L, app_new, "App");
    lua_setfield(L, -2, "App");
    lua_pushcfunction(L, window_new, "Window");
    lua_setfield(L, -2, "Window");
    lua_pushcfunction(L, dialog_new, "Dialog");
    lua_setfield(L, -2, "Dialog");
    lua_pushcfunction(L, layout_vbox, "VBox");
    lua_setfield(L, -2, "VBox");
    lua_pushcfunction(L, layout_hbox, "HBox");
    lua_setfield(L, -2, "HBox");
    lua_pushcfunction(L, layout_grid, "Grid");
    lua_setfield(L, -2, "Grid");
    lua_pushcfunction(L, layout_form, "Form");
    lua_setfield(L, -2, "Form");
    lua_pushcfunction(L, spacer_new, "Spacer");
    lua_setfield(L, -2, "Spacer");
    lua_pushcfunction(L, label_new, "Label");
    lua_setfield(L, -2, "Label");
    lua_pushcfunction(L, button_new, "Button");
    lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, togglebutton_new, "ToggleButton");
    lua_setfield(L, -2, "ToggleButton");
    lua_pushcfunction(L, toolbar_new, "ToolBar");
    lua_setfield(L, -2, "ToolBar");
    lua_pushcfunction(L, textbox_new, "TextBox");
    lua_setfield(L, -2, "TextBox");
    lua_pushcfunction(L, textarea_new, "TextArea");
    lua_setfield(L, -2, "TextArea");
    lua_pushcfunction(L, searchbox_new, "SearchBox");
    lua_setfield(L, -2, "SearchBox");
    lua_pushcfunction(L, checkbox_new, "CheckBox");
    lua_setfield(L, -2, "CheckBox");
    lua_pushcfunction(L, radiobutton_new, "RadioButton");
    lua_setfield(L, -2, "RadioButton");
    lua_pushcfunction(L, datepicker_new, "DatePicker");
    lua_setfield(L, -2, "DatePicker");
    lua_pushcfunction(L, hyperlink_new, "Hyperlink");
    lua_setfield(L, -2, "Hyperlink");
    lua_pushcfunction(L, choice_new, "Choice");
    lua_setfield(L, -2, "Choice");
    lua_pushcfunction(L, combobox_new, "ComboBox");
    lua_setfield(L, -2, "ComboBox");
    lua_pushcfunction(L, listbox_new, "ListBox");
    lua_setfield(L, -2, "ListBox");
    lua_pushcfunction(L, tree_new, "TreeView");
    lua_setfield(L, -2, "TreeView");
    lua_pushcfunction(L, slider_new, "Slider");
    lua_setfield(L, -2, "Slider");
    lua_pushcfunction(L, spinbox_new, "SpinBox");
    lua_setfield(L, -2, "SpinBox");
    lua_pushcfunction(L, progress_new, "ProgressBar");
    lua_setfield(L, -2, "ProgressBar");
    lua_pushcfunction(L, tabs_new, "Tabs");
    lua_setfield(L, -2, "Tabs");
    lua_pushcfunction(L, table_new, "TableView");
    lua_setfield(L, -2, "TableView");
    lua_pushcfunction(L, listview_new, "ListView");
    lua_setfield(L, -2, "ListView");
    lua_pushcfunction(L, panel_new, "Panel");
    lua_setfield(L, -2, "Panel");
    lua_pushcfunction(L, scrollarea_new, "ScrollArea");
    lua_setfield(L, -2, "ScrollArea");
    lua_pushcfunction(L, groupbox_new, "GroupBox");
    lua_setfield(L, -2, "GroupBox");
    lua_pushcfunction(L, staticline_new, "StaticLine");
    lua_setfield(L, -2, "StaticLine");
    lua_pushcfunction(L, infobar_new, "InfoBar");
    lua_setfield(L, -2, "InfoBar");
    lua_pushcfunction(L, hsplitter_new, "HSplitter");
    lua_setfield(L, -2, "HSplitter");
    lua_pushcfunction(L, vsplitter_new, "VSplitter");
    lua_setfield(L, -2, "VSplitter");
    lua_pushcfunction(L, status_new, "StatusBar");
    lua_setfield(L, -2, "StatusBar");
    lua_pushcfunction(L, menu_new, "Menu");
    lua_setfield(L, -2, "Menu");
    lua_pushcfunction(L, menubar_new, "MenuBar");
    lua_setfield(L, -2, "MenuBar");
    lua_pushcfunction(L, action_new, "Action");
    lua_setfield(L, -2, "Action");
    lua_pushcfunction(L, bitmap_from_image, "bitmap");
    lua_setfield(L, -2, "bitmap");
    lua_pushcfunction(L, open_file_dialog, "openFileDialog");
    lua_setfield(L, -2, "openFileDialog");
    lua_pushcfunction(L, save_file_dialog, "saveFileDialog");
    lua_setfield(L, -2, "saveFileDialog");
    lua_pushcfunction(L, open_directory_dialog, "openDirectoryDialog");
    lua_setfield(L, -2, "openDirectoryDialog");
    lua_pushcfunction(L, message_box, "messageBox");
    lua_setfield(L, -2, "messageBox");
    lua_pushcfunction(L, text_entry_dialog, "textEntryDialog");
    lua_setfield(L, -2, "textEntryDialog");
    lua_pushcfunction(L, number_entry_dialog, "numberEntryDialog");
    lua_setfield(L, -2, "numberEntryDialog");
    lua_pushcfunction(L, choice_dialog, "choiceDialog");
    lua_setfield(L, -2, "choiceDialog");
    lua_pushcfunction(L, colour_dialog, "colourDialog");
    lua_setfield(L, -2, "colourDialog");
    lua_pushcfunction(L, font_dialog, "fontDialog");
    lua_setfield(L, -2, "fontDialog");
    lua_pushcfunction(L, about_dialog, "aboutDialog");
    lua_setfield(L, -2, "aboutDialog");
    lua_pushcfunction(L, progress_dialog, "progressDialog");
    lua_setfield(L, -2, "progressDialog");
    lua_pushcfunction(L, set_clipboard_text, "setClipboardText");
    lua_setfield(L, -2, "setClipboardText");
    lua_pushcfunction(L, get_clipboard_text, "getClipboardText");
    lua_setfield(L, -2, "getClipboardText");

    lua_setreadonly(L, -1, true);
    return 1;
}
