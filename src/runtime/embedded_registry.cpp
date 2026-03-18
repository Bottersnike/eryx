// Runtime storage for embedded module tables.
// In embed/hybrid builds the exe calls eryx_register_embedded_modules()
// at startup; in normal builds the pointers stay null and all lookups
// gracefully fall through to filesystem / DLL resolution.

#include "embedded_modules.h"

static const EmbeddedNativeModule*  s_embedded_native  = nullptr;
static const EmbeddedScriptModule*  s_embedded_scripts = nullptr;

void eryx_register_embedded_modules(
    const EmbeddedNativeModule* native,
    const EmbeddedScriptModule* scripts)
{
    s_embedded_native  = native;
    s_embedded_scripts = scripts;
}

const EmbeddedNativeModule* eryx_get_embedded_native_modules() {
    return s_embedded_native;
}

const EmbeddedScriptModule* eryx_get_embedded_script_modules() {
    return s_embedded_scripts;
}

bool eryx_has_embedded_modules() {
    return s_embedded_native != nullptr || s_embedded_scripts != nullptr;
}
