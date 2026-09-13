#include "../broker/engine.h"
#include "sync_dictionary.h"
#include <fstream>
#include <iostream>

int wmain(int argc,wchar_t** argv) {
    try {
        if(argc!=3)throw std::runtime_error("Expected application and isolated fixture directory");
        auto app=rq::fs::absolute(argv[1]),base=rq::fs::absolute(argv[2]);
        if(rq::fs::exists(base))throw std::runtime_error("Fixture directory must be new");
        rq::fs::create_directories(base);
        auto require=[](bool ok,const char* reason){if(!ok)throw std::runtime_error(reason);};
        for(int node=0;node<6;++node){
            auto root=base/std::to_wstring(node);rq::Engine engine;engine.start(app,root,false);
            auto send=[&](rq::Command command,uint32_t key=0){return engine.process(1,{command,key,0});};
            auto type=[&](const std::string& input){rq::State value;for(unsigned char c:input)value=send(rq::Command::key,c);return value;};
            require(send(rq::Command::syncExport).handled,"Fresh dictionary export");
            auto directory=root/L"sync/engine";
            rq::fs::copy_file(directory/L"current.tsv",directory/L"before.tsv");
            std::ofstream(directory/L"after.tsv",std::ios::binary)<<"# Rime Q sync fixture\n熹微岚序\txi wei lan xu\t1000\n";
            type("nihao");
            require(!send(rq::Command::syncProbe).handled,"Composition must block sync probe");
            auto blocked=send(rq::Command::syncApply);
            require(!blocked.handled&&blocked.message=="sync-busy","Sync must not commit active composition");
            require(!send(rq::Command::hello).preedit.empty(),"Sync discarded active input");send(rq::Command::clear);
            auto applied=send(rq::Command::syncApply);require(applied.handled,"Sync apply");
            auto candidates=type("xiweilanxu");
            require(!candidates.candidates.empty()&&candidates.candidates[0].text=="熹微岚序","Synced phrase was not recalled");
            require(send(rq::Command::key,32).commit=="熹微岚序","Synced phrase was not committed");
            send(rq::Command::toggle);require(send(rq::Command::hello).ascii,"English toggle");
            require(send(rq::Command::syncExport).handled,"Export with English mode");
            require(send(rq::Command::hello).ascii,"Sync changed English mode");send(rq::Command::toggle);
            rq::fs::copy_file(directory/L"current.tsv",directory/L"before.tsv",rq::fs::copy_options::overwrite_existing);
            type("nihao");send(rq::Command::key,32);
            auto stale=send(rq::Command::syncApply);require(!stale.handled&&stale.message=="sync-stale","Stale snapshot overwrote local learning");
            auto actual=rq::syncRows(directory/L"current.tsv");require(actual.count({"你好","ni hao"})>0,"New local learning was lost");
            rq::fs::copy_file(directory/L"current.tsv",directory/L"before.tsv",rq::fs::copy_options::overwrite_existing);
            std::ofstream(directory/L"after.tsv",std::ios::binary)<<"# Rime Q sync fixture\n你好\tni hao\t1\n";
            require(send(rq::Command::syncApply).handled,"Remote delete and lower weight");
            actual=rq::syncRows(directory/L"current.tsv");require(!actual.count({"熹微岚序","xi wei lan xu"}),"Deleted personal phrase remains");
            require(actual.at({"你好","ni hao"})==1,"Weight lowering was not applied");
            require(!rq::fs::is_empty(root/L"sync/backups"),"Sync backup missing");
            engine.stop();
            rq::Engine reopened;reopened.start(app,root,false);require(reopened.process(1,{rq::Command::syncExport}).handled,"Export after engine restart");
            require(rq::syncRows(directory/L"current.tsv")==actual,"Dictionary changed after restart");
        }
        std::cout<<"PASS six isolated librime databases: idle-only application, first recall and commit, English preservation, stale snapshot rejection, deletion, lower weights, backup and restart persistence\n";
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
