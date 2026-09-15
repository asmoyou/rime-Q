#include "../tsf/candidate.h"
#include <gdiplus.h>
#include <cmath>
#include <iostream>
#include <set>
namespace {
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
uint64_t candidateHash(const char* text) {
    constexpr int width=112,height=50;
    Gdiplus::Bitmap image(width,height,PixelFormat32bppPARGB); Gdiplus::Graphics graphics(&image);
    rq::State state; state.ready=true; state.candidates={{text,""}};
    rq::visuals::Style style; style.fontSize=18;
    rq::visuals::Layout layout; layout.width=width; layout.height=height; layout.rowHeight=34; layout.numberWidth=8; layout.textX=26;
    rq::visuals::drawCandidates(graphics,state,style,layout);
    Gdiplus::Rect crop(26,8,48,34); Gdiplus::BitmapData data{};
    require(image.LockBits(&crop,Gdiplus::ImageLockModeRead,PixelFormat32bppPARGB,&data)==Gdiplus::Ok,"Lock emoji candidate render");
    uint64_t hash=1469598103934665603ull;
    for(int y=0;y<crop.Height;++y) {
        auto row=static_cast<const uint8_t*>(data.Scan0)+static_cast<ptrdiff_t>(y)*data.Stride;
        for(int x=0;x<crop.Width*4;++x) { hash^=row[x]; hash*=1099511628211ull; }
    }
    image.UnlockBits(&data); return hash;
}
void save(Gdiplus::Bitmap& image,const rq::fs::path& path) {
    CLSID encoder{0x557cf406,0x1a04,0x11d3,{0x9a,0x73,0x00,0x00,0xf8,0x1e,0xf3,0x2e}};
    require(image.Save(path.c_str(),&encoder,nullptr)==Gdiplus::Ok,"Save candidate render");
}
void captureSurface(const rq::State& state,rq::visuals::Style style,float scale,const rq::fs::path& path) {
    Gdiplus::Bitmap sample(1,1,PixelFormat32bppPARGB); Gdiplus::Graphics measure(&sample);
    auto layout=rq::visuals::measure(measure,state,style,580);
    Gdiplus::Bitmap image(static_cast<INT>(std::ceil(layout.width*scale)),static_cast<INT>(std::ceil(layout.height*scale)),PixelFormat32bppPARGB);
    Gdiplus::Graphics graphics(&image); graphics.ScaleTransform(scale,scale); rq::visuals::drawCandidates(graphics,state,style,layout); save(image,path);
}
void capture(HWND window, const rq::fs::path& path) {
    RECT rectangle{}; GetWindowRect(window, &rectangle); int width = rectangle.right - rectangle.left, height = rectangle.bottom - rectangle.top;
    HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen); BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; void* data = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen,&info,DIB_RGB_COLORS,&data,nullptr,0); auto old = SelectObject(dc,bitmap);
    SendMessageW(window,WM_PRINTCLIENT,reinterpret_cast<WPARAM>(dc),PRF_CLIENT);
    Gdiplus::Bitmap image(width,height,width*4,PixelFormat32bppPARGB,static_cast<BYTE*>(data));
    save(image,path);
    SelectObject(dc,old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr,screen);
}
}
int wmain(int argc,wchar_t** argv) {
    if (argc != 3) return 2;
    try {
        rq::fs::path output = rq::fs::absolute(argv[1]), settings = rq::fs::absolute(argv[2]);
        rq::fs::create_directories(output); rq::fs::create_directories(settings);
        Gdiplus::GdiplusStartupInput startup; ULONG_PTR token = 0; Gdiplus::GdiplusStartup(&token,&startup,nullptr);
        auto ini = settings / L"settings.ini";
        auto preference = [&](const wchar_t* key, const wchar_t* value) { WritePrivateProfileStringW(L"RimeQ",key,value,ini.c_str()); };
        unsigned selected = 99;
        rq::CandidateWindow window(GetModuleHandleW(nullptr),[&](unsigned index) { selected = index; },settings);
        rq::State state; state.ready = true; state.preedit = "ni"; state.candidates = {{"你",""}};
        preference(L"FontSize",L"18"); preference(L"Theme",L"0"); preference(L"Cat",L"0");
        window.show(state,{200,180,202,202},nullptr); UpdateWindow(window.handle());
        RECT original{}; GetWindowRect(window.handle(),&original);
        require(original.right - original.left < 130,"Short candidate retains fixed empty width");
        capture(window.handle(),output/L"candidate-short.png");
        preference(L"Cat",L"1"); window.show(state,{200,180,202,202},nullptr); RECT decorated{}; GetWindowRect(window.handle(),&decorated);
        require(original.right-original.left == decorated.right-decorated.left && original.bottom-original.top == decorated.bottom-decorated.top,"Decoration changes candidate layout");
        require(window.decoration() && (GetWindowLongPtrW(window.decoration(),GWL_EXSTYLE)&WS_EX_TRANSPARENT),"Decoration intercepts clicks");
        state.preedit = "ni hao"; state.candidates = {{"你好","问候"},{"拟好",""},{"你号",""}};
        window.show(state,{200,180,202,202},nullptr); capture(window.handle(),output/L"candidate-light.png");
        capture(window.decoration(),output/L"candidate-cat.png");
        SendMessageW(window.handle(),WM_LBUTTONUP,0,MAKELPARAM(24,59)); require(selected == 1,"Mouse candidate index mismatch");
        preference(L"Theme",L"5"); preference(L"Cat",L"0"); preference(L"FontSize",L"22");
        state.preedit = "rang shu ru hui gui zi ran";
        state.candidates = {{"让输入回归自然，在离线状态下也可以流畅地输入完整中文句子。","很长的注释必须与候选文字分别截断，不能相互覆盖"},{"自然",""}};
        window.show(state,{0,0,1,24},nullptr); capture(window.handle(),output/L"candidate-dark-long.png");
        preference(L"Theme",L"0"); preference(L"FontSize",L"20");
        state.preedit = "emoji";
        state.candidates = {{"❤ ☀","基础符号"},{"😀 🎉 🚀","补充平面"},{"❤️","变体选择符"},{"👍🏽","肤色"},
            {"👨‍👩‍👧‍👦","ZWJ 家庭"},{"测试😀中文","中英混排"},{"1️⃣","键帽"},{"🇨🇳","国旗"},{"⌚ ↔️ ⭐","扩展符号"}};
        window.show(state,{200,180,202,202},nullptr); capture(window.handle(),output/L"candidate-emoji.png");
        require(std::set<uint64_t>{candidateHash("😀"),candidateHash("🎉"),candidateHash("🚀")}.size()==3,
            "Distinct emoji candidates collapsed to the same missing-glyph box");
        for(const auto& theme:std::vector<std::pair<const wchar_t*,const wchar_t*>>{{L"1",L"light"},{L"5",L"dark"}}) {
            preference(L"Theme",theme.first);
            for(const auto* size:std::vector<const wchar_t*>{L"16",L"18",L"20",L"22"}) {
                preference(L"FontSize",size); window.show(state,{200,180,202,202},nullptr);
                capture(window.handle(),output/(std::wstring(L"candidate-emoji-")+theme.second+L"-"+size+L".png"));
            }
        }
        captureSurface(state,{1,22,false,false,false},2,output/L"candidate-emoji-light-200pct.png");
        captureSurface(state,{5,22,true,false,false},2,output/L"candidate-emoji-dark-200pct.png");
        preference(L"Cat",L"1"); window.show(state,{0,0,1,24},nullptr);
        MONITORINFO monitor{sizeof(monitor)}; GetMonitorInfoW(MonitorFromWindow(window.handle(),MONITOR_DEFAULTTONEAREST),&monitor);
        RECT box{},cat{}; GetWindowRect(window.handle(),&box); GetWindowRect(window.decoration(),&cat);
        require(box.left>=monitor.rcWork.left && cat.top>=monitor.rcWork.top,"Screen-edge avoidance failed");
        window.hide(); require(!window.visible() && !IsWindowVisible(window.decoration()),"Decoration remains visible after candidates hide");
        std::cout << "PASS candidate sizing, mouse index, long comments, emoji fallback, separate decoration, edge avoidance, hide; rendered native surfaces\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
