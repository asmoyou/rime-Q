#include "engine.h"
#include "../../include/rimeq/rime_preferences.hpp"
#include "sync_dictionary.h"
#include "../../third_party/librime/rime_levers_api.h"
#include "version.h"
#include <bcrypt.h>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <sstream>

namespace rq {
namespace {
const char* safe(const char* s) { return s ? s : ""; }
bool generationName(const std::string& value) {
    if (value.size() != 36) return false;
    for (size_t i = 0; i < value.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return false; }
        else if (!std::isxdigit(static_cast<unsigned char>(value[i]))) return false;
    }
    return true;
}
}
fs::path activeResources(const fs::path& application, const fs::path& data) {
    auto fallback = application / L"data";
    auto pointer = data / L"dictionaries/active.txt";
    std::ifstream input(pointer, std::ios::binary); std::string id;
    if (!input || !std::getline(input, id)) return fallback;
    if (!id.empty() && id.back() == '\r') id.pop_back();
    if (!generationName(id)) return fallback;
    std::error_code error;
    auto generations = fs::weakly_canonical(data / L"dictionaries/generations", error); if (error) return fallback;
    auto root = fs::weakly_canonical(generations / wide(id), error); if (error || root.parent_path() != generations) return fallback;
    auto shared = root / L"data";
    for (auto required : {root / L".rimeq-generation", shared / L"build/rime_ice.table.bin",
            shared / L"build/rime_q.schema.yaml", shared / L"build/rime_q_grammar.schema.yaml"})
        if (!fs::is_regular_file(required, error) || error) return fallback;
    return shared;
}
Engine::~Engine() { stop(); /* Static plugin registrations live until process exit. */ }
void Engine::stop() { if (started_) { api_->finalize(); started_ = false; sessions_.clear(); available_.clear(); generation_.clear(); } }
void Engine::start(const fs::path& application, const fs::path& data, bool deploy) {
    root_ = data; fs::create_directories(data / L"rime"); fs::create_directories(data / L"logs");
    library_ = LoadLibraryExW((application / L"runtime/rime.dll").c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library_) throw std::runtime_error("Cannot load bundled librime");
    auto getApi = reinterpret_cast<RimeApi* (*)()>(GetProcAddress(library_, "rime_get_api"));
    if (!getApi || !(api_ = getApi()) || !RIME_API_AVAILABLE(api_, select_candidate_on_current_page))
        throw std::runtime_error("Incompatible librime API");
    auto resources = activeResources(application, data);
    generation_ = resources == application / L"data" ? "" : utf8(resources.parent_path().filename().wstring());
    shared_ = utf8(resources.wstring()); user_ = utf8((data / L"rime").wstring());
    prebuilt_ = utf8((resources / L"build").wstring()); staging_ = utf8((data / L"rime/build").wstring());
    logs_ = utf8((data / L"logs").wstring());
    static const char* modules[] = {"default", "levers", "lua", "octagram", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared_.c_str(); traits.user_data_dir = user_.c_str();
    traits.prebuilt_data_dir = prebuilt_.c_str(); traits.staging_dir = staging_.c_str();
    traits.distribution_name = "Rime Q"; traits.distribution_code_name = "rime-q";
    traits.distribution_version = RIMEQ_VERSION; traits.app_name = "rime.rimeq";
    traits.modules = modules; traits.min_log_level = 2; traits.log_dir = logs_.c_str();
    api_->setup(&traits); api_->initialize(&traits); started_ = true;
    if (!api_->find_module("lua") || !api_->find_module("octagram")) throw std::runtime_error("Missing language plugins");
    if (deploy && api_->start_maintenance(true)) api_->join_maintenance_thread();
    adjacentKeys_ = preference(L"AdjacentKeyCorrection", 1, root_) != 0;
    correctionHints_ = preference(L"CorrectionHints", 1, root_) != 0;
    auto id = api_->create_session(); bool ok = id && configureSession(id, false, adjacentKeys_, correctionHints_, false);
    if (!ok) { if (id) api_->destroy_session(id); throw std::runtime_error("Base input resources are unavailable"); }
    // Keep the validated session warm. Opening a client must not repeat cold schema loading.
    available_.push_back(id);
}
RimeSessionId Engine::session(uint64_t client) {
    auto& id = sessions_[client];
    if (id && api_->find_session(id)) return id;
    if (!available_.empty()) {
        id = available_.back(); available_.pop_back(); api_->set_option(id, "ascii_mode", preservedAscii_[client]); return id;
    }
    id = api_->create_session();
    if (!id || !configureSession(id, grammar_, adjacentKeys_, correctionHints_, false)) {
        if (id) api_->destroy_session(id); id = 0; throw std::runtime_error("Cannot create input session");
    }
    api_->set_option(id, "ascii_mode", preservedAscii_[client]); return id;
}
void Engine::warmSession() {
    if (!available_.empty()) return;
    auto id=api_->create_session();
    if (!id || !configureSession(id,grammar_,adjacentKeys_,correctionHints_,false)) {
        if(id)api_->destroy_session(id);
        throw std::runtime_error("Cannot warm input session after dictionary maintenance");
    }
    available_.push_back(id);
}
State Engine::read(RimeSessionId id, bool handled) {
    State s; s.ready = true; s.handled = handled; s.ascii = api_->get_option(id, "ascii_mode") != 0;
    RIME_STRUCT(RimeCommit, commit);
    if (api_->get_commit(id, &commit)) { s.commit = safe(commit.text); api_->free_commit(&commit); }
    RIME_STRUCT(RimeContext, ctx);
    if (api_->get_context(id, &ctx)) {
        s.preedit = safe(ctx.composition.preedit);
        auto cursor = std::clamp(ctx.composition.cursor_pos, 0, static_cast<int>(s.preedit.size()));
        try { s.cursor = static_cast<uint32_t>(wide(s.preedit.substr(0, cursor)).size()); } catch (...) { s.cursor = 0; }
        auto count = ctx.menu.candidates ? std::clamp(ctx.menu.num_candidates, 0, 9) : 0;
        for (int i = 0; i < count; ++i) s.candidates.push_back({safe(ctx.menu.candidates[i].text), safe(ctx.menu.candidates[i].comment)});
        s.highlighted = static_cast<uint32_t>(std::clamp(ctx.menu.highlighted_candidate_index, 0, std::max(0, count - 1)));
        s.page = static_cast<uint32_t>(std::max(0, ctx.menu.page_no)); s.lastPage = ctx.menu.is_last_page != 0;
        api_->free_context(&ctx);
    }
    return s;
}
State Engine::process(uint64_t client, const Request& request) {
    State s;
    if (!started_) { s.message = "引擎正在准备，请稍后切换到 Rime Q。"; return s; }
    if (request.command == Command::ping) { s.ready = true; s.message = std::string("RimeQ ") + RIMEQ_VERSION + " " + std::to_string(RIMEQ_BUILD); return s; }
    if (request.command == Command::syncProbe) { s.ready=true;s.handled=idle();s.message=std::to_string(learningRevision_);return s; }
    if (request.command == Command::syncExport || request.command == Command::syncApply) return synchronize(request.command);
    if (request.command == Command::exportDictionary || request.command == Command::importDictionary) {
        s.ready = true;
        if (!idle()) { s.message = "请先结束当前输入，再操作个人词库。"; return s; }
        auto module = api_->find_module("levers");
        auto manager = module && module->get_api ? reinterpret_cast<RimeLeversApi*>(module->get_api()) : nullptr;
        if (!manager || !RIME_API_AVAILABLE(manager, import_user_dict)) throw std::runtime_error("Dictionary API unavailable");
        for (auto& item : sessions_) { if(item.second){preservedAscii_[item.first]=api_->get_option(item.second,"ascii_mode")!=0;api_->destroy_session(item.second);} item.second = 0; }
        for (auto id : available_) api_->destroy_session(id); available_.clear();
        auto directory = root_ / L"dictionary"; fs::create_directories(directory);
        auto file = directory / (request.command == Command::exportDictionary ? L"export.tsv" : L"import.tsv");
        if (request.command == Command::importDictionary && (!fs::is_regular_file(file) || fs::file_size(file) > 32 * 1024 * 1024)) {
            s.message = "导入文件不存在或超过 32 MB。"; return s;
        }
        auto path = utf8(file.wstring());
        int count = request.command == Command::exportDictionary ? manager->export_user_dict("rime_q", path.c_str())
                                                                : manager->import_user_dict("rime_q", path.c_str());
        // A new dictionary has no database until the first learned commit.
        if (count < 0 && request.command == Command::exportDictionary) {
            RimeUserDictIterator it{}; bool found = false;
            if (manager->user_dict_iterator_init(&it)) {
                while (auto name = manager->next_user_dict(&it)) if (std::string(name) == "rime_q") found = true;
                manager->user_dict_iterator_destroy(&it);
            }
            if (!found) { std::ofstream(file) << "# Rime Q personal dictionary\n"; count = 0; }
        }
        s.handled = count >= 0; s.message = s.handled ? "已处理 " + std::to_string(count) + " 条记录。" : "词库操作失败，原学习记录保留。";
        if (request.command == Command::importDictionary) ++learningRevision_;
        return s;
    }
    auto id = session(client); bool handled = false;
    std::string spelling;
    switch (request.command) {
    case Command::key:
        if (request.key > 0x10ffff || (request.modifiers & ~uint32_t(1 | 2 | 4 | 8 | 0x40000000)))
            throw std::runtime_error("Unsupported key");
        handled = api_->process_key(id, static_cast<int>(request.key), static_cast<int>(request.modifiers)) != 0; break;
    case Command::select:
        if (request.key < 9) handled = api_->select_candidate_on_current_page(id, request.key) != 0; break;
    case Command::clear: api_->clear_composition(id); handled = true; break;
    case Command::commit:
        spelling = safe(api_->get_input(id));
        if (!spelling.empty()) {
            handled = api_->commit_composition(id) != 0;
            if (!handled) { api_->clear_composition(id); handled = true; }
        }
        break;
    case Command::toggle:
        // Follow the pinned schema's commit_code behavior, preserving typed spelling.
        api_->process_key(id, 0xffe1, 0); api_->process_key(id, 0xffe1, 0x40000000); handled = true; break;
    default: break;
    }
    if(handled && request.command!=Command::hello) ++learningRevision_;
    auto result=read(id, handled);
    if (request.command == Command::commit && handled && result.commit.empty()) {
        result.commit = spelling;result.preedit.clear();result.candidates.clear();
    }
    preservedAscii_[client]=result.ascii;return result;
}
void Engine::disconnect(uint64_t client) {
    if (!started_) return;
    auto it = sessions_.find(client); if (it == sessions_.end()) return;
    if (it->second) {
        api_->clear_composition(it->second);
        RIME_STRUCT(RimeCommit, pending); if (api_->get_commit(it->second, &pending)) api_->free_commit(&pending);
        if (available_.size() < 8) available_.push_back(it->second); else api_->destroy_session(it->second);
    }
    sessions_.erase(it);preservedAscii_.erase(client);
}
State Engine::synchronize(Command command) {
    State result;result.ready=true;
    if (!idle()) {result.message="sync-busy";return result;}
    auto module=api_->find_module("levers");
    auto manager=module && module->get_api?reinterpret_cast<RimeLeversApi*>(module->get_api()):nullptr;
    if (!manager || !RIME_API_AVAILABLE(manager,import_user_dict)) throw std::runtime_error("Dictionary API unavailable");
    for (auto& item:sessions_) {if(item.second){preservedAscii_[item.first]=api_->get_option(item.second,"ascii_mode")!=0;api_->destroy_session(item.second);}item.second=0;}
    for (auto id:available_) api_->destroy_session(id);available_.clear();
    auto directory=root_/L"sync/engine";fs::create_directories(directory);auto current=directory/L"current.tsv";
    auto exportCurrent=[&]{
        int count=manager->export_user_dict("rime_q",utf8(current.wstring()).c_str());
        if(count<0){RimeUserDictIterator it{};bool found=false;
            if(manager->user_dict_iterator_init(&it)){while(auto name=manager->next_user_dict(&it)) if(std::string(name)=="rime_q")found=true;manager->user_dict_iterator_destroy(&it);}
            if(found)throw std::runtime_error("Sync export failed");std::ofstream(current,std::ios::binary)<<"# Rime Q personal dictionary\n";
        }
    };
    exportCurrent();
    if(command==Command::syncApply){
        const auto actual=syncRows(current),expected=syncRows(directory/L"before.tsv"),desired=syncRows(directory/L"after.tsv");
        if(actual!=expected){warmSession();result.message="sync-stale";return result;}
        auto backups=root_/L"sync/backups";fs::create_directories(backups);
        auto backup=backups/(L"before-"+std::to_wstring(std::time(nullptr))+L"-"+std::to_wstring(GetTickCount64())+L".tsv");
        fs::copy_file(current,backup,fs::copy_options::none);
        auto delta=directory/L"apply.tsv";syncDelta(delta,actual,desired);
        int count=manager->import_user_dict("rime_q",utf8(delta.wstring()).c_str());++learningRevision_;exportCurrent();
        if(count<0 || syncRows(current)!=desired){warmSession();result.message="sync-readback-failed";return result;}
    }
    // Levers requires closing sessions, which discards the preloaded schema.
    // Rewarm before releasing the broker lock, not on the user's next key.
    warmSession();
    result.handled=true;result.message=std::to_string(learningRevision_);return result;
}
bool Engine::idle() {
    for (auto& item : sessions_) {
        if (item.second && *safe(api_->get_input(item.second))) return false;
    }
    return true;
}
bool Engine::configureSession(RimeSessionId id, bool grammar, bool adjacentKeys, bool hints, bool preserveOptions) {
    const char* names[] = {"ascii_mode", "ascii_punct", "traditionalization", "emoji", "full_shape", "search_single_char"};
    bool values[6]{};
    for (int i = 0; i < 6; ++i) values[i] = api_->get_option(id, names[i]) != 0;
    bool ok = rimeq::select_schema_with_preferences(api_, id, grammar ? "rime_q_grammar" : "rime_q", adjacentKeys, hints);
    if (preserveOptions) for (int i = 0; i < 6; ++i) api_->set_option(id, names[i], values[i]);
    return ok;
}
void Engine::setCorrectionPreferences(bool adjacentKeys, bool hints) {
    if ((adjacentKeys_ == adjacentKeys && correctionHints_ == hints) || !idle()) return;
    bool ok = true;
    for (auto& item : sessions_) if (item.second && !configureSession(item.second, grammar_, adjacentKeys, hints)) ok = false;
    for (auto id : available_) if (!configureSession(id, grammar_, adjacentKeys, hints)) ok = false;
    if (!ok) {
        for (auto& item : sessions_) if (item.second) configureSession(item.second, grammar_, adjacentKeys_, correctionHints_);
        for (auto id : available_) configureSession(id, grammar_, adjacentKeys_, correctionHints_);
        throw std::runtime_error("Cannot apply pinyin preferences");
    }
    adjacentKeys_ = adjacentKeys; correctionHints_ = hints;
}
void Engine::setGrammar(bool enabled) {
    if (grammar_ == enabled || !idle()) return;
    bool failed = false;
    for (auto& item : sessions_) {
        if (!item.second) continue;
        bool ascii = api_->get_option(item.second, "ascii_mode") != 0;
        if (!configureSession(item.second, enabled, adjacentKeys_, correctionHints_)) {
            failed = true;
            configureSession(item.second, false, adjacentKeys_, correctionHints_);
        }
        api_->set_option(item.second, "ascii_mode", ascii);
    }
    for (auto id : available_) if (!configureSession(id, enabled, adjacentKeys_, correctionHints_)) failed = true;
    if (failed) {
        for (auto& item : sessions_) if (item.second) configureSession(item.second, false, adjacentKeys_, correctionHints_);
        for (auto id : available_) configureSession(id, false, adjacentKeys_, correctionHints_);
    }
    grammar_ = enabled && !failed;
}
std::string Engine::version() const { return api_ ? safe(api_->get_version()) : "unavailable"; }
bool verifiedModel(const fs::path& file) {
    std::error_code error;
    if (!fs::is_regular_file(file, error) || fs::file_size(file, error) != 420343852) return false;
    BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) { BCryptCloseAlgorithmProvider(algorithm, 0); return false; }
    bool ok = true; std::ifstream stream(file, std::ios::binary); std::vector<char> buffer(1024 * 1024);
    while (stream) {
        stream.read(buffer.data(), buffer.size()); auto n = stream.gcount();
        if (n && BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()), static_cast<ULONG>(n), 0) < 0) { ok = false; break; }
    }
    if (!stream.eof()) ok = false;
    unsigned char digest[32]{}; if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) ok = false;
    BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0);
    std::ostringstream out; for (auto b : digest) out << std::hex << std::setw(2) << std::setfill('0') << unsigned(b);
    return ok && out.str() == "9f80530f470033cfb6d4b44bb861b540f64100426f92dd0f87140883632a3d93";
}
bool applyModelLink(const fs::path& root, bool remove) {
    auto model = root / L"models/wanxiang-lts-zh-hans.gram";
    auto link = root / L"rime/wanxiang-lts-zh-hans.gram";
    std::error_code error;
    if (fs::exists(link, error)) {
        if (!fs::equivalent(link, model, error) || error) return false; // Never replace an unknown user file.
        if (remove) fs::remove(link);
    } else if (!remove) {
        if (!CreateHardLinkW(link.c_str(), model.c_str(), nullptr)) return false; // No symlink privilege required.
    }
    if (remove && fs::exists(model)) fs::remove(model);
    return true;
}
} // namespace rq
