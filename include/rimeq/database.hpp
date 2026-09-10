#pragma once

#include "rimeq/core.hpp"

struct sqlite3;

namespace rimeq {

// Explicit disk operations. Never call from a per-key event callback.
// One owner; use a serial worker and flush before normal process shutdown.
class LearningDatabase {
public:
    explicit LearningDatabase(const std::string& path);
    ~LearningDatabase();
    LearningDatabase(const LearningDatabase&) = delete;
    LearningDatabase& operator=(const LearningDatabase&) = delete;

    std::vector<LearnedEntry> load(std::size_t limit = 100000) const;
    void save(const std::vector<Change>& changes);

private:
    sqlite3* db_ = nullptr;
};

} // namespace rimeq
