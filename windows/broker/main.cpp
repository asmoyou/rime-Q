#include "engine.h"
#include "version.h"
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <mutex>
#include <thread>

namespace {
std::mutex engineMutex;
std::atomic<bool> ready{false}, stopping{false};
std::atomic<unsigned> clients{0};
std::atomic<uint64_t> nextClient{1};
rq::Engine engine;
void lifecycle(const rq::fs::path& root, const char* state) {
    rq::fs::create_directories(root / L"logs");
    std::ofstream out(root / L"logs/lifecycle.log", std::ios::app);
    out << std::time(nullptr) << " build=" << RIMEQ_BUILD << " pid=" << GetCurrentProcessId() << " state=" << state << '\n';
}
void serveClient(HANDLE raw) {
    rq::Handle pipe(raw); uint64_t client = nextClient++; ++clients;
    try {
        for (;;) {
            std::vector<uint8_t> bytes;
            if (!rq::receiveFrame(raw, bytes, GetTickCount64() + 24ull * 3600 * 1000)) break;
            auto request = rq::request(bytes); rq::State state;
            if (!ready) state.message = "引擎正在准备。";
            else {
                std::lock_guard<std::mutex> lock(engineMutex);
                if (request.command == rq::Command::shutdown) {
                    state.ready = true; state.handled = engine.idle();
                    if (state.handled) stopping = true; else state.message = "请先结束当前输入。";
                } else state = engine.process(client, request);
            }
            if (!rq::sendFrame(raw, rq::encode(state), GetTickCount64() + 2000)) break;
            if (stopping) break;
        }
    } catch (...) { /* A bad or disconnected client cannot terminate the service. */ }
    if (ready) { std::lock_guard<std::mutex> lock(engineMutex); engine.disconnect(client); }
    DisconnectNamedPipe(raw); --clients;
}
int smoke(const rq::fs::path& app, const rq::fs::path& data, bool deploy) {
    rq::Engine test; test.start(app, data, deploy);
    auto require = [](bool ok, const char* why) { if (!ok) throw std::runtime_error(why); };
    auto type = [&](uint64_t id, const std::string& text) {
        rq::State s; for (unsigned char key : text) { s = test.process(id, {rq::Command::key, key, 0}); require(s.handled, "Key not handled"); } return s;
    };
    auto s = type(1, "nihao"); require(!s.candidates.empty(), "No Chinese candidates");
    require(s.candidates[0].text == "你好", "Unexpected nihao candidate");
    s = test.process(1, {rq::Command::key, 32, 0}); require(s.commit == "你好" && s.preedit.empty(), "Space commit failed");
    s = type(1, "zhongwen"); require(!s.candidates.empty(), "No candidates");
    auto second = s.candidates.size() > 1 ? s.candidates[1].text : s.candidates[0].text;
    unsigned index = s.candidates.size() > 1 ? 1 : 0;
    s = test.process(1, {rq::Command::key, '1' + index, 0}); require(s.commit == second, "Number selection mismatch");
    type(1, "ni"); type(2, "hao");
    test.process(1, {rq::Command::clear}); s = test.process(2, {rq::Command::hello}); require(!s.preedit.empty(), "Session isolation failed");
    test.process(2, {rq::Command::clear});
    struct CorrectionCase { const char* input; const char* text; const char* comment; };
    for (const auto& fixture : {
        CorrectionCase{"zhognguo", "中国", "（zhong guo）"},
        CorrectionCase{"nihso", "你好", "（ni hao）"},
        CorrectionCase{"geiyu", "给予", "（jǐ yǔ）"},
        CorrectionCase{"nihao", "你好", ""},
        CorrectionCase{"nh", "你好", ""},
        CorrectionCase{"zhon", "中", ""},
        CorrectionCase{"n'h", "你好", ""},
        CorrectionCase{"zhg", "中国", ""},
        CorrectionCase{"nue", "虐", ""}}) {
        s = type(1, fixture.input);
        bool found = false;
        for (int page = 0; page < 20; ++page) {
            for (size_t i = 0; i < s.candidates.size(); ++i) {
                if (s.candidates[i].text != fixture.text) continue;
                require(s.candidates[i].comment == fixture.comment, "Correction comment mismatch");
                s = test.process(1, {rq::Command::key, static_cast<uint32_t>('1' + i), 0});
                require(s.commit == fixture.text, "Correction digit commit mismatch");
                found = true;
                break;
            }
            if (found || s.lastPage) break;
            s = test.process(1, {rq::Command::key, 0xff56, 0});
        }
        require(found, "Correction candidate missing");
        test.process(1, {rq::Command::clear});
    }
    for (const std::string text : {"rq", "sj", "nl", "cC1+2*3", "R123.45", "U62fc"}) {
        s = type(1, text); require(!s.candidates.empty(), "Lua produced no candidates");
        auto candidate = s.candidates.front().text;
        if (text == "cC1+2*3") require(candidate.find('7') != std::string::npos, "Calculator Lua not loaded");
        if (text == "U62fc") require(candidate == "拼", "Unicode Lua not loaded");
        if (text == "nl") require(candidate.find("年") != std::string::npos, "Lunar Lua not loaded");
        s = test.process(1, {rq::Command::select, 0}); require(s.commit == candidate, "Lua selection failed");
        test.process(1, {rq::Command::clear});
    }
    type(1, "nihao");
    s = test.process(1, {rq::Command::toggle}); require(s.ascii && s.commit == "nihao", "English toggle must preserve typed spelling");
    s = test.process(1, {rq::Command::key, 'a', 0}); require(!s.handled, "English key swallowed");
    test.process(1, {rq::Command::toggle});
    test.disconnect(1); test.disconnect(2);
    auto exported = test.process(99, {rq::Command::exportDictionary}); require(exported.handled, "Personal dictionary export failed");
    std::cout << "PASS librime " << test.version() << ": pinyin, space/number/mouse selection, isolated sessions, cancel, Shift policy, Lua commits\n";
    return 0;
}
int learning(const rq::fs::path& app, const rq::fs::path& data, bool write) {
    rq::Engine test; test.start(app, data, false);
    if (write) {
        rq::fs::create_directories(data / L"dictionary");
        std::ofstream(data / L"dictionary/import.tsv", std::ios::binary) << "# Rime Q regression fixture\n熹微岚序\txi wei lan xu \t1000\n";
        if (!test.process(1, {rq::Command::importDictionary}).handled) throw std::runtime_error("Learning import failed");
    }
    rq::State state;
    for (char c : std::string("xiweilanxu")) state = test.process(1, {rq::Command::key, static_cast<uint32_t>(c)});
    if (state.candidates.empty() || state.candidates[0].text != "熹微岚序") throw std::runtime_error("Personal phrase was not recalled");
    state = test.process(1, {rq::Command::key, 32});
    if (state.commit != "熹微岚序") throw std::runtime_error("Personal phrase commit failed");
    test.disconnect(1);
    if (!test.process(2, {rq::Command::exportDictionary}).handled) throw std::runtime_error("Learning export failed");
    std::cout << (write ? "PASS learning import and commit\n" : "PASS learning recall after process restart\n"); return 0;
}
int dictionarySmoke(const rq::fs::path& app, const rq::fs::path& data, const std::string& code,
                    const std::string& expected, bool present) {
    rq::Engine test; test.start(app, data, false); rq::State state;
    for (unsigned char key : code) state = test.process(1, {rq::Command::key, key, 0});
    bool found = std::any_of(state.candidates.begin(), state.candidates.end(), [&](const rq::Candidate& item) { return item.text == expected; });
    if (found != present) throw std::runtime_error("Managed dictionary activation mismatch");
    std::cout << "PASS managed dictionary " << (present ? "active" : "absent") << "\n"; return 0;
}
int modelSmoke(const rq::fs::path& app, const rq::fs::path& data, const rq::fs::path& original) {
    if (!rq::verifiedModel(original)) throw std::runtime_error("Model fixture did not match dependency lock");
    rq::fs::create_directories(data / L"models");
    auto model = data / L"models/wanxiang-lts-zh-hans.gram";
    if (rq::fs::exists(model)) throw std::runtime_error("Model smoke needs an empty isolated directory");
    if (!CreateHardLinkW(model.c_str(), original.c_str(), nullptr)) rq::fs::copy_file(original, model);
    rq::Engine test; test.start(app, data, false);
    if (!rq::applyModelLink(data,false)) throw std::runtime_error("Model link creation failed");
    test.setGrammar(true); if (!test.grammar()) throw std::runtime_error("Grammar schema did not load");
    rq::State state;
    for (char key : std::string("jintiantianqihenhao")) state = test.process(1,{rq::Command::key,static_cast<uint32_t>(key)});
    if (state.candidates.empty()) throw std::runtime_error("No grammar candidates");
    state = test.process(1,{rq::Command::key,32}); if (state.commit.empty()) throw std::runtime_error("Grammar commit failed");
    test.setGrammar(false);
    if (!rq::applyModelLink(data,true) || rq::fs::exists(model)) throw std::runtime_error("Model removal after base switch failed");
    test.disconnect(1);
    if (!test.process(2,{rq::Command::exportDictionary}).handled) throw std::runtime_error("Model removal lost personal learning");
    std::cout << "PASS real pinned model integrity, hard-link storage, grammar commit, base switch, removal and learning retention\n"; return 0;
}
}
int wmain(int argc, wchar_t** argv) {
    try {
        auto app = rq::modulePath().parent_path();
        if (argc > 1 && std::wstring(argv[1]) == L"--version") { std::cout << "Rime Q " RIMEQ_VERSION " (" << RIMEQ_BUILD << ")\n"; return 0; }
        if (argc == 4 && (std::wstring(argv[1]) == L"--deploy" || std::wstring(argv[1]) == L"--smoke"))
            return smoke(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), std::wstring(argv[1]) == L"--deploy");
        if (argc == 4 && (std::wstring(argv[1]) == L"--learn-write" || std::wstring(argv[1]) == L"--learn-read"))
            return learning(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), std::wstring(argv[1]) == L"--learn-write");
        if (argc == 7 && std::wstring(argv[1]) == L"--dictionary-smoke")
            return dictionarySmoke(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), rq::utf8(argv[4]), rq::utf8(argv[5]), std::wstring(argv[6]) == L"present");
        if (argc == 5 && std::wstring(argv[1]) == L"--model-smoke")
            return modelSmoke(rq::fs::absolute(argv[2]), rq::fs::absolute(argv[3]), rq::fs::absolute(argv[4]));
        if (argc > 1 && (std::wstring(argv[1]) == L"--ping" || std::wstring(argv[1]) == L"--shutdown")) {
            rq::Client client; rq::State state;
            bool stop = std::wstring(argv[1]) == L"--shutdown";
            if (!client.exchange({stop ? rq::Command::shutdown : rq::Command::ping}, state, 2000)) return 2;
            bool matches = stop || state.message == std::string("RimeQ ") + RIMEQ_VERSION + " " + std::to_string(RIMEQ_BUILD);
            std::cout << (state.ready && matches ? "ready" : "pending") << '\n'; return state.ready && matches && (!stop || state.handled) ? 0 : 3;
        }
        if (argc != 2 || std::wstring(argv[1]) != L"--serve") return 2;
        auto root = rq::dataRoot(); rq::fs::create_directories(root);
        // A file lock spans terminal sessions too: a single writer owns the user's database.
        rq::Handle owner(CreateFileW((root / L"engine.lock").c_str(), GENERIC_READ | GENERIC_WRITE,
            0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!owner) return 0;
        std::wstring acl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + rq::sid() + L")";
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(acl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return 2;
        SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
        lifecycle(root, "starting");
        std::thread initializer([app, root] {
            try {
                engine.start(app, root, false);
                auto generation = rq::wide(engine.generation());
                WritePrivateProfileStringW(L"RimeQ", L"ActiveGeneration", generation.c_str(), (root / L"settings.ini").c_str());
                ready = true; lifecycle(root, "ready");
            }
            catch (...) { lifecycle(root, "engine-failed"); stopping = true; }
        });
        std::thread modelWorker([root] {
            bool verified = false; rq::fs::file_time_type stamp{};
            std::wstring lastStatus;
            auto status = [&](const wchar_t* value) {
                if (lastStatus == value) return;
                if (WritePrivateProfileStringW(L"RimeQ",L"ModelStatus",value,(root/L"settings.ini").c_str())) lastStatus = value;
            };
            while (!stopping) {
                try {
                    auto model = root / L"models/wanxiang-lts-zh-hans.gram"; std::error_code error;
                    auto current = rq::fs::last_write_time(model, error);
                    if (!error && current != stamp) { status(L"checking"); verified = rq::verifiedModel(model); stamp = current; }
                    if (error) { verified = false; stamp = {}; }
                    if (ready) {
                        std::lock_guard<std::mutex> lock(engineMutex);
                        if (engine.idle()) {
                            bool remove = rq::preference(L"RemoveModel", 0, root) != 0;
                            bool enabled = rq::preference(L"Grammar", 0, root) && verified && !remove;
                            bool linked = true;
                            if (enabled) { linked = rq::applyModelLink(root, false); enabled = linked; }
                            engine.setGrammar(enabled);
                            if (remove && rq::applyModelLink(root, true)) {
                                WritePrivateProfileStringW(L"RimeQ", L"RemoveModel", L"0", (root / L"settings.ini").c_str());
                                WritePrivateProfileStringW(L"RimeQ", L"Grammar", L"0", (root / L"settings.ini").c_str());
                                status(L"missing");
                            }
                            else if (remove) status(L"link-error");
                            else if (!linked) status(L"link-error");
                            else if (enabled && !engine.grammar()) status(L"engine-error");
                            else if (engine.grammar()) status(L"enabled");
                            else status(verified ? L"downloaded" : error ? L"missing" : L"invalid");
                        }
                        else if (rq::preference(L"RemoveModel",0,root) || (rq::preference(L"Grammar",0,root) != int(engine.grammar()))) status(L"pending");
                    }
                } catch (...) { status(L"storage-error"); /* Basic input stays available if optional storage is unavailable. */ }
                for (int i = 0; i < 10 && !stopping; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        });
        rq::launch(app / L"RimeQ.exe", L"--background");
        bool first = true;
        while (!stopping) {
            rq::Handle pipe(CreateNamedPipeW(rq::pipeName().c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
                (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0), PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                64, rq::maxFrame, rq::maxFrame, 0, &security));
            if (!pipe) { stopping = true; break; } first = false;
            rq::Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr)); OVERLAPPED ov{}; ov.hEvent = event.value;
            bool connected = ConnectNamedPipe(pipe.value, &ov) != FALSE;
            auto error = connected ? ERROR_SUCCESS : GetLastError();
            if (error == ERROR_PIPE_CONNECTED) connected = true;
            else if (error == ERROR_IO_PENDING) {
                while (!stopping && WaitForSingleObject(event.value, 200) == WAIT_TIMEOUT) {}
                DWORD count = 0;
                if (stopping) { CancelIoEx(pipe.value, &ov); GetOverlappedResult(pipe.value, &ov, &count, TRUE); break; }
                connected = GetOverlappedResult(pipe.value, &ov, &count, FALSE) != FALSE;
            }
            if (connected) { HANDLE raw = pipe.value; pipe.value = INVALID_HANDLE_VALUE; std::thread(serveClient, raw).detach(); }
        }
        initializer.join(); modelWorker.join(); LocalFree(descriptor);
        lifecycle(root, "stopping");
        // Terminate only our own broker after flushing librime; client handles close with this process.
        { std::lock_guard<std::mutex> lock(engineMutex); ready = false; engine.stop(); }
        ExitProcess(0);
    } catch (const std::exception& error) { std::cerr << "Rime Q: " << error.what() << '\n'; return 1; }
}
