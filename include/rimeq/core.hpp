#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace rimeq {

struct LearningKey {
    std::string scope;
    std::string code;

    static LearningKey normalized(std::string scope, std::string code);
    bool operator==(const LearningKey& other) const noexcept;
};

struct KeyHash {
    std::size_t operator()(const LearningKey& key) const noexcept;
};

struct LearnedEntry {
    LearningKey key;
    std::string text;
    std::uint32_t selections = 0;
    std::int64_t last_used = 0; // UTC seconds supplied by caller; no clock in rank().
    bool pinned = false;
};

// Exactly one row to upsert, or one key/text identity to delete.
struct Change {
    LearnedEntry entry;
    bool removed = false;
};

enum class Match { complete, prefix };
enum class CommitAction { select_engine_candidate, commit_learned_text };

struct Candidate {
    std::string text;
    std::string comment;
    std::size_t engine_index = 0;
    Match match = Match::complete;
};

struct RankedCandidate {
    Candidate candidate;
    CommitAction action = CommitAction::select_engine_candidate;
    bool personalized = false;
    bool pinned = false;
};

// Thread-confined. The host serializes mutation/query and schedules disk I/O separately.
class PersonalLexicon {
public:
    static constexpr std::size_t max_candidates = 128;
    static constexpr std::size_t max_text_bytes = 1024;
    static constexpr std::uint32_t max_selections = 1000000;

    explicit PersonalLexicon(std::size_t capacity = 100000,
                             std::size_t per_code_capacity = 64);

    // Called only after a confirmed commit. nullopt reports a full capacity.
    std::optional<Change> learn(const LearningKey& key, const std::string& text,
                                std::int64_t now);
    std::optional<Change> pin(const LearningKey& key, const std::string& text,
                              bool pinned);
    std::optional<Change> erase(const LearningKey& key, const std::string& text);
    void restore(const std::vector<LearnedEntry>& entries);
    std::vector<LearnedEntry> entries() const;

    std::vector<RankedCandidate> rank(const LearningKey& key,
                                      const std::vector<Candidate>& candidates,
                                      std::size_t limit, std::int64_t now) const;
    std::size_t size() const noexcept { return size_; }

private:
    std::size_t capacity_;
    std::size_t per_code_capacity_;
    std::size_t size_ = 0;
    std::unordered_map<LearningKey, std::vector<LearnedEntry>, KeyHash> rows_;
};

void validate_entry(const LearnedEntry& entry);

} // namespace rimeq
