#include "../broker/engine.h"
#include <iostream>
#include <chrono>

// Synthetic stdio fixture. It has no named pipe, registration or UI and cannot
// use a production root. Each process owns exactly one real librime database.
int wmain(int argc,wchar_t** argv) {
    if(argc!=3)return 2;
    try {
        auto app=rq::fs::absolute(argv[1]),root=rq::fs::absolute(argv[2]);
        if(!rq::fs::is_regular_file(root/L"sync/isolated-test-only"))throw std::runtime_error("Isolated helper marker required");
        rq::Engine engine;engine.start(app,root,false);
        std::cout<<"RIMEQ-SYNC-TEST ready\n"<<std::flush;
        std::string line;
        bool firstLine=true;
        while(std::getline(std::cin,line)) {
            if(firstLine && line.rfind("\xEF\xBB\xBF",0)==0)line.erase(0,3);
            firstLine=false;
            if(!line.empty()&&line.back()=='\r')line.pop_back();
            rq::State state;
            if(line=="quit")break;
            if(line=="export")state=engine.process(1,{rq::Command::syncExport});
            else if(line=="probe")state=engine.process(1,{rq::Command::syncProbe});
            else if(line=="first-key") {
                auto start=std::chrono::steady_clock::now();
                state=engine.process(1,{rq::Command::key,'n'});
                state.message=std::to_string(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
                engine.process(1,{rq::Command::clear});
            }
            else if(line=="apply")state=engine.process(1,{rq::Command::syncApply});
            else if(line=="begin") {
                for(auto key:std::string("nihao"))state=engine.process(1,{rq::Command::key,static_cast<uint32_t>(key)});
                if(state.preedit.empty())throw std::runtime_error("Synthetic composition did not start");
            } else if(line=="cancel")state=engine.process(1,{rq::Command::clear});
            else throw std::runtime_error("Unknown fixture command");
            std::cout<<"RIMEQ-SYNC-TEST "<<(state.handled?"ok":"blocked")<<"\t"<<state.message<<"\n"<<std::flush;
        }
        engine.stop();return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
