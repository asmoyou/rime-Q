#pragma once
#include "win.h"
#include <gdiplus.h>

namespace rq::visuals {
struct Style {
    int skin = 0;
    float fontSize = 18;
    bool dark = false, highContrast = false, transparent = false;
};
struct Palette { Gdiplus::Color background, text, accent, selection, border; };
struct Layout { float width = 0, height = 0, rowHeight = 34, numberWidth = 8, textX = 26; };
struct Placement { RECT body{}, pet{}; bool showPet = false; };
Palette palette(const Style& style);
Layout measure(Gdiplus::Graphics& graphics, const State& state, const Style& style, float maxWidth = 580);
void drawCandidates(Gdiplus::Graphics& graphics, const State& state, const Style& style, const Layout& layout, bool surface = true);
// Exact 96 x 64 geometry and 0/1/2 poses from macos/Sources/TypingCat.swift.
void drawCat(Gdiplus::Graphics& graphics, const Gdiplus::RectF& rect, int pose, bool dark);
Placement place(const Layout& layout, const RECT& caret, const RECT& work, float scale, bool cat);
void drawPreview(Gdiplus::Graphics& graphics, float width, float height, const Style& style, int pose, int mode);
void drawIcon(Gdiplus::Graphics& graphics, float size);
}
