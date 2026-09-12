#include "render.h"
extern "C" __declspec(dllexport) int __cdecl RimeQRenderPreview(int skin,int size,int pose,int dark,int width,int height,double scale,int mode,void* pixels,int stride) {
    if (!pixels || width<=0 || height<=0 || width>4096 || height>4096 || stride!=width*4 || scale<=0 || scale>4 || size<8 || size>32) return 0;
    Gdiplus::GdiplusStartupInput startup; ULONG_PTR token=0;
    if (Gdiplus::GdiplusStartup(&token,&startup,nullptr)!=Gdiplus::Ok) return 0;
    int ok=1;
    try {
        memset(pixels,0,static_cast<size_t>(stride)*height);
        Gdiplus::Bitmap bitmap(width,height,stride,PixelFormat32bppPARGB,static_cast<BYTE*>(pixels)); Gdiplus::Graphics g(&bitmap);
        g.ScaleTransform(static_cast<float>(scale),static_cast<float>(scale));
        if(mode==3) rq::visuals::drawIcon(g,static_cast<float>(width/scale));
        else rq::visuals::drawPreview(g,static_cast<float>(width/scale),static_cast<float>(height/scale),{skin,static_cast<float>(size),dark!=0,false,false},pose,mode);
    } catch (...) { ok=0; }
    Gdiplus::GdiplusShutdown(token); return ok;
}
