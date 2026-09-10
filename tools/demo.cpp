#include "rimeq/core.hpp"
#include "rimeq/database.hpp"
#include <iostream>

int main(int argc, char** argv) {
    if (argc != 2 || std::string(argv[1]) != "demo") {
        std::cerr << "Usage: rimeq demo\n"; return 2;
    }
    try {
        rimeq::PersonalLexicon lexicon;
        rimeq::LearningDatabase database(":memory:");
        const auto key = rimeq::LearningKey::normalized("demo:full:v1", "shi");
        const std::vector<rimeq::Candidate> candidates{{"是", "", 0}, {"时", "", 1},
                                                      {"事", "", 2}, {"诗", "", 3}};
        auto print = [&](const char* label) {
            std::cout << label;
            for (const auto& item : lexicon.rank(key, candidates, 5, 1700000000))
                std::cout << ' ' << item.candidate.text;
            std::cout << '\n';
        };
        print("学习前：");
        database.save({*lexicon.learn(key, "诗", 1700000000)});
        lexicon.restore(database.load());
        print("选择「诗」并保存后：");
        const auto phrase = rimeq::LearningKey::normalized("demo:full:v1", "xing he ci ku shi yan");
        lexicon.learn(phrase, "星河词库试验", 1700000000);
        std::cout << "自造词召回： " << lexicon.rank(phrase, {}, 5, 1700000000)[0].candidate.text << '\n';
        std::cout << "仅为算法演示；未接入系统输入法，也未读取个人数据。\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
