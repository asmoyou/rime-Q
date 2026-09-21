#pragma once
#include "win.h"
#include <fstream>
#include <map>
#include <sstream>

namespace rq {
using SyncRows = std::map<std::pair<std::string,std::string>,int>;
inline SyncRows syncRows(const fs::path& file) {
    if (!fs::is_regular_file(file) || fs::file_size(file)>32*1024*1024) throw std::runtime_error("Invalid sync dictionary file");
    std::ifstream in(file,std::ios::binary); if (!in) throw std::runtime_error("Cannot read sync dictionary");
    SyncRows rows; std::string line;
    while (std::getline(in,line)) {
        if (!line.empty() && line.back()=='\r') line.pop_back();
        if (line.empty()) continue;
        if (line[0]=='#') {
            if (line.rfind("#@/db_name\t",0)==0 && line.substr(11)!="rime_q") throw std::runtime_error("Wrong dictionary namespace");
            continue;
        }
        auto a=line.find('\t'),b=a==std::string::npos?a:line.find('\t',a+1);
        if (a==std::string::npos || b==std::string::npos || line.find('\t',b+1)!=std::string::npos) throw std::runtime_error("Invalid sync dictionary columns");
        auto text=line.substr(0,a),code=line.substr(a+1,b-a-1),weight=line.substr(b+1);
        if (text.empty() || text.size()>1024 || code.empty() || code.size()>1024) throw std::runtime_error("Invalid sync dictionary row");
        (void)wide(text);
        for (unsigned char c:text) if (c<32 || c==127) throw std::runtime_error("Invalid dictionary control character");
        std::string normalized,syllable;std::istringstream syllables(code);
        while (syllables>>syllable) {
            if (!std::all_of(syllable.begin(),syllable.end(),[](char c){return c>='a' && c<='z' || c>='A' && c<='Z';})) throw std::runtime_error("Unsupported sync encoding");
            if (!normalized.empty()) normalized+=' ';normalized+=syllable;
        }
        size_t end=0;auto value=std::stoll(weight,&end);
        if (end!=weight.size() || value>INT_MAX-1 || value< -1 || normalized.empty()) throw std::runtime_error("Invalid sync weight");
        if (value>=0) {auto& prior=rows[{text,normalized}];prior=std::max(prior,static_cast<int>(value));}
        if (rows.size()>200000) throw std::runtime_error("Sync dictionary capacity exceeded");
    }
    if (!in.eof()) throw std::runtime_error("Sync dictionary read failed");return rows;
}
inline void syncDelta(const fs::path& file,const SyncRows& before,const SyncRows& after) {
    std::ofstream out(file,std::ios::binary|std::ios::trunc);if (!out) throw std::runtime_error("Cannot write sync application");
    out<<"# Rime Q sync application\n";
    for (const auto& row:after) {
        auto old=before.find(row.first);if (old!=before.end() && old->second==row.second) continue;
        if (old!=before.end() && old->second>row.second) out<<row.first.first<<'\t'<<row.first.second<<"\t-1\n";
        out<<row.first.first<<'\t'<<row.first.second<<'\t'<<row.second<<'\n';
    }
    for (const auto& row:before) if (!after.count(row.first)) out<<row.first.first<<'\t'<<row.first.second<<"\t-1\n";
    out.flush();if (!out) throw std::runtime_error("Sync application write failed");
}
}
