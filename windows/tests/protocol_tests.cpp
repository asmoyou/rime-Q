#include "win.h"
#include <iostream>
#include <functional>
void require(bool condition) { if (!condition) throw std::runtime_error("Assertion failed"); }
void rejects(const std::function<void()>& f) {
    bool rejected = false; try { f(); } catch (const std::exception&) { rejected = true; } require(rejected);
}
int main() {
    try {
        rq::State s; s.ready = true; s.handled = true; s.preedit = "ni hao"; s.commit = "你好😀";
        s.candidates = {{"你好", "问候"}, {"拟好", ""}}; s.highlighted = 1;
        auto bytes = rq::encode(s); auto result = rq::state(bytes);
        require(result.commit == s.commit && result.candidates[1].text == "拟好" && result.highlighted == 1);
        for (size_t n = 0; n < bytes.size(); ++n) {
            std::vector<uint8_t> truncated(bytes.begin(), bytes.begin() + n); rejects([&] { rq::state(truncated); });
        }
        auto extra = bytes; extra.push_back(0); rejects([&] { rq::state(extra); });
        auto badVersion = bytes; badVersion[0] = 255; rejects([&] { rq::state(badVersion); });
        s.candidates.resize(10); rejects([&] { rq::encode(s); });
        require(rq::wide("😀").size() == 2 && rq::utf8(rq::wide("简体😀")) == "简体😀");
        rejects([] { rq::wide(std::string("\xff")); });
        auto request = rq::request(rq::encode({rq::Command::key, 'a', 4})); require(request.key == 'a' && request.modifiers == 4);
        auto unknown = rq::encode({static_cast<rq::Command>(100), 0, 0}); rejects([&] { rq::request(unknown); });
        std::cout << "PASS: framing, truncation, bounds, Unicode, protocol version and commands\n"; return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
