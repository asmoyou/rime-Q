#pragma once
#include "win.h"
#include "../../third_party/librime/rime_api.h"
#include <map>

namespace rq {
class Engine {
    HMODULE library_ = nullptr;
    RimeApi* api_ = nullptr;
    bool started_ = false, grammar_ = false;
    fs::path root_;
    std::string shared_, user_, prebuilt_, staging_, logs_, generation_;
    std::map<uint64_t, RimeSessionId> sessions_;
    std::vector<RimeSessionId> available_;
    RimeSessionId session(uint64_t client);
    State read(RimeSessionId id, bool handled);
public:
    ~Engine();
    void stop();
    void start(const fs::path& application, const fs::path& data, bool deploy);
    State process(uint64_t client, const Request& request);
    void disconnect(uint64_t client);
    bool idle();
    void setGrammar(bool enabled);
    bool grammar() const { return grammar_; }
    const std::string& generation() const { return generation_; }
    std::string version() const;
};
bool verifiedModel(const fs::path& file);
bool applyModelLink(const fs::path& root, bool remove);
fs::path activeResources(const fs::path& application, const fs::path& data);
}
