#include "candidate.h"
#include <windowsx.h>
#include <cmath>

namespace rq {
namespace {
// Text and translucent backgrounds have independent per-pixel alpha.
template<class Draw> void surface(HWND window,HDC print,Draw draw) {
    RECT rectangle{}; GetWindowRect(window,&rectangle); int width=rectangle.right-rectangle.left, height=rectangle.bottom-rectangle.top;
    if (width<=0 || height<=0) return;
    PAINTSTRUCT ps{}; HDC target=print?print:BeginPaint(window,&ps), dc=CreateCompatibleDC(target);
    BITMAPINFO info{}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth=width; info.bmiHeader.biHeight=-height;
    info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32; info.bmiHeader.biCompression=BI_RGB;
    void* pixels=nullptr; HBITMAP bitmap=CreateDIBSection(target,&info,DIB_RGB_COLORS,&pixels,nullptr,0);
    if(bitmap && pixels) {
        memset(pixels,0,static_cast<size_t>(width)*height*4); auto old=SelectObject(dc,bitmap);
        { Gdiplus::Bitmap image(width,height,width*4,PixelFormat32bppPARGB,static_cast<BYTE*>(pixels)); Gdiplus::Graphics g(&image); draw(g,width,height); }
        if(print) BitBlt(print,0,0,width,height,dc,0,0,SRCCOPY);
        else {
            POINT destination{rectangle.left,rectangle.top}, source{}; SIZE size{width,height}; BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
            UpdateLayeredWindow(window,target,&destination,&size,dc,&source,0,&blend,ULW_ALPHA);
        }
        SelectObject(dc,old);
    }
    if(bitmap) DeleteObject(bitmap); DeleteDC(dc); if(!print) EndPaint(window,&ps);
}
}
CandidateWindow::~CandidateWindow() {
    if(cat_) DestroyWindow(cat_); if(window_) DestroyWindow(window_);
    if(graphics_) Gdiplus::GdiplusShutdown(graphics_);
}
void CandidateWindow::hide() {
    pose_=0;
    if(window_) ShowWindow(window_,SW_HIDE);
    if(cat_) { KillTimer(cat_,1); ShowWindow(cat_,SW_HIDE); }
}
void CandidateWindow::show(const State& state,RECT caret,HWND owner) {
    if(state.candidates.empty()) { hide(); return; }
    bool tap=state.preedit!=state_.preedit || state.highlighted!=state_.highlighted || state.page!=state_.page || state.cursor!=state_.cursor;
    state_=state;
    if(!graphics_) { Gdiplus::GdiplusStartupInput startup; if(Gdiplus::GdiplusStartup(&graphics_,&startup,nullptr)!=Gdiplus::Ok) return; }
    if(!window_) {
        WNDCLASSEXW wc{sizeof(wc)}; wc.hInstance=module_; wc.lpfnWndProc=procedure; wc.lpszClassName=L"RimeQ.Candidates.v1";
        wc.hCursor=LoadCursorW(nullptr,IDC_ARROW); wc.style=CS_DROPSHADOW; RegisterClassExW(&wc);
        window_=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST|WS_EX_LAYERED,wc.lpszClassName,L"Rime Q 候选",WS_POPUP,0,0,1,1,owner,nullptr,module_,this);
        if(!window_) return;
    }
    if(owner) SetWindowLongPtrW(window_,GWLP_HWNDPARENT,reinterpret_cast<LONG_PTR>(owner));
    dpi_=static_cast<int>(GetDpiForWindow(owner?owner:window_)); if(!dpi_) dpi_=96; float scale=dpi_/96.0f;
    int size=preference(L"FontSize",18,preferences_); if(size!=16 && size!=18 && size!=20 && size!=22) size=18;
    style_.fontSize=static_cast<float>(size); style_.skin=preference(L"Cat",0,preferences_)?6:std::clamp(preference(L"Theme",0,preferences_),0,5);
    DWORD light=1, transparency=1, bytes=sizeof(DWORD);
    RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&light,&bytes);
    bytes=sizeof(DWORD); RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"EnableTransparency",RRF_RT_REG_DWORD,nullptr,&transparency,&bytes);
    HIGHCONTRASTW contrast{sizeof(contrast)}; SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(contrast),&contrast,0);
    style_.dark=!light; style_.highContrast=(contrast.dwFlags&HCF_HIGHCONTRASTON)!=0; style_.transparent=transparency && !style_.highContrast;
    MONITORINFO monitor{sizeof(monitor)}; GetMonitorInfoW(MonitorFromRect(&caret,MONITOR_DEFAULTTONEAREST),&monitor);
    { Gdiplus::Bitmap sample(1,1,PixelFormat32bppPARGB); Gdiplus::Graphics g(&sample);
      layout_=visuals::measure(g,state_,style_,std::min(580.0f,(monitor.rcWork.right-monitor.rcWork.left)/scale)); }
    auto placement=visuals::place(layout_,caret,monitor.rcWork,scale,style_.skin==6);
    rows_.clear();
    for(size_t i=0;i<state_.candidates.size();++i) rows_.push_back({static_cast<LONG>(4*scale),static_cast<LONG>((8+i*layout_.rowHeight)*scale),
        static_cast<LONG>((layout_.width-4)*scale),static_cast<LONG>((8+(i+1)*layout_.rowHeight)*scale)});
    const auto& body=placement.body; SetWindowPos(window_,HWND_TOPMOST,body.left,body.top,body.right-body.left,body.bottom-body.top,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    InvalidateRect(window_,nullptr,FALSE);
    if(placement.showPet) showCat(placement.pet,tap);
    else if(cat_) { KillTimer(cat_,1); pose_=0; ShowWindow(cat_,SW_HIDE); }
}
void CandidateWindow::showCat(RECT rect,bool tap) {
    if(!cat_) cat_=CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST,
        L"RimeQ.Candidates.v1",L"",WS_POPUP,rect.left,rect.top,1,1,window_,nullptr,module_,this);
    if(!cat_) return;
    BOOL motion=TRUE; SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&motion,0);
    if(!motion) { KillTimer(cat_,1); pose_=0; }
    else if(tap) { lastPaw_=lastPaw_==1?2:1; pose_=lastPaw_; SetTimer(cat_,1,160,nullptr); }
    SetWindowPos(cat_,HWND_TOPMOST,rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    InvalidateRect(cat_,nullptr,FALSE); UpdateWindow(cat_);
}
void CandidateWindow::paint(HDC print) {
    surface(window_,print,[this](Gdiplus::Graphics& g,int,int) { g.ScaleTransform(dpi_/96.0f,dpi_/96.0f); visuals::drawCandidates(g,state_,style_,layout_); });
}
void CandidateWindow::paintCat(HDC print) {
    surface(cat_,print,[this](Gdiplus::Graphics& g,int width,int height) { visuals::drawCat(g,Gdiplus::RectF(0,0,static_cast<float>(width),static_cast<float>(height)),pose_,style_.dark); });
}
LRESULT CALLBACK CandidateWindow::procedure(HWND window,UINT message,WPARAM wparam,LPARAM lparam) {
    auto self=reinterpret_cast<CandidateWindow*>(GetWindowLongPtrW(window,GWLP_USERDATA));
    if(message==WM_NCCREATE) { self=static_cast<CandidateWindow*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams); SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self)); }
    if(self) {
        if(message==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
        if(message==WM_ERASEBKGND) return 1;
        if(window==self->cat_) {
            if(message==WM_NCHITTEST) return HTTRANSPARENT;
            if(message==WM_TIMER) { KillTimer(window,1); self->pose_=0; InvalidateRect(window,nullptr,FALSE); return 0; }
            if(message==WM_PAINT) { self->paintCat(); return 0; }
            if(message==WM_PRINT || message==WM_PRINTCLIENT) { self->paintCat(reinterpret_cast<HDC>(wparam)); return 0; }
        } else {
            if(message==WM_PAINT) { self->paint(); return 0; }
            if(message==WM_PRINT || message==WM_PRINTCLIENT) { self->paint(reinterpret_cast<HDC>(wparam)); return 0; }
            if(message==WM_LBUTTONUP) {
                POINT point{GET_X_LPARAM(lparam),GET_Y_LPARAM(lparam)};
                for(unsigned i=0;i<self->rows_.size();++i) if(PtInRect(&self->rows_[i],point)) { self->select_(i); break; } return 0;
            }
        }
    }
    return DefWindowProcW(window,message,wparam,lparam);
}
}
