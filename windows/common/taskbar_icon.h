#pragma once
#include <windows.h>
#include <vector>

namespace rq {
inline COLORREF taskbarInk() {
    HIGHCONTRASTW contrast{sizeof(contrast)};
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) && (contrast.dwFlags & HCF_HIGHCONTRASTON))
        return GetSysColor(COLOR_BTNTEXT);
    DWORD light = 0, bytes = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &bytes);
    return light ? RGB(32,33,36) : RGB(255,255,255);
}
inline DWORD taskbarPixel(DWORD alpha, COLORREF ink) {
    return (alpha << 24) | ((GetRValue(ink) * alpha / 255) << 16) |
        ((GetGValue(ink) * alpha / 255) << 8) | (GetBValue(ink) * alpha / 255);
}
inline HICON taskbarIcon(HMODULE module, int size, COLORREF ink) {
    auto source = static_cast<HICON>(LoadImageW(module, MAKEINTRESOURCEW(102), IMAGE_ICON, size, size, 0));
    if (!source) return nullptr;
    struct Bitmaps {
        ICONINFO info{};
        ~Bitmaps() { if (info.hbmColor) DeleteObject(info.hbmColor); if (info.hbmMask) DeleteObject(info.hbmMask); }
    } bitmaps;
    auto read = GetIconInfo(source, &bitmaps.info); DestroyIcon(source);
    if (!read || !bitmaps.info.hbmColor) return nullptr;
    BITMAP bitmap{}; if (!GetObjectW(bitmaps.info.hbmColor, sizeof(bitmap), &bitmap)) return nullptr;
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = bitmap.bmWidth; info.bmiHeader.biHeight = -bitmap.bmHeight;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    std::vector<DWORD> pixels(static_cast<size_t>(bitmap.bmWidth) * bitmap.bmHeight);
    auto dc = GetDC(nullptr); if (!dc) return nullptr;
    auto rows = GetDIBits(dc, bitmaps.info.hbmColor, 0, bitmap.bmHeight, pixels.data(), &info, DIB_RGB_COLORS);
    if (rows == bitmap.bmHeight) {
        for (auto& pixel : pixels) pixel = taskbarPixel(pixel >> 24, ink);
        rows = SetDIBits(dc, bitmaps.info.hbmColor, 0, bitmap.bmHeight, pixels.data(), &info, DIB_RGB_COLORS);
    }
    ReleaseDC(nullptr, dc);
    return rows == bitmap.bmHeight ? CreateIconIndirect(&bitmaps.info) : nullptr;
}
}
