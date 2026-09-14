#pragma once
#include "../../third_party/librime/rime_api.h"

namespace rimeq {
// librime shares opened schema data. Hold the handle while constructing the
// session's translator, then restore it; never save or edit a compiled YAML.
// The host serializes engine calls and invokes this only with no composition.
inline bool select_schema_with_preferences(RimeApi* api, RimeSessionId session,
                                           const char* schema, bool adjacent_keys,
                                           bool show_hints) {
    if (!api || !session || !schema || !RIME_API_AVAILABLE(api, config_clear)) return false;
    RimeConfig config{};
    if (!api->schema_open(schema, &config)) return false;
    const char* key = "translator/enable_correction";
    Bool previous = False;
    bool existed = api->config_get_bool(&config, key, &previous);
    bool applied = api->config_set_bool(&config, key, adjacent_keys);
    bool selected = applied && api->select_schema(session, schema);
    bool restored = existed ? api->config_set_bool(&config, key, previous)
                            : api->config_clear(&config, key);
    api->config_close(&config);
    if (selected && restored) api->set_option(session, "q_hide_correction_hints", !show_hints);
    return selected && restored;
}
}
