#include "rimeq/database.hpp"

#include <sqlite3.h>

#include <limits>
#include <memory>
#include <stdexcept>

namespace rimeq {
namespace {

using Statement = std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)>;

// Diagnostics deliberately omit SQL values and filenames containing user data.
void check(int result, const char* operation) {
    if (result != SQLITE_OK) {
        throw std::runtime_error(std::string(operation) + " (SQLite " + std::to_string(result) + ")");
    }
}

void execute(sqlite3* db, const char* sql) {
    check(sqlite3_exec(db, sql, nullptr, nullptr, nullptr), "database operation failed");
}

Statement prepare(sqlite3* db, const char* sql) {
    sqlite3_stmt* raw = nullptr;
    const int result = sqlite3_prepare_v2(db, sql, -1, &raw, nullptr);
    Statement statement(raw, sqlite3_finalize);
    check(result, "database statement failed");
    return statement;
}

void bind_text(sqlite3_stmt* statement, int position, const std::string& value) {
    check(sqlite3_bind_text(statement, position, value.data(), static_cast<int>(value.size()),
                           SQLITE_TRANSIENT), "binding failed");
}

std::string read_text(sqlite3_stmt* statement, int column) {
    if (sqlite3_column_type(statement, column) != SQLITE_TEXT) {
        throw std::runtime_error("invalid text in learning database");
    }
    const auto* text = sqlite3_column_text(statement, column);
    const int bytes = sqlite3_column_bytes(statement, column);
    if (!text || bytes <= 0 || bytes > static_cast<int>(PersonalLexicon::max_text_bytes)) {
        throw std::runtime_error("invalid field size in learning database");
    }
    return {reinterpret_cast<const char*>(text), static_cast<std::size_t>(bytes)};
}

std::int64_t read_integer(sqlite3_stmt* statement, int column) {
    if (sqlite3_column_type(statement, column) != SQLITE_INTEGER) {
        throw std::runtime_error("invalid integer in learning database");
    }
    return sqlite3_column_int64(statement, column);
}

std::int64_t scalar(sqlite3* db, const char* sql) {
    auto statement = prepare(db, sql);
    if (sqlite3_step(statement.get()) != SQLITE_ROW) throw std::runtime_error("database metadata unavailable");
    return read_integer(statement.get(), 0);
}

} // namespace

LearningDatabase::LearningDatabase(const std::string& path) {
    if (path.empty() || path.find('\0') != std::string::npos) {
        throw std::invalid_argument("invalid database path");
    }
    try {
        check(sqlite3_open_v2(path.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                              nullptr), "opening learning database failed");
        check(sqlite3_busy_timeout(db_, 1000), "database timeout configuration failed");
        const auto version = scalar(db_, "PRAGMA user_version");
        if (version != 0 && version != 1) throw std::runtime_error("unsupported learning database version");
        if (version == 0) {
            if (scalar(db_, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") != 0) {
                throw std::runtime_error("unrecognized database; refusing to replace existing data");
            }
            execute(db_, "BEGIN IMMEDIATE");
            execute(db_, "CREATE TABLE learning (scope TEXT NOT NULL, code TEXT NOT NULL, "
                         "text TEXT NOT NULL, selections INTEGER NOT NULL CHECK(selections BETWEEN 0 AND 1000000), "
                         "last_used INTEGER NOT NULL CHECK(last_used >= 0), "
                         "pinned INTEGER NOT NULL CHECK(pinned IN (0, 1)), "
                         "PRIMARY KEY(scope, code, text)) WITHOUT ROWID");
            execute(db_, "PRAGMA user_version = 1");
            execute(db_, "COMMIT");
        }
        // Durability is handled on the caller's storage worker, never the typing thread.
        execute(db_, "PRAGMA journal_mode = WAL");
        execute(db_, "PRAGMA synchronous = FULL");
    } catch (...) {
        if (db_) sqlite3_close(db_);
        db_ = nullptr;
        throw;
    }
}

LearningDatabase::~LearningDatabase() {
    if (db_) sqlite3_close(db_);
}

std::vector<LearnedEntry> LearningDatabase::load(std::size_t limit) const {
    auto statement = prepare(db_, "SELECT scope, code, text, selections, last_used, pinned "
                                  "FROM learning ORDER BY scope, code, text");
    std::vector<LearnedEntry> result;
    int status;
    while ((status = sqlite3_step(statement.get())) == SQLITE_ROW) {
        if (result.size() >= limit) throw std::length_error("learning database exceeds configured capacity");
        const auto selections = read_integer(statement.get(), 3);
        const auto pinned = read_integer(statement.get(), 5);
        if (selections < 0 || selections > PersonalLexicon::max_selections || (pinned != 0 && pinned != 1)) {
            throw std::runtime_error("invalid learning statistics in database");
        }
        LearnedEntry entry{{read_text(statement.get(), 0), read_text(statement.get(), 1)},
                           read_text(statement.get(), 2), static_cast<std::uint32_t>(selections),
                           read_integer(statement.get(), 4), pinned != 0};
        validate_entry(entry);
        result.push_back(std::move(entry));
    }
    if (status != SQLITE_DONE) check(status, "reading learning database failed");
    return result;
}

void LearningDatabase::save(const std::vector<Change>& changes) {
    if (changes.empty()) return;
    // Prevalidate, then apply the entire batch atomically. Do not acknowledge failed batches.
    for (const auto& change : changes) validate_entry(change.entry);
    auto upsert = prepare(db_, "INSERT INTO learning(scope, code, text, selections, last_used, pinned) "
                              "VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(scope, code, text) DO UPDATE SET "
                              "selections=excluded.selections, last_used=excluded.last_used, pinned=excluded.pinned");
    auto remove = prepare(db_, "DELETE FROM learning WHERE scope=? AND code=? AND text=?");
    execute(db_, "BEGIN IMMEDIATE");
    try {
        for (const auto& change : changes) {
            auto* statement = change.removed ? remove.get() : upsert.get();
            check(sqlite3_reset(statement), "resetting statement failed");
            check(sqlite3_clear_bindings(statement), "resetting bindings failed");
            bind_text(statement, 1, change.entry.key.scope);
            bind_text(statement, 2, change.entry.key.code);
            bind_text(statement, 3, change.entry.text);
            if (!change.removed) {
                check(sqlite3_bind_int64(statement, 4, change.entry.selections), "binding failed");
                check(sqlite3_bind_int64(statement, 5, change.entry.last_used), "binding failed");
                check(sqlite3_bind_int(statement, 6, change.entry.pinned ? 1 : 0), "binding failed");
            }
            const int status = sqlite3_step(statement);
            if (status != SQLITE_DONE) check(status, "saving learning data failed");
        }
        execute(db_, "COMMIT");
    } catch (...) {
        sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
        throw;
    }
}

} // namespace rimeq
