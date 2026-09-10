#include "rimeq/core.hpp"
#include <algorithm>
#include <chrono>
#include <iostream>
#include <vector>

int main() {
    rimeq::PersonalLexicon lexicon;
    std::vector<rimeq::LearningKey> keys;
    std::vector<rimeq::Candidate> candidates;
    for (int i = 0; i < 64; ++i) candidates.push_back({"合成候选" + std::to_string(i), "", static_cast<std::size_t>(i)});
    for (int i = 0; i < 10000; ++i) {
        keys.push_back(rimeq::LearningKey::normalized("benchmark:v1", "synthetic" + std::to_string(i)));
        for (int j = 0; j < 5; ++j) lexicon.learn(keys.back(), candidates[(i + j) % 64].text, 1700000000);
    }
    std::vector<double> elapsed;
    elapsed.reserve(20000);
    std::size_t checksum = 0;
    for (int i = -1000; i < 20000; ++i) {
        const auto& key = keys[static_cast<std::size_t>(i + 1000) % keys.size()];
        const auto start = std::chrono::steady_clock::now();
        auto result = lexicon.rank(key, candidates, 9, 1700000001);
        const auto end = std::chrono::steady_clock::now();
        checksum += result[0].candidate.engine_index;
        if (i >= 0) elapsed.push_back(std::chrono::duration<double, std::micro>(end - start).count());
    }
    std::sort(elapsed.begin(), elapsed.end());
    auto percentile = [&](double p) { return elapsed[static_cast<std::size_t>(p * (elapsed.size() - 1))]; };
    std::cout << "Synthetic in-memory ranking only; excludes librime, disk and UI.\n"
              << "entries=" << lexicon.size() << " candidates=64 samples=" << elapsed.size() << '\n'
              << "p50_us=" << percentile(0.50) << " p95_us=" << percentile(0.95)
              << " p99_us=" << percentile(0.99) << " checksum=" << checksum << '\n';
}
