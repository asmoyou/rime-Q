#include "taskbar_icon.h"
#include <shellapi.h>
#include <iostream>
#include <stdexcept>

static void verifyRegisteredProfileIcon() {
    // This executable embeds tip.rc: shell index 0 is the DLL's registered icon.
    // Testing only the tinted GetIcon helper missed this separate shell path.
    wchar_t path[32768]{};GetModuleFileNameW(nullptr,path,32768);
    HICON icon=nullptr;
    if(ExtractIconExW(path,0,&icon,nullptr,1)!=1||!icon)
        throw std::runtime_error("Shell could not extract registered icon index 0");
    ICONINFO source{};GetIconInfo(icon,&source);DestroyIcon(icon);
    BITMAP bitmap{};GetObjectW(source.hbmColor,sizeof(bitmap),&bitmap);
    BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=bitmap.bmWidth;
    info.bmiHeader.biHeight=-bitmap.bmHeight;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
    std::vector<DWORD> pixels(bitmap.bmWidth*bitmap.bmHeight);auto dc=GetDC(nullptr);
    auto rows=GetDIBits(dc,source.hbmColor,0,bitmap.bmHeight,pixels.data(),&info,DIB_RGB_COLORS);
    ReleaseDC(nullptr,dc);DeleteObject(source.hbmColor);DeleteObject(source.hbmMask);
    if(rows!=bitmap.bmHeight)throw std::runtime_error("Could not read registered profile icon");
    int solid=0;
    for(auto pixel:pixels)if((pixel>>24)==255) {
        ++solid;if((pixel&0xffffff)!=0xffffff)throw std::runtime_error("Registered profile icon must be solid white, not black with a white outline");
    }
    if(solid<10)throw std::runtime_error("Registered profile icon has no solid strokes");
}

int main() {
    try {
        verifyRegisteredProfileIcon();
        for (int size : {16,20,24,32,40,48,64}) for (auto ink : {RGB(255,255,255),RGB(32,33,36),RGB(255,255,0)}) {
            auto icon=rq::taskbarIcon(GetModuleHandleW(nullptr),size,ink);
            if(!icon)throw std::runtime_error("Could not create native taskbar icon");
            ICONINFO source{};GetIconInfo(icon,&source);DestroyIcon(icon);
            BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=size;
            info.bmiHeader.biHeight=-size;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
            std::vector<DWORD> pixels(size*size);auto dc=GetDC(nullptr);
            auto rows=GetDIBits(dc,source.hbmColor,0,size,pixels.data(),&info,DIB_RGB_COLORS);
            ReleaseDC(nullptr,dc);DeleteObject(source.hbmColor);DeleteObject(source.hbmMask);
            if(rows!=size)throw std::runtime_error("Native icon size differs");
            int solid=0,clear=0;
            for(auto pixel:pixels) {
                auto alpha=pixel>>24;if(alpha<=3)++clear;
                if(alpha==255) {
                    ++solid;
                    auto rgb=((DWORD)GetRValue(ink)<<16)|((DWORD)GetGValue(ink)<<8)|GetBValue(ink);
                    if((pixel&0xffffff)!=rgb)throw std::runtime_error("Opaque taskbar strokes have wrong colour");
                }
                if((pixel&255)>alpha||((pixel>>8)&255)>alpha||((pixel>>16)&255)>alpha)
                    throw std::runtime_error("Taskbar icon is not premultiplied");
            }
            if(solid<10||clear<size*size/2)throw std::runtime_error("Taskbar icon lost transparent background or strokes");
        }
        std::cout<<"PASS shell profile icon index 0: solid white; native taskbar Q: white/dark/high-contrast ink, 7 sizes, alpha and premultiplied edges\n";
        return 0;
    } catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
