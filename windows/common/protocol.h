#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace rq {
constexpr uint32_t protocolVersion = 1;
constexpr uint32_t maxFrame = 65536;
enum class Command : uint32_t { hello = 1, key, select, clear, toggle, shutdown,
    exportDictionary, importDictionary, ping, syncProbe, syncExport, syncApply };
struct Request { Command command = Command::hello; uint32_t key = 0, modifiers = 0; };
struct Candidate { std::string text, comment; };
struct State {
    bool ready = false, handled = false, ascii = false, lastPage = true;
    uint32_t cursor = 0, highlighted = 0, page = 0;
    std::string preedit, commit, message;
    std::vector<Candidate> candidates;
};
struct Writer {
    std::vector<uint8_t> data;
    void number(uint32_t n) { for (unsigned i = 0; i < 4; ++i) data.push_back(uint8_t(n >> (i * 8))); }
    void string(const std::string& s) {
        if (s.size() > 16384) throw std::runtime_error("Text exceeds protocol limit");
        number(static_cast<uint32_t>(s.size())); data.insert(data.end(), s.begin(), s.end());
    }
};
struct Reader {
    const std::vector<uint8_t>& data; size_t offset = 0;
    uint32_t number() {
        if (data.size() - offset < 4) throw std::runtime_error("Truncated frame");
        uint32_t n = 0; for (unsigned i = 0; i < 4; ++i) n |= uint32_t(data[offset++]) << (i * 8);
        return n;
    }
    std::string string() {
        auto n = number();
        if (n > 16384 || n > data.size() - offset) throw std::runtime_error("Invalid string length");
        std::string s(reinterpret_cast<const char*>(data.data() + offset), n); offset += n; return s;
    }
    void end() const { if (offset != data.size()) throw std::runtime_error("Trailing frame data"); }
};
inline std::vector<uint8_t> encode(const Request& r) {
    Writer w; w.number(protocolVersion); w.number(static_cast<uint32_t>(r.command));
    w.number(r.key); w.number(r.modifiers); return w.data;
}
inline Request request(const std::vector<uint8_t>& bytes) {
    Reader r{bytes}; if (r.number() != protocolVersion) throw std::runtime_error("Protocol mismatch");
    Request q; q.command = static_cast<Command>(r.number()); q.key = r.number(); q.modifiers = r.number(); r.end();
    if (q.command < Command::hello || q.command > Command::syncApply) throw std::runtime_error("Unknown command");
    return q;
}
inline std::vector<uint8_t> encode(const State& s) {
    Writer w; w.number(protocolVersion); w.number(s.ready); w.number(s.handled); w.number(s.ascii);
    w.number(s.lastPage); w.number(s.cursor); w.number(s.highlighted); w.number(s.page);
    w.string(s.preedit); w.string(s.commit); w.string(s.message);
    if (s.candidates.size() > 9) throw std::runtime_error("Too many candidates");
    w.number(static_cast<uint32_t>(s.candidates.size()));
    for (const auto& c : s.candidates) { w.string(c.text); w.string(c.comment); }
    if (w.data.size() > maxFrame) throw std::runtime_error("Frame too large");
    return w.data;
}
inline State state(const std::vector<uint8_t>& bytes) {
    Reader r{bytes}; if (r.number() != protocolVersion) throw std::runtime_error("Protocol mismatch");
    State s; s.ready = r.number() != 0; s.handled = r.number() != 0; s.ascii = r.number() != 0;
    s.lastPage = r.number() != 0; s.cursor = r.number(); s.highlighted = r.number(); s.page = r.number();
    s.preedit = r.string(); s.commit = r.string(); s.message = r.string();
    auto count = r.number(); if (count > 9) throw std::runtime_error("Invalid candidate count");
    for (uint32_t i = 0; i < count; ++i) s.candidates.push_back({r.string(), r.string()});
    if (count && s.highlighted >= count) throw std::runtime_error("Invalid selection");
    r.end(); return s;
}
} // namespace rq
