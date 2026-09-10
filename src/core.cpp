#include "rimeq/core.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <tuple>
#include <utility>

namespace rimeq {
namespace {

bool valid_text(const std::string& text) {
    if (text.empty() || text.size() > PersonalLexicon::max_text_bytes) return false;
    // Validate Unicode scalars, rejecting controls, overlong sequences and surrogates.
    for (std::size_t i = 0; i < text.size();) {
        auto c = static_cast<unsigned char>(text[i++]);
        if (c < 0x80) {
            if (c < 0x20 || c == 0x7f) return false;
            continue;
        }
        unsigned continuation = 0;
        std::uint32_t scalar = 0;
        std::uint32_t minimum = 0;
        if (c >= 0xc2 && c <= 0xdf) {
            continuation = 1; scalar = c & 0x1f; minimum = 0x80;
        } else if (c >= 0xe0 && c <= 0xef) {
            continuation = 2; scalar = c & 0x0f; minimum = 0x800;
        } else if (c >= 0xf0 && c <= 0xf4) {
            continuation = 3; scalar = c & 0x07; minimum = 0x10000;
        } else {
            return false;
        }
        if (i + continuation > text.size()) return false;
        for (unsigned j = 0; j < continuation; ++j) {
            auto next = static_cast<unsigned char>(text[i++]);
            if ((next & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (next & 0x3f);
        }
        if (scalar < minimum || scalar > 0x10ffff ||
            (scalar >= 0xd800 && scalar <= 0xdfff) ||
            (scalar >= 0x80 && scalar <= 0x9f)) return false;
    }
    return true;
}

void validate_key(const LearningKey& key) {
    if (!(LearningKey::normalized(key.scope, key.code) == key)) {
        throw std::invalid_argument("learning key must be normalized by the adapter");
    }
}

void validate_text(const std::string& text) {
    if (!valid_text(text)) throw std::invalid_argument("invalid candidate text");
}

double preference_score(const LearnedEntry& entry, std::int64_t now) {
    const double age = static_cast<double>(now > entry.last_used ? now - entry.last_used : 0);
    const double recency = 1.0 / (1.0 + age / (7.0 * 86400.0));
    return 4.0 + std::log1p(static_cast<double>(entry.selections)) + recency;
}

} // namespace

LearningKey LearningKey::normalized(std::string scope, std::string code) {
    if (scope.empty() || scope.size() > 128 || code.empty() || code.size() > 256) {
        throw std::invalid_argument("invalid learning key length");
    }
    for (unsigned char c : scope) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == ':' || c == '.')) {
            throw std::invalid_argument("invalid learning namespace");
        }
    }
    std::string normalized;
    normalized.reserve(code.size());
    bool separator = false;
    for (unsigned char c : code) {
        if (c == ' ' || c == '\t' || c == '\'') {
            separator = !normalized.empty();
            continue;
        }
        if (c < 0x21 || c > 0x7e) throw std::invalid_argument("invalid learning code");
        if (separator) normalized.push_back('\'');
        separator = false;
        normalized.push_back(static_cast<char>(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c));
    }
    if (normalized.empty()) throw std::invalid_argument("empty learning code");
    return {std::move(scope), std::move(normalized)};
}

bool LearningKey::operator==(const LearningKey& other) const noexcept {
    return scope == other.scope && code == other.code;
}

std::size_t KeyHash::operator()(const LearningKey& key) const noexcept {
    const auto first = std::hash<std::string>{}(key.scope);
    const auto second = std::hash<std::string>{}(key.code);
    return first ^ (second + 0x9e3779b9U + (first << 6U) + (first >> 2U));
}

void validate_entry(const LearnedEntry& entry) {
    validate_key(entry.key);
    validate_text(entry.text);
    if (entry.last_used < 0 || entry.selections > PersonalLexicon::max_selections ||
        (entry.selections == 0 && !entry.pinned)) {
        throw std::invalid_argument("invalid learning statistics");
    }
}

PersonalLexicon::PersonalLexicon(std::size_t capacity, std::size_t per_code_capacity)
    : capacity_(capacity), per_code_capacity_(per_code_capacity) {
    if (capacity == 0 || per_code_capacity == 0 || per_code_capacity > max_candidates) {
        throw std::invalid_argument("invalid lexicon capacity");
    }
}

std::optional<Change> PersonalLexicon::learn(const LearningKey& key,
                                            const std::string& text, std::int64_t now) {
    validate_key(key);
    validate_text(text);
    if (now < 0) throw std::invalid_argument("negative timestamp");
    auto found = rows_.find(key);
    if (found != rows_.end()) {
        auto& entries = found->second;
        for (auto& entry : entries) {
            if (entry.text == text) {
                entry.selections = std::min(max_selections, entry.selections + 1);
                entry.last_used = std::max(entry.last_used, now);
                return Change{entry, false};
            }
        }
        if (entries.size() >= per_code_capacity_) return std::nullopt;
    }
    if (size_ >= capacity_) return std::nullopt;
    LearnedEntry entry{key, text, 1, now, false};
    rows_[key].push_back(entry);
    ++size_;
    return Change{std::move(entry), false};
}

std::optional<Change> PersonalLexicon::pin(const LearningKey& key,
                                          const std::string& text, bool pinned) {
    validate_key(key);
    validate_text(text);
    auto found = rows_.find(key);
    if (found != rows_.end()) {
        for (auto& entry : found->second) {
            if (entry.text != text) continue;
            if (!pinned && entry.selections == 0) return erase(key, text);
            entry.pinned = pinned;
            return Change{entry, false};
        }
        if (found->second.size() >= per_code_capacity_) return std::nullopt;
    }
    if (!pinned || size_ >= capacity_) return std::nullopt;
    LearnedEntry entry{key, text, 0, 0, true};
    rows_[key].push_back(entry);
    ++size_;
    return Change{std::move(entry), false};
}

std::optional<Change> PersonalLexicon::erase(const LearningKey& key,
                                            const std::string& text) {
    validate_key(key);
    validate_text(text);
    auto found = rows_.find(key);
    if (found == rows_.end()) return std::nullopt;
    auto& entries = found->second;
    auto entry = std::find_if(entries.begin(), entries.end(), [&](const auto& item) {
        return item.text == text;
    });
    if (entry == entries.end()) return std::nullopt;
    Change change{*entry, true};
    entries.erase(entry);
    --size_;
    if (entries.empty()) rows_.erase(found);
    return change;
}

void PersonalLexicon::restore(const std::vector<LearnedEntry>& entries) {
    // Validate the entire snapshot before replacing the working in-memory index.
    if (entries.size() > capacity_) throw std::length_error("lexicon capacity exceeded");
    PersonalLexicon replacement(capacity_, per_code_capacity_);
    for (const auto& entry : entries) {
        validate_entry(entry);
        auto& bucket = replacement.rows_[entry.key];
        if (bucket.size() >= per_code_capacity_) throw std::length_error("code capacity exceeded");
        if (std::any_of(bucket.begin(), bucket.end(), [&](const auto& item) {
                return item.text == entry.text;
            })) throw std::invalid_argument("duplicate learning identity");
        bucket.push_back(entry);
        ++replacement.size_;
    }
    rows_.swap(replacement.rows_);
    size_ = replacement.size_;
}

std::vector<LearnedEntry> PersonalLexicon::entries() const {
    std::vector<LearnedEntry> result;
    result.reserve(size_);
    for (const auto& bucket : rows_) {
        result.insert(result.end(), bucket.second.begin(), bucket.second.end());
    }
    std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) {
        return std::tie(a.key.scope, a.key.code, a.text) < std::tie(b.key.scope, b.key.code, b.text);
    });
    return result;
}

std::vector<RankedCandidate> PersonalLexicon::rank(const LearningKey& key,
                                                  const std::vector<Candidate>& candidates,
                                                  std::size_t limit, std::int64_t now) const {
    validate_key(key);
    if (now < 0) throw std::invalid_argument("negative timestamp");
    if (candidates.size() > max_candidates || limit > max_candidates) {
        throw std::length_error("candidate budget exceeded");
    }
    if (limit == 0) return {};
    auto found = rows_.find(key);
    const auto* learned = found == rows_.end() ? nullptr : &found->second;
    struct Scored {
        RankedCandidate result;
        double score;
    };
    std::vector<Scored> scored;
    scored.reserve(candidates.size() + (learned ? learned->size() : 0));
    for (std::size_t i = 0; i < candidates.size(); ++i) {
        const auto& candidate = candidates[i];
        validate_text(candidate.text);
        if (std::any_of(scored.begin(), scored.end(), [&](const auto& previous) {
                return previous.result.candidate.text == candidate.text &&
                       previous.result.candidate.match == candidate.match;
            })) continue;
        RankedCandidate result{candidate, CommitAction::select_engine_candidate, false, false};
        double score = -static_cast<double>(i);
        if (learned && candidate.match == Match::complete) {
            for (const auto& entry : *learned) {
                if (entry.text != candidate.text) continue;
                result.personalized = true;
                result.pinned = entry.pinned;
                score = preference_score(entry, now);
                break;
            }
        }
        scored.push_back({std::move(result), score});
    }
    if (learned) {
        for (const auto& entry : *learned) {
            const bool exists = std::any_of(scored.begin(), scored.end(), [&](const auto& item) {
                return item.result.candidate.text == entry.text &&
                       item.result.candidate.match == Match::complete;
            });
            if (exists) continue;
            RankedCandidate result{{entry.text, "", 0, Match::complete},
                                   CommitAction::commit_learned_text, true, entry.pinned};
            scored.push_back({std::move(result), preference_score(entry, now)});
        }
    }
    // Stable ordering avoids candidate jumps for equal scores and untouched entries.
    std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
        if (a.result.pinned != b.result.pinned) return a.result.pinned;
        return a.score > b.score;
    });
    std::vector<RankedCandidate> result;
    result.reserve(std::min(limit, scored.size()));
    for (std::size_t i = 0; i < std::min(limit, scored.size()); ++i) {
        result.push_back(std::move(scored[i].result));
    }
    return result;
}

} // namespace rimeq
