#include "candidate.h"
#include "identity.h"
#include <msctf.h>
#include <ctfutb.h>
#include <initguid.h>
#include <inputscope.h>
#include <olectl.h>
#include <wrl/client.h>
#include <functional>
#include <memory>
using Microsoft::WRL::ComPtr;
HMODULE rqModule = nullptr;
long rqObjects = 0;

namespace {
class Edit final : public ITfEditSession {
    long references_ = 1;
    std::function<HRESULT(TfEditCookie)> action_;
public:
    explicit Edit(std::function<HRESULT(TfEditCookie)> action) : action_(std::move(action)) { InterlockedIncrement(&rqObjects); }
    ~Edit() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ITfEditSession) return E_NOINTERFACE;
        *out = static_cast<ITfEditSession*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie) override {
        try { return action_(cookie); } catch (...) { return E_FAIL; }
    }
};
class Attribute final : public ITfDisplayAttributeInfo {
    long references_ = 1;
public:
    Attribute() { InterlockedIncrement(&rqObjects); }
    ~Attribute() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ITfDisplayAttributeInfo) return E_NOINTERFACE;
        *out = static_cast<ITfDisplayAttributeInfo*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE GetGUID(GUID* guid) override { if (!guid) return E_POINTER; *guid = rq::displayAttribute; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDescription(BSTR* text) override {
        if (!text) return E_POINTER; *text = SysAllocString(L"Rime Q 组合文本"); return *text ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE GetAttributeInfo(TF_DISPLAYATTRIBUTE* a) override {
        if (!a) return E_POINTER; *a = {};
        a->crText.type = TF_CT_NONE; a->crBk.type = TF_CT_NONE; a->lsStyle = TF_LS_DOT;
        a->crLine.type = TF_CT_SYSCOLOR; a->crLine.nIndex = COLOR_WINDOWTEXT; a->bAttr = TF_ATTR_INPUT; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetAttributeInfo(const TF_DISPLAYATTRIBUTE*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Reset() override { return S_OK; }
};
class AttributeEnum final : public IEnumTfDisplayAttributeInfo {
    long references_ = 1; bool used_ = false;
public:
    explicit AttributeEnum(bool used = false) : used_(used) { InterlockedIncrement(&rqObjects); }
    ~AttributeEnum() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IEnumTfDisplayAttributeInfo) return E_NOINTERFACE;
        *out = static_cast<IEnumTfDisplayAttributeInfo*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Clone(IEnumTfDisplayAttributeInfo** out) override {
        if (!out) return E_POINTER; *out = new (std::nothrow) AttributeEnum(used_); return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE Next(ULONG count, ITfDisplayAttributeInfo** out, ULONG* fetched) override {
        if (!out || (!fetched && count != 1)) return E_POINTER; if (fetched) *fetched = 0;
        if (!count) return S_OK; if (used_) return S_FALSE;
        *out = new (std::nothrow) Attribute(); if (!*out) return E_OUTOFMEMORY;
        used_ = true; if (fetched) *fetched = 1; return count == 1 ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Reset() override { used_ = false; return S_OK; }
    HRESULT STDMETHODCALLTYPE Skip(ULONG count) override {
        if (!count) return S_OK; bool old = used_; used_ = true; return !old && count == 1 ? S_OK : S_FALSE;
    }
};
class Element final : public ITfCandidateListUIElementBehavior {
    long references_ = 1;
public:
    rq::State state;
    ComPtr<ITfDocumentMgr> document;
    std::function<void(unsigned)> select;
    std::function<void()> abort;
    bool shown = true;
    Element() { InterlockedIncrement(&rqObjects); }
    ~Element() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ITfUIElement && iid != IID_ITfCandidateListUIElement && iid != IID_ITfCandidateListUIElementBehavior)
            return E_NOINTERFACE;
        *out = static_cast<ITfCandidateListUIElementBehavior*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE GetDescription(BSTR* out) override { if (!out) return E_POINTER; *out = SysAllocString(L"Rime Q 候选"); return *out ? S_OK : E_OUTOFMEMORY; }
    HRESULT STDMETHODCALLTYPE GetGUID(GUID* out) override { if (!out) return E_POINTER; *out = rq::profile; return S_OK; }
    HRESULT STDMETHODCALLTYPE Show(BOOL show) override { shown = show != FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE IsShown(BOOL* out) override { if (!out) return E_POINTER; *out = shown; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetUpdatedFlags(DWORD* out) override {
        if (!out) return E_POINTER; *out = TF_CLUIE_COUNT | TF_CLUIE_SELECTION | TF_CLUIE_STRING | TF_CLUIE_PAGEINDEX | TF_CLUIE_CURRENTPAGE; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDocumentMgr(ITfDocumentMgr** out) override { return document.CopyTo(out); }
    HRESULT STDMETHODCALLTYPE GetCount(UINT* out) override { if (!out) return E_POINTER; *out = static_cast<UINT>(state.candidates.size()); return S_OK; }
    HRESULT STDMETHODCALLTYPE GetSelection(UINT* out) override { if (!out) return E_POINTER; *out = state.highlighted; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetString(UINT index, BSTR* out) override {
        if (!out) return E_POINTER; *out = nullptr; if (index >= state.candidates.size()) return E_INVALIDARG;
        try { *out = SysAllocString(rq::wide(state.candidates[index].text).c_str()); return *out ? S_OK : E_OUTOFMEMORY; } catch (...) { return E_FAIL; }
    }
    HRESULT STDMETHODCALLTYPE GetPageIndex(UINT* out, UINT size, UINT* count) override {
        if (!count) return E_POINTER; *count = 1; if (!size) return S_FALSE; if (!out) return E_POINTER; *out = 0; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetPageIndex(UINT*, UINT) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetCurrentPage(UINT* out) override { if (!out) return E_POINTER; *out = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE SetSelection(UINT index) override { if (index >= state.candidates.size()) return E_INVALIDARG; state.highlighted = index; return S_OK; }
    HRESULT STDMETHODCALLTYPE Finalize() override { if (select) select(state.highlighted); return S_OK; }
    HRESULT STDMETHODCALLTYPE Abort() override { if (abort) abort(); return S_OK; }
};
class LanguageBar final : public ITfLangBarItemButton, public ITfSource {
    long references_ = 1;
    ComPtr<ITfLangBarItemSink> sink_;
public:
    std::function<void(UINT)> action;
    LanguageBar() { InterlockedIncrement(&rqObjects); }
    ~LanguageBar() { InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_ITfLangBarItem || iid == IID_ITfLangBarItemButton) *out = static_cast<ITfLangBarItemButton*>(this);
        else if (iid == IID_ITfSource) *out = static_cast<ITfSource*>(this); else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE GetInfo(TF_LANGBARITEMINFO* out) override {
        if (!out) return E_POINTER; *out = {}; out->clsidService = rq::clsid; out->guidItem = rq::languageBar;
        out->dwStyle = TF_LBI_STYLE_BTN_MENU | TF_LBI_STYLE_SHOWNINTRAY; wcscpy_s(out->szDescription, L"Rime Q"); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetStatus(DWORD* out) override { if (!out) return E_POINTER; *out = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE Show(BOOL) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetTooltipString(BSTR* out) override { return GetText(out); }
    HRESULT STDMETHODCALLTYPE OnClick(TfLBIClick, POINT, const RECT*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE InitMenu(ITfMenu* menu) override {
        if (!menu) return E_POINTER;
        const wchar_t* items[] = {L"中 / 英", L"设置", L"个人数据文件夹", L"使用说明", L"检查更新", L"卸载 Rime Q"};
        for (UINT i = 0; i < 6; ++i) {
            HRESULT hr = menu->AddMenuItem(i, 0, nullptr, nullptr, items[i], static_cast<ULONG>(wcslen(items[i])), nullptr);
            if (FAILED(hr)) return hr;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnMenuSelect(UINT id) override { if (id > 5) return E_INVALIDARG; if (action) action(id); return S_OK; }
    HRESULT STDMETHODCALLTYPE GetIcon(HICON* out) override {
        if (!out) return E_POINTER; *out = static_cast<HICON>(LoadImageW(rqModule, MAKEINTRESOURCEW(101), IMAGE_ICON, 16, 16, 0)); return *out ? S_OK : E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE GetText(BSTR* out) override { if (!out) return E_POINTER; *out = SysAllocString(L"Rime Q"); return *out ? S_OK : E_OUTOFMEMORY; }
    HRESULT STDMETHODCALLTYPE AdviseSink(REFIID iid, IUnknown* unknown, DWORD* cookie) override {
        if (!cookie || !unknown) return E_POINTER; if (iid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
        if (sink_) return CONNECT_E_ADVISELIMIT; auto hr = unknown->QueryInterface(IID_PPV_ARGS(&sink_)); if (SUCCEEDED(hr)) *cookie = 1; return hr;
    }
    HRESULT STDMETHODCALLTYPE UnadviseSink(DWORD cookie) override { if (cookie != 1 || !sink_) return CONNECT_E_NOCONNECTION; sink_.Reset(); return S_OK; }
};

class Service final : public ITfTextInputProcessorEx, public ITfKeyEventSink, public ITfThreadMgrEventSink,
    public ITfCompositionSink, public ITfTextLayoutSink, public ITfTextEditSink, public ITfThreadFocusSink, public ITfDisplayAttributeProvider {
    long references_ = 1;
    ComPtr<ITfThreadMgr> manager_;
    ComPtr<ITfContext> context_;
    ComPtr<ITfComposition> composition_;
    struct Cancellation { ComPtr<ITfContext> context; ComPtr<ITfComposition> composition; bool done = false, clear = true; };
    std::vector<std::shared_ptr<Cancellation>> cancellations_;
    ComPtr<ITfUIElementMgr> uiManager_;
    ComPtr<Element> element_;
    ComPtr<LanguageBar> languageBar_;
    DWORD managerCookie_ = TF_INVALID_COOKIE, focusCookie_ = TF_INVALID_COOKIE, layoutCookie_ = TF_INVALID_COOKIE, editCookie_ = TF_INVALID_COOKIE;
    DWORD elementId_ = TF_INVALID_UIELEMENTID;
    TfClientId clientId_ = TF_CLIENTID_NULL;
    TfGuidAtom attribute_ = TF_INVALID_GUIDATOM;
    rq::Client client_;
    rq::State state_;
    std::unique_ptr<rq::CandidateWindow> window_;
    HWND timer_ = nullptr;
    bool shift_ = false, shiftUsed_ = false, ready_ = false, focused_ = true, ending_ = false;
    uint64_t generation_ = 0;
    ULONGLONG nextLaunch_ = 0;
    rq::fs::path application() const { return rq::modulePath(rqModule).parent_path().parent_path(); }
    bool current(ITfContext* context) const {
        if (!manager_ || !focused_) return false;
        ComPtr<ITfDocumentMgr> document; ComPtr<ITfContext> focused;
        return SUCCEEDED(manager_->GetFocus(&document)) && document && SUCCEEDED(document->GetTop(&focused)) && focused.Get() == context;
    }
    bool disabled(ITfContext* context) const {
        if (!context || !manager_) return true;
        ComPtr<ITfCompartmentMgr> compartments;
        if (FAILED(context->QueryInterface(IID_PPV_ARGS(&compartments)))) return false;
        for (auto guid : {GUID_COMPARTMENT_KEYBOARD_DISABLED, GUID_COMPARTMENT_EMPTYCONTEXT}) {
            ComPtr<ITfCompartment> compartment; VARIANT value; VariantInit(&value);
            if (SUCCEEDED(compartments->GetCompartment(guid, &compartment)) && SUCCEEDED(compartment->GetValue(&value))) {
                bool set = value.vt == VT_I4 && value.lVal != 0; VariantClear(&value); if (set) return true;
            }
        }
        return false;
    }
    bool password(ITfContext* context, TfEditCookie cookie) const {
        TF_SELECTION selection{}; ULONG fetched = 0;
        if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || !fetched) return true;
        ComPtr<ITfRange> range; range.Attach(selection.range); ComPtr<ITfReadOnlyProperty> property;
        if (FAILED(context->GetAppProperty(GUID_PROP_INPUTSCOPE, &property))) return false;
        VARIANT value; VariantInit(&value); bool blocked = false;
        if (SUCCEEDED(property->GetValue(cookie, range.Get(), &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
            ComPtr<ITfInputScope> scope;
            if (SUCCEEDED(value.punkVal->QueryInterface(IID_PPV_ARGS(&scope)))) {
                InputScope* scopes = nullptr; UINT count = 0;
                if (SUCCEEDED(scope->GetInputScopes(&scopes, &count))) {
                    for (UINT i = 0; i < count; ++i) if (scopes[i] == IS_PASSWORD) blocked = true;
                    CoTaskMemFree(scopes);
                }
            }
        }
        VariantClear(&value); return blocked;
    }
    void hide() {
        if (window_) window_->hide();
        if (element_) { element_->select = {}; element_->abort = {}; }
        if (uiManager_ && elementId_ != TF_INVALID_UIELEMENTID) uiManager_->EndUIElement(elementId_);
        elementId_ = TF_INVALID_UIELEMENTID; element_.Reset();
    }
    void bind(ITfContext* context) {
        if (context_.Get() == context) return;
        if (context_) {
            ComPtr<ITfSource> source; if (SUCCEEDED(context_.As(&source))) {
                if (layoutCookie_ != TF_INVALID_COOKIE) source->UnadviseSink(layoutCookie_);
                if (editCookie_ != TF_INVALID_COOKIE) source->UnadviseSink(editCookie_);
            }
        }
        layoutCookie_ = editCookie_ = TF_INVALID_COOKIE; context_ = context;
        if (context_) {
            ComPtr<ITfSource> source;
            if (SUCCEEDED(context_.As(&source))) {
                source->AdviseSink(IID_ITfTextLayoutSink, static_cast<ITfTextLayoutSink*>(this), &layoutCookie_);
                source->AdviseSink(IID_ITfTextEditSink, static_cast<ITfTextEditSink*>(this), &editCookie_);
            }
        }
    }
    HRESULT finish(TfEditCookie cookie, bool clear) {
        if (!composition_) return S_OK;
        auto composition = composition_; composition_.Reset();
        ComPtr<ITfRange> range; HRESULT hr = composition->GetRange(&range);
        if (SUCCEEDED(hr) && clear) hr = range->SetText(cookie, 0, L"", 0);
        if (range && context_) {
            ComPtr<ITfProperty> property;
            if (SUCCEEDED(context_->GetProperty(GUID_PROP_ATTRIBUTE, &property))) property->Clear(cookie, range.Get());
        }
        ending_ = true; auto ended = composition->EndComposition(cookie); ending_ = false;
        return FAILED(hr) ? hr : ended;
    }
    void cancel(bool clear = true) {
        ++generation_; shift_ = shiftUsed_ = false; hide();
        rq::State ignored;
        if (client_.connected() && !client_.exchange({rq::Command::clear}, ignored)) ready_ = false;
        state_.preedit.clear(); state_.candidates.clear();
        if (!context_ || !composition_) return;
        // Capture only the old composition/context. A delayed cancellation never sees a new field.
        cancellations_.erase(std::remove_if(cancellations_.begin(), cancellations_.end(), [](const auto& item) { return item->done; }), cancellations_.end());
        auto pending = std::make_shared<Cancellation>(); pending->context = context_; pending->composition = composition_;
        pending->clear = clear;
        cancellations_.push_back(pending); auto context = context_; composition_.Reset();
        auto edit = new (std::nothrow) Edit([pending](TfEditCookie cookie) {
            if (pending->done) return S_OK;
            auto composition = pending->composition; auto context = pending->context;
            ComPtr<ITfRange> range; auto hr = composition->GetRange(&range);
            if (SUCCEEDED(hr) && pending->clear) hr = range->SetText(cookie, 0, L"", 0);
            ComPtr<ITfProperty> property;
            if (range && SUCCEEDED(context->GetProperty(GUID_PROP_ATTRIBUTE, &property))) property->Clear(cookie, range.Get());
            pending->done = true;
            composition->EndComposition(cookie); pending->composition.Reset(); pending->context.Reset(); return hr;
        });
        if (!edit) return; HRESULT result = E_FAIL;
        context->RequestEditSession(clientId_, edit, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE, &result); edit->Release();
    }
    HRESULT updateText(ITfContext* context, TfEditCookie cookie, const rq::State& state) {
        if (!state.commit.empty()) {
            auto commit = rq::wide(state.commit);
            if (composition_) {
                ComPtr<ITfRange> range; auto hr = composition_->GetRange(&range); if (FAILED(hr)) return hr;
                hr = range->SetText(cookie, 0, commit.c_str(), static_cast<LONG>(commit.size())); if (FAILED(hr)) return hr;
                range->Collapse(cookie, TF_ANCHOR_END); TF_SELECTION selection{range.Get(), {TF_AE_NONE, FALSE}};
                hr = context->SetSelection(cookie, 1, &selection); if (FAILED(hr)) return hr;
                hr = finish(cookie, false); if (FAILED(hr)) return hr;
            } else {
                ComPtr<ITfInsertAtSelection> insert; auto hr = context->QueryInterface(IID_PPV_ARGS(&insert)); if (FAILED(hr)) return hr;
                ComPtr<ITfRange> range; hr = insert->InsertTextAtSelection(cookie, 0, commit.c_str(), static_cast<LONG>(commit.size()), &range);
                if (FAILED(hr)) return hr;
            }
        }
        if (state.preedit.empty()) return finish(cookie, true);
        if (!composition_) {
            ComPtr<ITfInsertAtSelection> insert; auto hr = context->QueryInterface(IID_PPV_ARGS(&insert)); if (FAILED(hr)) return hr;
            ComPtr<ITfRange> range; hr = insert->InsertTextAtSelection(cookie, TF_IAS_QUERYONLY, L"", 0, &range); if (FAILED(hr)) return hr;
            ComPtr<ITfContextComposition> composition; hr = context->QueryInterface(IID_PPV_ARGS(&composition)); if (FAILED(hr)) return hr;
            hr = composition->StartComposition(cookie, range.Get(), static_cast<ITfCompositionSink*>(this), &composition_); if (FAILED(hr) || !composition_) return E_FAIL;
        }
        ComPtr<ITfRange> range; auto hr = composition_->GetRange(&range); if (FAILED(hr)) return hr;
        auto preedit = rq::wide(state.preedit); hr = range->SetText(cookie, 0, preedit.c_str(), static_cast<LONG>(preedit.size())); if (FAILED(hr)) return hr;
        ComPtr<ITfProperty> property;
        if (attribute_ != TF_INVALID_GUIDATOM && SUCCEEDED(context->GetProperty(GUID_PROP_ATTRIBUTE, &property))) {
            VARIANT value; VariantInit(&value); value.vt = VT_I4; value.lVal = attribute_; property->SetValue(cookie, range.Get(), &value);
        }
        ComPtr<ITfRange> caret; hr = range->Clone(&caret); if (FAILED(hr)) return hr;
        caret->Collapse(cookie, TF_ANCHOR_START); LONG shifted = 0;
        caret->ShiftStart(cookie, static_cast<LONG>(std::min<size_t>(state.cursor, preedit.size())), &shifted, nullptr);
        caret->Collapse(cookie, TF_ANCHOR_START); TF_SELECTION selection{caret.Get(), {TF_AE_NONE, FALSE}};
        return context->SetSelection(cookie, 1, &selection);
    }
    void present(TfEditCookie cookie) {
        if (!context_ || !composition_ || state_.candidates.empty() || !current(context_.Get())) { hide(); return; }
        ComPtr<ITfContextView> view; ComPtr<ITfRange> range; RECT caret{}; BOOL clipped = FALSE; HWND owner = nullptr;
        if (FAILED(context_->GetActiveView(&view)) || !view || FAILED(composition_->GetRange(&range))) { hide(); return; }
        range->Collapse(cookie, TF_ANCHOR_END);
        // If the host cannot report a caret, hide until its layout callback. Never position at an unrelated desktop caret.
        if (FAILED(view->GetTextExt(cookie, range.Get(), &caret, &clipped)) || clipped) { hide(); return; }
        view->GetWnd(&owner);
        if (!element_ && uiManager_) {
            element_.Attach(new Element()); element_->state = state_; context_->GetDocumentMgr(&element_->document);
            auto generation = generation_;
            element_->select = [this, generation](unsigned index) { if (generation == generation_) select(index); };
            element_->abort = [this, generation] { if (generation == generation_) cancel(); };
            BOOL show = TRUE;
            if (FAILED(uiManager_->BeginUIElement(element_.Get(), &show, &elementId_))) { elementId_ = TF_INVALID_UIELEMENTID; element_.Reset(); }
            else element_->shown = show != FALSE;
        }
        if (element_) {
            element_->state = state_; uiManager_->UpdateUIElement(elementId_);
            if (!element_->shown) { window_->hide(); return; }
        }
        window_->show(state_, caret, owner);
    }
    bool perform(ITfContext* context, const rq::Request& request) {
        if (!current(context) || disabled(context)) return false;
        if (context_.Get() != context) { cancel(); bind(context); }
        bool handled = false;
        auto edit = new (std::nothrow) Edit([&, context](TfEditCookie cookie) {
            if (!current(context) || password(context, cookie)) return S_FALSE;
            rq::State response;
            if (!client_.exchange(request, response) || !response.ready) {
                ready_ = false; client_.close(); finish(cookie, true); hide(); state_ = {}; return S_FALSE;
            }
            auto hr = updateText(context, cookie, response);
            if (FAILED(hr)) {
                client_.close(); ready_ = false; finish(cookie, true); hide(); state_ = {}; return hr;
            }
            state_ = std::move(response); handled = state_.handled;
            try { present(cookie); } catch (...) { hide(); } // UI failure cannot turn a successful commit into a second host key.
            return S_OK;
        });
        if (!edit) return false; HRESULT result = E_FAIL;
        // Obtain the host write lock before mutating the engine. No async key replay or double-processing in test callbacks.
        auto hr = context->RequestEditSession(clientId_, edit, TF_ES_SYNC | TF_ES_READWRITE, &result); edit->Release();
        return SUCCEEDED(hr) && SUCCEEDED(result) && handled;
    }
    void select(unsigned index) {
        if (context_ && index < state_.candidates.size()) perform(context_.Get(), {rq::Command::select, index});
    }
    bool interested(ITfContext* context, WPARAM key) {
        if (shift_ && key != VK_SHIFT && key != VK_LSHIFT && key != VK_RSHIFT) shiftUsed_ = true;
        if (!ready_ || !current(context) || disabled(context)) return false;
        if (GetKeyState(VK_CONTROL) < 0 || GetKeyState(VK_MENU) < 0 || GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) return false;
        if (key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT) return true;
        if (state_.ascii || (GetKeyState(VK_CAPITAL) & 1)) return false;
        if (key >= 'A' && key <= 'Z') return true;
        if (!state_.preedit.empty()) {
            return (key >= '0' && key <= '9') || (key >= VK_NUMPAD0 && key <= VK_DIVIDE) ||
                key == VK_SPACE || key == VK_RETURN || key == VK_ESCAPE || key == VK_BACK ||
                (key >= VK_PRIOR && key <= VK_DOWN) || key == VK_DELETE || (key >= VK_OEM_1 && key <= VK_OEM_8);
        }
        return false;
    }
    static uint32_t translate(WPARAM key, LPARAM lparam) {
        switch (key) {
        case VK_BACK: return 0xff08; case VK_TAB: return 0xff09; case VK_RETURN: return 0xff0d;
        case VK_ESCAPE: return 0xff1b; case VK_DELETE: return 0xffff; case VK_LEFT: return 0xff51;
        case VK_UP: return 0xff52; case VK_RIGHT: return 0xff53; case VK_DOWN: return 0xff54;
        case VK_PRIOR: return 0xff55; case VK_NEXT: return 0xff56; case VK_HOME: return 0xff50; case VK_END: return 0xff57;
        }
        BYTE keyboard[256]{}; GetKeyboardState(keyboard); wchar_t text[8]{};
        int count = ToUnicodeEx(static_cast<UINT>(key), (static_cast<UINT>(lparam) >> 16) & 0xff,
            keyboard, text, 8, 4, GetKeyboardLayout(0)); // TU_NO_STATE_CHANGE avoids consuming dead-key state.
        return count == 1 && text[0] >= 32 && text[0] < 127 ? text[0] : 0;
    }
    static LRESULT CALLBACK timerProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        auto self = reinterpret_cast<Service*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            self = static_cast<Service*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (self && message == WM_TIMER && !self->ready_) {
            rq::State state;
            if (self->client_.exchange({rq::Command::hello}, state, 30) && state.ready) { self->ready_ = true; self->state_ = std::move(state); }
            else if (GetTickCount64() >= self->nextLaunch_) {
                self->nextLaunch_ = GetTickCount64() + 10000;
                rq::launch(self->application() / L"RimeQ.Broker.exe", L"--serve");
            }
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }
public:
    Service() { InterlockedIncrement(&rqObjects); }
    ~Service() { Deactivate(); InterlockedDecrement(&rqObjects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_ITfTextInputProcessor || iid == IID_ITfTextInputProcessorEx) *out = static_cast<ITfTextInputProcessorEx*>(this);
        else if (iid == IID_ITfKeyEventSink) *out = static_cast<ITfKeyEventSink*>(this);
        else if (iid == IID_ITfThreadMgrEventSink) *out = static_cast<ITfThreadMgrEventSink*>(this);
        else if (iid == IID_ITfCompositionSink) *out = static_cast<ITfCompositionSink*>(this);
        else if (iid == IID_ITfTextLayoutSink) *out = static_cast<ITfTextLayoutSink*>(this);
        else if (iid == IID_ITfTextEditSink) *out = static_cast<ITfTextEditSink*>(this);
        else if (iid == IID_ITfThreadFocusSink) *out = static_cast<ITfThreadFocusSink*>(this);
        else if (iid == IID_ITfDisplayAttributeProvider) *out = static_cast<ITfDisplayAttributeProvider*>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override { auto n = InterlockedDecrement(&references_); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr* manager, TfClientId id) override { return ActivateEx(manager, id, 0); }
    HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* manager, TfClientId id, DWORD flags) override {
        if (!manager) return E_INVALIDARG;
        if (flags & (TF_TMAE_SECUREMODE | TF_TMAE_COMLESS)) return E_FAIL;
        try {
            if (manager_) return E_UNEXPECTED; manager_ = manager; clientId_ = id; focused_ = true;
            ComPtr<ITfKeystrokeMgr> keys; auto hr = manager_.As(&keys);
            if (SUCCEEDED(hr)) hr = keys->AdviseKeyEventSink(id, static_cast<ITfKeyEventSink*>(this), TRUE);
            ComPtr<ITfSource> source; if (SUCCEEDED(hr)) hr = manager_.As(&source);
            if (SUCCEEDED(hr)) hr = source->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink*>(this), &managerCookie_);
            if (SUCCEEDED(hr)) hr = source->AdviseSink(IID_ITfThreadFocusSink, static_cast<ITfThreadFocusSink*>(this), &focusCookie_);
            if (FAILED(hr)) { Deactivate(); return hr; }
            manager_.As(&uiManager_);
            ComPtr<ITfCategoryMgr> categories;
            if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&categories))))
                categories->RegisterGUID(rq::displayAttribute, &attribute_);
            window_ = std::make_unique<rq::CandidateWindow>(rqModule, [this](unsigned index) { select(index); });
            languageBar_.Attach(new LanguageBar());
            languageBar_->action = [this](UINT action) {
                if (!action) { if (context_) perform(context_.Get(), {rq::Command::toggle}); return; }
                const wchar_t* arguments[] = {L"", L"--settings", L"--data", L"--help", L"--updates", L"--uninstall"};
                rq::launch(application() / L"RimeQ.exe", arguments[action]);
            };
            ComPtr<ITfLangBarItemMgr> bar; if (SUCCEEDED(manager_.As(&bar))) bar->AddItem(languageBar_.Get());
            WNDCLASSEXW wc{sizeof(wc)}; wc.hInstance = rqModule; wc.lpfnWndProc = timerProcedure; wc.lpszClassName = L"RimeQ.TsfTimer.v1";
            RegisterClassExW(&wc); timer_ = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, rqModule, this);
            if (timer_) SetTimer(timer_, 1, 500, nullptr);
            rq::State state;
            if (client_.exchange({rq::Command::hello}, state, 150) && state.ready) { ready_ = true; state_ = std::move(state); }
            else rq::launch(application() / L"RimeQ.Broker.exe", L"--serve");
            ComPtr<ITfDocumentMgr> document; ComPtr<ITfContext> context;
            if (SUCCEEDED(manager_->GetFocus(&document)) && document && SUCCEEDED(document->GetTop(&context))) bind(context.Get());
            return S_OK;
        } catch (...) { Deactivate(); return E_FAIL; }
    }
    HRESULT STDMETHODCALLTYPE Deactivate() override {
        if (!manager_) return S_OK;
        cancel(); bind(nullptr); client_.close(); ready_ = false;
        if (timer_) { KillTimer(timer_, 1); DestroyWindow(timer_); timer_ = nullptr; }
        ComPtr<ITfKeystrokeMgr> keys; if (SUCCEEDED(manager_.As(&keys))) keys->UnadviseKeyEventSink(clientId_);
        ComPtr<ITfSource> source;
        if (SUCCEEDED(manager_.As(&source))) {
            if (managerCookie_ != TF_INVALID_COOKIE) source->UnadviseSink(managerCookie_);
            if (focusCookie_ != TF_INVALID_COOKIE) source->UnadviseSink(focusCookie_);
        }
        if (languageBar_) {
            languageBar_->action = {}; ComPtr<ITfLangBarItemMgr> bar;
            if (SUCCEEDED(manager_.As(&bar))) bar->RemoveItem(languageBar_.Get()); languageBar_.Reset();
        }
        window_.reset(); uiManager_.Reset(); manager_.Reset(); clientId_ = TF_CLIENTID_NULL;
        managerCookie_ = focusCookie_ = TF_INVALID_COOKIE; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL foreground) override { if (!foreground) cancel(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext* context, WPARAM key, LPARAM, BOOL* eaten) override {
        if (!eaten) return E_POINTER; *eaten = interested(context, key); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext*, WPARAM key, LPARAM, BOOL* eaten) override {
        if (!eaten) return E_POINTER; *eaten = shift_ && (key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* context, WPARAM key, LPARAM lparam, BOOL* eaten) override {
        if (!eaten) return E_POINTER; *eaten = FALSE;
        if (!interested(context, key)) return S_OK;
        if (key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT) { if (!shift_) { shift_ = true; shiftUsed_ = false; } *eaten = TRUE; return S_OK; }
        auto translated = translate(key, lparam); if (!translated) return S_OK;
        uint32_t modifiers = (GetKeyState(VK_SHIFT) < 0 ? 1u : 0u);
        *eaten = perform(context, {rq::Command::key, translated, modifiers}); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* context, WPARAM key, LPARAM, BOOL* eaten) override {
        if (!eaten) return E_POINTER; *eaten = FALSE;
        if (shift_ && (key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT)) {
            bool toggle = !shiftUsed_ && GetKeyState(VK_CONTROL) >= 0 && GetKeyState(VK_MENU) >= 0;
            shift_ = shiftUsed_ = false; *eaten = TRUE; if (toggle) perform(context, {rq::Command::toggle});
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) override { if (!eaten) return E_POINTER; *eaten = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE OnInitDocumentMgr(ITfDocumentMgr*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnUninitDocumentMgr(ITfDocumentMgr* document) override {
        if (context_) { ComPtr<ITfDocumentMgr> current; context_->GetDocumentMgr(&current); if (current.Get() == document) { cancel(); bind(nullptr); } } return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnSetFocus(ITfDocumentMgr* focus, ITfDocumentMgr*) override {
        ComPtr<ITfContext> context; if (focus) focus->GetTop(&context);
        if (context_.Get() != context.Get()) { cancel(); bind(context.Get()); } return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPushContext(ITfContext* context) override { if (current(context)) { cancel(); bind(context); } return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPopContext(ITfContext* context) override { if (context_.Get() == context) { cancel(); bind(nullptr); } return S_OK; }
    HRESULT STDMETHODCALLTYPE OnCompositionTerminated(TfEditCookie cookie, ITfComposition* composition) override {
        if (ending_) return S_OK;
        for (auto pending : cancellations_) {
            if (!pending->done && pending->composition.Get() == composition) {
                pending->done = true; ComPtr<ITfRange> range;
                if (pending->clear && SUCCEEDED(composition->GetRange(&range))) range->SetText(cookie, 0, L"", 0);
                pending->composition.Reset(); pending->context.Reset(); return S_OK;
            }
        }
        if (composition_.Get() != composition) return S_OK;
        composition_.Reset(); ComPtr<ITfRange> range;
        if (SUCCEEDED(composition->GetRange(&range))) range->SetText(cookie, 0, L"", 0);
        ++generation_; hide(); rq::State ignored; client_.exchange({rq::Command::clear}, ignored); state_.preedit.clear(); state_.candidates.clear(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnLayoutChange(ITfContext* context, TfLayoutCode code, ITfContextView*) override {
        if (context_.Get() != context) return S_OK;
        if (code == TF_LC_DESTROY) { cancel(); return S_OK; }
        if (!composition_) return S_OK;
        auto edit = new (std::nothrow) Edit([this](TfEditCookie cookie) { present(cookie); return S_OK; });
        if (edit) { HRESULT result; context->RequestEditSession(clientId_, edit, TF_ES_SYNC | TF_ES_READ, &result); edit->Release(); } return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnEndEdit(ITfContext* context, TfEditCookie cookie, ITfEditRecord*) override {
        if (!composition_ || context_.Get() != context) return S_OK;
        try {
            ComPtr<ITfRange> range; if (FAILED(composition_->GetRange(&range))) return S_OK;
            auto expected = rq::wide(state_.preedit); std::wstring actual(expected.size() + 1, 0); ULONG length = 0;
            if (SUCCEEDED(range->GetText(cookie, 0, actual.data(), static_cast<ULONG>(actual.size()), &length))) {
                actual.resize(length);
                if (actual != expected) { cancel(false); return S_OK; } // Preserve text inserted by the host, e.g. paste/undo.
            }
            TF_SELECTION selection{}; ULONG fetched = 0;
            if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
                ComPtr<ITfRange> selected; selected.Attach(selection.range); LONG start = 0, end = 0;
                if (SUCCEEDED(range->CompareStart(cookie, selected.Get(), TF_ANCHOR_START, &start)) &&
                    SUCCEEDED(range->CompareEnd(cookie, selected.Get(), TF_ANCHOR_END, &end)) && (start > 0 || end < 0)) cancel();
            }
        } catch (...) { hide(); client_.close(); ready_ = false; }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnSetThreadFocus() override { focused_ = true; return S_OK; }
    HRESULT STDMETHODCALLTYPE OnKillThreadFocus() override { focused_ = false; cancel(); return S_OK; }
    HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** out) override {
        if (!out) return E_POINTER; *out = new (std::nothrow) AttributeEnum(); return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** out) override {
        if (!out) return E_POINTER; *out = nullptr; if (guid != rq::displayAttribute) return E_INVALIDARG;
        *out = new (std::nothrow) Attribute(); return *out ? S_OK : E_OUTOFMEMORY;
    }
};
}
HRESULT createService(REFIID iid, void** out) {
    auto service = new (std::nothrow) Service(); if (!service) return E_OUTOFMEMORY;
    auto hr = service->QueryInterface(iid, out); service->Release(); return hr;
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { rqModule = module; DisableThreadLibraryCalls(module); } return TRUE;
}
