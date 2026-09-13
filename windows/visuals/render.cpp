#include "render.h"
#include <cmath>

namespace rq::visuals {
using namespace Gdiplus;
namespace {
Color rgb(unsigned color, BYTE alpha = 255) { return Color(alpha, (color >> 16) & 255, (color >> 8) & 255, color & 255); }
Color systemColor(int index) { auto c = GetSysColor(index); return Color(255,GetRValue(c),GetGValue(c),GetBValue(c)); }
void roundPath(GraphicsPath& path, RectF r, float radius) {
    radius = std::min(radius, std::min(r.Width,r.Height)/2); float d = radius*2;
    if (d <= 0) return;
    path.AddArc(r.X,r.Y,d,d,180,90); path.AddArc(r.GetRight()-d,r.Y,d,d,270,90);
    path.AddArc(r.GetRight()-d,r.GetBottom()-d,d,d,0,90); path.AddArc(r.X,r.GetBottom()-d,d,d,90,90); path.CloseFigure();
}
void roundRect(Graphics& g, RectF r, float radius, Color fill, Color border = Color(0,0,0,0), float line = 1) {
    GraphicsPath path; roundPath(path,r,radius); SolidBrush brush(fill); g.FillPath(&brush,&path);
    if (border.GetA()) { Pen pen(border,line); g.DrawPath(&pen,&path); }
}
struct Fonts {
    Font text, secondaryFont, number;
    explicit Fonts(float size) : text(L"Microsoft YaHei UI",size,FontStyleRegular,UnitPixel),
        secondaryFont(L"Microsoft YaHei UI",12,FontStyleRegular,UnitPixel), number(L"Consolas",12,FontStyleRegular,UnitPixel) {}
};
float width(Graphics& g, const std::wstring& text, const Font& font) {
    if (text.empty()) return 0;
    StringFormat format(StringFormat::GenericTypographic()); format.SetFormatFlags(StringFormatFlagsNoWrap | StringFormatFlagsMeasureTrailingSpaces);
    RectF bounds; g.MeasureString(text.c_str(), static_cast<INT>(text.size()),&font,PointF(0,0),&format,&bounds);
    return std::ceil(bounds.Width);
}
void label(Graphics& g,const std::wstring& text,const Font& font,RectF box,Color color) {
    if (box.Width <= 0 || box.Height <= 0) return;
    StringFormat format(StringFormat::GenericTypographic()); format.SetFormatFlags(StringFormatFlagsNoWrap);
    format.SetTrimming(StringTrimmingEllipsisCharacter); format.SetLineAlignment(StringAlignmentCenter);
    SolidBrush ink(color); auto saved = g.Save(); g.SetClip(box,CombineModeIntersect);
    g.DrawString(text.c_str(),static_cast<INT>(text.size()),&font,box,&format,&ink); g.Restore(saved);
}
const wchar_t* skinName(int id) { static const wchar_t* names[] = {L"随系统",L"纸白",L"雾蓝",L"青玉",L"浅樱",L"暮色",L"敲敲猫"}; return names[std::clamp(id,0,6)]; }
}
Palette palette(const Style& s) {
    unsigned backgrounds[] = {s.dark?0x272A31u:0xF3F4F7u,0xFAF8F2,0xEFF4FC,0xF0F6F2,0xFCF2EF,0x252B38,s.dark?0x2D2D33u:0xFBF7EFu};
    unsigned texts[] = {s.dark?0xF2F2F7u:0x202124u,0x383A3B,0x293C59,0x244637,0x62413B,0xEDF1F8,s.dark?0xF2E9DCu:0x493F36u};
    unsigned accents[] = {0x007AFF,0x71624C,0x386BAF,0x317458,0xA45B53,0xB5CFF5,s.dark?0xE8BA83u:0xB67843u};
    unsigned selections[] = {s.dark?0x273B58u:0xD2E3FCu,0xEBE5D8,0xD6E4F7,0xD4E9DC,0xF1DAD4,0x3A4B68,s.dark?0x514539u:0xF1E3CEu};
    int id = std::clamp(s.skin,0,6);
    Palette p{rgb(backgrounds[id],s.transparent && id == 0 ? 235 : 255),rgb(texts[id]),rgb(accents[id]),rgb(selections[id]),rgb(texts[id],id == 5 ? 41 : 26)};
    if (s.highContrast) p = {systemColor(COLOR_WINDOW),systemColor(COLOR_WINDOWTEXT),systemColor(COLOR_HIGHLIGHT),systemColor(COLOR_HIGHLIGHT),systemColor(COLOR_WINDOWTEXT)};
    return p;
}
Layout measure(Graphics& g,const State& state,const Style& style,float maximum) {
    Layout result; if (state.candidates.empty()) return result;
    Fonts fonts(style.fontSize); result.rowHeight = style.fontSize + 16;
    result.numberWidth = width(g,std::to_wstring(state.candidates.size()),fonts.number); result.textX = 10 + result.numberWidth + 8;
    float widest = 0;
    for (const auto& c : state.candidates) widest = std::max(widest,width(g,wide(c.text),fonts.text) + (c.comment.empty()?0:8+width(g,wide(c.comment),fonts.secondaryFont)));
    result.width = std::min(maximum,std::ceil(result.textX + widest + 10));
    result.height = state.candidates.size()*result.rowHeight+16; return result;
}
void drawCandidates(Graphics& g,const State& state,const Style& style,const Layout& layout,bool surface) {
    if (layout.width <= 0 || layout.height <= 0) return;
    g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    auto p = palette(style); Fonts fonts(style.fontSize);
    if (surface) roundRect(g,RectF(.5f,.5f,layout.width-1,layout.height-1),14,p.background,p.border);
    for (size_t i = 0; i < state.candidates.size(); ++i) {
        bool selected = i == state.highlighted; float y = 8 + i*layout.rowHeight;
        if (selected) roundRect(g,RectF(4,y,layout.width-8,layout.rowHeight),9,p.selection);
        auto textColor = style.highContrast && selected ? systemColor(COLOR_HIGHLIGHTTEXT) : p.text;
        Color secondary(style.highContrast?255:174,textColor.GetR(),textColor.GetG(),textColor.GetB());
        label(g,std::to_wstring(i+1),fonts.number,RectF(10,y,layout.numberWidth+2,layout.rowHeight),secondary);
        const auto& item = state.candidates[i]; float available = std::max(0.0f,layout.width-layout.textX-10);
        float annotation = 0;
        if (!item.comment.empty()) {
            float minimum = std::min(width(g,wide(item.text),fonts.text),std::max(style.fontSize*2,available*.65f));
            annotation = std::min(width(g,wide(item.comment),fonts.secondaryFont),std::max(0.0f,available-minimum-8));
        }
        float textWidth = std::max(0.0f,available-(annotation>0?annotation+8:0));
        label(g,wide(item.text),fonts.text,RectF(layout.textX,y,textWidth,layout.rowHeight),textColor);
        if (annotation>0) label(g,wide(item.comment),fonts.secondaryFont,RectF(layout.width-10-annotation,y,annotation,layout.rowHeight),secondary);
    }
}
void drawCat(Graphics& g,const RectF& rect,int pose,bool dark) {
    auto saved = g.Save(); g.TranslateTransform(rect.X,rect.Y); g.ScaleTransform(rect.Width/96,rect.Height/64);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    Color outline = rgb(0x9E7460), fur = rgb(dark?0xF1C896:0xFFDBAE), face = rgb(dark?0xFBEAD1:0xFFF9EF), peach = rgb(0xECA991), ink = rgb(0x62473F);
    auto shape = [&](GraphicsPath& path,Color fill,bool stroke = true) {
        SolidBrush brush(fill); g.FillPath(&brush,&path);
        if (stroke) { Pen pen(outline,1.4f); pen.SetLineJoin(LineJoinRound); g.DrawPath(&pen,&path); }
    };
    auto oval = [&](float x,float y,float w,float h,Color fill,bool stroke=false) { GraphicsPath path; path.AddEllipse(x,y,w,h); shape(path,fill,stroke); };
    auto line = [&](float x1,float y1,float x2,float y2,Color color,float thickness=1.2f) {
        Pen pen(color,thickness); pen.SetStartCap(LineCapRound); pen.SetEndCap(LineCapRound); pen.SetLineJoin(LineJoinRound); g.DrawLine(&pen,x1,y1,x2,y2);
    };
    GraphicsPath tail; tail.AddBezier(72.0f,45.0f,99.0f,43.0f,91.0f,16.0f,83.0f,pose==0?21.0f:19.0f);
    Pen tailOutline(outline,8), tailFur(fur,5.4f); tailOutline.SetStartCap(LineCapRound); tailOutline.SetEndCap(LineCapRound);
    tailFur.SetStartCap(LineCapRound); tailFur.SetEndCap(LineCapRound); g.DrawPath(&tailOutline,&tail); g.DrawPath(&tailFur,&tail);
    oval(35,29,48,27,fur,true); oval(60,38,15,13,rgb(0xF1BB83)); oval(68,48,14,9,face,true);
    auto headState = g.Save(); g.TranslateTransform(0,pose==0?0:.7f);
    GraphicsPath head;
    head.AddBezier(13.0f,27.0f,12.0f,21.0f,11.0f,10.0f,15.0f,10.0f);
    head.AddBezier(15.0f,10.0f,18.0f,8.0f,22.0f,14.0f,26.0f,17.0f);
    head.AddBezier(26.0f,17.0f,32.0f,13.0f,40.0f,13.0f,46.0f,16.0f);
    head.AddBezier(46.0f,16.0f,52.0f,9.0f,56.0f,7.0f,57.0f,10.0f);
    head.AddBezier(57.0f,10.0f,60.0f,12.0f,59.0f,20.0f,59.0f,27.0f);
    head.AddBezier(59.0f,27.0f,69.0f,44.0f,52.0f,52.0f,36.0f,51.0f);
    head.AddBezier(36.0f,51.0f,18.0f,52.0f,5.0f,44.0f,13.0f,27.0f); head.CloseFigure(); shape(head,fur);
    oval(14,28,44,21,face);
    line(17,15,21,20,peach,3.5f); line(55,15,51,20,peach,3.5f);
    line(33,18,35,22,rgb(0xEAB783),2); line(40,18,39,22,rgb(0xEAB783),2);
    oval(23,29,5,6.5f,ink); oval(45,29,5,6.5f,ink); oval(24,29.5f,1.8f,2,rgb(0xFFFFFF)); oval(46,29.5f,1.8f,2,rgb(0xFFFFFF));
    line(23,25.5f,26,25,outline,1); line(46,25,49,25.5f,outline,1);
    oval(16,36,9,4.5f,rgb(0xECA991,179)); oval(49,36,9,4.5f,rgb(0xECA991,179)); oval(34,35,4.5f,3,rgb(0xCA8D80));
    GraphicsPath smile; smile.AddBezier(30.0f,39.0f,30.0f,43.0f,35.0f,43.0f,36.0f,38.0f);
    smile.AddBezier(36.0f,38.0f,37.0f,43.0f,42.0f,43.0f,42.0f,39.0f);
    Pen mouth(ink,1.2f); mouth.SetStartCap(LineCapRound); mouth.SetEndCap(LineCapRound); g.DrawPath(&mouth,&smile); g.Restore(headState);
    roundRect(g,RectF(15,54,57,8),3,rgb(dark?0xB6A398:0xF1E4D8),outline,1.4f);
    for (int row=0;row<2;++row) for(int column=0;column<8;++column) roundRect(g,RectF(20+column*6.0f,56+row*2.5f,4,1.5f),.6f,face);
    for (int i=0;i<2;++i) {
        float x = i==0?22.0f:46.0f, y = pose==i+1?50.0f:46.0f;
        oval(x,y,15,11,face,true); line(x+5,y+7,x+5,y+9,outline,.8f); line(x+9,y+7,x+9,y+9,outline,.8f);
        if (pose && pose != i+1) oval(x+5,y+4,5,3,rgb(0xECA991,166));
    }
    if (pose) {
        float x=pose==1?24.0f:59.0f; line(x,48,x-2,45,peach,1.4f);
        line(73,16,73,23,rgb(0xD6A562),1.5f); line(70,19.5f,76,19.5f,rgb(0xD6A562),1.5f);
    }
    g.Restore(saved);
}
Placement place(const Layout& layout,const RECT& caret,const RECT& work,float scale,bool cat) {
    Placement p; int width=static_cast<int>(std::ceil(layout.width*scale)), height=static_cast<int>(std::ceil(layout.height*scale));
    int petWidth=static_cast<int>(std::ceil(std::min(88.0f,std::max(64.0f,layout.width+12))*scale)), petHeight=static_cast<int>(std::ceil(petWidth*2.0f/3));
    int overlap=static_cast<int>(std::round(2*scale)), extra=cat?petHeight-overlap:0;
    p.showPet=cat && height+extra <= work.bottom-work.top; if (!p.showPet) extra=0;
    int total=height+extra, gap=static_cast<int>(std::ceil(5*scale));
    int x=std::clamp(int(caret.left),int(work.left),std::max(int(work.left),int(work.right)-width));
    int y=caret.bottom+gap; if(y+total>work.bottom) y=caret.top-total-gap;
    y=std::clamp(y,int(work.top),std::max(int(work.top),int(work.bottom)-total));
    p.body={x,y+extra,x+width,y+extra+height};
    int petX=width<petWidth+8*scale?x+(width-petWidth)/2:x+width-petWidth-static_cast<int>(4*scale);
    petX=std::clamp(petX,int(work.left),std::max(int(work.left),int(work.right)-petWidth));
    p.pet={petX,p.body.top-petHeight+overlap,petX+petWidth,p.body.top+overlap}; return p;
}
void drawPreview(Graphics& g,float widthValue,float heightValue,const Style& style,int pose,int mode) {
    g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    if (mode==2) { drawCat(g,RectF(0,0,widthValue,heightValue),pose,style.dark); return; }
    auto p=palette(style); Color frame=rgb(style.dark?0x24272E:0xEEF0F5), border=rgb(style.dark?0x3C3F46:0xE1E4E9);
    roundRect(g,RectF(.5f,.5f,widthValue-1,heightValue-1),mode==1?8.0f:12.0f,mode==1?p.background:frame,mode==1?Color(0,0,0,0):border);
    if(mode==0) { SolidBrush dot(rgb(style.dark?0xFFFFFF:0x000000,11)); for(float x=16;x<widthValue-8;x+=20) for(float y=16;y<heightValue-8;y+=20) g.FillEllipse(&dot,x,y,1.5f,1.5f); }
    State sample; sample.candidates={{"你好世界",""},{"你好",""}}; Style opaque=style; opaque.transparent=false;
    auto layout=measure(g,sample,opaque,std::max(1.0f,widthValue-20));
    float petWidth=std::min(88.0f,std::max(64.0f,layout.width+12)), petHeight=petWidth*2/3, extra=style.skin==6?petHeight-2:0;
    float x=std::floor((widthValue-layout.width)/2), y=mode==1?std::floor((heightValue-layout.height)/2):std::max(20.0f,std::floor((heightValue-layout.height-extra)/2)+extra-3);
    auto saved=g.Save(); g.TranslateTransform(x,y); drawCandidates(g,sample,opaque,layout,mode!=1); g.Restore(saved);
    if(style.skin==6) drawCat(g,RectF(layout.width<petWidth+8?x+(layout.width-petWidth)/2:x+layout.width-petWidth-4,y-petHeight+2,petWidth,petHeight),pose,style.dark);
    else if(mode==0) { Font font(L"Microsoft YaHei UI",12,FontStyleRegular,UnitPixel); label(g,L"ni hao shi jie",font,RectF(x+4,y-24,160,20),rgb(style.dark?0xA5A8B0:0x73767C)); }
    if(mode==0) { Font font(L"Microsoft YaHei UI",11,FontStyleRegular,UnitPixel); label(g,std::wstring(skinName(style.skin))+L" · "+std::to_wstring(int(style.fontSize)),font,RectF(14,heightValue-26,widthValue-28,20),rgb(style.dark?0xA5A8B0:0x73767C)); }
}
void drawIcon(Graphics& g,float side) {
    g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    roundRect(g,RectF(0,0,side,side),side*.22f,rgb(0x304775));
    Font font(L"Segoe UI",side*.71f,FontStyleRegular,UnitPixel); StringFormat format;
    format.SetAlignment(StringAlignmentCenter); format.SetLineAlignment(StringAlignmentCenter);
    SolidBrush white(rgb(0xFFFFFF)); g.DrawString(L"Q",1,&font,RectF(0,-side*.025f,side,side),&format,&white);
}
}
