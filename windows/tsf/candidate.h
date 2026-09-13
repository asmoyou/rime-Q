#pragma once
#include "../visuals/render.h"
#include <functional>

namespace rq {
class CandidateWindow {
    HWND window_ = nullptr, cat_ = nullptr;
    HMODULE module_ = nullptr;
    ULONG_PTR graphics_ = 0;
    int dpi_ = 96, pose_ = 0, lastPaw_ = 2;
    State state_;
    visuals::Style style_;
    visuals::Layout layout_;
    std::vector<RECT> rows_;
    std::function<void(unsigned)> select_;
    fs::path preferences_;
    static LRESULT CALLBACK procedure(HWND, UINT, WPARAM, LPARAM);
    void paint(HDC print = nullptr);
    void paintCat(HDC print = nullptr);
    void showCat(RECT rectangle, bool tap);
public:
    CandidateWindow(HMODULE module, std::function<void(unsigned)> select, fs::path preferences = dataRoot())
        : module_(module), select_(std::move(select)), preferences_(std::move(preferences)) {}
    ~CandidateWindow();
    void show(const State& state, RECT caret, HWND owner);
    void hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }
    HWND handle() const { return window_; }
    HWND decoration() const { return cat_; }
};
}
