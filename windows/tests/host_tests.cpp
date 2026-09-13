// Installed-client acceptance in an independent, visible native RichEdit document.
// Every physical key is guarded by exact foreground-window and edit-control checks.
#include "win.h"
#include "identity.h"
#include <msctf.h>
#include <richedit.h>
#include <wrl/client.h>
#include <fstream>
#include <iostream>
using Microsoft::WRL::ComPtr;
namespace {
constexpr unsigned focusSecond = 0x10000, switchAway = 0x10001, switchBack = 0x10002;
struct Case { const char* name; std::vector<unsigned> keys; const wchar_t* first; const wchar_t* second; };
std::vector<unsigned> spelling(const char* value) { std::vector<unsigned> keys; for (auto p = value; *p; ++p) keys.push_back(static_cast<unsigned char>(*p)); return keys; }
class Host {
public:
    HWND window = nullptr, first = nullptr, second = nullptr, status = nullptr, edit = nullptr;
    ComPtr<ITfInputProcessorProfileMgr> profiles;
    TF_INPUTPROCESSORPROFILE previous{};
    std::vector<Case> cases;
    size_t current = 0, position = 0;
    bool failed = false, complete = false;
    std::string reason;
    unsigned idleTicks = 0;
    rq::fs::path report;
    std::wstring text(HWND field) {
        auto count = GetWindowTextLengthW(field); std::wstring value(count + 1,0); GetWindowTextW(field,value.data(),count + 1); value.resize(count); return value;
    }
    bool activate(bool ours) {
        HRESULT hr = ours ? profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, rq::language, rq::clsid, rq::profile, nullptr,
            TF_IPPMF_FORPROCESS | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE)
            : profiles->ActivateProfile(previous.dwProfileType,previous.langid,previous.clsid,previous.guidProfile,previous.hkl,
                TF_IPPMF_FORPROCESS | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE);
        return SUCCEEDED(hr);
    }
    void save(const char* result) {
        rq::fs::create_directories(report.parent_path());
        std::string tipBuild="unavailable";
        if(auto module=GetModuleHandleW(L"RimeQ.Tip.dll")) {
            auto path=rq::modulePath(module); DWORD ignored=0, size=GetFileVersionInfoSizeW(path.c_str(),&ignored);
            std::vector<BYTE> bytes(size);
            if(size && GetFileVersionInfoW(path.c_str(),0,size,bytes.data())) {
                VS_FIXEDFILEINFO* info=nullptr; UINT length=0;
                if(VerQueryValueW(bytes.data(),L"\\",reinterpret_cast<void**>(&info),&length) && info)
                    tipBuild=std::to_string(HIWORD(info->dwFileVersionMS))+"."+std::to_string(LOWORD(info->dwFileVersionMS))+"."+
                        std::to_string(HIWORD(info->dwFileVersionLS))+"."+std::to_string(LOWORD(info->dwFileVersionLS));
            }
        }
        std::ofstream out(report,std::ios::binary);
        out << "{\"host\":\"Windows RichEdit50W\",\"result\":\"" << result << "\",\"completed_cases\":" << current
            << ",\"architecture\":\"" << (sizeof(void*) == 8 ? "x64" : "x86") << "\",\"loaded_tip_version\":\"" << tipBuild
            << "\",\"reason\":\"" << reason << "\",\"first_length\":" << GetWindowTextLengthW(first) << ",\"second_length\":" << GetWindowTextLengthW(second) << "}\n";
    }
    void fail(const wchar_t* message) {
        failed = true; KillTimer(window,1); SetWindowTextW(status,message); save("failed-or-focus-interrupted");
        std::cerr << "Installed RichEdit test did not pass; case=" << current << "; reason=" << reason << '\n';
        std::cerr << rq::utf8(message) << '\n';
        SetTimer(window,2,1500,nullptr);
    }
    void beginCase() {
        SetWindowTextW(first,L""); SetWindowTextW(second,L""); edit = first; SetFocus(first); position = 0; idleTicks = 4;
        auto label = L"正在验证 " + std::to_wstring(current + 1) + L" / " + std::to_wstring(cases.size()) + L"。请保持此空白测试文档在前台。";
        SetWindowTextW(status,label.c_str());
    }
    void tick() {
        if (complete || failed) return;
        if (GetForegroundWindow() != window || GetFocus() != edit) { reason="focus-changed"; fail(L"已停止：前台窗口或输入焦点发生变化，未向其他窗口发键。"); return; }
        if (idleTicks) { --idleTicks; return; }
        auto& test = cases[current];
        if (position == test.keys.size()) {
            if (text(first) != test.first || text(second) != test.second) { reason="text-mismatch"; fail(L"本轮实际输入结果未通过。已停止发键，结果写入验证报告。"); return; }
            ++current;
            if (current == cases.size()) {
                complete = true; KillTimer(window,1); SetWindowTextW(status,L"全部实际 RichEdit 输入检查通过。此结果仅覆盖本宿主与当前机器。");
                save("passed"); std::cout << "PASS installed RichEdit " << (sizeof(void*) == 8 ? "x64" : "x86") << ": first key, pinyin, space/number, Esc, Shift, focus and profile switching\n";
                SetTimer(window,2,1500,nullptr); return;
            }
            beginCase(); return;
        }
        auto key = test.keys[position++];
        if (key == focusSecond) { edit = second; SetFocus(second); idleTicks = 3; return; }
        if (key == switchAway || key == switchBack) {
            if (!activate(key == switchBack)) { fail(L"输入源切换未完成。"); return; } idleTicks = 8; return;
        }
        TF_INPUTPROCESSORPROFILE active{};
        if (FAILED(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&active)) || active.clsid != rq::clsid || active.guidProfile != rq::profile) {
            fail(L"当前测试进程未激活 Rime Q，已停止发键。"); return;
        }
        // This is the only injection site. It cannot run unless the exact owned
        // document, focus and installed profile were just checked above.
        INPUT events[2]{}; events[0].type = events[1].type = INPUT_KEYBOARD;
        events[0].ki.wVk = events[1].ki.wVk = static_cast<WORD>(key); events[1].ki.dwFlags = KEYEVENTF_KEYUP;
        if (SendInput(2,events,sizeof(INPUT)) != 2) { fail(L"Windows 未接受测试按键，已停止。"); return; }
        idleTicks = 1;
    }
    static LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM wparam,LPARAM lparam) {
        auto self = reinterpret_cast<Host*>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if (message == WM_NCCREATE) { self = static_cast<Host*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams); SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self)); }
        if (self) {
            if (message == WM_TIMER) { if (wparam == 1) self->tick(); else DestroyWindow(window); return 0; }
            if (message == WM_CLOSE) { if (!self->complete) self->save("closed-before-completion"); DestroyWindow(window); return 0; }
            if (message == WM_DESTROY) { PostQuitMessage(self->complete ? 0 : 1); return 0; }
        }
        return DefWindowProcW(window,message,wparam,lparam);
    }
};
}
int wmain(int argc,wchar_t** argv) {
    if (argc != 2) return 2;
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    try {
        if ((GetKeyState(VK_CAPITAL)&1) || GetAsyncKeyState(VK_SHIFT)<0 || GetAsyncKeyState(VK_CONTROL)<0 || GetAsyncKeyState(VK_MENU)<0)
            throw std::runtime_error("Release modifiers and turn off Caps Lock before the isolated host test");
        if (!LoadLibraryExW(L"msftedit.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32)) throw std::runtime_error("RichEdit unavailable");
        Host host; host.report = rq::fs::absolute(argv[1]);
        if (FAILED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&host.profiles)))) throw std::runtime_error("TSF profiles unavailable");
        if (FAILED(host.profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&host.previous))) throw std::runtime_error("Cannot inspect active profile");
        host.cases = {{"first-key-space",spelling("NIHAO "),L"你好",L""},
            {"number",spelling("ZHONGWEN1"),L"中文",L""}, {"cancel",{'N','I','H','A','O',VK_ESCAPE},L"",L""},
            {"shift",{VK_SHIFT,'A','B','C',VK_SHIFT,'N','I','H','A','O',VK_SPACE},L"abc你好",L""},
            {"focus",{'N','I',focusSecond,'H','A','O',VK_SPACE},L"",L"好"},
            {"switch-first-key",{switchAway,switchBack,'N','I','H','A','O',VK_SPACE},L"你好",L""}};
        WNDCLASSEXW wc{sizeof(wc)}; wc.hInstance = GetModuleHandleW(nullptr); wc.lpfnWndProc = Host::procedure;
        wc.lpszClassName = L"RimeQ.InstalledHostAcceptance"; wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW+1); wc.hCursor = LoadCursorW(nullptr,IDC_ARROW);
        RegisterClassExW(&wc);
        host.window = CreateWindowExW(0,wc.lpszClassName,L"Rime Q 实际宿主验证 · 独立空白文档",WS_OVERLAPPEDWINDOW,100,100,760,470,nullptr,nullptr,wc.hInstance,&host);
        host.status = CreateWindowExW(0,L"STATIC",L"准备实际输入测试…",WS_CHILD|WS_VISIBLE,24,20,690,42,host.window,nullptr,wc.hInstance,nullptr);
        host.first = CreateWindowExW(WS_EX_CLIENTEDGE,MSFTEDIT_CLASS,L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE|ES_AUTOVSCROLL,24,80,690,130,host.window,nullptr,wc.hInstance,nullptr);
        host.second = CreateWindowExW(WS_EX_CLIENTEDGE,MSFTEDIT_CLASS,L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE|ES_AUTOVSCROLL,24,235,690,130,host.window,nullptr,wc.hInstance,nullptr);
        if (!host.window || !host.first || !host.second) throw std::runtime_error("Cannot create isolated RichEdit document");
        for (auto field : {host.first,host.second}) SendMessageW(field,EM_SETEDITSTYLE,SES_USECTF,SES_USECTF);
        ShowWindow(host.window,SW_SHOWNORMAL); SetForegroundWindow(host.window); SetFocus(host.first);
        if (!host.activate(true)) throw std::runtime_error("Installed Rime Q profile activation failed");
        host.beginCase(); host.idleTicks = 20; SetTimer(host.window,1,60,nullptr);
        MSG message{}; while (GetMessageW(&message,nullptr,0,0)>0) { TranslateMessage(&message); DispatchMessageW(&message); }
        host.activate(false); return host.complete ? 0 : 1;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
