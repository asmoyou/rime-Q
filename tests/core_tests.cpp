#include "rimeq/core.hpp"
#include "rimeq/database.hpp"
#include <sqlite3.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <random>
#include <stdexcept>

using namespace rimeq;

void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

void rejects(const std::function<void()>& action) {
    bool rejected = false;
    try { action(); } catch (const std::exception&) { rejected = true; }
    require(rejected, "invalid operation was accepted");
}

struct TemporaryDirectory {
    std::filesystem::path path;
    TemporaryDirectory() {
        std::random_device random;
        for (int i = 0; i < 100; ++i) {
            path = std::filesystem::temp_directory_path() /
                   ("rimeq-test-" + std::to_string(random()) + "-" + std::to_string(random()));
            if (std::filesystem::create_directory(path)) return;
        }
        throw std::runtime_error("cannot create isolated fixture directory");
    }
    ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};

const auto shi = LearningKey::normalized("ice:full:v1", "shi");
const std::vector<Candidate> baseline{{"是", "", 18}, {"时", "", 25}, {"事", "", 31},
                                      {"市", "", 40}, {"十", "", 62}, {"诗", "", 91}};
constexpr std::int64_t now = 1700000000;

void stable_baseline_and_engine_identity() {
    PersonalLexicon lexicon;
    auto result = lexicon.rank(shi, baseline, 6, now);
    for (std::size_t i = 0; i < baseline.size(); ++i) {
        require(result[i].candidate.engine_index == baseline[i].engine_index, "baseline changed");
    }
    for (int i = 0; i < 3; ++i) lexicon.learn(shi, "诗", now + i);
    result = lexicon.rank(shi, baseline, 6, now + 3);
    require(result[0].candidate.text == "诗", "frequent character was not promoted");
    require(result[0].candidate.engine_index == 91, "display index replaced engine identity");
    require(result[0].action == CommitAction::select_engine_candidate, "wrong commit action");
    require(result[1].candidate.text == "是", "untouched order changed");
}

void new_phrase_recall_and_scope_isolation() {
    PersonalLexicon lexicon;
    auto key = LearningKey::normalized("ice:full:v1", "xing he ci ku shi yan");
    lexicon.learn(key, "星河词库试验", now);
    auto result = lexicon.rank(key, {}, 5, now);
    require(result.size() == 1 && result[0].candidate.text == "星河词库试验", "new phrase missing");
    require(result[0].action == CommitAction::commit_learned_text, "recall pretended to be an engine index");
    auto other = key;
    other.scope = "wanxiang:full:tone:v1";
    require(lexicon.rank(other, {}, 5, now).empty(), "learning leaked to another scheme");
    other = LearningKey::normalized(key.scope, "xing he");
    require(lexicon.rank(other, {}, 5, now).empty(), "learning leaked to a prefix");
}

void preserve_syllable_boundaries() {
    require(LearningKey::normalized("pinyin", " XI  AN '").code == "xi'an", "normalization failed");
    require(!(LearningKey::normalized("pinyin", "xi'an") == LearningKey::normalized("pinyin", "xian")),
            "different syllables collapsed");
    rejects([] { LearningKey::normalized("", "a"); });
    rejects([] { LearningKey::normalized("pinyin", "\n"); });
    rejects([] { LearningKey::normalized("pinyin", "   "); });
}

void complete_and_prefix_have_distinct_commit_actions() {
    PersonalLexicon lexicon;
    lexicon.learn(shi, "诗", now);
    auto result = lexicon.rank(shi, {{"诗", "prefix", 77, Match::prefix}}, 5, now);
    require(result.size() == 2, "prefix and complete candidates were wrongly deduplicated");
    require(result[0].action == CommitAction::commit_learned_text, "full recall lost");
    require(result[1].candidate.engine_index == 77 && result[1].candidate.match == Match::prefix,
            "partial selection identity lost");
}

void pin_erase_and_capacity() {
    PersonalLexicon lexicon(2, 1);
    require(lexicon.pin(shi, "诗", true).has_value(), "pin failed");
    require(!lexicon.learn(shi, "时", now), "per-code bound ignored");
    require(lexicon.learn(shi, "诗", now).has_value(), "existing word blocked by capacity");
    auto key = LearningKey::normalized("ice:full:v1", "ni");
    lexicon.learn(key, "你", now);
    require(!lexicon.learn(LearningKey::normalized("ice:full:v1", "hao"), "好", now), "global bound ignored");
    require(lexicon.rank(shi, baseline, 5, now)[0].pinned, "pin lost");
    require(lexicon.erase(shi, "诗")->removed, "erase did not report a deletion");
    require(lexicon.rank(shi, baseline, 5, now)[0].candidate.text == "是", "deletion kept preference");
    require(lexicon.pin(shi, "诗", true).has_value(), "erased capacity was not freed");
    require(lexicon.pin(shi, "诗", false)->removed, "pin-only row remained after unpin");
}

void failed_restore_does_not_replace_data() {
    PersonalLexicon lexicon;
    lexicon.learn(shi, "诗", now);
    auto snapshot = lexicon.entries();
    snapshot.push_back(snapshot.front());
    rejects([&] { lexicon.restore(snapshot); });
    require(lexicon.size() == 1 && lexicon.rank(shi, baseline, 5, now)[0].candidate.text == "诗",
            "failed restore discarded current data");
    rejects([&] { lexicon.learn(shi, std::string("a\0b", 3), now); });
    rejects([&] { lexicon.learn(shi, "\xed\xa0\x80", now); });
    rejects([&] { lexicon.learn(shi, "\xc0\x80", now); });
    rejects([&] { lexicon.learn(shi, "诗", -1); });
    rejects([&] { lexicon.rank(shi, std::vector<Candidate>(129, baseline.front()), 5, now); });
}

void disk_round_trip_and_removal() {
    TemporaryDirectory temporary;
    auto path = (temporary.path / "learning.db").string();
    PersonalLexicon first;
    {
        LearningDatabase db(path);
        db.save({*first.learn(shi, "诗", now), *first.pin(shi, "诗", true)});
    }
    {
        LearningDatabase db(path);
        PersonalLexicon reloaded;
        reloaded.restore(db.load());
        auto result = reloaded.rank(shi, baseline, 5, now);
        require(result[0].candidate.text == "诗" && result[0].pinned, "restart lost learning or pin");
        auto deletion = *reloaded.erase(shi, "诗");
        db.save({deletion});
    }
    LearningDatabase reopened(path);
    require(reopened.load().empty(), "deletion did not survive restart");
}

void transaction_failure_rolls_back_entire_batch() {
    TemporaryDirectory temporary;
    auto path = (temporary.path / "learning.db").string();
    LearningDatabase database(path);
    sqlite3* raw = nullptr;
    require(sqlite3_open(path.c_str(), &raw) == SQLITE_OK, "fixture database unavailable");
    const int code = sqlite3_exec(raw, "CREATE TRIGGER reject_second BEFORE INSERT ON learning "
                                      "WHEN NEW.text='时' BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                                  nullptr, nullptr, nullptr);
    sqlite3_close(raw);
    require(code == SQLITE_OK, "failure fixture unavailable");
    PersonalLexicon lexicon;
    rejects([&] { database.save({*lexicon.learn(shi, "诗", now), *lexicon.learn(shi, "时", now)}); });
    require(database.load().empty(), "failed transaction left a partial batch");
    database.save({*lexicon.learn(shi, "诗", now)});
    require(database.load().size() == 1, "database unusable after rollback");
}

void unknown_database_is_preserved() {
    TemporaryDirectory temporary;
    auto path = (temporary.path / "future.db").string();
    sqlite3* raw = nullptr;
    require(sqlite3_open(path.c_str(), &raw) == SQLITE_OK, "fixture database unavailable");
    require(sqlite3_exec(raw, "PRAGMA user_version=999; CREATE TABLE precious(value); INSERT INTO precious VALUES(42)",
                         nullptr, nullptr, nullptr) == SQLITE_OK, "fixture initialization failed");
    sqlite3_close(raw);
    rejects([&] { LearningDatabase db(path); });
    require(sqlite3_open(path.c_str(), &raw) == SQLITE_OK, "fixture reopen failed");
    sqlite3_stmt* statement = nullptr;
    sqlite3_prepare_v2(raw, "SELECT value FROM precious", -1, &statement, nullptr);
    const bool preserved = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 42;
    sqlite3_finalize(statement);
    sqlite3_close(raw);
    require(preserved, "unknown database was overwritten");
}

int main() {
    const std::vector<std::pair<const char*, std::function<void()>>> tests{
        {"stable baseline and engine identity", stable_baseline_and_engine_identity},
        {"new phrase and scope isolation", new_phrase_recall_and_scope_isolation},
        {"syllable boundaries", preserve_syllable_boundaries},
        {"prefix commit semantics", complete_and_prefix_have_distinct_commit_actions},
        {"pin erase and capacity", pin_erase_and_capacity},
        {"restore validation", failed_restore_does_not_replace_data},
        {"disk persistence", disk_round_trip_and_removal},
        {"transaction rollback", transaction_failure_rolls_back_entire_batch},
        {"unknown database preservation", unknown_database_is_preserved}
    };
    for (const auto& test : tests) {
        try { test.second(); std::cout << "PASS " << test.first << '\n'; }
        catch (const std::exception& error) {
            std::cerr << "FAIL " << test.first << ": " << error.what() << '\n'; return 1;
        }
    }
}
