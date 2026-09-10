#include "QRimeBridge.h"
#include "../../third_party/librime/rime_api.h"
#include "../../third_party/librime/rime_levers_api.h"
#include <dlfcn.h>
#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>

namespace {
RimeApi* api = nullptr;
bool started = false;
std::vector<void*> libraries;
std::string error_message, shared_path, user_path, prebuilt_path, staging_path;
std::string preedit, input, committed;
std::string dictionary_name, dictionary_version, dictionary_columns;
std::vector<std::string> texts, comments;
int cursor = 0, highlighted = 0, page = 0;
bool last_page = true;

bool load(const std::string& path) {
    void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!library) { error_message = "Cannot load bundled runtime: " + std::filesystem::path(path).filename().string(); return false; }
    libraries.push_back(library);
    return true;
}
const char* safe(const char* text) { return text ? text : ""; }
RimeLeversApi* levers() {
    if (!started) return nullptr;
    auto module = api->find_module("levers");
    if (!module || !module->get_api) return nullptr;
    auto result = reinterpret_cast<RimeLeversApi*>(module->get_api());
    return result && RIME_API_AVAILABLE(result, import_user_dict) &&
           RIME_API_AVAILABLE(result, export_user_dict) ? result : nullptr;
}
}

bool QRimeStart(const char* frameworks, const char* shared, const char* user, bool deploy) {
    if (started) return true;
    error_message.clear();
    if (!frameworks || !shared || !user) { error_message = "Missing runtime paths"; return false; }
    if (libraries.empty()) {
        const std::string root(frameworks);
        if (!load(root + "/librime.1.dylib") ||
            !load(root + "/rime-plugins/librime-lua.dylib") ||
            !load(root + "/rime-plugins/librime-octagram.dylib")) return false;
    }
    auto get_api = reinterpret_cast<RimeApi* (*)()>(dlsym(libraries.front(), "rime_get_api"));
    if (!get_api || !(api = get_api())) { error_message = "Missing Rime API"; return false; }
    if (!RIME_API_AVAILABLE(api, select_candidate_on_current_page)) {
        error_message = "Bundled Rime API is too old"; return false;
    }
    shared_path = shared;
    user_path = user;
    prebuilt_path = shared_path + "/build";
    staging_path = user_path + "/build";
    static const char* modules[] = {"default", "levers", "lua", "octagram", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared_path.c_str();
    traits.user_data_dir = user_path.c_str();
    traits.prebuilt_data_dir = prebuilt_path.c_str();
    traits.staging_dir = staging_path.c_str();
    traits.distribution_name = "Rime Q";
    traits.distribution_code_name = "rime-q";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.rimeq";
    traits.modules = modules;
    traits.min_log_level = 2;
    traits.log_dir = user_path.c_str();
    api->setup(&traits);
    api->initialize(&traits);
    started = true;
    if (!api->find_module("lua") || !api->find_module("octagram")) {
        error_message = "Bundled language modules could not initialize";
        QRimeStop(); return false;
    }
    if (deploy && api->start_maintenance(true)) api->join_maintenance_thread();
    const auto session = api->create_session();
    if (!session || !api->select_schema(session, "rime_q")) {
        if (session) api->destroy_session(session);
        error_message = "Input resources are not deployed";
        QRimeStop(); return false;
    }
    api->destroy_session(session);
    return true;
}

void QRimeStop(void) {
    if (started) { api->finalize(); started = false; }
    // Plugins register static module pointers. Keep their images loaded until process exit.
}
const char* QRimeError(void) { return error_message.c_str(); }
const char* QRimeVersion(void) { return api ? api->get_version() : "unavailable"; }
uintptr_t QRimeCreateSession(void) { return started ? api->create_session() : 0; }
void QRimeDestroySession(uintptr_t session) { if (started && session) api->destroy_session(session); }
bool QRimeProcess(uintptr_t session, int key, int modifiers) { return started && session && api->process_key(session, key, modifiers); }
bool QRimeSelect(uintptr_t session, size_t index) { return started && session && api->select_candidate_on_current_page(session, index); }
bool QRimeSchema(uintptr_t session, const char* schema) { return started && session && schema && api->select_schema(session, schema); }
void QRimeClear(uintptr_t session) { if (started && session) api->clear_composition(session); }
bool QRimeCommitComposition(uintptr_t session) { return started && session && api->commit_composition(session); }
void QRimeSetOption(uintptr_t session, const char* name, bool value) { if (started && session) api->set_option(session, name, value); }
bool QRimeGetOption(uintptr_t session, const char* name) { return started && session && api->get_option(session, name); }

int QRimePersonalDictionaryState(void) {
    auto manager = levers();
    if (!manager || !RIME_API_AVAILABLE(manager, next_user_dict) ||
        !manager->user_dict_iterator_init || !manager->user_dict_iterator_destroy) return -1;
    RimeUserDictIterator iterator{};
    if (!manager->user_dict_iterator_init(&iterator)) return -1;
    int found = 0;
    while (const char* name = manager->next_user_dict(&iterator)) {
        if (std::string(name) == "rime_q") { found = 1; break; }
    }
    manager->user_dict_iterator_destroy(&iterator);
    return found;
}
int QRimeExportPersonalDictionary(const char* file) {
    auto manager = levers();
    if (!manager || !file || !*file) return -1;
    api->cleanup_all_sessions();
    return manager->export_user_dict("rime_q", file);
}
int QRimeImportPersonalDictionary(const char* file) {
    auto manager = levers();
    if (!manager || !file || !*file) return -1;
    api->cleanup_all_sessions();
    return manager->import_user_dict("rime_q", file);
}

bool QRimeParseDictionaryHeader(const char* yaml) {
    dictionary_name.clear(); dictionary_version.clear(); dictionary_columns.clear();
    if (!started || !yaml) return false;
    RimeConfig config{};
    if (!api->config_init(&config)) return false;
    const bool loaded = api->config_load_string(&config, yaml);
    bool valid = loaded && api->config_list_size(&config, "import_tables") == 0;
    if (valid) {
        dictionary_name = safe(api->config_get_cstring(&config, "name"));
        dictionary_version = safe(api->config_get_cstring(&config, "version"));
        const auto count = api->config_list_size(&config, "columns");
        if (!count) dictionary_columns = "text\tcode\tweight";
        for (size_t i = 0; i < count; ++i) {
            if (i) dictionary_columns += '\t';
            dictionary_columns += safe(api->config_get_cstring(&config, ("columns/@" + std::to_string(i)).c_str()));
        }
        valid = !dictionary_name.empty();
    }
    api->config_close(&config);
    return valid;
}

const char* QRimeTakeCommit(uintptr_t session) {
    committed.clear();
    if (started && session) {
        RIME_STRUCT(RimeCommit, commit);
        if (api->get_commit(session, &commit)) {
            committed = safe(commit.text);
            api->free_commit(&commit);
        }
    }
    return committed.c_str();
}

bool QRimeRead(uintptr_t session) {
    preedit.clear(); input.clear(); texts.clear(); comments.clear();
    cursor = highlighted = page = 0; last_page = true;
    if (!started || !session) return false;
    RIME_STRUCT(RimeContext, context);
    if (!api->get_context(session, &context)) return false;
    preedit = safe(context.composition.preedit);
    input = safe(api->get_input(session));
    cursor = context.composition.cursor_pos;
    highlighted = context.menu.highlighted_candidate_index;
    page = context.menu.page_no;
    last_page = context.menu.is_last_page;
    const int count = context.menu.candidates ? std::clamp(context.menu.num_candidates, 0, 9) : 0;
    for (int i = 0; i < count; ++i) {
        texts.emplace_back(safe(context.menu.candidates[i].text));
        comments.emplace_back(safe(context.menu.candidates[i].comment));
    }
    api->free_context(&context);
    return true;
}
const char* QRimePreedit(void) { return preedit.c_str(); }
const char* QRimeInput(void) { return input.c_str(); }
int QRimeCursorBytes(void) { return cursor; }
int QRimeHighlighted(void) { return highlighted; }
int QRimePage(void) { return page; }
bool QRimeLastPage(void) { return last_page; }
size_t QRimeCandidateCount(void) { return texts.size(); }
const char* QRimeCandidateText(size_t index) { return index < texts.size() ? texts[index].c_str() : ""; }
const char* QRimeCandidateComment(size_t index) { return index < comments.size() ? comments[index].c_str() : ""; }
const char* QRimeDictionaryName(void) { return dictionary_name.c_str(); }
const char* QRimeDictionaryVersion(void) { return dictionary_version.c_str(); }
const char* QRimeDictionaryColumns(void) { return dictionary_columns.c_str(); }
